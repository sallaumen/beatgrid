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
//     was armed with (or the one the DJ requests) and reports; order authority
//     lives on the server.
//   - Audio-critical continuations are event/timeout-driven, never rAF-driven:
//     rAF freezes in background tabs.
//
// Graph per deck:
//   <audio> → Source → deckGain → HPF → bass shelf ─┬─ dry ────────────┐
//                                                   └─ echoSend → Delay┤→ channel → xfadeGain → master → out
//                                                          ↺ feedback  │   (analyser taps: channel + master)
//
// The HPF (transparent at 10 Hz) drives the "filtro" sweep; the low shelf
// (flat at 0 dB) drives the "troca de grave" bass swap.

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
  filterS: 4.0, // full high-pass sweep on the outgoing deck
  filterTopHz: 1600,
  bassOverlapS: 4.0, // both tracks run together before the bass swap
  bassSwapMoveS: 0.35, // the swap itself is fast — that's the trick
  bassCutDb: -24,
  brakeS: 1.1, // vinyl brake: platter stops in about a second
  autoFireSlackMs: 15_000, // AUTO won't fire a window it is already far past
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

function sideOf(deckId) {
  return deckId === "a" ? 0 : 1
}

function otherId(deckId) {
  return deckId === "a" ? "b" : "a"
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
    this.hpf = ctx.createBiquadFilter() // "filtro" sweep; 10 Hz = transparent
    this.hpf.type = "highpass"
    this.hpf.frequency.value = 10
    this.bass = ctx.createBiquadFilter() // "troca de grave"; 0 dB = flat
    this.bass.type = "lowshelf"
    this.bass.frequency.value = 200
    this.bass.gain.value = 0
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
    this.gain.connect(this.hpf)
    this.hpf.connect(this.bass)
    this.bass.connect(this.dry)
    this.bass.connect(this.echoSend)
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
    return !this.el.paused && !this.el.ended && !this.el.error && this.trackId != null
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
    this.el.preservesPitch = true
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

  // Cancel scheduled automation and settle at the CURRENT value — the fix for
  // the stranded-near-zero ramps: interruption never abandons a param mid-air.
  settleParam(param) {
    const now = this.ctx.currentTime
    const current = param.value
    param.cancelScheduledValues(now)
    param.setValueAtTime(current, now)
  }

  settleGain(node) {
    this.settleParam(node.gain)
  }

  destroyGraph() {
    const nodes = [
      this.gain,
      this.hpf,
      this.bass,
      this.dry,
      this.echoSend,
      this.delay,
      this.feedback,
      this.channel,
      this.analyser,
    ]
    for (const node of nodes) {
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
    activeDeck: null, // "a" | "b" | null — who owns the set boundary
    hint: null, // {deck, track, transition} armed on the idle deck
    transitionToken: 0,
    firedForTrack: null, // dedupes transition vs ended for one boundary
    lastFireAt: null, // performance.now() of the last fired transition
    autoOn: false,
  }

  const emit = (name, payload) => callbacks[name] && callbacks[name](payload)

  // "No ar" = the deck the crossfader favors, among the ones actually playing.
  // With both decks running (mid-mix) the knob decides — not the play buttons.
  function audibleDeckId() {
    const aOn = decks.a.audible()
    const bOn = decks.b.audible()
    if (aOn && bOn) {
      // Dead center (e.g. bass_swap parks at 0.5 for the whole overlap): the
      // knob says nothing, so the boundary owner is "no ar" — not always A.
      if (Math.abs(xfade.pos - 0.5) < 0.02 && state.activeDeck) return state.activeDeck
      return xfade.pos <= 0.5 ? "a" : "b"
    }
    if (aOn) return "a"
    if (bOn) return "b"
    return null
  }

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
      const other = decks[otherId(deck.id)]

      if (state.autoOn && hint && decks[hint.deck].trackId != null) {
        // The outgoing deck is ALREADY silent here — running the marked
        // transition (an 8s crossfade from a dead deck…) would be seconds of
        // near-silence. End of track always advances with a cut.
        boundaryOnce(deck.trackId, () =>
          fireTransition(
            deck,
            decks[hint.deck],
            {type: "cut", to_ms: (hint.transition && hint.transition["to_ms"]) ?? 0},
            "auto"
          )
        )
      } else if (other.audible()) {
        // Manual mid-mix: this track ran out while the other deck carries the
        // sound. Hand the boundary over quietly — no "end of set".
        state.activeDeck = other.id
        state.firedForTrack = null
      } else {
        boundaryOnce(deck.trackId, () => emit("trackEnded", {trackId: deck.trackId}))
      }
    })
    deck.el.addEventListener("error", () => {
      if (deck.trackId == null) return
      // A fatally-errored element must not keep reading as "audible" — pause it
      // so the deck frees up (deckFreed) and recovery loads are not refused.
      deck.pause()
      emit("deckError", {deck: deck.id, trackId: deck.trackId})
    })
  }

  function maybeFire(deck) {
    const hint = state.hint
    if (!state.autoOn || !hint || deck.id !== state.activeDeck) return
    if (!hint.transition) return // sequential entries advance on `ended`

    const fromMs = clampFromMs(hint.transition["from_ms"], deck)
    const pos = deck.positionMs()
    // Inside the window only: toggling AUTO on far past the mark must not slam
    // an instant transition — the ended fallback covers the overshoot.
    if (pos < fromMs || pos > fromMs + RAMP.autoFireSlackMs) return

    boundaryOnce(deck.trackId, () => fireTransition(deck, decks[hint.deck], hint.transition, "auto"))
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

  const TRANSITIONS = () => ({cut, fade, crossfade, echo, filter, bass_swap: bassSwap, brake})

  function fireTransition(from, to, transition, mode) {
    const token = ++state.transitionToken
    state.lastFireAt = performance.now()
    const type = transition["type"] || "cut"
    // null → the incoming deck starts wherever it is cued (manual fire); armed
    // hints resolved their to_ms into the pending seek at load time.
    const toMs = transition["to_ms"] ?? null

    emit("transitionStarted", {
      fromTrackId: from.trackId,
      toTrackId: to.trackId,
      type,
      deck: to.id,
      mode,
    })

    // A transition interrupted by this one must not keep steering either deck:
    // kill every scheduled ramp NOW (invariant 2 — a pending ramp-to-zero on
    // the deck going back on air is the dead-air bug from the party).
    settleTransitionParams(from)
    settleTransitionParams(to)
    neutralizeIncoming(to, type)

    const run = TRANSITIONS()[type] || cut
    run(from, to, toMs, token)
    state.activeDeck = to.id
    state.hint = null
    state.firedForTrack = null
  }

  function settleTransitionParams(deck) {
    deck.settleParam(deck.gain.gain)
    deck.settleParam(deck.dry.gain)
    deck.settleParam(deck.echoSend.gain)
    deck.settleParam(deck.hpf.frequency)
    deck.settleParam(deck.bass.gain)
  }

  // The deck going on air must not inherit FX from an interrupted transition
  // (dry at zero, echo send open, filter swept). Short ramps, never jumps —
  // it may already be audible. Params the incoming transition owns are left
  // for it to set.
  function neutralizeIncoming(to, type) {
    const now = ctx.currentTime
    to.dry.gain.linearRampToValueAtTime(1, now + 0.3)
    to.echoSend.gain.linearRampToValueAtTime(0, now + 0.3)
    to.hpf.frequency.linearRampToValueAtTime(10, now + 0.2)
    if (type !== "bass_swap") to.bass.gain.linearRampToValueAtTime(0, now + 0.3)
    if (type === "cut" || type === "crossfade" || type === "brake") {
      to.gain.gain.linearRampToValueAtTime(1, now + 0.2)
    }
  }

  // Start the incoming deck — unless it is already in the mix (manual fire with
  // both decks running): never seek or restart something audible.
  function startIncoming(to, toMs) {
    if (to.audible()) return
    to.play(toMs)
  }

  // Incoming gain rise: from silence when the deck is idle; from its CURRENT
  // level when the DJ already has it in the mix (a hard drop to zero on the
  // deck the room is about to rely on is an audible hole).
  function riseIncoming(to, riseEndS) {
    const now = ctx.currentTime
    if (!to.audible()) to.gain.gain.setValueAtTime(0, now)
    to.gain.gain.linearRampToValueAtTime(1, now + riseEndS)
  }

  function cut(from, to, toMs) {
    from.pause()
    startIncoming(to, toMs)
    setXfadeTo(sideOf(to.id), 0.15)
  }

  function fade(from, to, toMs, token) {
    const now = ctx.currentTime
    from.gain.gain.linearRampToValueAtTime(0, now + RAMP.fadeOutS)

    startIncoming(to, toMs)
    riseIncoming(to, RAMP.fadeOutS + RAMP.fadeInS)
    setXfadeTo(sideOf(to.id), RAMP.fadeOutS)

    after(RAMP.fadeOutS + 0.1, () => {
      if (token !== state.transitionToken) return
      from.pause()
      resetChain(from)
    })
  }

  function crossfade(from, to, toMs, token) {
    if (from.bpm) to.syncTo(from.bpm * from.el.playbackRate)
    startIncoming(to, toMs)
    setXfadeTo(sideOf(to.id), RAMP.crossfadeS)

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
    from.echoSend.gain.linearRampToValueAtTime(RAMP.echoWetLevel, now + RAMP.echoWetUpS)
    from.dry.gain.linearRampToValueAtTime(0, now + RAMP.echoDryDownS)

    startIncoming(to, toMs)
    riseIncoming(to, RAMP.echoInS)
    setXfadeTo(sideOf(to.id), RAMP.echoWetUpS + tailS * 0.5)

    after(RAMP.echoDryDownS + tailS, () => {
      if (token !== state.transitionToken) return
      const end = ctx.currentTime
      from.settleGain(from.echoSend)
      from.echoSend.gain.linearRampToValueAtTime(0, end + 0.4)
      after(0.5, () => {
        if (token !== state.transitionToken) return
        from.pause()
        resetChain(from)
      })
    })

    emit("echoState", {deck: from.id, on: true, delayMs: Math.round(delayS * 1000)})
    after(RAMP.echoDryDownS + tailS + 0.6, () => emit("echoState", {deck: from.id, on: false}))
  }

  // High-pass sweep: the outgoing track loses its body, thins into air while the
  // next one comes up underneath — the "filtro" every controller has.
  function filter(from, to, toMs, token) {
    const now = ctx.currentTime
    from.hpf.frequency.setValueAtTime(Math.max(from.hpf.frequency.value, 20), now)
    from.hpf.frequency.exponentialRampToValueAtTime(RAMP.filterTopHz, now + RAMP.filterS)
    from.gain.gain.setValueAtTime(from.gain.gain.value, now + RAMP.filterS - 0.6)
    from.gain.gain.linearRampToValueAtTime(0, now + RAMP.filterS)

    startIncoming(to, toMs)
    riseIncoming(to, RAMP.filterS * 0.5)
    setXfadeTo(sideOf(to.id), RAMP.filterS * 0.8)

    after(RAMP.filterS + 0.2, () => {
      if (token !== state.transitionToken) return
      from.pause()
      resetChain(from)
    })
  }

  // Bass swap: the incoming track rides bodiless over the outgoing groove, then
  // the low end changes hands in one fast move — the forró/house handover.
  function bassSwap(from, to, toMs, token) {
    const now = ctx.currentTime
    if (from.bpm) to.syncTo(from.bpm * from.el.playbackRate)

    // Bodiless entry: instant when the deck is idle, a fast dip when the DJ
    // already has it playing (never a hard jump on something audible).
    if (to.audible()) to.bass.gain.linearRampToValueAtTime(RAMP.bassCutDb, now + 0.25)
    else to.bass.gain.setValueAtTime(RAMP.bassCutDb, now)
    startIncoming(to, toMs)
    riseIncoming(to, 1.0)
    setXfadeTo(0.5, 1.0)

    const swapAt = now + RAMP.bassOverlapS
    from.bass.gain.setValueAtTime(0, swapAt)
    from.bass.gain.linearRampToValueAtTime(RAMP.bassCutDb, swapAt + RAMP.bassSwapMoveS)
    to.bass.gain.setValueAtTime(RAMP.bassCutDb, swapAt)
    to.bass.gain.linearRampToValueAtTime(0, swapAt + RAMP.bassSwapMoveS)

    after(RAMP.bassOverlapS, () => {
      if (token !== state.transitionToken) return
      setXfadeTo(sideOf(to.id), 2.0)
    })
    after(RAMP.bassOverlapS + 2.4, () => {
      if (token !== state.transitionToken) return
      from.pause()
      resetChain(from)
      // The incoming deck keeps playing — only make sure its shelf sits flat.
      // (No resetChain: that would snap the SYNCed tempo back audibly.)
      to.settleParam(to.bass.gain)
      to.bass.gain.setValueAtTime(0, ctx.currentTime)
    })
  }

  // Vinyl brake: the platter winds down (pitch drops with it), then the next
  // track slams in. playbackRate is not an AudioParam, so the wind-down is a
  // JS interval — the final pause is timeout-guarded and lands regardless.
  function brake(from, to, toMs, token) {
    const el = from.el
    el.preservesPitch = false
    const startRate = el.playbackRate
    const t0 = performance.now()
    const restoreRate = () => {
      el.preservesPitch = true
      el.playbackRate = 1
    }
    const iv = setInterval(() => {
      if (token !== state.transitionToken) {
        // Aborted mid-brake: the deck may be back ON AIR — snap the platter up.
        clearInterval(iv)
        restoreRate()
        return
      }
      const p = Math.min((performance.now() - t0) / (RAMP.brakeS * 1000), 1)
      el.playbackRate = Math.max(startRate * (1 - p) * (1 - p), 0.07)
      if (p >= 1) clearInterval(iv)
    }, 40)

    after(RAMP.brakeS * 0.65, () => {
      if (token !== state.transitionToken) return
      startIncoming(to, toMs)
      setXfadeTo(sideOf(to.id), 0.3)
    })
    after(RAMP.brakeS + 0.05, () => {
      clearInterval(iv)
      if (token !== state.transitionToken) {
        // The wind-down must never outlive an aborted brake.
        restoreRate()
        return
      }
      from.pause()
      resetChain(from)
    })
  }

  // Return a silenced deck to a neutral chain: unity gain, open filter, flat
  // shelf, no echo, natural tempo. Only ever called on non-audible decks.
  function resetChain(deck) {
    const now = ctx.currentTime
    deck.settleGain(deck.gain)
    deck.gain.gain.setValueAtTime(1, now)
    deck.settleGain(deck.dry)
    deck.dry.gain.setValueAtTime(1, now)
    deck.settleGain(deck.echoSend)
    deck.echoSend.gain.setValueAtTime(0, now)
    deck.settleParam(deck.hpf.frequency)
    deck.hpf.frequency.setValueAtTime(10, now)
    deck.settleParam(deck.bass.gain)
    deck.bass.gain.setValueAtTime(0, now)
    deck.resetRate()
  }

  // ── crossfader (automated glides + manual takeover) ─────────────────────────

  function setXfadeTo(target, seconds) {
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
      if (state.hint && state.hint.deck === deckId) {
        // The DJ overrode the armed preload: the hint must point at what is
        // REALLY on the deck, and the old track's entry point means nothing.
        state.hint = {
          ...state.hint,
          track,
          transition: state.hint.transition && {...state.hint.transition, to_ms: null},
        }
      }
      if (autoplay) {
        // New ownership: whatever an interrupted transition still had
        // scheduled for these decks must not run.
        state.transitionToken++
        this.resume()
        resetChain(deck)
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
      resetChain(deck)
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

    // "No ar" for the UI and for manual fires: crossfader side wins when both
    // decks are running.
    audibleDeck: audibleDeckId,

    // The DJ pressed a transition button: fire it NOW, from the deck the
    // crossfader says is on air, into the other deck. Works with AUTO on or
    // off — the server hears the same transition_started either way.
    fireManual(type) {
      // Double-click guard: two near-simultaneous fires would reverse the
      // transition that just started and double-advance the boundary.
      if (state.lastFireAt && performance.now() - state.lastFireAt < 400) {
        return {ok: false, reason: "too_fast"}
      }
      const fromId = audibleDeckId()
      if (!fromId) return {ok: false, reason: "no_audible"}
      const to = decks[otherId(fromId)]
      if (to.trackId == null) return {ok: false, reason: "empty_target"}
      if (!to.audible() && !to.ready()) return {ok: false, reason: "target_loading"}
      this.resume()
      fireTransition(decks[fromId], to, {type: type, to_ms: null}, "manual")
      return {ok: true, from: fromId, to: to.id, type}
    },

    playPause(deckId) {
      const deck = decks[deckId]
      this.resume()
      if (deck.audible()) {
        deck.pause()
      } else if (deck.trackId) {
        // Manual restart takes ownership: cancel stale transition cleanups and
        // rescue a gain an interrupted ramp may have stranded near zero.
        state.transitionToken++
        deck.settleGain(deck.gain)
        if (deck.gain.gain.value < 0.05) deck.gain.gain.setValueAtTime(1, ctx.currentTime)
        deck.play()
        state.activeDeck = deckId
        state.firedForTrack = null
        emit("deckStarted", {deck: deckId, trackId: deck.trackId})
      }
    },

    cueTo(deckId, ms) {
      const deck = decks[deckId]
      if (deck.trackId == null) return
      // The cue OWNS the start position now — a stale armed to_ms must not
      // yank the deck elsewhere on the next play.
      deck._pendingSeekMs = null
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
      const other = decks[otherId(deckId)]
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
      state.transitionToken++ // no in-flight cleanup may outlive a stop
      decks.a.pause()
      decks.b.pause()
      state.activeDeck = null
      state.hint = null
    },

    // Pause without losing state — used when another audio source (o player
    // global) takes over; loads and the armed hint survive.
    pauseAll() {
      state.transitionToken++
      decks.a.pause()
      decks.b.pause()
    },

    snapshot() {
      return {
        activeDeck: state.activeDeck,
        audibleDeck: audibleDeckId(),
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
