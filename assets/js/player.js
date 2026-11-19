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
    this.playToken = 0
    this.lastAdvanceToken = null
    this.loadingAudio = false
    this.activeSetId = null
    let autoplayOnLoad = false

    const safePlay = (el) => {
      const attempt = el.play()
      if (attempt && typeof attempt.catch === "function") {
        attempt.catch((err) => {
          if (!err || err.name === "AbortError") return
          console.warn("Beatgrid playback failed", err)
        })
      }
    }

    const clearPendingStart = () => {
      if (!a._pendingStart) return
      a.removeEventListener("loadedmetadata", a._pendingStart)
      a._pendingStart = null
    }

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
      this.playToken++
      const token = this.playToken
      autoplayOnLoad = true
      this.lastAdvanceToken = null
      if (lane) lane.innerHTML = ""
      clearPendingStart()
      const start = () => {
        a.removeEventListener("loadedmetadata", start)
        if (token !== this.playToken) return
        this.loadingAudio = false
        const durMs = (a.duration || 0) * 1000
        if (atMs != null) a.currentTime = atMs / 1000
        else a.currentTime = (preview && durMs >= minDur) ? offset / 1000 : 0
        // Volume is client-owned: it persists on this phx-update="ignore" <audio>
        // element and is only changed by the slider's input listener. Do NOT reset
        // it per load — that snapped the volume on every track change (live bug).
        a.playbackRate = 1
        if (autoplayOnLoad) safePlay(a)
        a._pendingStart = null
      }
      const absoluteSrc = new URL(src, window.location.href).href
      this.loadingAudio = true
      a._pendingStart = start
      if ((a.currentSrc === absoluteSrc || a.src === absoluteSrc) && a.readyState >= 1) {
        start()
      } else {
        a.src = src
        a.load()
        a.addEventListener("loadedmetadata", start)
      }
    }

    // User-initiated play from a page (may carry a set_id for set playback, or
    // an at_ms to start straight at a cue-point marker).
    a.addEventListener("beatgrid:play", (e) => {
      this.activeSetId = e.detail.set_id || null
      playSrc(e.detail.src, e.detail.preview, e.detail.at_ms)
      this.pushEvent("now_playing", {id: e.detail.id, set_id: e.detail.set_id || null})
    })

    // Server-initiated auto-advance: the server already updated now_playing,
    // so just play the next src (full track), no now_playing push.
    this.handleEvent("play_track", ({src}) => playSrc(src, false))

    a.addEventListener("beatgrid:toggle", () => {
      if (this.loadingAudio) {
        autoplayOnLoad = !autoplayOnLoad
        if (!autoplayOnLoad) this.pushEvent("playback_paused", {})
      } else if (a.paused) {
        safePlay(a)
      } else {
        a.pause()
      }
    })
    a.addEventListener("beatgrid:stop", () => {
      this.playToken++
      this.activeSetId = null
      this.loadingAudio = false
      clearPendingStart()
      a.pause()
      a.removeAttribute("src")
      a.load()
    })

    const requestAdvance = () => {
      const hasSet = this.activeSetId != null
      if (!hasSet || this.lastAdvanceToken === this.playToken) return
      this.lastAdvanceToken = this.playToken
      this.pushEvent("track_ended", {})
    }

    // Body flag drives the now-playing disc spin (CSS), pause-aware + correct
    // for pages mounted mid-playback.
    const setPlaying = (on) => { document.body.dataset.playing = on ? "true" : "false" }

    a.addEventListener("play", () => {
      setIcon("⏸")
      setPlaying(true)
      this.pushEvent("playback_playing", {set_id: this.activeSetId || null})
      window.dispatchEvent(new CustomEvent("beatgrid:playing", {detail: {source: "player-audio"}}))
    })
    a.addEventListener("pause", () => {
      setIcon("▶")
      setPlaying(false)
      if (!this.loadingAudio) this.pushEvent("playback_paused", {})
      window.dispatchEvent(new CustomEvent("beatgrid:paused"))
    })
    a.addEventListener("ended", () => {
      setIcon("▶")
      setPlaying(false)
      this.pushEvent("playback_paused", {})
      window.dispatchEvent(new CustomEvent("beatgrid:paused"))
      requestAdvance()
    })
    a.addEventListener("error", () => {
      setIcon("▶")
      setPlaying(false)
      if (!this.loadingAudio) this.pushEvent("playback_paused", {})
      console.warn("Beatgrid media error", a.error)
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

    const seek = byId("player-seek")
    if (seek) seek.addEventListener("input", () => { a.currentTime = Number(seek.value) })
    const vol = byId("player-volume")
    if (vol) vol.addEventListener("input", () => { a.volume = Number(vol.value) / 100 })

    window.addEventListener("beatgrid:playing", (e) => {
      if (e.detail.source === "player-audio") return
      autoplayOnLoad = false
      a.pause()
    })
  }
}
