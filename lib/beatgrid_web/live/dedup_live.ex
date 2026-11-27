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

  # Reload the pending groups and reset every pick to that group's keeper.
  defp load(socket) do
    groups = Dedup.list_pending()
    assign(socket, groups: groups, picks: default_picks(groups))
  end

  defp default_picks(groups), do: Map.new(groups, fn g -> {g.id, keeper_of(g)} end)

  # --- manual scan ---

  @impl true
  def handle_event("scan", _params, socket) do
    DedupWorker.enqueue(Uniq.UUID.uuid7())
    {:noreply, assign(socket, scanning?: true)}
  end

  # --- per-group keeper choice (ephemeral; no DB write) ---

  def handle_event("pick_keeper", %{"group" => gid, "track" => tid}, socket) do
    {:noreply, update(socket, :picks, &Map.put(&1, gid, tid))}
  end

  # --- resolve / ignore ---

  def handle_event("resolve", %{"group" => gid}, socket) do
    keeper_id = socket.assigns.picks[gid] || keeper_for(socket, gid)

    socket =
      case Dedup.resolve_group(gid, keeper_id) do
        {:ok, %{quarantined: n, batch_id: batch_id}} ->
          socket |> assign(undo: {gid, batch_id, n}) |> load()

        {:error, _reason} ->
          assign(socket, undo: {:error, gid})
      end

    {:noreply, socket}
  end

  def handle_event("ignore", %{"group" => gid}, socket) do
    Dedup.ignore_group(gid)
    {:noreply, socket |> assign(undo: nil) |> load()}
  end

  # --- undo: restore the quarantined files + re-open the group ---

  def handle_event("undo", _params, socket) do
    case socket.assigns.undo do
      {gid, batch_id, _n} ->
        Operations.undo_batch(batch_id)

        case Dedup.get_group(gid) do
          nil -> :ok
          group -> Dedup.set_group_status(group, :pending)
        end

        {:noreply, socket |> assign(undo: nil) |> load()}

      _ ->
        {:noreply, assign(socket, undo: nil)}
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

  # --- helpers ---

  defp keeper_for(socket, gid) do
    case Enum.find(socket.assigns.groups, &(&1.id == gid)) do
      nil -> nil
      group -> keeper_of(group)
    end
  end

  # The currently-flagged keeper for a group: its keeper_track_id, falling back to
  # the keeper member, then the first member.
  defp keeper_of(%{keeper_track_id: id}) when not is_nil(id), do: id

  defp keeper_of(%{members: members}) do
    case Enum.find(members, & &1.is_keeper) || List.first(members) do
      nil -> nil
      member -> member.track_id
    end
  end

  defp keeper_of(_group), do: nil

  # How many will actually be quarantined: non-keepers MINUS the ones spared as a
  # different recording (different ISRC), which we keep on purpose.
  defp non_keeper_count(group, keeper_id) do
    keeper_isrc = group.members |> Enum.find(&(&1.track_id == keeper_id)) |> Dedup.member_isrc()

    Enum.count(group.members, fn m ->
      m.track_id != keeper_id and not Dedup.different_recording?(m, keeper_isrc)
    end)
  end

  defp match_label(:exact_hash), do: "exata"
  defp match_label(:fuzzy_meta), do: "parecida"
  defp match_label(:near_meta), do: "quase igual"
  defp match_label(_other), do: "duplicada"

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
  defp quality_fields(track) do
    [
      {"Bitrate", bitrate_part(track.bitrate_kbps)},
      {"Duração", duration_part(track.duration_ms)},
      {"Formato", format_part(track.format)},
      {"Pasta", placement_part(track)},
      {"Metadados", resolved_part(track)},
      {"Nota", track.rating}
    ]
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
        keeper_isrc: Dedup.member_isrc(keeper),
        members: assigns.group.members,
        group_label: group_label(assigns.group.members),
        kept_count: length(assigns.group.members) - quarantine_count,
        quarantine_count: quarantine_count
      )

    ~H"""
    <article
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
        <p class="mt-1 break-all font-mono text-caption text-ink-muted">{@group.signature}</p>
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
          different?={
            member.track_id != @keeper_id and Dedup.different_recording?(member, @keeper_isrc)
          }
        />
      </div>

      <footer class="flex flex-wrap items-center justify-end gap-2 border-t border-white/6 px-4 py-3">
        <p class="mr-auto text-body text-ink-secondary">
          <span class="font-mono text-green">{@kept_count}</span>
          {if @kept_count == 1, do: "cópia será mantida", else: "cópias serão mantidas"}
          <span class="mx-1.5 text-ink-muted">·</span>
          <span class="font-mono text-amber">{@quarantine_count}</span>
          {copy_label(@quarantine_count)} para a quarentena
        </p>
        <button
          phx-click="ignore"
          phx-value-group={@group.id}
          aria-label={"Manter todas as cópias — #{@group_label}"}
          class="rounded-md border border-white/10 bg-input px-3 py-2 text-body text-ink-secondary hover:text-ink"
        >
          Manter todas as cópias
        </button>
        <button
          phx-click="resolve"
          phx-value-group={@group.id}
          aria-label={"#{resolve_label(@quarantine_count)} — #{@group_label}"}
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
        <p class="mt-1 break-words font-mono text-body-sm text-ink-muted [overflow-wrap:anywhere]">
          {@member.track.rel_path}
        </p>
      </div>

      <dl class="col-span-2 grid min-w-0 grid-cols-2 gap-x-3 gap-y-2 sm:grid-cols-3 lg:col-span-1">
        <div :for={{label, value} <- quality_fields(@member.track)} class="min-w-0">
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
          !@chosen && "border-white/10 bg-input text-ink-secondary hover:text-ink"
        ]}>
          <input
            type="radio"
            name={"keeper-#{@group_id}"}
            phx-click="pick_keeper"
            phx-value-group={@group_id}
            phx-value-track={@member.track_id}
            checked={@chosen}
            aria-label={"Escolher cópia para manter: #{@member.track.rel_path}"}
            class="size-4 shrink-0 accent-green"
          />
          {if @chosen, do: "Cópia selecionada", else: "Escolher cópia"}
        </label>
        <p class={[
          "mt-1.5 text-body-sm font-medium",
          @chosen && "text-green",
          !@chosen && @different? && "text-ink-secondary",
          !@chosen && !@different? && "text-amber"
        ]}>
          {copy_outcome(@chosen, @different?)}
        </p>
      </div>
    </div>
    """
  end

  defp copy_outcome(true, _different?), do: "Fica na biblioteca"
  defp copy_outcome(false, true), do: "Manter · ISRC diferente"
  defp copy_outcome(false, false), do: "Vai para a quarentena"

  defp copy_label(1), do: "cópia"
  defp copy_label(_), do: "cópias"

  defp resolve_label(0), do: "Confirmar seleção"

  defp resolve_label(count),
    do: "Manter selecionada e mover #{count} #{copy_label(count)} para a quarentena"

  attr :undo, :any, required: true

  defp undo_toast(assigns) do
    ~H"""
    <div
      role="status"
      class={[
        "flex flex-wrap items-center justify-between gap-3 border-b px-5 py-3",
        if(match?({:error, _}, @undo),
          do: "border-coral/30 bg-coral/10",
          else: "border-green/30 bg-green/10"
        )
      ]}
    >
      <p class="text-body-sm text-ink">{undo_message(@undo)}</p>
      <div class="flex items-center gap-3">
        <button
          :if={match?({_gid, _batch, _n}, @undo)}
          phx-click="undo"
          class="rounded-md border border-green/40 bg-green/15 px-2.5 py-1 text-body-sm font-semibold text-green hover:bg-green/25"
        >
          Desfazer
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

  defp undo_message({:error, _gid}), do: "Falha ao resolver o grupo. Nada foi movido."
  defp undo_message({_gid, _batch, 0}), do: "Grupo resolvido — nada para quarentenar."

  defp undo_message({_gid, _batch, 1}),
    do: "1 cópia movida para _Quarantine. A faixa mantida ficou no lugar."

  defp undo_message({_gid, _batch, n}),
    do: "#{n} cópias movidas para _Quarantine. A faixa mantida ficou no lugar."

  defp group_count(groups) do
    case length(groups) do
      1 -> "· 1 grupo"
      n -> "· #{n} grupos"
    end
  end
end
