defmodule BeatgridWeb.PlayerLive do
  @moduledoc """
  The single, app-wide audio player. Rendered once as a sticky nested LiveView in
  `app_shell`, so it keeps playing across live navigation. It owns the only
  `<audio>` element + the `.Player` colocated hook + the bottom banner.

  Playback is triggered client-side (`beatgrid:play` dispatched to `#player-audio`)
  for zero-latency start; the hook then pushes `now_playing` so this LiveView renders
  the cover/title/artist from the DB. Seek/time/volume are client-owned (the `<audio>`
  is the source of truth) inside a `phx-update="ignore"` region.
  """
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Playback

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, now_playing: nil), layout: false}
  end

  @impl true
  def handle_event("now_playing", %{"id" => id}, socket) do
    {:noreply, assign(socket, now_playing: Tracks.get_with_song(id))}
  end

  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, now_playing: nil)}
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

            a.addEventListener("beatgrid:play", (e) => {
              a.src = e.detail.src
              a.load()
              if (a._pendingStart) a.removeEventListener("loadedmetadata", a._pendingStart)
              const start = () => {
                const durMs = (a.duration || 0) * 1000
                a.currentTime = (e.detail.preview && durMs >= minDur) ? offset / 1000 : 0
                a.play()
                a.removeEventListener("loadedmetadata", start)
                a._pendingStart = null
              }
              a._pendingStart = start
              a.addEventListener("loadedmetadata", start)
              this.pushEvent("now_playing", {id: e.detail.id})
            })

            a.addEventListener("beatgrid:toggle", () => a.paused ? a.play() : a.pause())
            a.addEventListener("beatgrid:stop", () => a.pause())

            a.addEventListener("play", () => {
              setIcon("⏸")
              window.dispatchEvent(new CustomEvent("beatgrid:playing", {detail: {source: "player-audio"}}))
            })
            a.addEventListener("pause", () => setIcon("▶"))
            a.addEventListener("ended", () => setIcon("▶"))

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
