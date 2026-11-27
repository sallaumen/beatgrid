defmodule BeatgridWeb.PlayerLive do
  @moduledoc """
  The single, app-wide audio player. Rendered once as a sticky nested LiveView in
  `app_shell`, so it keeps playing across live navigation. It owns the only
  `<audio>` element + the `.Player` colocated hook + the bottom banner, and it is the
  **conductor** of set playback.

  Playback is triggered client-side (`beatgrid:play` dispatched to `#player-audio`,
  optionally carrying a `set_id`) for zero-latency start; the hook pushes `now_playing`
  so this LiveView renders the cover/title/artist and records the now-playing pointer
  (`Beatgrid.Playback.set_now_playing/1`). When a track ends inside a set, the hook
  pushes `track_ended` and this LiveView asks `Sets.next_after/2` for the next track
  (the pointer is `(set_id, current track)` — no track list is held) and pushes
  `play_track` back to the hook. Seek/time/volume stay client-owned inside a
  `phx-update="ignore"` region.
  """
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library.{Marker, Tracks}
  alias Beatgrid.Playback
  alias Beatgrid.Sets

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe for {:markers_changed, id} so cue points added/renamed/removed from
    # another page (e.g. the track page) refresh the player's lane + popover live.
    if connected?(socket), do: Playback.subscribe_markers()
    {:ok, assign(socket, now_playing: nil, playing_set: nil, show_markers: false), layout: false}
  end

  @impl true
  def handle_event("now_playing", %{"id" => id} = params, socket) do
    case Tracks.get_with_song(id) do
      nil ->
        # The track vanished (deleted / stale row) — clear so no page ghosts a
        # highlight for a track the player can't show.
        Playback.release_now_playing()
        Playback.deactivate_quiet_mode()
        {:noreply, assign(socket, now_playing: nil, playing_set: nil)}

      track ->
        set = load_playing_set(params["set_id"])
        set_id = set && set.id
        Playback.set_now_playing(%{track_id: id, set_id: set_id})
        sync_quiet_mode(set_id)

        {:noreply,
         socket
         |> assign(now_playing: track, playing_set: set)
         |> push_markers()}
    end
  end

  def handle_event("track_ended", params, socket) do
    if current_media?(socket, params),
      do: advance(socket, params["play_token"]),
      else: {:noreply, socket}
  end

  def handle_event("playback_playing", params, socket) do
    if current_media?(socket, params), do: sync_quiet_mode(socket.assigns.playing_set)
    {:noreply, socket}
  end

  def handle_event("playback_paused", params, socket) do
    if current_media?(socket, params), do: Playback.deactivate_quiet_mode()
    {:noreply, socket}
  end

  def handle_event("close", _params, socket) do
    Playback.release_now_playing()
    Playback.deactivate_quiet_mode()
    {:noreply, assign(socket, now_playing: nil, playing_set: nil, show_markers: false)}
  end

  def handle_event("toggle_markers", _params, socket),
    do: {:noreply, assign(socket, show_markers: !socket.assigns.show_markers)}

  def handle_event(
        "add_marker",
        %{"track_id" => target},
        %{assigns: %{now_playing: %{id: current}}} = socket
      )
      when target != current,
      do: {:noreply, socket}

  # Cue-point markers always target the now-playing track. The hook supplies the
  # current playback position (ms) for add; rename/remove come from the popover.
  # The position parser rejects invalid input, and `mutate_markers` re-reads the
  # track fresh (no lost update vs a concurrent track-page edit) and updates the lane
  # synchronously instead of waiting for the broadcast echo.
  def handle_event("add_marker", %{"ms" => ms}, %{assigns: %{now_playing: %{id: id}}} = socket) do
    case Marker.parse_position(ms) do
      {:ok, n} -> {:noreply, mutate_markers(socket, id, &Tracks.add_marker(&1, n))}
      :error -> {:noreply, socket}
    end
  end

  def handle_event(
        "rename_marker",
        %{"ms" => ms, "label" => label},
        %{assigns: %{now_playing: %{id: id}}} = socket
      ) do
    case Marker.parse_position(ms) do
      {:ok, n} -> {:noreply, mutate_markers(socket, id, &Tracks.rename_marker(&1, n, label))}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("remove_marker", %{"ms" => ms}, %{assigns: %{now_playing: %{id: id}}} = socket) do
    case Marker.parse_position(ms) do
      {:ok, n} -> {:noreply, mutate_markers(socket, id, &Tracks.remove_marker(&1, n))}
      :error -> {:noreply, socket}
    end
  end

  def handle_event(
        "set_marker_type",
        %{"ms" => ms, "type" => type},
        %{assigns: %{now_playing: %{id: id}}} = socket
      ) do
    case Marker.parse_position(ms) do
      {:ok, n} -> {:noreply, mutate_markers(socket, id, &Tracks.set_marker_type(&1, n, type))}
      :error -> {:noreply, socket}
    end
  end

  # Marker events with nothing playing are no-ops (defensive).
  def handle_event(event, _params, socket)
      when event in ~w(add_marker rename_marker remove_marker set_marker_type),
      do: {:noreply, socket}

  # A track's markers changed (from here or another page) — if it's the one playing,
  # reload it so the popover count/list and the seek-lane ticks refresh. The repeated
  # `id` in the head matches only when the changed track is the now-playing one.
  @impl true
  def handle_info({:markers_changed, id}, %{assigns: %{now_playing: %{id: id}}} = socket) do
    case Tracks.get_with_song(id) do
      nil -> {:noreply, socket}
      track -> {:noreply, socket |> assign(now_playing: track) |> push_markers()}
    end
  end

  # Ignore everything else on the topic (our own {:now_playing, _} echoes, other tracks).
  def handle_info(_msg, socket), do: {:noreply, socket}

  # The tab lost its audio. Another tab or the booth may have taken over already.
  @impl true
  def terminate(_reason, _socket) do
    Playback.release_now_playing()
    Playback.deactivate_quiet_mode()
  end

  # End of a track. If a set is playing, advance to the next ordered track — the
  # pointer is `(set_id, current track)` and `next_after` reads the live order, so a
  # reorder is honored with no re-sync. At the end of the set, drop the set context
  # (no more auto-advance) but keep the last track shown. No set ⇒ nothing to do.
  defp advance(
         %{assigns: %{playing_set: %{id: set_id}, now_playing: %{id: current_id}}} = socket,
         token
       ) do
    case Sets.next_after(set_id, current_id) do
      nil ->
        Playback.set_now_playing(%{track_id: current_id, set_id: nil})
        Playback.deactivate_quiet_mode()

        {:noreply,
         socket
         |> assign(playing_set: nil)
         |> push_event("player_set_finished", %{after_token: token})}

      next ->
        Playback.set_now_playing(%{track_id: next.id, set_id: set_id})
        Playback.activate_quiet_mode()

        {:noreply,
         socket
         |> assign(now_playing: next)
         |> push_event("play_track", %{
           src: ~p"/audio/#{next.id}",
           id: next.id,
           set_id: set_id,
           after_token: token
         })
         |> push_markers()}
    end
  end

  defp advance(socket, _token), do: {:noreply, socket}

  # Push the now-playing track's cue points to the hook, which draws the seek-lane ticks.
  defp push_markers(socket) do
    track = socket.assigns.now_playing
    push_event(socket, "player_markers", %{track_id: track.id, markers: track.cue_points || []})
  end

  # Re-read the track fresh (so a concurrent track-page edit isn't clobbered), apply the
  # cue mutation, then update the player synchronously + tell the track's page. The fresh
  # read carries the song preload, which Repo.update keeps, so now_playing stays complete.
  defp mutate_markers(socket, id, fun) do
    with fresh when not is_nil(fresh) <- Tracks.get_with_song(id),
         {:ok, updated} <- fun.(fresh) do
      Playback.broadcast_markers_changed(id)
      socket |> assign(now_playing: updated) |> push_markers()
    else
      _ -> socket
    end
  end

  defp load_playing_set(nil), do: nil

  defp load_playing_set(set_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(set_id), %{} = set <- Sets.get(uuid) do
      Map.take(set, [:id, :name])
    else
      _ -> nil
    end
  end

  # Mounted clients from before media identities were added omit these fields.
  defp current_media?(%{assigns: %{now_playing: track, playing_set: set}}, params) do
    matches_id?(params, "track_id", track) and matches_id?(params, "set_id", set)
  end

  defp matches_id?(params, key, record) do
    not Map.has_key?(params, key) or params[key] == (record && record.id)
  end

  defp sync_quiet_mode(nil), do: Playback.deactivate_quiet_mode()
  defp sync_quiet_mode(_set_id), do: Playback.activate_quiet_mode()

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="player-bar"
      role="region"
      aria-label="Reprodutor"
      class={[
        "fixed inset-x-0 bottom-0 z-40 border-t border-white/10 bg-rail/95 px-3 py-2 backdrop-blur",
        !@now_playing && "hidden"
      ]}
    >
      <div class="mx-auto grid max-w-5xl grid-cols-[minmax(0,1fr)_auto_auto] items-center gap-x-2 gap-y-1 lg:flex lg:gap-4">
        <div class="flex min-w-0 items-center gap-2 lg:w-56 lg:shrink-0">
          <.cover
            :if={@now_playing}
            src={cover_src(@now_playing)}
            artist={@now_playing.tag_artist}
            size={44}
          />
          <div :if={@now_playing} class="min-w-0">
            <.link
              navigate={~p"/track/#{@now_playing.id}"}
              class="block truncate text-body-sm font-medium text-primary hover:underline"
            >
              {@now_playing.tag_title || @now_playing.filename}
            </.link>
            <p class="text-ink-muted truncate text-caption">{@now_playing.tag_artist || "—"}</p>
          </div>
        </div>

        <.link
          :if={@playing_set}
          navigate={~p"/set/#{@playing_set.id}"}
          class="col-start-2 inline-flex min-w-0 items-center gap-1 rounded-md px-1 py-1 text-caption font-medium text-primary hover:underline"
          title="Ir para o set"
        >
          <span class="hero-queue-list size-3.5" aria-hidden="true" />
          <span class="max-w-16 truncate sm:max-w-40">{@playing_set.name}</span>
        </.link>

        <div :if={@now_playing} class="relative col-start-3 shrink-0">
          <button
            type="button"
            phx-click="toggle_markers"
            class={[
              "flex items-center gap-1 rounded-full px-2.5 py-1 text-caption font-semibold",
              @show_markers && "bg-amber/25 text-amber",
              !@show_markers && "bg-amber/10 text-amber hover:bg-amber/20"
            ]}
            aria-label="Marcadores"
            aria-expanded={to_string(@show_markers)}
            aria-controls="player-markers"
            title="Marcadores"
          >
            <span class="hero-flag size-3.5" aria-hidden="true"></span>
            <span>{length(@now_playing.cue_points || [])}</span>
          </button>
          <div
            :if={@show_markers}
            id="player-markers"
            class="absolute right-0 bottom-full z-50 mb-2 max-h-[60dvh] w-72 max-w-[calc(100vw-2rem)] overflow-y-auto rounded-lg border border-white/10 bg-rail p-3 shadow-xl"
          >
            <div class="mb-2 flex items-center justify-between">
              <span class="text-caption font-semibold text-ink-secondary">Marcadores</span>
              <button
                type="button"
                phx-click={JS.dispatch("beatgrid:add-marker", to: "#player-audio")}
                class="rounded-md border border-amber/40 bg-amber/10 px-2 py-0.5 text-[11px] font-semibold text-amber hover:bg-amber/20"
                title="Marcar a posição atual"
              >
                ＋ marcar
              </button>
            </div>
            <.marker_list
              markers={@now_playing.cue_points || []}
              track_id={@now_playing.id}
              play_src={~p"/audio/#{@now_playing.id}"}
              seekable={true}
              id_prefix="player"
            />
          </div>
        </div>

        <div
          id="player-controls"
          phx-update="ignore"
          class="col-span-full flex min-w-0 flex-1 items-center gap-1.5 sm:gap-3"
        >
          <button
            id="player-toggle"
            type="button"
            phx-click={JS.dispatch("beatgrid:toggle", to: "#player-audio")}
            class="flex size-9 shrink-0 items-center justify-center rounded-full bg-primary/15 text-primary hover:bg-primary/25"
            aria-label="Tocar ou pausar"
            title="Tocar / pausar"
          >
            <span id="player-toggle-icon" aria-hidden="true">▶</span>
          </button>
          <span id="player-elapsed" class="text-ink-faint w-9 text-right font-mono text-[11px]">0:00</span>
          <div class="relative min-w-0 flex-1">
            <div id="player-marker-lane" class="pointer-events-none absolute inset-x-0 -top-2 h-2.5">
            </div>
            <input
              id="player-seek"
              type="range"
              min="0"
              max="100"
              value="0"
              aria-label="Posição na faixa"
              class="h-1 w-full"
              style="accent-color:var(--color-primary)"
            />
          </div>
          <span id="player-duration" class="text-ink-faint w-9 font-mono text-[11px]">0:00</span>
          <span class="hero-speaker-wave size-3.5 shrink-0 text-ink-muted" aria-hidden="true"></span>
          <input
            id="player-volume"
            type="range"
            min="0"
            max="100"
            value="100"
            aria-label="Volume"
            class="h-1 w-12 shrink-0 sm:w-20"
            style="accent-color:var(--color-primary)"
          />
          <button
            type="button"
            phx-click={JS.push("close") |> JS.dispatch("beatgrid:stop", to: "#player-audio")}
            class="flex size-8 shrink-0 items-center justify-center rounded-md text-ink-muted hover:text-ink"
            aria-label="Fechar"
            title="Fechar"
          >
            ✕
          </button>
        </div>
      </div>

      <audio
        id="player-audio"
        phx-hook=".Player"
        phx-update="ignore"
        preload="none"
        data-preview-offset-ms={Playback.preview_offset_ms()}
        data-preview-min-ms={Playback.preview_min_duration_ms()}
        class="hidden"
      ></audio>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Player">
        import Player from "@/js/player.js"
        export default Player
      </script>
    </div>
    """
  end
end
