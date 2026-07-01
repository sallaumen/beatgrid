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
  defp match_label(_other), do: "duplicada"

  # Exact-hash matches are certain (amber); fuzzy meta-matches are softer (violet).
  defp match_color(:exact_hash), do: "#ffb020"
  defp match_color(_fuzzy), do: "#8b7bf0"

  defp artist_title(track) do
    artist =
      present_str(track.tag_artist) || present_str(track.norm_artist) || "Artista desconhecido"

    title = present_str(track.tag_title) || present_str(track.norm_title) || track.filename
    {artist, title}
  end

  defp present_str(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_str(_), do: nil

  # A compact mono "quality + placement" line for a member row, joined with " · ".
  defp quality_line(track) do
    [
      bitrate_part(track.bitrate_kbps),
      duration_part(track.duration_ms),
      format_part(track.format),
      placement_part(track),
      resolved_part(track),
      rating_part(track.rating)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
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

  defp rating_part(n) when is_integer(n), do: "nota #{n}"
  defp rating_part(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={:dedup} socket={@socket}>
      <div class="flex h-[calc(100vh_-_5rem)] flex-col">
        <header class="flex items-center justify-between gap-4 border-b border-white/6 bg-rail px-5 py-3">
          <div class="flex items-baseline gap-3">
            <h2 class="text-[22px] font-semibold">Duplicatas</h2>
            <span class="font-mono text-body-sm text-ink-muted">{group_count(@groups)}</span>
          </div>
          <button
            phx-click="scan"
            disabled={@scanning?}
            class="flex items-center gap-2 rounded-md bg-primary px-3.5 py-1.5 text-body-sm font-semibold text-white disabled:cursor-not-allowed disabled:opacity-60"
          >
            <span
              :if={@scanning?}
              class="size-2 animate-pulse rounded-full bg-white"
              aria-hidden="true"
            />
            <span class={[!@scanning? && "hero-magnifying-glass size-4"]} aria-hidden="true" />
            {if @scanning?, do: "Procurando…", else: "Procurar duplicatas"}
          </button>
        </header>

        <.undo_toast :if={@undo} undo={@undo} />

        <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">
          <p class="mb-4 text-caption text-ink-faint">
            Versões de artistas diferentes nunca são agrupadas — só faixas do mesmo artista e título.
          </p>

          <div :if={@groups != []} class="space-y-3">
            <.group_card :for={group <- @groups} group={group} pick={@picks[group.id]} />
          </div>

          <div
            :if={@groups == []}
            class="flex flex-col items-center justify-center gap-2 py-24 text-center"
          >
            <span class="hero-document-duplicate size-10 text-ink-disabled" />
            <p class="text-ink-muted">Nenhuma duplicata pendente — rode uma busca.</p>
            <button
              phx-click="scan"
              disabled={@scanning?}
              class="text-body-sm text-primary hover:underline disabled:opacity-60"
            >
              {if @scanning?, do: "Procurando…", else: "Procurar duplicatas"}
            </button>
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

    assigns =
      assign(assigns,
        keeper_id: keeper_id,
        keeper_isrc: Dedup.member_isrc(keeper),
        members: assigns.group.members
      )

    ~H"""
    <div class="rounded-xl border border-white/8 bg-surface">
      <div class="flex items-center gap-2.5 border-b border-white/6 px-4 py-2.5">
        <span
          class="bg-token-chip inline-flex items-center rounded-xs px-[7px] py-[2px] text-[9.5px] font-bold uppercase tracking-wide"
          style={"--c:#{match_color(@group.match_type)}"}
        >
          {match_label(@group.match_type)}
        </span>
        <span class="truncate font-mono text-caption text-ink-muted" title={@group.signature}>
          {@group.signature}
        </span>
        <span class="ml-auto font-mono text-[11px] text-ink-faint">
          {length(@members)} cópias
        </span>
      </div>

      <div class="divide-y divide-white/6">
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

      <div class="flex flex-wrap items-center justify-end gap-2 border-t border-white/6 px-4 py-3">
        <button
          phx-click="ignore"
          phx-value-group={@group.id}
          class="rounded-md border border-white/10 bg-input px-3 py-1.5 text-body-sm text-ink-secondary hover:text-ink"
        >
          Ignorar (não são duplicatas)
        </button>
        <button
          phx-click="resolve"
          phx-value-group={@group.id}
          class="rounded-md bg-green px-3.5 py-1.5 text-body-sm font-semibold text-[#0b0c10] hover:bg-green/90"
        >
          Manter selecionada + quarentenar {non_keeper_count(@group, @keeper_id)}
        </button>
      </div>
    </div>
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
    <div class={[
      "flex items-center gap-3 px-4 py-3 transition-colors",
      @chosen && "bg-green/8",
      !@chosen && "opacity-70 hover:opacity-100"
    ]}>
      <label
        class="flex cursor-pointer items-center justify-center"
        title="Escolher cópia para manter"
      >
        <input
          type="radio"
          name={"keeper-#{@group_id}"}
          phx-click="pick_keeper"
          phx-value-group={@group_id}
          phx-value-track={@member.track_id}
          checked={@chosen}
          class="sr-only"
        />
        <span class={[
          "flex size-[18px] shrink-0 items-center justify-center rounded-full border transition-colors",
          @chosen && "border-green bg-green",
          !@chosen && "border-white/25"
        ]}>
          <span :if={@chosen} class="size-2 rounded-full bg-[#0b0c10]" />
        </span>
      </label>

      <.cover_play
        src={cover_src(@member.track)}
        artist={@artist}
        size={40}
        play_src={~p"/audio/#{@member.track.id}"}
        track_id={@member.track.id}
      />

      <div class="min-w-0 flex-1">
        <.link
          navigate={~p"/track/#{@member.track.id}"}
          class="block truncate text-body font-medium text-ink hover:text-primary hover:underline"
        >
          <span class="text-ink-muted">{@artist}</span>
          <span class="text-ink-faint">—</span>
          {@title}
        </.link>
        <p class="truncate font-mono text-[11px] text-ink-faint">{quality_line(@member.track)}</p>
      </div>

      <span
        :if={@chosen}
        class="shrink-0 rounded-sm bg-green/15 px-2 py-[3px] text-[10px] font-semibold text-green"
      >
        manter
      </span>
      <span
        :if={!@chosen and @different?}
        class="shrink-0 rounded-sm bg-primary/15 px-2 py-[3px] text-[10px] font-semibold text-primary"
        title="ISRC diferente — gravação/versão distinta, será mantida"
      >
        versão diferente
      </span>
      <span
        :if={!@chosen and not @different?}
        class="shrink-0 rounded-sm bg-amber/12 px-2 py-[3px] text-[10px] font-semibold text-amber"
      >
        → quarentena
      </span>
    </div>
    """
  end

  attr :undo, :any, required: true

  defp undo_toast(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-4 border-b border-green/30 bg-green/10 px-5 py-2.5">
      <p class="text-body-sm text-ink">{undo_message(@undo)}</p>
      <div class="flex items-center gap-3">
        <button
          :if={match?({_gid, _batch, _n}, @undo)}
          phx-click="undo"
          class="rounded-md border border-green/40 bg-green/15 px-2.5 py-1 text-body-sm font-semibold text-green hover:bg-green/25"
        >
          Desfazer
        </button>
        <button phx-click="dismiss_undo" class="text-body-sm text-ink-muted hover:text-ink">✕</button>
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
