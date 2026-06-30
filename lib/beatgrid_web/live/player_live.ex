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

  alias Beatgrid.Library.Tracks
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
        Playback.clear_now_playing()
        {:noreply, assign(socket, now_playing: nil, playing_set: nil)}

      track ->
        set_id = params["set_id"]
        Playback.set_now_playing(%{track_id: id, set_id: set_id})

        {:noreply,
         socket
         |> assign(now_playing: track, playing_set: load_playing_set(set_id))
         |> push_markers()
         |> push_set_plan()}
    end
  end

  def handle_event("track_ended", _params, socket), do: advance(socket)

  def handle_event("close", _params, socket) do
    Playback.clear_now_playing()
    {:noreply, assign(socket, now_playing: nil, playing_set: nil, show_markers: false)}
  end

  def handle_event("toggle_markers", _params, socket),
    do: {:noreply, assign(socket, show_markers: !socket.assigns.show_markers)}

  # Cue-point markers always target the now-playing track. The hook supplies the
  # current playback position (ms) for add; rename/remove come from the popover.
  # `to_ms` rejects crafted/empty payloads (no crash); `mutate_markers` re-reads the
  # track fresh (no lost update vs a concurrent track-page edit) and updates the lane
  # synchronously instead of waiting for the broadcast echo.
  def handle_event("add_marker", %{"ms" => ms}, %{assigns: %{now_playing: %{id: id}}} = socket) do
    case to_ms(ms) do
      {:ok, n} -> {:noreply, mutate_markers(socket, id, &Tracks.add_marker(&1, n))}
      :error -> {:noreply, socket}
    end
  end

  def handle_event(
        "rename_marker",
        %{"ms" => ms, "label" => label},
        %{assigns: %{now_playing: %{id: id}}} = socket
      ) do
    case to_ms(ms) do
      {:ok, n} -> {:noreply, mutate_markers(socket, id, &Tracks.rename_marker(&1, n, label))}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("remove_marker", %{"ms" => ms}, %{assigns: %{now_playing: %{id: id}}} = socket) do
    case to_ms(ms) do
      {:ok, n} -> {:noreply, mutate_markers(socket, id, &Tracks.remove_marker(&1, n))}
      :error -> {:noreply, socket}
    end
  end

  def handle_event(
        "set_marker_type",
        %{"ms" => ms, "type" => type},
        %{assigns: %{now_playing: %{id: id}}} = socket
      ) do
    case to_ms(ms) do
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

  # On teardown (refresh / tab close) the audio is gone — reset the pointer (silent,
  # no live subscribers to notify) so a freshly-mounted page won't read a stale one.
  @impl true
  def terminate(_reason, _socket), do: Playback.reset_now_playing()

  # End of a track. If a set is playing, advance to the next ordered track — the
  # pointer is `(set_id, current track)` and `next_after` reads the live order, so a
  # reorder is honored with no re-sync. At the end of the set, drop the set context
  # (no more auto-advance) but keep the last track shown. No set ⇒ nothing to do.
  defp advance(%{assigns: %{playing_set: %{id: set_id}, now_playing: %{id: current_id}}} = socket) do
    case Sets.next_after(set_id, current_id) do
      nil ->
        Playback.set_now_playing(%{track_id: current_id, set_id: nil})
        {:noreply, assign(socket, playing_set: nil)}

      next ->
        Playback.set_now_playing(%{track_id: next.id, set_id: set_id})

        {:noreply,
         socket
         |> assign(now_playing: next)
         |> push_markers()
         |> push_event("play_track", %{src: ~p"/audio/#{next.id}", id: next.id})}
    end
  end

  defp advance(socket), do: {:noreply, socket}

  # Push the now-playing track's cue points to the hook, which draws the seek-lane ticks.
  defp push_markers(socket) do
    markers = (socket.assigns.now_playing && socket.assigns.now_playing.cue_points) || []
    push_event(socket, "player_markers", %{markers: markers})
  end

  # When a set is playing, push the ordered plan (src + bpm + incoming transition per
  # entry) to the hook so it can drive the dual-deck crossfades client-side, plus the
  # index of the track that just started. No set / deleted set → no push.
  defp push_set_plan(%{assigns: %{now_playing: %{id: id}, playing_set: %{id: set_id}}} = socket) do
    case Sets.get(set_id) do
      nil ->
        socket

      set ->
        tracks =
          Enum.map(Sets.entries(set), fn e ->
            %{
              id: e.track.id,
              src: ~p"/audio/#{e.track.id}",
              bpm: Beatgrid.Library.effective(e.track).bpm,
              transition: e.transition
            }
          end)

        push_event(socket, "set_plan", %{
          set_id: set_id,
          tracks: tracks,
          index: Enum.find_index(tracks, &(&1.id == id)) || 0
        })
    end
  end

  defp push_set_plan(socket), do: socket

  # Re-read the track fresh (so a concurrent track-page edit isn't clobbered), apply the
  # cue mutation, then update the player synchronously + tell the track's page. The fresh
  # read carries the song preload, which Repo.update keeps, so now_playing stays complete.
  defp mutate_markers(socket, id, fun) do
    case Tracks.get_with_song(id) do
      nil ->
        socket

      fresh ->
        {:ok, updated} = fun.(fresh)
        Playback.broadcast_markers_changed(id)
        socket |> assign(now_playing: updated) |> push_markers()
    end
  end

  # Coerce a client-supplied position to integer ms; reject empty/non-numeric (no crash).
  defp to_ms(ms) when is_integer(ms), do: {:ok, ms}
  defp to_ms(ms) when is_float(ms), do: {:ok, trunc(ms)}

  defp to_ms(ms) when is_binary(ms) do
    case Integer.parse(ms) do
      {n, _rest} -> {:ok, n}
      :error -> :error
    end
  end

  defp to_ms(_ms), do: :error

  defp load_playing_set(nil), do: nil

  defp load_playing_set(set_id) do
    case Sets.get(set_id) do
      nil -> nil
      set -> %{id: set.id, name: set.name}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="player-bar"
      class={[
        "fixed inset-x-0 bottom-0 z-40 border-t border-white/10 bg-rail/95 px-3 py-2 backdrop-blur",
        !@now_playing && "hidden"
      ]}
    >
      <div class="mx-auto flex max-w-5xl items-center gap-4">
        <div class="flex w-56 shrink-0 items-center gap-2.5">
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
          class="hidden shrink-0 items-center gap-1.5 rounded-full bg-primary/15 px-2.5 py-1 text-caption font-semibold text-primary hover:bg-primary/25 sm:flex"
          title="Ir para o set"
        >
          <span class="hero-queue-list size-3.5" aria-hidden="true" />
          <span class="max-w-[160px] truncate">{@playing_set.name}</span>
        </.link>

        <div :if={@now_playing} class="relative shrink-0">
          <button
            type="button"
            phx-click="toggle_markers"
            class={[
              "flex items-center gap-1 rounded-full px-2.5 py-1 text-caption font-semibold",
              @show_markers && "bg-amber/25 text-amber",
              !@show_markers && "bg-amber/10 text-amber hover:bg-amber/20"
            ]}
            title="Marcadores"
          >
            <span aria-hidden="true">🚩</span>
            <span>{length(@now_playing.cue_points || [])}</span>
          </button>
          <div
            :if={@show_markers}
            class="absolute bottom-full left-0 z-50 mb-2 w-72 rounded-lg border border-white/10 bg-rail p-3 shadow-xl"
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

        <div id="player-controls" phx-update="ignore" class="flex flex-1 items-center gap-3">
          <button
            id="player-toggle"
            type="button"
            phx-click={JS.dispatch("beatgrid:toggle", to: "#player-audio")}
            class="flex size-9 shrink-0 items-center justify-center rounded-full bg-primary/15 text-primary hover:bg-primary/25"
            title="Tocar / pausar"
          >
            <span id="player-toggle-icon">▶</span>
          </button>
          <span id="player-elapsed" class="text-ink-faint w-9 text-right font-mono text-[11px]">0:00</span>
          <div class="relative flex-1">
            <div id="player-marker-lane" class="pointer-events-none absolute inset-x-0 -top-2 h-2.5">
            </div>
            <input
              id="player-seek"
              type="range"
              min="0"
              max="100"
              value="0"
              class="h-1 w-full"
              style="accent-color:#8b7bf0"
            />
          </div>
          <span id="player-duration" class="text-ink-faint w-9 font-mono text-[11px]">0:00</span>
          <span class="text-ink-faint ml-2 text-[13px]">🔊</span>
          <input
            id="player-volume"
            type="range"
            min="0"
            max="100"
            value="100"
            class="h-1 w-20"
            style="accent-color:#8b7bf0"
          />
          <button
            type="button"
            phx-click={JS.push("close") |> JS.dispatch("beatgrid:stop", to: "#player-audio")}
            class="text-ink-muted hover:text-ink flex size-7 items-center justify-center rounded-full"
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
      <%!-- Deck B: the idle/overlap deck the .Player hook uses for crossfades (Part 4). --%>
      <audio id="player-audio-b" phx-update="ignore" preload="none" class="hidden"></audio>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Player">
        export default {
          mounted() {
            const a = this.el
            const offset = parseInt(a.dataset.previewOffsetMs || "20000", 10)
            const minDur = parseInt(a.dataset.previewMinMs || "25000", 10)
            const byId = (id) => document.getElementById(id)
            const fmt = (s) => {
              if (!isFinite(s)) return "0:00"
              const m = Math.floor(s / 60), ss = Math.floor(s % 60)
              return `${m}:${ss < 10 ? "0" : ""}${ss}`
            }
            const setIcon = (t) => { const el = byId("player-toggle-icon"); if (el) el.textContent = t }

            // --- cue-point markers drawn over the seek lane (data pushed from the server) ---
            this._markers = []
            const lane = byId("player-marker-lane")
            const renderMarkers = () => {
              if (!lane) return
              lane.innerHTML = ""
              const durMs = (a.duration || 0) * 1000
              if (!durMs) return
              const COLORS = {cue: "#ffb020", intro: "#5ad1a0", outro: "#ff5d6c"}
              this._markers.forEach((m) => {
                if (m.ms < 0 || m.ms > durMs) return
                const left = (m.ms / durMs) * 100
                const color = COLORS[m.type] || COLORS.cue
                const auto = m.source === "auto"
                const tick = document.createElement("button")
                tick.type = "button"
                tick.title = (auto ? "auto · " : "") + (m.label || fmt(m.ms / 1000))
                tick.style.cssText =
                  `position:absolute;top:0;bottom:0;left:${left}%;width:3px;` +
                  `transform:translateX(-1px);background:${color};border:0;border-radius:2px;` +
                  `cursor:pointer;pointer-events:auto;opacity:${auto ? 0.55 : 1}`
                tick.addEventListener("click", () => { if (a.duration) a.currentTime = m.ms / 1000 })
                lane.appendChild(tick)
              })
            }
            this.handleEvent("player_markers", ({markers}) => { this._markers = markers || []; renderMarkers() })
            // "Mark now": the button (player or track page) dispatches this; we read the
            // live position and let the server persist it on the now-playing track. Ignore
            // it when nothing has loaded/played yet, so we never store a junk 0:00 cue.
            a.addEventListener("beatgrid:add-marker", () => {
              if (!a.duration || a.currentTime <= 0) return
              this.pushEvent("add_marker", {ms: Math.round(a.currentTime * 1000)})
            })
            a.addEventListener("beatgrid:seek", (e) => { if (a.duration) a.currentTime = e.detail.ms / 1000 })

            // Load + play a src. `atMs` (jump to a marker) wins; else a preview jumps
            // to the configured offset for long tracks; otherwise start at 0.
            const playSrc = (src, preview, atMs) => {
              if (lane) lane.innerHTML = ""
              a.src = src
              a.load()
              if (a._pendingStart) a.removeEventListener("loadedmetadata", a._pendingStart)
              const start = () => {
                const durMs = (a.duration || 0) * 1000
                if (atMs != null) a.currentTime = atMs / 1000
                else a.currentTime = (preview && durMs >= minDur) ? offset / 1000 : 0
                a.play()
                a.removeEventListener("loadedmetadata", start)
                a._pendingStart = null
              }
              a._pendingStart = start
              a.addEventListener("loadedmetadata", start)
            }

            // User-initiated play from a page (may carry a set_id for set playback, or
            // an at_ms to start straight at a cue-point marker).
            a.addEventListener("beatgrid:play", (e) => {
              // Single-track play (no set) clears any set plan so no stray crossfade fires;
              // set play leaves it — the server re-pushes set_plan in response to now_playing.
              if (!e.detail.set_id) { this.plan = null; this.setId = null }
              playSrc(e.detail.src, e.detail.preview, e.detail.at_ms)
              this.pushEvent("now_playing", {id: e.detail.id, set_id: e.detail.set_id || null})
            })

            // Server-initiated auto-advance: the server already updated now_playing,
            // so just play the next src (full track), no now_playing push.
            this.handleEvent("play_track", ({src}) => playSrc(src, false))

            a.addEventListener("beatgrid:toggle", () => a.paused ? a.play() : a.pause())
            a.addEventListener("beatgrid:stop", () => a.pause())

            // Body flag drives the now-playing disc spin (CSS), pause-aware + correct
            // for pages mounted mid-playback.
            const setPlaying = (on) => { document.body.dataset.playing = on ? "true" : "false" }

            a.addEventListener("play", () => {
              setIcon("⏸")
              setPlaying(true)
              window.dispatchEvent(new CustomEvent("beatgrid:playing", {detail: {source: "player-audio"}}))
            })
            a.addEventListener("pause", () => {
              setIcon("▶")
              setPlaying(false)
              window.dispatchEvent(new CustomEvent("beatgrid:paused"))
            })
            a.addEventListener("ended", () => {
              setIcon("▶")
              setPlaying(false)
              window.dispatchEvent(new CustomEvent("beatgrid:paused"))
              this.pushEvent("track_ended", {})
            })
            // A load/decode failure (e.g. a missing file mid-set) recovers the set by
            // skipping to the next track instead of stalling silently.
            a.addEventListener("error", () => {
              setIcon("▶")
              setPlaying(false)
              this.pushEvent("track_ended", {})
            })

            a.addEventListener("loadedmetadata", () => {
              const seek = byId("player-seek")
              const dur = byId("player-duration")
              if (seek) { seek.max = Math.floor(a.duration || 0); seek.value = 0 }
              if (dur) dur.textContent = fmt(a.duration)
              renderMarkers()
            })
            a.addEventListener("timeupdate", () => {
              const seek = byId("player-seek")
              const el = byId("player-elapsed")
              if (el) el.textContent = fmt(a.currentTime)
              if (seek && document.activeElement !== seek) seek.value = Math.floor(a.currentTime)
            })

            // --- Part 4b: dual-deck crossfade for set autoplay -----------------------
            // Deck A (#player-audio) stays primary (seek/markers/elapsed bound to it).
            // Deck B (#player-audio-b) plays the INCOMING track during the overlap; at the
            // end A reloads that track at B's exact position (same track, same spot = an
            // inaudible switch) and B stops, so A is primary again. NOTE: the volume ramp
            // runs on requestAnimationFrame — smooth in a foreground tab; a backgrounded
            // tab throttles rAF (audio keeps playing, the fade just gets coarse).
            const deckB = byId("player-audio-b")
            this.plan = null
            this.planIdx = 0
            this.setId = null
            this.xfading = false

            this.handleEvent("set_plan", ({set_id, tracks, index}) => {
              this.plan = tracks || null
              this.planIdx = index || 0
              this.setId = set_id
            })

            const currentBpm = () => (this.plan && this.plan[this.planIdx] && this.plan[this.planIdx].bpm) || null
            const clampRate = (r) => Math.max(0.94, Math.min(1.06, r))   // BPM nudge ±6%
            const W = 8000                                               // overlap window (ms)

            const handBackToA = (next, posSec) => {
              const resume = () => {
                a.removeEventListener("loadedmetadata", resume)
                a.currentTime = posSec
                a.volume = 1
                a.playbackRate = 1
                a.play()
                deckB.pause()
                this.planIdx++
                this.xfading = false
                this.pushEvent("now_playing", {id: next.id, set_id: this.setId})
              }
              a.src = next.src
              a.load()
              a.addEventListener("loadedmetadata", resume)
            }

            const startCrossfade = (next) => {
              if (!deckB || this.xfading) return
              this.xfading = true
              const tr = next.transition || {}
              const type = tr.type || "crossfade"
              const toMs = tr.to_ms || 0

              if (type === "cut") {
                this.planIdx++
                playSrc(next.src, false, toMs)
                this.pushEvent("now_playing", {id: next.id, set_id: this.setId})
                this.xfading = false
                return
              }

              const bpmA = currentBpm(), bpmB = next.bpm
              deckB.src = next.src
              deckB.load()
              const startB = () => {
                deckB.removeEventListener("loadedmetadata", startB)
                deckB.currentTime = toMs / 1000
                deckB.volume = 0
                deckB.playbackRate = (type === "crossfade" && bpmA && bpmB) ? clampRate(bpmA / bpmB) : 1
                deckB.play()
                const t0 = performance.now()
                const ramp = () => {
                  const p = Math.min(1, (performance.now() - t0) / W)
                  a.volume = Math.cos(p * Math.PI / 2)        // equal-power: A falls
                  deckB.volume = Math.sin(p * Math.PI / 2)    // B rises
                  if (p < 1) requestAnimationFrame(ramp)
                  else handBackToA(next, deckB.currentTime)
                }
                requestAnimationFrame(ramp)
              }
              deckB.addEventListener("loadedmetadata", startB)
            }

            // Arm the crossfade when A reaches the next track's `from_ms` (or ~10s before
            // the end when there's no outro marker). Only while a set plan is loaded.
            a.addEventListener("timeupdate", () => {
              if (this.xfading || !this.plan) return
              const next = this.plan[this.planIdx + 1]
              if (!next || !(next.transition && next.transition.enabled)) return
              const fromMs =
                next.transition.from_ms != null ? next.transition.from_ms : (a.duration || 0) * 1000 - 10000
              if (a.duration && a.currentTime * 1000 >= fromMs) startCrossfade(next)
            })

            const seek = byId("player-seek")
            if (seek) seek.addEventListener("input", () => { a.currentTime = Number(seek.value) })
            const vol = byId("player-volume")
            if (vol) vol.addEventListener("input", () => { a.volume = Number(vol.value) / 100 })

            window.addEventListener("beatgrid:playing", (e) => {
              if (e.detail.source !== "player-audio") { a.pause(); if (deckB) deckB.pause() }
            })
          }
        }
      </script>
    </div>
    """
  end
end
