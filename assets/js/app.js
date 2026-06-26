// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/beatgrid"
import topbar from "../vendor/topbar"
import WaveSurfer from "../vendor/wavesurfer.esm.js"

// Waveform player for the track detail: scrub by clicking the wave, play/pause,
// and "mark this moment" cue points drawn over the wave (data from the server).
const Hooks = {
  Waveform: {
    mounted() {
      this.ws = WaveSurfer.create({
        container: this.el,
        url: this.el.dataset.audio,
        height: 76,
        waveColor: "#3a3d48",
        progressColor: "#8b7bf0",
        cursorColor: "#eef0f5",
        barWidth: 2,
        barGap: 1,
        barRadius: 2
      })
      this.markers = JSON.parse(this.el.dataset.markers || "[]")

      this.ws.on("ready", () => this.drawMarkers())
      this.ws.on("play", () => {
        this.setToggle("⏸")
        window.dispatchEvent(new CustomEvent("beatgrid:playing", {detail: {source: "waveform"}}))
      })
      this.ws.on("pause", () => this.setToggle("▶"))
      this.ws.on("finish", () => this.setToggle("▶"))

      this.el.addEventListener("beatgrid:toggle", () => this.ws.playPause())
      this.el.addEventListener("beatgrid:mark", () =>
        this.pushEvent("add_marker", {ms: Math.round(this.ws.getCurrentTime() * 1000)})
      )
      this.el.addEventListener("beatgrid:seek", (e) => {
        if (this.ws.getDuration()) this.ws.setTime(e.detail.ms / 1000)
      })
      this.handleEvent("markers", ({markers}) => {
        this.markers = markers
        this.drawMarkers()
      })
      this._pauseOnOthers = (e) => {
        if (e.detail.source !== "waveform") this.ws.pause()
      }
      window.addEventListener("beatgrid:playing", this._pauseOnOthers)
    },
    setToggle(txt) {
      const b = document.getElementById("wf-toggle")
      if (b) b.textContent = txt
    },
    drawMarkers() {
      const wrap = this.el.parentElement
      const dur = this.ws.getDuration()
      wrap.querySelectorAll(".wf-marker").forEach((m) => m.remove())
      if (!dur) return
      this.markers.forEach((m) => {
        const line = document.createElement("div")
        line.className = "wf-marker"
        line.style.cssText =
          `position:absolute;top:0;bottom:0;width:2px;background:#ffb020;` +
          `left:${(m.ms / 1000 / dur) * 100}%;pointer-events:none;z-index:5`
        wrap.appendChild(line)
      })
    },
    destroyed() {
      window.removeEventListener("beatgrid:playing", this._pauseOnOthers)
      this.ws && this.ws.destroy()
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

