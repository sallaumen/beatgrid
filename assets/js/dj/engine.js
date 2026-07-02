// Dual-deck WebAudio engine for the Discotecagem console.
//
// Post-mortem rules this module exists to enforce (see
// docs/superpowers/specs/2026-07-02-discotecagem-design.md):
//   - ALL gain moves through GainNode automation timelines — never
//     HTMLMediaElement.volume, never requestAnimationFrame ramps. Interrupted
//     automations are cancelable without stranding gain near zero.
//   - Each deck owns ONE fixed <audio> element; the incoming track always loads
//     on the idle deck. `src` is never swapped while a deck is audible.
//   - Nothing audible starts before `canplay` on the target deck.
//   - Every async continuation is token-guarded.
//   - The engine never advances the set on its own: it fires the transition it
//     was armed with and reports; order authority lives on the server.
//
// Graph per deck:
//   <audio> → MediaElementSource → deckGain ─┬─ dry ────────────┐
//                                            └─ echoSend → Delay┤→ channel → xfadeGain → master → destination
//                                                   ↺ feedback  │           (analyser taps: channel + master)

const RAMP = Object.freeze({
  manualFaderTau: 0.01, // s — smoothing for hand moves (kills zipper noise)
  fadeOutS: 2.2,
  fadeInS: 2.2,
  crossfadeS: 8.0,
  echoWetUpS: 1.2,
  echoDryDownS: 1.2,
  echoInS: 0.5,
  echoTailBeats: 4,
  echoFeedback: 0.55,
  echoWetLevel: 0.85,
  echoFallbackDelayMs: 375,
})

const SYNC_RATE_CLAMP = 0.08 // ±8%, matching the set-builder's bpm_close? band

// The AudioContext and MediaElementSource nodes must survive LiveView remounts:
// createMediaElementSource() works exactly once per element, forever.
let sharedCtx = null

function context() {
  if (!sharedCtx) sharedCtx = new (window.AudioContext || window.webkitAudioContext)()
  return sharedCtx
}

function sourceFor(el) {
  if (!el._djSource) el._djSource = context().createMediaElementSource(el)
  return el._djSource
}

function equalPower(pos) {
  // pos 0 = full A, 1 = full B.
  return {a: Math.cos((pos * Math.PI) / 2), b: Math.cos(((1 - pos) * Math.PI) / 2)}
}

class Deck {
  constructor(id, el, ctx) {
    this.id = id
    this.el = el
    this.ctx = ctx
    this.trackId = null
    this.bpm = null
    this.durationMs = null
    this.loadToken = 0

    this.gain = ctx.createGain() // deck level fader
    this.dry = ctx.createGain()
    this.echoSend = ctx.createGain()
    this.delay = ctx.createDelay(2.0)
    this.feedback = ctx.createGain()
    this.channel = ctx.createGain() // post-fader channel bus (metered)
    this.analyser = ctx.createAnalyser()
    this.analyser.fftSize = 256
    this._meterBuf = new Uint8Array(this.analyser.fftSize)

    this.echoSend.gain.value = 0
    this.feedback.gain.value = RAMP.echoFeedback

    sourceFor(el).disconnect()
    sourceFor(el).connect(this.gain)
    this.gain.connect(this.dry)
    this.gain.connect(this.echoSend)
    this.echoSend.connect(this.delay)
    this.delay.connect(this.feedback)
    this.feedback.connect(this.delay) // the echo tail
    this.dry.connect(this.channel)
    this.delay.connect(this.channel)
    this.channel.connect(this.analyser)
  }

  // Loading is REFUSED while audible — the incoming track belongs on the idle deck.
  load(track, atMs = 0) {
    if (this.audible()) return false
    const token = ++this.loadToken
    this.trackId = track.id
    this.bpm = track.bpm || null
    this.durationMs = track.duration_ms || null
    this.el.src = track.src
    this.el.load()
    this._pendingSeekMs = atMs
    this._readyToken = token
    return true
  }

  ready() {
    return this.el.readyState >= 3 // HAVE_FUTURE_DATA — the canplay gate
  }

  whenReady(fn) {
    if (this.ready()) return fn()
    const token = this.loadToken
    const once = () => {
      this.el.removeEventListener("canplay", once)
      if (token === this.loadToken) fn()
    }
    this.el.addEventListener("canplay", once)
  }

  play(atMs = null) {
    const seek = atMs != null ? atMs : this._pendingSeekMs
    this._pendingSeekMs = null

    this.whenReady(() => {
      if (seek != null) this.el.currentTime = seek / 1000
      this.el.play().catch(() => {})
    })
  }

  pause() {
    this.el.pause()
  }

  audible() {
    return !this.el.paused && !this.el.ended && this.trackId != null
  }

  positionMs() {
    return Math.round(this.el.currentTime * 1000)
  }

  // SYNC: match this deck's tempo to `targetBpm`; the rate KEEPS for the rest of
  // the track (the old engine's snap-back at handoff was audible), reset on load.
  syncTo(targetBpm) {
    if (!this.bpm || !targetBpm) return false
    const rate = targetBpm / this.bpm
    const clamped = Math.min(1 + SYNC_RATE_CLAMP, Math.max(1 - SYNC_RATE_CLAMP, rate))
    this.el.preservesPitch = true
    this.el.playbackRate = clamped
    return true
  }

  resetRate() {
    this.el.playbackRate = 1
  }

  level() {
    this.analyser.getByteTimeDomainData(this._meterBuf)
    let sum = 0
    for (const v of this._meterBuf) {
      const c = (v - 128) / 128
      sum += c * c
    }
    return Math.sqrt(sum / this._meterBuf.length)
  }

  // Cancel any scheduled automation and settle at the CURRENT value — the fix
  // for the stranded-near-zero ramps: interruption never abandons the gain.
  settleGain(node) {
    const now = this.ctx.currentTime
    const current = node.gain.value
    node.gain.cancelScheduledValues(now)
    node.gain.setValueAtTime(current, now)
  }

  destroyGraph() {
    for (const node of [this.gain, this.dry, this.echoSend, this.delay, this.feedback, this.channel, this.analyser]) {
      try {
        node.disconnect()
      } catch (_e) {
        // already disconnected
      }
    }
    try {
      sourceFor(this.el).disconnect()
    } catch (_e) {
      // idem
    }
  }
}

export function createEngine({deckElA, deckElB, callbacks = {}}) {
  const ctx = context()
  const master = ctx.createGain()
  const masterAnalyser = ctx.createAnalyser()
  masterAnalyser.fftSize = 256
  const masterBuf = new Uint8Array(masterAnalyser.fftSize)

  const decks = {
    a: new Deck("a", deckElA, ctx),
    b: new Deck("b", deckElB, ctx),
  }
  const xfade = {a: ctx.createGain(), b: ctx.createGain(), pos: 0.5}

  decks.a.channel.connect(xfade.a)
  decks.b.channel.connect(xfade.b)
  xfade.a.connect(master)
  xfade.b.connect(master)
  master.connect(masterAnalyser)
  masterAnalyser.connect(ctx.destination)

  const g = equalPower(xfade.pos)
  xfade.a.gain.value = g.a
  xfade.b.gain.value = g.b

  const state = {
    activeDeck: null, // "a" | "b" | null
    hint: null, // {deck, track, transition} armed on the idle deck
    transitionToken: 0,
    firedForTrack: null, // dedupes transition vs ended for one boundary
    autoOn: false,
  }

  const emit = (name, payload) => callbacks[name] && callbacks[name](payload)

  // ── boundary handling: ONE advance per track, whatever triggers it ──────────

  function boundaryOnce(trackId, fn) {
    if (state.firedForTrack === trackId) return
    state.firedForTrack = trackId
    fn()
  }

  function watchOutgoing(deck) {
    deck.el.addEventListener("timeupdate", () => maybeFire(deck))
    // A deck going silent is the moment a queued hint can claim it. Event-driven
    // on purpose: rAF loops don't run in background tabs, and re-arming the next
    // track must not depend on the page being visible.
    deck.el.addEventListener("pause", () => emit("deckFreed", {deck: deck.id}))
    deck.el.addEventListener("ended", () => {
      if (deck.id !== state.activeDeck) return
      const hint = state.hint
      if (state.autoOn && hint && decks[hint.deck].trackId != null) {
        // Sequential entry (no transition) or a missed window: advance with a cut.
        boundaryOnce(deck.trackId, () =>
          fireTransition(deck, decks[hint.deck], {
            ...hint,
            transition: hint.transition || {type: "cut", to_ms: 0},
          })
        )
      } else {
        boundaryOnce(deck.trackId, () => emit("trackEnded", {trackId: deck.trackId}))
      }
    })
    deck.el.addEventListener("error", () => {
      if (deck.trackId == null) return
      emit("deckError", {deck: deck.id, trackId: deck.trackId})
    })
  }

  function maybeFire(deck) {
    const hint = state.hint
    if (!state.autoOn || !hint || deck.id !== state.activeDeck) return
    if (!hint.transition) return // sequential entries advance on `ended`

    const fromMs = clampFromMs(hint.transition["from_ms"], deck)
    if (deck.positionMs() < fromMs) return

    boundaryOnce(deck.trackId, () => fireTransition(deck, decks[hint.deck], hint))
  }

  // The server already clamped against its known duration; re-clamp against the
  // REAL media duration (never-again #4 applies twice).
  function clampFromMs(fromMs, deck) {
    const durMs = (deck.el.duration || 0) * 1000
    if (!durMs) return fromMs ?? Infinity
    const fallback = durMs - 8000
    return Math.max(Math.min(fromMs ?? fallback, durMs - 1500), durMs / 2, 0)
  }

  // ── transitions ──────────────────────────────────────────────────────────────

  function fireTransition(from, to, hint) {
    const token = ++state.transitionToken
    const type = hint.transition["type"] || "cut"
    const toMs = hint.transition["to_ms"] || 0

    emit("transitionStarted", {
      fromTrackId: from.trackId,
      toTrackId: to.trackId,
      type,
      deck: to.id,
    })

    const run = {cut, fade, crossfade, echo}[type] || cut
    run(from, to, toMs, token)
    state.activeDeck = to.id
    state.hint = null
    state.firedForTrack = null
  }

  function cut(from, to, toMs) {
    from.pause()
    to.play(toMs)
    setXfadeTo(to.id, 0.15)
  }

  function fade(from, to, toMs, token) {
    const now = ctx.currentTime
    from.settleGain(from.gain)
    from.gain.gain.linearRampToValueAtTime(0, now + RAMP.fadeOutS)

    to.gain.gain.setValueAtTime(0, now)
    to.play(toMs)
    to.gain.gain.linearRampToValueAtTime(1, now + RAMP.fadeOutS + RAMP.fadeInS)
    setXfadeTo(to.id, RAMP.fadeOutS)

    after(RAMP.fadeOutS + 0.1, () => {
      if (token !== state.transitionToken) return
      from.pause()
      restoreDeckGain(from)
    })
  }

  function crossfade(from, to, toMs, token) {
    if (from.bpm) to.syncTo(from.bpm * from.el.playbackRate)
    to.play(toMs)
    setXfadeTo(to.id, RAMP.crossfadeS)

    after(RAMP.crossfadeS + 0.2, () => {
      if (token !== state.transitionToken) return
      from.pause()
    })
  }

  // The requested classic: a strong beat-synced feedback delay swells on the
  // outgoing deck while its dry signal drops; the tail rings as the next track
  // enters. Delay = dotted eighth of the outgoing tempo.
  function echo(from, to, toMs, token) {
    const now = ctx.currentTime
    const bpm = from.bpm ? from.bpm * from.el.playbackRate : null
    const delayS = bpm ? (60 / bpm) * 0.75 : RAMP.echoFallbackDelayMs / 1000
    const tailS = bpm ? (60 / bpm) * RAMP.echoTailBeats : 2.5

    from.delay.delayTime.setValueAtTime(Math.min(delayS, 2.0), now)
    from.settleGain(from.echoSend)
    from.settleGain(from.dry)
    from.echoSend.gain.linearRampToValueAtTime(RAMP.echoWetLevel, now + RAMP.echoWetUpS)
    from.dry.gain.linearRampToValueAtTime(0, now + RAMP.echoDryDownS)

    to.gain.gain.setValueAtTime(0, now)
    to.play(toMs)
    to.gain.gain.linearRampToValueAtTime(1, now + RAMP.echoInS)
    setXfadeTo(to.id, RAMP.echoWetUpS + tailS * 0.5)

    after(RAMP.echoDryDownS + tailS, () => {
      if (token !== state.transitionToken) return
      const end = ctx.currentTime
      from.echoSend.gain.cancelScheduledValues(end)
      from.echoSend.gain.setValueAtTime(from.echoSend.gain.value, end)
      from.echoSend.gain.linearRampToValueAtTime(0, end + 0.4)
      after(0.5, () => {
        if (token !== state.transitionToken) return
        from.pause()
        restoreDeckGain(from)
      })
    })

    emit("echoState", {deck: from.id, on: true, delayMs: Math.round(delayS * 1000)})
    after(RAMP.echoDryDownS + tailS + 0.6, () => emit("echoState", {deck: from.id, on: false}))
  }

  function restoreDeckGain(deck) {
    const now = ctx.currentTime
    deck.settleGain(deck.gain)
    deck.gain.gain.setValueAtTime(1, now)
    deck.settleGain(deck.dry)
    deck.dry.gain.setValueAtTime(1, now)
    deck.settleGain(deck.echoSend)
    deck.echoSend.gain.setValueAtTime(0, now)
    deck.resetRate()
  }

  // ── crossfader (automated glides + manual takeover) ─────────────────────────

  function setXfadeTo(deckId, seconds) {
    const target = deckId === "a" ? 0 : 1
    const now = ctx.currentTime
    for (const side of ["a", "b"]) {
      const node = xfade[side]
      const current = node.gain.value
      node.gain.cancelScheduledValues(now)
      node.gain.setValueAtTime(current, now)
      node.gain.linearRampToValueAtTime(equalPower(target)[side], now + Math.max(seconds, 0.05))
    }
    animateXfadePos(target, seconds)
  }

  let xfadeAnim = null
  let xfadeGlide = 0

  function animateXfadePos(target, seconds) {
    // UI-only mirror of the audio ramp: audio never depends on this rAF loop.
    cancelAnimationFrame(xfadeAnim)
    const start = performance.now()
    const from = xfade.pos
    const tick = (t) => {
      const p = Math.min((t - start) / (seconds * 1000), 1)
      xfade.pos = from + (target - from) * p
      emit("xfadePos", {pos: xfade.pos, automated: true})
      if (p < 1) xfadeAnim = requestAnimationFrame(tick)
    }
    xfadeAnim = requestAnimationFrame(tick)

    // Background tabs freeze rAF — settle the mirrored position at the end of
    // the glide regardless, unless a manual move took over meanwhile.
    const glide = ++xfadeGlide
    setTimeout(() => {
      if (glide !== xfadeGlide) return
      xfade.pos = target
      emit("xfadePos", {pos: target, automated: true})
    }, seconds * 1000 + 60)
  }

  // Manual gesture (UI or MIDI): cancel any automated glide and take over.
  function setCrossfader(pos) {
    xfadeGlide++
    cancelAnimationFrame(xfadeAnim)
    xfade.pos = Math.min(Math.max(pos, 0), 1)
    const g2 = equalPower(xfade.pos)
    const now = ctx.currentTime
    for (const side of ["a", "b"]) {
      xfade[side].gain.cancelScheduledValues(now)
      xfade[side].gain.setTargetAtTime(g2[side], now, RAMP.manualFaderTau)
    }
    emit("xfadePos", {pos: xfade.pos, automated: false})
  }

  function setDeckLevel(deckId, value) {
    const deck = decks[deckId]
    const now = ctx.currentTime
    deck.gain.gain.cancelScheduledValues(now)
    deck.gain.gain.setTargetAtTime(Math.min(Math.max(value, 0), 1), now, RAMP.manualFaderTau)
  }

  function setMasterLevel(value) {
    const now = ctx.currentTime
    master.gain.cancelScheduledValues(now)
    master.gain.setTargetAtTime(Math.min(Math.max(value, 0), 1.2), now, RAMP.manualFaderTau)
  }

  watchOutgoing(decks.a)
  watchOutgoing(decks.b)

  return {
    ctx,
    decks,

    resume() {
      if (ctx.state === "suspended") ctx.resume()
    },

    loadDeck(deckId, track, {autoplay = false, atMs = 0} = {}) {
      const deck = decks[deckId]
      if (!deck.load(track, atMs)) return false
      if (autoplay) {
        this.resume()
        restoreDeckGain(deck)
        deck.play()
        state.activeDeck = deckId
        state.firedForTrack = null
        emit("deckStarted", {deck: deckId, trackId: track.id})
      }
      return true
    },

    // The revocable lookahead: (re)load the hint's track on the idle deck. A
    // fresh hint for the same boundary simply replaces the preload — this is
    // how a live set edit swaps the next track before the transition fires.
    armHint(hint) {
      const idle = state.activeDeck === "a" ? "b" : "a"
      const deck = decks[idle]
      if (deck.audible()) return false
      restoreDeckGain(deck)
      deck.load(hint.track, hint.transition ? hint.transition["to_ms"] || 0 : 0)
      state.hint = {...hint, deck: idle}
      return idle
    },

    clearHint() {
      state.hint = null
    },

    setAuto(on) {
      state.autoOn = on
    },

    playPause(deckId) {
      const deck = decks[deckId]
      this.resume()
      if (deck.audible()) {
        deck.pause()
      } else if (deck.trackId) {
        deck.play()
        state.activeDeck = deckId
        state.firedForTrack = null
        emit("deckStarted", {deck: deckId, trackId: deck.trackId})
      }
    },

    cueTo(deckId, ms) {
      const deck = decks[deckId]
      if (deck.trackId == null) return
      deck.whenReady(() => {
        deck.el.currentTime = ms / 1000
      })
    },

    nudge(deckId, deltaMs) {
      const deck = decks[deckId]
      if (deck.trackId == null) return
      deck.el.currentTime = Math.max(deck.el.currentTime + deltaMs / 1000, 0)
    },

    sync(deckId) {
      const other = decks[deckId === "a" ? "b" : "a"]
      return decks[deckId].syncTo(other.bpm ? other.bpm * other.el.playbackRate : null)
    },

    setRate(deckId, rate) {
      const deck = decks[deckId]
      deck.el.preservesPitch = true
      deck.el.playbackRate = Math.min(Math.max(rate, 1 - SYNC_RATE_CLAMP), 1 + SYNC_RATE_CLAMP)
    },

    setCrossfader,
    setDeckLevel,
    setMasterLevel,

    stopAll() {
      decks.a.pause()
      decks.b.pause()
      state.activeDeck = null
      state.hint = null
    },

    // Pause without losing state — used when another audio source (o player
    // global) takes over; loads and the armed hint survive.
    pauseAll() {
      decks.a.pause()
      decks.b.pause()
    },

    snapshot() {
      return {
        activeDeck: state.activeDeck,
        xfadePos: xfade.pos,
        a: {trackId: decks.a.trackId, posMs: decks.a.positionMs(), playing: decks.a.audible()},
        b: {trackId: decks.b.trackId, posMs: decks.b.positionMs(), playing: decks.b.audible()},
      }
    },

    levels() {
      masterAnalyser.getByteTimeDomainData(masterBuf)
      let sum = 0
      for (const v of masterBuf) {
        const c = (v - 128) / 128
        sum += c * c
      }
      return {a: decks.a.level(), b: decks.b.level(), master: Math.sqrt(sum / masterBuf.length)}
    },

    destroy() {
      cancelAnimationFrame(xfadeAnim)
      decks.a.pause()
      decks.b.pause()
      decks.a.destroyGraph()
      decks.b.destroyGraph()
      for (const node of [xfade.a, xfade.b, master, masterAnalyser]) {
        try {
          node.disconnect()
        } catch (_e) {
          // already disconnected
        }
      }
    },
  }

  function after(seconds, fn) {
    setTimeout(fn, seconds * 1000)
  }
}
