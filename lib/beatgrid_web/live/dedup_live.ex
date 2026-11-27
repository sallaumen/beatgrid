defmodule BeatgridWeb.DedupLive do
  @moduledoc """
  Duplicatas — review duplicate groups and resolve each one by keeping the best
  copy and quarantining the rest (reversibly; never a delete). A manual "Procurar
  duplicatas" re-runs detection in the background; resolved groups carry a one-shot
  "Desfazer" that restores the quarantined files and re-opens the group.

  Picks (the chosen keeper per group) are ephemeral UI state: switching a radio
  never writes to the DB, so the cards never reorder mid-review. Only "Manter +
  quarentenar" and "Ignorar" mutate anything.
  """
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.{Dedup, Operations}
  alias Beatgrid.Workers.DedupWorker

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Dedup.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Duplicatas", scanning?: false, undo: nil)
     |> load()}
  end

  # Keep a review choice while the same pending group still contains that member.
  defp load(socket) do
    groups = Dedup.list_pending()
    previous = socket.assigns[:picks] || %{}

    picks =
      Map.new(groups, fn group ->
        selected = previous[group.id]
        {group.id, if(eligible_keeper?(group, selected), do: selected, else: keeper_of(group))}
      end)

    assign(socket, groups: groups, picks: picks)
  end

  # --- manual scan ---

  @impl true
  def handle_event("scan", _params, socket) do
    DedupWorker.enqueue(Uniq.UUID.uuid7())
    {:noreply, assign(socket, scanning?: true)}
  end

  # --- per-group keeper choice (ephemeral; no DB write) ---

  def handle_event("pick_keeper", %{"group" => gid, "track" => tid}, socket) do
    case Enum.find(socket.assigns.groups, &(&1.id == gid)) do
      nil ->
        {:noreply, socket}

      group ->
        if eligible_keeper?(group, tid),
          do: {:noreply, update(socket, :picks, &Map.put(&1, gid, tid))},
          else: {:noreply, socket}
    end
  end

  # --- resolve / ignore ---

  def handle_event("resolve", %{"group" => gid, "track" => keeper_id}, socket) do
    # The confirmation must correspond to the rendered keeper, not to a newer
    # server-side radio choice the browser has not rendered yet.
    with true <- socket.assigns.picks[gid] == keeper_id,
         %{status: :pending} = group <- Dedup.get_group(gid),
         true <- eligible_keeper?(group, keeper_id),
         true <- current_preview?(socket, group) do
      socket =
        case Dedup.resolve_group(gid, keeper_id) do
          {:ok, %{quarantined: n, failed: failures, batch_id: batch_id}} ->
            socket |> assign(undo: {:resolution, gid, batch_id, n, failures}) |> load()

          {:error, :keeper_unavailable} ->
            socket |> load() |> assign(undo: {:keeper_unavailable, gid})

          {:error, _reason} ->
            assign(socket, undo: {:error, gid})
        end

      {:noreply, socket}
    else
      _ -> {:noreply, socket |> load() |> assign(undo: {:stale, gid})}
    end
  end

  def handle_event("ignore", %{"group" => gid}, socket) do
    with true <- Map.has_key?(socket.assigns.picks, gid),
         %{status: :pending} <- Dedup.get_group(gid),
         {:ok, _} <- Dedup.ignore_group(gid) do
      {:noreply, socket |> assign(undo: nil) |> load()}
    else
      _ -> {:noreply, socket |> load() |> assign(undo: {:stale, gid})}
    end
  end

  # --- undo: restore the quarantined files + re-open the group ---

  def handle_event("undo", _params, socket) do
    case undo_batch_info(socket.assigns.undo) do
      {gid, batch_id} ->
        result = Operations.undo_batch(batch_id)
        {:noreply, finish_undo(socket, gid, batch_id, result)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("dismiss_undo", _params, socket), do: {:noreply, assign(socket, undo: nil)}

  # --- background scan progress ---

  @impl true
  def handle_info({:dedup_progress, %{status: :done}}, socket) do
    {:noreply, socket |> assign(scanning?: false) |> load()}
  end

  def handle_info({:dedup_progress, %{status: :running}}, socket) do
    {:noreply, assign(socket, scanning?: true)}
  end

  def handle_info({:dedup_progress, _payload}, socket), do: {:noreply, socket}

  defp finish_undo(socket, gid, _batch_id, {:ok, %{failed: 0}}) do
    case Dedup.get_group(gid) do
      nil -> :ok
      group -> Dedup.set_group_status(group, :pending)
    end

    socket |> assign(undo: nil) |> load()
  end

  defp finish_undo(socket, gid, batch_id, {:ok, %{undone: n, failed: failed}}),
    do: socket |> assign(undo: {:undo_partial, gid, batch_id, n, failed}) |> load()

  defp undo_batch_info({:resolution, gid, batch_id, n, failures}) when n > 0 or failures == [],
    do: {gid, batch_id}

  defp undo_batch_info({:undo_partial, gid, batch_id, _n, _failed}), do: {gid, batch_id}
  defp undo_batch_info(_), do: nil

  # --- helpers ---

  defp eligible_keeper?(%{members: members}, tid),
    do: Enum.any?(members, &(&1.track_id == tid and &1.track.status == :present))

  # The confirmation describes this exact member set, paths and version IDs.
  # Changes that alter any outcome require another look at the updated group.
  defp current_preview?(socket, group) do
    case Enum.find(socket.assigns.groups, &(&1.id == group.id)) do
      nil -> false
      displayed -> preview_snapshot(displayed) == preview_snapshot(group)
    end
  end

  defp preview_snapshot(group) do
    Map.new(group.members, fn member ->
      {member.track_id, {member.track.rel_path, member.track.status, Dedup.member_isrc(member)}}
    end)
  end

  defp keeper_of(%{keeper_track_id: id} = group) when not is_nil(id) do
    if eligible_keeper?(group, id), do: id, else: keeper_of(%{members: group.members})
  end

  defp keeper_of(%{members: members}) do
    present = Enum.filter(members, &(&1.track.status == :present))

    case Enum.find(present, & &1.is_keeper) || List.first(present) do
      nil -> nil
      member -> member.track_id
    end
  end

  # How many will actually be quarantined: non-keepers MINUS the ones spared as a
  # different recording (different ISRC), which we keep on purpose.
  defp non_keeper_count(group, keeper_id) do
    keeper_isrc = group.members |> Enum.find(&(&1.track_id == keeper_id)) |> Dedup.member_isrc()

    Enum.count(group.members, fn m ->
      m.track_id != keeper_id and m.track.status != :quarantined and
        not Dedup.different_recording?(m, keeper_isrc)
    end)
  end

  defp match_label(:exact_hash), do: "exata"
  defp match_label(:fuzzy_meta), do: "parecida"
  defp match_label(:near_meta), do: "quase igual"
  defp match_label(_other), do: "duplicada"

  defp match_description(:exact_hash), do: "Mesmo hash de arquivo."
  defp match_description(:fuzzy_meta), do: "Artista e título normalizados coincidem."
  defp match_description(:near_meta), do: "Artista e título-base iguais, durações próximas."
  defp match_description(_), do: "Compare as gravações antes de decidir."

  # Exact-hash matches are certain (amber); fuzzy meta-matches are softer
  # (violet); near matches (base title + duration) are the softest (teal).
  defp match_color(:exact_hash), do: "var(--color-amber)"
  defp match_color(:near_meta), do: "var(--color-green)"
  defp match_color(_fuzzy), do: "var(--color-primary)"

  defp artist_title(track) do
    artist =
      present_str(track.tag_artist) || present_str(track.norm_artist) || "Artista desconhecido"

    title = present_str(track.tag_title) || present_str(track.norm_title) || track.filename
    {artist, title}
  end

  # A group's members share artist and title by construction, so the first one
  # names the whole group — what the repeated card buttons need to tell apart the
  # group they act on (the signature can be a bare content hash).
  defp group_label(members) do
    case List.first(members) do
      nil ->
        "grupo sem faixas"

      member ->
        {artist, title} = artist_title(member.track)
        "#{artist} — #{title}"
    end
  end

  defp present_str(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_str(_), do: nil

  # Keep each measurement on the same grid across members so different copies
  # can be compared without searching a varying string of dot-separated values.
  defp quality_fields(track, member, show_isrc?) do
    fields = [
      {"Bitrate", bitrate_part(track.bitrate_kbps)},
      {"Duração", duration_part(track.duration_ms)},
      {"Formato", format_part(track.format)},
      {"Pasta", placement_part(track)},
      {"Metadados", resolved_part(track)},
      {"Nota", track.rating}
    ]

    if show_isrc?, do: fields ++ [{"ISRC", Dedup.member_isrc(member)}], else: fields
  end

  defp bitrate_part(kbps) when is_integer(kbps) and kbps > 0, do: "#{kbps} kbps"
  defp bitrate_part(_), do: nil

  defp duration_part(ms) when is_integer(ms) and ms > 0 do
    secs = div(ms, 1000)
    "#{div(secs, 60)}:#{String.pad_leading(to_string(rem(secs, 60)), 2, "0")}"
  end

  defp duration_part(_), do: nil

  defp format_part(format) when is_atom(format) and not is_nil(format),
    do: format |> to_string() |> String.upcase()

  defp format_part(_), do: nil

  defp placement_part(%{status: :quarantined}), do: "quarentena"
  defp placement_part(%{genre_folder: nil}), do: "Inbox"
  defp placement_part(%{genre_folder: key}), do: folder_label(key)

  defp resolved_part(%{soundcharts_song_id: id}) when not is_nil(id), do: "resolvida"
  defp resolved_part(_), do: "sem match"

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell flash={@flash} active={:dedup} socket={@socket}>
      <div class="flex min-w-0 flex-col">
        <header class="flex flex-wrap items-center justify-between gap-4 border-b border-white/6 bg-rail px-5 py-3">
          <div class="flex items-baseline gap-3">
            <h1 class="text-[22px] font-semibold">Duplicatas</h1>
            <span class="font-mono text-body-sm text-ink-muted">{group_count(@groups)}</span>
          </div>
          <button
            phx-click="scan"
            disabled={@scanning?}
            class="flex items-center gap-2 rounded-md bg-primary-deep px-3 py-2 text-body font-semibold text-white disabled:cursor-not-allowed disabled:opacity-60"
          >
            <span
              :if={@scanning?}
              class="size-2 motion-safe:animate-pulse rounded-full bg-white"
              aria-hidden="true"
            />
            <span class={[!@scanning? && "hero-magnifying-glass size-4"]} aria-hidden="true" />
            {if @scanning?, do: "Procurando…", else: "Procurar duplicatas"}
          </button>
        </header>

        <.undo_toast :if={@undo} undo={@undo} />

        <div class="mx-auto w-full max-w-[1600px] px-4 py-4 sm:px-5">
          <div class="mb-4 flex flex-wrap items-center justify-between gap-2 text-body">
            <p class="text-ink-muted">
              Compare os arquivos, artista e título de cada gravação antes de escolher qual cópia manter.
            </p>
            <.link navigate={~p"/resgate" <> "#quarentena"} class="text-primary hover:underline">
              Recuperar cópias da quarentena
            </.link>
          </div>

          <div :if={@groups != []} class="space-y-3">
            <.group_card :for={group <- @groups} group={group} pick={@picks[group.id]} />
          </div>

          <div
            :if={@groups == []}
            class="flex items-start gap-3 rounded-xl border border-white/8 bg-surface px-4 py-5"
            role="status"
          >
            <.icon
              name={if @scanning?, do: "hero-magnifying-glass", else: "hero-check-circle"}
              class="size-6 shrink-0 text-ink-muted"
            />
            <div>
              <p class="text-body-lg font-semibold text-ink">
                {if @scanning?, do: "Busca em andamento", else: "Nenhuma duplicata pendente."}
              </p>
              <p class="mt-1 text-body text-ink-muted">
                {if @scanning?,
                  do: "Os grupos aparecem ao concluir a busca.",
                  else: "Use Procurar duplicatas para conferir a biblioteca novamente."}
              </p>
            </div>
          </div>
        </div>
      </div>
    </.app_shell>
    """
  end

  attr :group, :map, required: true
  attr :pick, :string, default: nil

  defp group_card(assigns) do
    keeper_id = assigns.pick || keeper_of(assigns.group)
    keeper = Enum.find(assigns.group.members, &(&1.track_id == keeper_id))
    quarantine_count = non_keeper_count(assigns.group, keeper_id)

    assigns =
      assign(assigns,
        keeper_id: keeper_id,
        keeper_path: keeper && keeper.track.rel_path,
        show_isrc?: Enum.any?(assigns.group.members, &(not is_nil(Dedup.member_isrc(&1)))),
        keeper_isrc: Dedup.member_isrc(keeper),
        members: assigns.group.members,
        group_label: group_label(assigns.group.members),
        previously_quarantined:
          Enum.count(assigns.group.members, &(&1.track.status == :quarantined)),
        kept_count:
          Enum.count(assigns.group.members, &(&1.track.status != :quarantined)) - quarantine_count,
        quarantine_count: quarantine_count
      )

    ~H"""
    <article
      id={"dedup-group-#{@group.id}"}
      aria-labelledby={"group-#{@group.id}"}
      class="overflow-hidden rounded-xl border border-white/8 bg-surface"
    >
      <header class="border-b border-white/6 px-4 py-3">
        <div class="flex flex-wrap items-center gap-2">
          <h2
            id={"group-#{@group.id}"}
            class="min-w-0 break-words text-body-lg font-semibold text-ink"
          >
            {@group_label}
          </h2>
          <span
            class="bg-token-chip inline-flex items-center rounded-xs px-[7px] py-[2px] text-[9.5px] font-bold uppercase tracking-wide"
            style={"--c:#{match_color(@group.match_type)}"}
          >
            {match_label(@group.match_type)}
          </span>
          <span class="ml-auto shrink-0 font-mono text-body-sm text-ink-muted">
            {length(@members)} {copy_label(length(@members))}
          </span>
        </div>
        <p title={@group.signature} class="mt-1 text-body-sm text-ink-muted">
          {match_description(@group.match_type)}
        </p>
      </header>

      <div
        role="radiogroup"
        aria-label={"Cópia a manter — #{@group_label}"}
        class="divide-y divide-white/6"
      >
        <.member_row
          :for={member <- @members}
          group_id={@group.id}
          member={member}
          chosen={member.track_id == @keeper_id}
          recommended?={member.track_id == keeper_of(@group)}
          show_isrc?={@show_isrc?}
          different?={
            member.track_id != @keeper_id and Dedup.different_recording?(member, @keeper_isrc)
          }
        />
      </div>

      <footer class="flex flex-wrap items-center justify-end gap-2 border-t border-white/6 px-4 py-3">
        <p :if={!@keeper_id} class="mr-auto text-body text-coral">
          Nenhuma cópia disponível para manter. Confira os arquivos antes de procurar duplicatas novamente.
        </p>
        <p :if={@keeper_id} class="mr-auto text-body text-ink-secondary">
          <span class="font-mono text-green">{@kept_count}</span>
          {if @kept_count == 1, do: "cópia será mantida", else: "cópias serão mantidas"}
          <span class="mx-1.5 text-ink-muted">·</span>
          <span class="font-mono text-amber">{@quarantine_count}</span>
          {copy_label(@quarantine_count)} para a quarentena
          <span :if={@previously_quarantined > 0}> · {@previously_quarantined} já na quarentena</span>
        </p>
        <button
          :if={@keeper_id && @quarantine_count > 0}
          phx-click="ignore"
          phx-value-group={@group.id}
          aria-label={"#{if @previously_quarantined > 0, do: "Manter as restantes", else: "Manter todas as cópias"} — #{@group_label}"}
          class="rounded-md border border-white/10 bg-input px-3 py-2 text-body text-ink-secondary hover:text-ink"
        >
          {if @previously_quarantined > 0, do: "Manter as restantes", else: "Manter todas as cópias"}
        </button>
        <button
          :if={@keeper_id}
          phx-click="resolve"
          phx-value-group={@group.id}
          phx-value-track={@keeper_id}
          data-confirm={confirm_resolution(@keeper_path, @quarantine_count)}
          aria-label={"#{resolve_label(@quarantine_count)} — #{@keeper_path}"}
          class="rounded-md bg-green px-3 py-2 text-body font-semibold text-[#0b0c10] hover:bg-green/90"
        >
          {resolve_label(@quarantine_count)}
        </button>
      </footer>
    </article>
    """
  end

  attr :group_id, :string, required: true
  attr :member, :map, required: true
  attr :chosen, :boolean, required: true
  attr :different?, :boolean, default: false
  attr :recommended?, :boolean, default: false
  attr :show_isrc?, :boolean, default: false

  defp member_row(assigns) do
    {artist, title} = artist_title(assigns.member.track)
    assigns = assign(assigns, artist: artist, title: title)

    ~H"""
    <div
      id={"copy-#{@member.track_id}"}
      class={[
        "grid min-w-0 grid-cols-[auto_minmax(0,1fr)] items-start gap-x-3 gap-y-3 px-4 py-3 lg:grid-cols-[auto_minmax(0,1.25fr)_minmax(0,1fr)_minmax(9rem,auto)]",
        @chosen && "bg-green/5"
      ]}
    >
      <.cover_play
        src={cover_src(@member.track)}
        artist={@artist}
        size={40}
        play_src={~p"/audio/#{@member.track.id}"}
        track_id={@member.track.id}
      />

      <div class="min-w-0">
        <.link
          navigate={~p"/track/#{@member.track.id}"}
          class="block break-words text-body-lg font-semibold text-ink hover:text-primary hover:underline"
        >
          {@title}
        </.link>
        <p class="break-words text-body text-ink-secondary">{@artist}</p>
        <p :if={@recommended?} class="mt-1 text-body-sm font-medium text-primary">Recomendada</p>
        <p class="mt-1 break-words font-mono text-body-sm text-ink-muted [overflow-wrap:anywhere]">
          {@member.track.rel_path}
        </p>
      </div>

      <dl class="col-span-2 grid min-w-0 grid-cols-2 gap-x-3 gap-y-2 sm:grid-cols-3 lg:col-span-1">
        <div
          :for={{label, value} <- quality_fields(@member.track, @member, @show_isrc?)}
          class="min-w-0"
        >
          <dt class="text-caption text-ink-muted">{label}</dt>
          <dd class="break-words font-mono text-body font-medium text-ink-secondary">
            {value || "—"}
          </dd>
        </div>
      </dl>

      <div class="col-span-2 min-w-0 lg:col-span-1">
        <label class={[
          "flex min-h-10 cursor-pointer items-center gap-2 rounded-md border px-3 py-2 text-body font-medium",
          @chosen && "border-green/40 bg-green/10 text-green",
          !@chosen && "border-white/10 bg-input text-ink-secondary hover:text-ink",
          @member.track.status != :present && "cursor-not-allowed opacity-60"
        ]}>
          <input
            type="radio"
            id={"keeper-#{@member.track_id}"}
            name={"keeper-#{@group_id}"}
            phx-click="pick_keeper"
            phx-value-group={@group_id}
            phx-value-track={@member.track_id}
            checked={@chosen}
            disabled={@member.track.status != :present}
            aria-label={"Escolher cópia para manter: #{@member.track.rel_path}"}
            class="size-4 shrink-0 accent-green"
          />
          {cond do
            @chosen -> "Cópia selecionada"
            @member.track.status != :present -> "Indisponível para manter"
            true -> "Escolher cópia"
          end}
        </label>
        <p class={[
          "mt-1.5 text-body-sm font-medium",
          @chosen && "text-green",
          !@chosen && (@different? or @member.track.status != :present) && "text-ink-secondary",
          !@chosen && !@different? && @member.track.status == :present && "text-amber"
        ]}>
          {copy_outcome(@member.track.status, @chosen, @different?)}
        </p>
      </div>
    </div>
    """
  end

  defp copy_outcome(:quarantined, _chosen, _different?), do: "Já na quarentena"
  defp copy_outcome(:missing, _chosen, _different?), do: "Arquivo não encontrado"
  defp copy_outcome(:present, true, _different?), do: "Fica na biblioteca"
  defp copy_outcome(:present, false, true), do: "Manter · ISRC diferente"
  defp copy_outcome(:present, false, false), do: "Vai para a quarentena"

  defp copy_label(1), do: "cópia"
  defp copy_label(_), do: "cópias"

  defp resolve_label(0), do: "Encerrar grupo sem mover arquivos"

  defp resolve_label(count),
    do: "Manter selecionada e mover #{count} #{copy_label(count)} para a quarentena"

  defp confirm_resolution(_path, 0), do: nil

  defp confirm_resolution(path, count) do
    "Manter “#{path}” e mover #{count} #{copy_label(count)} para a quarentena? " <>
      "A cópia mantida assume os lugares das cópias movidas nos sets. " <>
      "Você pode recuperar os arquivos em Recuperação de arquivos."
  end

  attr :undo, :any, required: true

  defp undo_toast(assigns) do
    ~H"""
    <div
      role="status"
      class={[
        "flex flex-wrap items-center justify-between gap-3 border-b px-5 py-3",
        if(undo_problem?(@undo),
          do: "border-coral/30 bg-coral/10",
          else: "border-green/30 bg-green/10"
        )
      ]}
    >
      <div class="min-w-0 flex-1">
        <p class="text-body-sm text-ink">{undo_message(@undo)}</p>
        <ul :if={undo_failures(@undo) != []} class="mt-1 space-y-1 text-body-sm text-ink-secondary">
          <li :for={failure <- undo_failures(@undo)} class="break-words">
            {failure.path} — {failure_label(failure.reason)}
          </li>
        </ul>
        <.link
          :if={undo_problem?(@undo)}
          navigate={~p"/resgate" <> "#quarentena"}
          class="mt-1 inline-block text-body-sm text-primary hover:underline"
        >Recuperação de arquivos</.link>
      </div>
      <div class="flex items-center gap-3">
        <button
          :if={undo_batch_info(@undo)}
          phx-click="undo"
          class="rounded-md border border-green/40 bg-green/15 px-2.5 py-1 text-body-sm font-semibold text-green hover:bg-green/25"
        >
          {if match?({:undo_partial, _, _, _, _}, @undo),
            do: "Tentar desfazer novamente",
            else: "Desfazer"}
        </button>
        <button
          phx-click="dismiss_undo"
          aria-label="Fechar aviso"
          class="text-body-sm text-ink-muted hover:text-ink"
        >✕</button>
      </div>
    </div>
    """
  end

  defp undo_problem?({:resolution, _, _, _, failures}), do: failures != []
  defp undo_problem?({:undo_partial, _, _, _, _}), do: true
  defp undo_problem?({kind, _}) when kind in [:stale, :error, :keeper_unavailable], do: true
  defp undo_problem?(_), do: false

  defp undo_failures({:resolution, _, _, _, failures}), do: failures
  defp undo_failures(_), do: []

  defp undo_message({:stale, _gid}),
    do: "A seleção mudou. Confira as cópias e confirme novamente."

  defp undo_message({:keeper_unavailable, _gid}),
    do:
      "A cópia escolhida está indisponível. Escolha outra ou recupere o arquivo antes de tentar novamente."

  defp undo_message({:error, _gid}), do: "Falha ao resolver o grupo. Nada foi movido."

  defp undo_message({:resolution, _, _, 0, []}), do: "Grupo resolvido — nenhum arquivo movido."

  defp undo_message({:resolution, _, _, n, []}), do: "#{moved_message(n)}. Grupo resolvido."

  defp undo_message({:resolution, _, _, n, failures}) do
    "#{moved_message(n)} · #{failure_count(length(failures))}. O grupo permanece pendente."
  end

  defp undo_message({:undo_partial, _, _, n, failed}),
    do:
      "#{n} #{if n == 1, do: "restaurada", else: "restauradas"} · #{failure_count(failed)}. Tente recuperar as cópias pendentes novamente."

  defp moved_message(1), do: "1 cópia movida para a quarentena"
  defp moved_message(n), do: "#{n} cópias movidas para a quarentena"
  defp failure_count(1), do: "1 falha"
  defp failure_count(n), do: "#{n} falhas"

  defp failure_label(reason) when reason in [:source_missing, :enoent, :track_not_found],
    do: "arquivo não encontrado"

  defp failure_label(reason) when reason in [:eacces, :eperm], do: "sem permissão para mover"
  defp failure_label(:enospc), do: "sem espaço em disco"
  defp failure_label(_), do: "não foi possível mover o arquivo"

  defp group_count(groups) do
    case length(groups) do
      1 -> "· 1 grupo"
      n -> "· #{n} grupos"
    end
  end
end
