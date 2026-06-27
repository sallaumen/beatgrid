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
    {:ok, assign(socket, now_playing: nil, playing_set: nil), layout: false}
  end

  @impl true
  def handle_event("now_playing", %{"id" => id} = params, socket) do
    set_id = params["set_id"]
    Playback.set_now_playing(%{track_id: id, set_id: set_id})

    {:noreply,
     assign(socket, now_playing: Tracks.get_with_song(id), playing_set: load_playing_set(set_id))}
  end

  def handle_event("track_ended", _params, socket), do: advance(socket)

  def handle_event("close", _params, socket) do
    Playback.clear_now_playing()
    {:noreply, assign(socket, now_playing: nil, playing_set: nil)}
  end

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
         |> push_event("play_track", %{src: ~p"/audio/#{next.id}", id: next.id})}
    end
  end

  defp advance(socket), do: {:noreply, socket}

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
          <input
            id="player-seek"
            type="range"
            min="0"
            max="100"
            value="0"
            class="h-1 flex-1"
            style="accent-color:#8b7bf0"
          />
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

            // Load + play a src; preview jumps to the configured offset for long tracks.
            const playSrc = (src, preview) => {
              a.src = src
              a.load()
              if (a._pendingStart) a.removeEventListener("loadedmetadata", a._pendingStart)
              const start = () => {
                const durMs = (a.duration || 0) * 1000
                a.currentTime = (preview && durMs >= minDur) ? offset / 1000 : 0
                a.play()
                a.removeEventListener("loadedmetadata", start)
                a._pendingStart = null
              }
              a._pendingStart = start
              a.addEventListener("loadedmetadata", start)
            }

            // User-initiated play from a page (may carry a set_id for set playback).
            a.addEventListener("beatgrid:play", (e) => {
              playSrc(e.detail.src, e.detail.preview)
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

            a.addEventListener("loadedmetadata", () => {
              const seek = byId("player-seek")
              const dur = byId("player-duration")
              if (seek) { seek.max = Math.floor(a.duration || 0); seek.value = 0 }
              if (dur) dur.textContent = fmt(a.duration)
            })
            a.addEventListener("timeupdate", () => {
              const seek = byId("player-seek")
              const el = byId("player-elapsed")
              if (el) el.textContent = fmt(a.currentTime)
              if (seek && document.activeElement !== seek) seek.value = Math.floor(a.currentTime)
            })

            const seek = byId("player-seek")
            if (seek) seek.addEventListener("input", () => { a.currentTime = Number(seek.value) })
            const vol = byId("player-volume")
            if (vol) vol.addEventListener("input", () => { a.volume = Number(vol.value) / 100 })

            window.addEventListener("beatgrid:playing", (e) => {
              if (e.detail.source !== "player-audio") a.pause()
            })
          }
        }
      </script>
    </div>
    """
  end
end
