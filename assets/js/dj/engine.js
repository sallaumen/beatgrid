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
// Graph per deck (mixer-standard: the fader sits AFTER the metered/PFL point,
// so headphone cue and meters are pre-fader — o fone não depende do volume):
//   <audio> → Source → HPF → bass shelf ─┬─ dry ────────────┐
//                                        └─ echoSend → Delay┤→ channel → deckGain → xfadeGain → master
//                                               ↺ feedback  │      │ (analyser + cue tap)
//                                                           │      └→ cueGain → cueBus → phones
//
// The HPF (transparent at 10 Hz) drives the "filtro" sweep; the low shelf
// (flat at 0 dB) drives the "troca de grave" bass swap. The cue bus reaches
// the headphones either as channels 3/4 of a 4-channel interface (DJ2GO2
// Touch main = 1/2, phones = 3/4) or via a routable MediaStream element.

import {getScratchPcm} from "./waveform.js"
import {ensureScratchModule, scratchPattern} from "./scratch.js"

const RAMP = Object.freeze({
  manualFaderTau: 0.01, // s — smoothing for hand moves (kills zipper noise)
  fadeOutS: 2.2,
  fadeInS: 2.2,
  crossfadeS: 8.0,
  // Echo-out envelope: the tail must RING while the next track settles in —
  // the first cut of this felt like a fast fade (real-hardware feedback).
  echoWetUpS: 1.8,
  echoDryDownS: 2.4,
  echoInS: 2.0,
  echoTailBeats: 8,
  echoFeedback: 0.6,
  echoWetLevel: 0.85,
  echoFallbackDelayMs: 375,
  echoFallbackTailS: 5.0,
  filterS: 4.0, // full high-pass sweep on the outgoing deck
  filterTopHz: 1600,
  bassOverlapS: 4.0, // both tracks run together before the bass swap
  bassSwapMoveS: 0.35, // the swap itself is fast — that's the trick
  bassCutDb: -24,
  brakeS: 1.1, // vinyl brake: platter stops in about a second
  lowpassS: 4.0, // "afunda": low-pass sweep drowns the outgoing track
  lowpassFloorHz: 160,
  autoFireSlackMs: 15_000, // AUTO won't fire a window it is already far past
  // Jog edge nudge: strong enough to FEEL on real hardware (o BPM ao vivo na
  // tela mostra o quanto está dobrando) and slow to settle back.
  bendStep: 0.006,
  bendMax: 0.16,
  bendDecay: 0.9, // per 60ms tick — full nudge settles in ~2s
  scratchStepS: 0.006, // jog top held: seconds scrubbed per encoder tick (fallback)
  // Real scratch (AudioWorklet): how many audio samples the platter travels per
  // jog "unit" (radian on the on-screen wheel / encoder tick), and the swing of
  // the auto-scratch patterns. Tuned by ear — Lucas can nudge these.
  jogScratchSamples: 2600,
  scratchDepthS: 0.16,
  scratchGain: 1.5, // the scratched deck sits ~3.5 dB above its own music (Lucas mixes at max on the crossfader)
  toneMaxDb: 9, // "Tom" tilt EQ: full turn tilts each shelf ±9 dB
  // Scratch DROP transitions — deliberately abrupt, NOT scaled by the length
  // knob. "rasgo": a quick baby-scratch flourish then a hard drop. "rebobina":
  // a reverse spin-back (rewind whoosh) then the drop.
  rasgoS: 0.5,
  rasgoDepthS: 0.1,
  rasgoStrokes: 3,
  spinbackS: 0.55,
  spinbackBackS: 1.15, // rewinds ~2.1x the run in reverse — a clear "rewinnnd", not an aliased blur
})

const SYNC_RATE_CLAMP = 0.08 // ±8%, matching the set-builder's bpm_close? band
const PITCH_RATE_CLAMP = 0.2 // ±20% for the manual pitch fader (well wide/slow on purpose)

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

// Sharp "cut" crossfader curve for scratching: each deck stays SILENT across the
// far part of the throw (a comfortable dead zone, not just the exact end-stop),
// then snaps to full near its own edge — so a chop needs only a short flick and
// the off-deck never bleeds. equalPower (the smooth blend) stays the default; the
// DJ flips to this with the crossfader-curve toggle. Tunables: bigger CUT_DEAD =
// wider silent zone, smaller CUT_WIDTH = harder snap.
const CUT_DEAD = 0.3 // fraction of the throw from each edge the far deck stays silent
const CUT_WIDTH = 0.12 // ramp from silent to full after the dead zone
function cutCurve(pos) {
  const clamp = (x) => Math.min(Math.max(x, 0), 1)
  return {a: clamp((1 - pos - CUT_DEAD) / CUT_WIDTH), b: clamp((pos - CUT_DEAD) / CUT_WIDTH)}
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
    this.lpf = ctx.createBiquadFilter() // "afunda"/filtro bipolar; 20 kHz = transparent
    this.lpf.type = "lowpass"
    this.lpf.frequency.value = 20_000
    this.bass = ctx.createBiquadFilter() // "troca de grave"; 0 dB = flat
    this.bass.type = "lowshelf"
    this.bass.frequency.value = 200
    this.bass.gain.value = 0
    // "Tom": the DJ's tilt EQ (grave↔agudo). Its own shelf pair, separate from
    // `bass` above (which the bass_swap transition automates) so the two never
    // fight. v>0 = brighter (less low, more high), v<0 = warmer. 0 dB = flat.
    this.toneBass = ctx.createBiquadFilter()
    this.toneBass.type = "lowshelf"
    this.toneBass.frequency.value = 250
    this.toneBass.gain.value = 0
    this.toneTreble = ctx.createBiquadFilter()
    this.toneTreble.type = "highshelf"
    this.toneTreble.frequency.value = 3_000
    this.toneTreble.gain.value = 0

    this.baseRate = 1 // tempo alvo (pitch fader / SYNC); o bend do jog decai para cá
    this.vinylMode = false // TOM: pitch muda a afinação; sobrevive a SYNC/brake
    this.loop = {on: false, startMs: null, endMs: null, beats: null}
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
    sourceFor(el).connect(this.hpf)
    this.hpf.connect(this.lpf)
    this.lpf.connect(this.bass)
    this.bass.connect(this.toneBass)
    this.toneBass.connect(this.toneTreble)
    this.toneTreble.connect(this.dry)
    this.toneTreble.connect(this.echoSend)
    this.echoSend.connect(this.delay)
    this.delay.connect(this.feedback)
    this.feedback.connect(this.delay) // the echo tail
    this.dry.connect(this.channel)
    this.delay.connect(this.channel)
    this.channel.connect(this.analyser)
    this.channel.connect(this.gain) // fader AFTER the cue/meter tap (pre-fader listen)
  }

  // Loading is REFUSED while audible — the incoming track belongs on the idle deck.
  load(track, atMs = 0) {
    if (this.audible()) return false
    const token = ++this.loadToken
    this.trackId = track.id
    this.bpm = track.bpm || null
    this.durationMs = track.duration_ms || null
    this.loop = {on: false, startMs: null, endMs: null, beats: null}
    // Beat-synced default so the manual echo send sounds musical right away.
    this.delay.delayTime.value = Math.min(
      this.bpm ? (60 / this.bpm) * 0.75 : RAMP.echoFallbackDelayMs / 1000,
      2.0
    )
    // The media load algorithm resets el.playbackRate to 1 — mirror it, or the
    // first nudge/TOM toggle after a manual preload would pitch-jump.
    this.baseRate = 1
    this._cued = false
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
    this.baseRate = Math.min(1 + SYNC_RATE_CLAMP, Math.max(1 - SYNC_RATE_CLAMP, rate))
    this.el.preservesPitch = !this.vinylMode
    this.el.playbackRate = this.baseRate
    return true
  }

  resetRate() {
    this.baseRate = 1
    this.el.preservesPitch = !this.vinylMode
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
      this.lpf,
      this.bass,
      this.toneBass,
      this.toneTreble,
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
  const xfade = {a: ctx.createGain(), b: ctx.createGain(), pos: 0.5, curve: "smooth"}
  // The crossfader gain map: smooth equal-power for mixing, sharp cut for
  // scratching (the DJ toggles it). Transitions IGNORE this and always ramp
  // equal-power — a fired blend stays smooth regardless of the toggle.
  const xfadeGains = (pos) => (xfade.curve === "sharp" ? cutCurve(pos) : equalPower(pos))

  // "Estourado": compressor before the master. IMPORTANT: WebAudio's
  // DynamicsCompressor applies automatic makeup gain, so a low fixed threshold
  // would boost/squash the whole night even "at zero". Transparência em 0 vem
  // de threshold 0 dB (nada a comprimir → makeup 1); o slider EMPURRA o
  // threshold para baixo e o drive para cima.
  const punch = ctx.createGain()
  const punchComp = ctx.createDynamicsCompressor()
  punchComp.threshold.value = 0
  punchComp.knee.value = 12
  punchComp.ratio.value = 8
  punchComp.attack.value = 0.004
  punchComp.release.value = 0.24

  decks.a.gain.connect(xfade.a)
  decks.b.gain.connect(xfade.b)
  xfade.a.connect(punch)
  xfade.b.connect(punch)
  punch.connect(punchComp)
  punchComp.connect(master)

  const g = xfadeGains(xfade.pos)
  xfade.a.gain.value = g.a
  xfade.b.gain.value = g.b

  // ── headphone cue (PFL): pre-fader taps → per-deck switch → cue bus ─────────
  const cue = {
    a: ctx.createGain(),
    b: ctx.createGain(),
    bus: ctx.createGain(),
    on: {a: false, b: false},
    mode: "stereo", // "quad" when the output device exposes 4+ channels
  }
  cue.a.gain.value = 0
  cue.b.gain.value = 0
  decks.a.channel.connect(cue.a)
  decks.b.channel.connect(cue.b)
  cue.a.connect(cue.bus)
  cue.b.connect(cue.bus)
  // Force the two buses stereo at the tap points: mono tracks would otherwise
  // reach the quad splitters as 1 channel and zero-pad the right side dead.
  master.channelCount = 2
  master.channelCountMode = "explicit"
  cue.bus.channelCount = 2
  cue.bus.channelCountMode = "explicit"
  // Stereo-mode fallback: a routable stream the hook can point at any output
  // device (<audio srcObject + setSinkId>). NOT fed in quad mode — the cue
  // must never reach a device's main channels by accident.
  const cueStreamDest = ctx.createMediaStreamDestination()

  let outputNodes = []

  // Wire master (and, on 4-channel interfaces, the cue bus) to the device.
  // DJ2GO2 Touch is a 4-out card: main = channels 1/2, phones = 3/4 — with it
  // as the output device, the browser can feed the room AND the headphones.
  function wireOutputs() {
    try {
      master.disconnect()
    } catch (_e) {
      // not connected yet
    }
    try {
      cue.bus.disconnect()
    } catch (_e) {
      // idem
    }
    for (const node of outputNodes) {
      try {
        node.disconnect()
      } catch (_e) {
        // idem
      }
    }
    outputNodes = []
    master.connect(masterAnalyser)

    const maxCh = ctx.destination.maxChannelCount || 2
    if (maxCh >= 4) {
      ctx.destination.channelCount = 4
      ctx.destination.channelCountMode = "explicit"
      ctx.destination.channelInterpretation = "discrete"
      const merger = ctx.createChannelMerger(4)
      const masterSplit = ctx.createChannelSplitter(2)
      const cueSplit = ctx.createChannelSplitter(2)
      master.connect(masterSplit)
      cue.bus.connect(cueSplit)
      masterSplit.connect(merger, 0, 0)
      masterSplit.connect(merger, 1, 1)
      cueSplit.connect(merger, 0, 2)
      cueSplit.connect(merger, 1, 3)
      merger.connect(ctx.destination)
      outputNodes = [merger, masterSplit, cueSplit]
      cue.mode = "quad"
    } else {
      // Undo any leftover quad destination config from a device switch.
      ctx.destination.channelCountMode = "explicit"
      ctx.destination.channelCount = Math.min(2, Math.max(maxCh, 1))
      ctx.destination.channelInterpretation = "speakers"
      master.connect(ctx.destination)
      // The routable fallback only exists in stereo mode — in quad the cue
      // rides channels 3/4 and must not double anywhere else.
      cue.bus.connect(cueStreamDest)
      cue.mode = "stereo"
    }
    emit("cueMode", {mode: cue.mode, maxChannels: maxCh})
  }

  const state = {
    activeDeck: null, // "a" | "b" | null — who owns the set boundary
    hint: null, // {deck, track, transition} armed on the idle deck
    transitionToken: 0,
    firedForTrack: null, // dedupes transition vs ended for one boundary
    lastFireAt: null, // performance.now() of the last fired transition
    autoOn: false,
    // "Ainda não!": offset added to the AUTO fire point for the CURRENT
    // boundary only — cleared whenever the boundary advances or changes hands.
    postponeMs: 0,
    // User "comprimento" knob: scales every transition's timings around the
    // reference length (REF_LEN_S = the default crossfade). 1.0 = as designed.
    transitionScale: 1,
    // Per-fire squeeze: when the outgoing track has less runway than the knob
    // asks for, THIS run shrinks to fit instead of truncating mid-blend.
    fireScale: 1,
  }

  const REF_LEN_S = RAMP.crossfadeS // 8s — the seconds shown on the length control

  // Scale a base duration by the user's length knob (never below a tiny floor,
  // so a "cut" stays a cut and no ramp collapses to an instant click).
  const dur = (v) => Math.max(v * state.transitionScale * state.fireScale, 0.05)

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
    // A seek that lands inside the AUTO window must not fire on the spot — the
    // DJ was inspecting the outro, not asking to advance. Playing back into the
    // region from BEFORE the fire point re-arms it (see maybeFire).
    deck.el.addEventListener("seeked", () => {
      if (deck.id === state.activeDeck) deck._seekGuard = true
    })
    // A deck going silent is the moment a queued hint can claim it. Event-driven
    // on purpose: rAF loops don't run in background tabs, and re-arming the next
    // track must not depend on the page being visible.
    deck.el.addEventListener("pause", () => emit("deckFreed", {deck: deck.id}))
    deck.el.addEventListener("ended", () => {
      if (deck.id !== state.activeDeck) return
      state.postponeMs = 0
      const hint = state.hint
      const other = decks[otherId(deck.id)]

      if (state.autoOn && hintFireable(hint)) {
        // The outgoing deck is ALREADY silent here — running the marked
        // transition (an 8s crossfade from a dead deck…) would be seconds of
        // near-silence. End of track always advances with a cut.
        const planned = hint.transition && hint.transition["type"]
        if (planned && planned !== "cut") {
          // The DJ planned a blend and got a dry cut — say it, don't hide it.
          emit("planDowngraded", {planned})
        }
        boundaryOnce(deck.trackId, () =>
          fireTransition(
            deck,
            decks[hint.deck],
            {type: "cut", to_ms: (hint.transition && hint.transition["to_ms"]) ?? 0},
            "auto",
            "ended"
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

  // A hint deck can only RECEIVE a transition when its media is actually
  // playable — firing into a still-buffering or errored deck is dead air.
  function hintFireable(hint) {
    if (!hint) return false
    const target = decks[hint.deck]
    return target.trackId != null && target.ready() && !target.el.error
  }

  function maybeFire(deck) {
    const hint = state.hint
    if (!state.autoOn || !hint || deck.id !== state.activeDeck) return
    // pause() and scrubbing both fire 'timeupdate' — a jog-held (or otherwise
    // silent) deck must never be the source of an automatic transition. Nor may
    // AUTO fire while a scratch is in the DJ's hands (it steers the crossfader).
    if (!deck.audible() || jog[deck.id].held || autoScratch.a || autoScratch.b) return
    if (!hint.transition) return // sequential entries advance on `ended`
    if (!hintFireable(hint)) return // waits; the ended fallback still covers it

    const fromMs = clampFromMs(hint.transition["from_ms"], deck) + state.postponeMs
    const pos = deck.positionMs()
    if (deck._seekGuard) {
      if (pos >= fromMs) return // landed at/past the point: re-enter or let `ended` cut
      deck._seekGuard = false
    }
    // Inside the window only: toggling AUTO on far past the mark must not slam
    // an instant transition — the ended fallback covers the overshoot.
    if (pos < fromMs || pos > fromMs + RAMP.autoFireSlackMs) return

    boundaryOnce(deck.trackId, () => fireTransition(deck, decks[hint.deck], hint.transition, "auto", "window"))
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

  const TRANSITIONS = () => ({
    cut,
    fade,
    crossfade,
    echo,
    filter,
    bass_swap: bassSwap,
    brake,
    lowpass,
    scratch_cut: (from, to, toMs, token) => scratchDrop(from, to, toMs, token, "rasgo"),
    spinback: (from, to, toMs, token) => scratchDrop(from, to, toMs, token, "rebobina"),
  })

  function fireTransition(from, to, transition, mode, origin) {
    const token = ++state.transitionToken
    state.lastFireAt = performance.now()
    // A transition owns both decks and the crossfader now — abandon any scratch
    // in progress WITHOUT restoring the fader (the transition steers it).
    resetScratch(from.id, false)
    resetScratch(to.id, false)
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
      // Who pulled the trigger (window|ended|hint|palette) and where the
      // outgoing deck REALLY was — the server learns fire points from these.
      origin,
      atMs: Math.round(from.positionMs()),
    })

    // A transition interrupted by this one must not keep steering either deck:
    // kill every scheduled ramp NOW (invariant 2 — a pending ramp-to-zero on
    // the deck going back on air is the dead-air bug from the party).
    settleTransitionParams(from)
    settleTransitionParams(to)
    neutralizeIncoming(to, type)
    // The incoming chain was just washed neutral — tell the UI so the FX
    // sliders don't lie over transparent audio.
    emit("fxReset", {deck: to.id})

    const run = TRANSITIONS()[type] || cut
    // Manual fires are the DJ's hand — only the runway cap applies; AUTO also
    // respects the incoming track's structure (state.hint is still set here).
    state.fireScale = fitScale(from, mode === "auto" ? state.hint : null, toMs)
    if (state.fireScale < 0.95) {
      emit("transitionSqueezed", {type, factor: state.fireScale})
    }
    run(from, to, toMs, token)
    state.fireScale = 1
    state.activeDeck = to.id
    state.hint = null
    state.firedForTrack = null
    state.postponeMs = 0
    from._seekGuard = false
    to._seekGuard = false
  }

  // How much of the knob's length actually FITS this pair. Two caps, Mixxx
  // style (duration comes from the pair, the knob is only the ceiling):
  // - the outgoing track's remaining runway (the blend completes before it dies)
  // - on AUTO, the incoming track's first section change: the blend should be
  //   over before its vocals/drop enter, not burying them under the old track.
  // Coarse on purpose (REF_LEN_S approximates every type's longest ramp).
  function fitScale(from, hint, toMs) {
    const caps = []
    const durS = from.el.duration
    if (durS && from.trackId != null) {
      caps.push(Math.max(durS - from.el.currentTime - 0.3, 0.4))
    }
    const introS = introWindowS(hint, toMs)
    if (introS != null) caps.push(Math.max(introS, 2))
    if (caps.length === 0) return 1
    return Math.min(1, Math.min(...caps) / (REF_LEN_S * state.transitionScale))
  }

  // Seconds from the incoming track's entry point to its first section cue —
  // the v2 detector's structural boundaries double as "the music changes here".
  function introWindowS(hint, toMs) {
    if (!hint || !hint.track || !Array.isArray(hint.track.markers)) return null
    const startMs = toMs ?? 0
    const next = hint.track.markers
      .filter((m) => m.type === "cue" && m.ms > startMs + 1000)
      .map((m) => m.ms)
      .sort((a, b) => a - b)[0]
    return next == null ? null : (next - startMs) / 1000
  }

  function settleTransitionParams(deck) {
    deck.settleParam(deck.gain.gain)
    deck.settleParam(deck.dry.gain)
    deck.settleParam(deck.echoSend.gain)
    deck.settleParam(deck.hpf.frequency)
    deck.settleParam(deck.lpf.frequency)
    deck.settleParam(deck.bass.gain)
    // The echo blooms the feedback — freeze it too, or an interrupted echo
    // keeps ramping toward 0.82 and the next echo would start hot.
    deck.settleParam(deck.feedback.gain)
  }

  // The deck going on air must not inherit FX from an interrupted transition
  // (dry at zero, echo send open, filter swept). Short ramps, never jumps —
  // it may already be audible. Params the incoming transition owns are left
  // for it to set.
  function neutralizeIncoming(to, type) {
    const now = ctx.currentTime
    to.dry.gain.linearRampToValueAtTime(1, now + 0.3)
    to.echoSend.gain.linearRampToValueAtTime(0, now + 0.3)
    to.feedback.gain.linearRampToValueAtTime(RAMP.echoFeedback, now + 0.3)
    to.hpf.frequency.linearRampToValueAtTime(10, now + 0.2)
    to.lpf.frequency.linearRampToValueAtTime(20_000, now + 0.2)
    if (type !== "bass_swap") to.bass.gain.linearRampToValueAtTime(0, now + 0.3)
    to.toneBass.gain.linearRampToValueAtTime(0, now + 0.3)
    to.toneTreble.gain.linearRampToValueAtTime(0, now + 0.3)
    if (type === "cut" || type === "crossfade" || type === "brake") {
      to.gain.gain.linearRampToValueAtTime(1, now + 0.2)
    }
  }

  // Start the incoming deck — unless it is already in the mix (manual fire with
  // both decks running): never seek or restart something audible. A deck the
  // DJ re-cued by hand keeps ITS position — the plan's to_ms is discarded.
  function startIncoming(to, toMs) {
    if (to.audible()) return
    to.play(to._cued ? null : toMs)
    to._cued = false
  }

  // Incoming gain rise: from silence when the deck is idle; from its CURRENT
  // level when the DJ already has it in the mix (a hard drop to zero on the
  // deck the room is about to rely on is an audible hole).
  // MUST be scheduled BEFORE startIncoming: play() flips the element to
  // "audible" synchronously, which would make this skip the silent start.
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
    const outS = dur(RAMP.fadeOutS)
    from.gain.gain.linearRampToValueAtTime(0, now + outS)

    riseIncoming(to, outS + dur(RAMP.fadeInS))
    startIncoming(to, toMs)
    setXfadeTo(sideOf(to.id), outS)

    after(outS + 0.1, () => {
      if (token !== state.transitionToken) return
      from.pause()
      resetChain(from)
    })
  }

  function crossfade(from, to, toMs, token) {
    // baseRate, not playbackRate: a transient jog bend (or mid-brake rate)
    // must never become the incoming track's permanent tempo.
    if (from.bpm) to.syncTo(from.bpm * from.baseRate)
    startIncoming(to, toMs)
    const xfS = dur(RAMP.crossfadeS)
    setXfadeTo(sideOf(to.id), xfS)

    after(xfS + 0.2, () => {
      if (token !== state.transitionToken) return
      from.pause()
    })
  }

  // Echo-out, reworked to BREATHE. Timeline (all scaled by the length knob):
  //   1. the delay opens on a QUARTER note — spacious/dub, not a fast ping;
  //   2. the feedback BLOOMS (0.55→0.82) so the repeats sustain into a wash;
  //   3. the outgoing dry holds a beat, then DISSOLVES into that wash;
  //   4. the incoming stays silent, then EMERGES from under the tail (delayed
  //      rise) — the space between old-gone and new-arriving is what makes it
  //      feel fluid instead of a quick crossfade;
  //   5. the tail rings out as the feedback eases back down.
  function echo(from, to, toMs, token) {
    const now = ctx.currentTime
    const bpm = from.bpm ? from.bpm * from.el.playbackRate : null
    const beatS = bpm ? 60 / bpm : 0.5
    const delayS = Math.min(beatS, 1.2) // quarter note
    const tailS = dur(bpm ? beatS * RAMP.echoTailBeats : RAMP.echoFallbackTailS)

    const wetUp = dur(RAMP.echoWetUpS)
    const dryStart = dur(0.6)
    const dryDown = dur(RAMP.echoDryDownS)
    const inStart = dur(RAMP.echoInS + 0.4) // the new track waits under the wash
    const inRise = dur(3.0)
    const total = Math.max(dryStart + dryDown, inStart + inRise, wetUp + tailS)

    // Glide, don't step: an instant delayTime change while the feedback loop
    // holds energy clicks/warbles on air.
    from.delay.delayTime.setTargetAtTime(delayS, now, 0.03)

    // Wet swells; feedback blooms then eases back so the tail rings out.
    from.echoSend.gain.linearRampToValueAtTime(RAMP.echoWetLevel, now + wetUp)
    from.settleParam(from.feedback.gain)
    from.feedback.gain.linearRampToValueAtTime(0.82, now + wetUp + dur(0.8))
    from.feedback.gain.linearRampToValueAtTime(0.35, now + total)

    // Dry holds a beat (last phrase gets thrown), then dissolves.
    from.dry.gain.setValueAtTime(from.dry.gain.value, now + dryStart)
    from.dry.gain.linearRampToValueAtTime(0, now + dryStart + dryDown)

    // Incoming: silent until inStart, then rises out of the tail.
    if (!to.audible()) {
      to.gain.gain.setValueAtTime(0, now)
      to.gain.gain.setValueAtTime(0, now + inStart)
    }
    to.gain.gain.linearRampToValueAtTime(1, now + inStart + inRise)
    startIncoming(to, toMs)

    // The crossfader follows the emergence — the wash stays on the outgoing
    // side until the new track has surfaced.
    setXfadeTo(sideOf(to.id), inStart + inRise * 0.8)

    after(total, () => {
      if (token !== state.transitionToken) return
      const end = ctx.currentTime
      from.settleGain(from.echoSend)
      from.echoSend.gain.linearRampToValueAtTime(0, end + dur(0.6))
      after(dur(0.7), () => {
        if (token !== state.transitionToken) return
        from.pause()
        resetChain(from)
      })
    })

    emit("echoState", {deck: from.id, on: true, delayMs: Math.round(delayS * 1000)})
    after(total + dur(0.7), () => emit("echoState", {deck: from.id, on: false}))
  }

  // High-pass sweep: the outgoing track loses its body, thins into air while the
  // next one comes up underneath — the "filtro" every controller has.
  function filter(from, to, toMs, token) {
    const now = ctx.currentTime
    const s = dur(RAMP.filterS)
    from.hpf.frequency.setValueAtTime(Math.max(from.hpf.frequency.value, 20), now)
    from.hpf.frequency.exponentialRampToValueAtTime(RAMP.filterTopHz, now + s)
    from.gain.gain.setValueAtTime(from.gain.gain.value, now + s - dur(0.6))
    from.gain.gain.linearRampToValueAtTime(0, now + s)

    riseIncoming(to, s * 0.5)
    startIncoming(to, toMs)
    setXfadeTo(sideOf(to.id), s * 0.8)

    after(s + 0.2, () => {
      if (token !== state.transitionToken) return
      from.pause()
      resetChain(from)
    })
  }

  // "Afunda": the mirror of the filter sweep — the outgoing track loses its
  // highs and sinks underwater while the next one surfaces on top.
  function lowpass(from, to, toMs, token) {
    const now = ctx.currentTime
    const s = dur(RAMP.lowpassS)
    from.lpf.frequency.setValueAtTime(Math.min(from.lpf.frequency.value, 20_000), now)
    from.lpf.frequency.exponentialRampToValueAtTime(RAMP.lowpassFloorHz, now + s)
    from.gain.gain.setValueAtTime(from.gain.gain.value, now + s - dur(0.6))
    from.gain.gain.linearRampToValueAtTime(0, now + s)

    riseIncoming(to, s * 0.5)
    startIncoming(to, toMs)
    setXfadeTo(sideOf(to.id), s * 0.8)

    after(s + 0.2, () => {
      if (token !== state.transitionToken) return
      from.pause()
      resetChain(from)
    })
  }

  // Bass swap: the incoming track rides bodiless over the outgoing groove, then
  // the low end changes hands in one fast move — the forró/house handover.
  function bassSwap(from, to, toMs, token) {
    const now = ctx.currentTime
    if (from.bpm) to.syncTo(from.bpm * from.baseRate)

    // Bodiless entry: instant when the deck is idle, a fast dip when the DJ
    // already has it playing (never a hard jump on something audible).
    const overlapS = dur(RAMP.bassOverlapS)
    const moveS = dur(RAMP.bassSwapMoveS)
    if (to.audible()) to.bass.gain.linearRampToValueAtTime(RAMP.bassCutDb, now + 0.25)
    else to.bass.gain.setValueAtTime(RAMP.bassCutDb, now)
    riseIncoming(to, dur(1.0))
    startIncoming(to, toMs)
    setXfadeTo(0.5, dur(1.0))

    const swapAt = now + overlapS
    from.bass.gain.setValueAtTime(0, swapAt)
    from.bass.gain.linearRampToValueAtTime(RAMP.bassCutDb, swapAt + moveS)
    to.bass.gain.setValueAtTime(RAMP.bassCutDb, swapAt)
    to.bass.gain.linearRampToValueAtTime(0, swapAt + moveS)

    after(overlapS, () => {
      if (token !== state.transitionToken) return
      setXfadeTo(sideOf(to.id), dur(2.0))
    })
    after(overlapS + dur(2.4), () => {
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
    const brakeS = dur(RAMP.brakeS)
    cancelBend(from.id) // the wind-down owns playbackRate — no bend ping-pong
    from._braking = true
    el.preservesPitch = false
    const startRate = el.playbackRate
    const t0 = performance.now()
    const restoreRate = () => {
      from._braking = false
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
      const p = Math.min((performance.now() - t0) / (brakeS * 1000), 1)
      el.playbackRate = Math.max(startRate * (1 - p) * (1 - p), 0.07)
      if (p >= 1) clearInterval(iv)
    }, 40)

    after(brakeS * 0.65, () => {
      if (token !== state.transitionToken) return
      startIncoming(to, toMs)
      setXfadeTo(sideOf(to.id), 0.3)
    })
    after(brakeS + 0.05, () => {
      clearInterval(iv)
      from._braking = false
      if (token !== state.transitionToken) {
        // The wind-down must never outlive an aborted brake.
        restoreRate()
        return
      }
      from.pause()
      resetChain(from)
    })
  }

  // Scratch DROP transitions: scratch the OUTGOING track (real worklet audio)
  // then slam the incoming in at its cued point. "rasgo" = a baby-scratch
  // flourish; "rebobina" = a reverse spin-back rewind. Abrupt on purpose.
  // Falls back to a plain cut when the outgoing has no decoded PCM/worklet.
  function scratchDrop(from, to, toMs, token, kind) {
    if (!scratchArm(from.id)) {
      // No PCM/worklet → fall back to a plain cut, but raise the incoming gain
      // first (neutralizeIncoming doesn't do it for the scratch types, so cut
      // alone could drop a frozen-low deck in silent — dead air).
      riseIncoming(to, 0.03)
      cut(from, to, toMs)
      return
    }
    const s = scratch[from.id]
    const center = from.el.currentTime * sr
    from.el.pause()
    s.active = true
    s.token = from.loadToken
    scratchScrub(from.id, center)
    setXfadeTo(sideOf(from.id), 0.04) // hear only the scratch of the outgoing

    // Respect the length knob: a longer setting = MORE scratch (more strokes / a
    // longer, further rewind) at the SAME speed. The rasgo runs at a fixed rate
    // (rasgoStrokes/rasgoS Hz) so the scratch pitch never changes with the knob;
    // the rewind is capped at the headroom so it can't run off the track start.
    const scale = state.transitionScale
    const runS = dur(kind === "rebobina" ? RAMP.spinbackS : RAMP.rasgoS)
    const rasgoCycles = RAMP.rasgoStrokes * (runS / RAMP.rasgoS) // constant Hz over the run
    const backSamples = Math.min(RAMP.spinbackBackS * scale * sr, center)
    const t0 = performance.now()

    const drop = () => {
      clearInterval(iv)
      if (s.active) {
        s.active = false
        if (s.node) s.node.port.postMessage({type: "stop"})
      }
      if (token !== state.transitionToken) return // aborted — a new fire owns it
      from.pause()
      riseIncoming(to, 0.03) // hard drop — near-instant, just declicked
      startIncoming(to, toMs)
      setXfadeTo(sideOf(to.id), 0.06)
      after(0.2, () => token === state.transitionToken && resetChain(from))
    }

    const iv = setInterval(() => {
      if (s.token !== from.loadToken) {
        // Something loaded over the outgoing deck mid-run (the load's
        // resetScratch already silenced the worklet). The scratch is gone, but
        // the HANDOFF must still land: die without starting the incoming and
        // the room gets dead air with a stuck crossfader. Never touch `from`
        // here — its new owner drives it now.
        clearInterval(iv)
        if (token === state.transitionToken) {
          riseIncoming(to, 0.03)
          startIncoming(to, toMs)
          setXfadeTo(sideOf(to.id), 0.06)
        }
        return
      }
      if (token !== state.transitionToken) {
        drop()
        return
      }
      const p = Math.min((performance.now() - t0) / (runS * 1000), 1)
      const pos =
        kind === "rebobina"
          ? // steady reverse at ~2x — audible the WHOLE rewind (no silent
            // accelerate-from-zero start, no silent decelerate-to-zero tail, no
            // aliased-to-nothing over-fast blur), then the drop cuts it.
            center - backSamples * p
          : center + RAMP.rasgoDepthS * sr * Math.sin(2 * Math.PI * rasgoCycles * p)
      scratchScrub(from.id, pos)
      if (p >= 1) drop()
    }, 16)
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
    deck.settleParam(deck.lpf.frequency)
    deck.lpf.frequency.setValueAtTime(20_000, now)
    deck.settleParam(deck.bass.gain)
    deck.bass.gain.setValueAtTime(0, now)
    deck.settleParam(deck.toneBass.gain)
    deck.toneBass.gain.setValueAtTime(0, now)
    deck.settleParam(deck.toneTreble.gain)
    deck.toneTreble.gain.setValueAtTime(0, now)
    // The echo blooms the feedback — bring it back to its resting value.
    deck.settleParam(deck.feedback.gain)
    deck.feedback.gain.setValueAtTime(RAMP.echoFeedback, now)
    clearLoop(deck)
    deck.vinylMode = false
    deck.resetRate()
    emit("fxReset", {deck: deck.id})
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

  // Manual takeover of an automating param: cancelScheduledValues alone ROLLS
  // BACK to the pre-ramp value (an audible snap mid-transition) — pin the
  // currently-heard value first, then glide to the hand's target.
  function takeOver(param, target, tau) {
    const now = ctx.currentTime
    const current = param.value
    param.cancelScheduledValues(now)
    param.setValueAtTime(current, now)
    param.setTargetAtTime(target, now, tau)
  }

  // Manual gesture (UI or MIDI): cancel any automated glide and take over.
  function setCrossfader(pos) {
    xfadeGlide++
    cancelAnimationFrame(xfadeAnim)
    xfade.pos = Math.min(Math.max(pos, 0), 1)
    const g2 = xfadeGains(xfade.pos)
    for (const side of ["a", "b"]) {
      takeOver(xfade[side].gain, g2[side], RAMP.manualFaderTau)
    }
    emit("xfadePos", {pos: xfade.pos, automated: false})
  }

  // Flip the crossfader gain map (smooth blend ↔ sharp scratch cut) and re-map
  // the CURRENT position through it so the change is heard immediately. Only the
  // gains change — xfade.pos (and thus on-air detection) is untouched.
  function setCrossfaderCurve(mode) {
    xfade.curve = mode === "sharp" ? "sharp" : "smooth"
    const g = xfadeGains(xfade.pos)
    const now = ctx.currentTime
    for (const side of ["a", "b"]) {
      xfade[side].gain.cancelScheduledValues(now)
      xfade[side].gain.setTargetAtTime(g[side], now, 0.01)
    }
    emit("xfadeCurve", {curve: xfade.curve})
  }

  function setDeckLevel(deckId, value) {
    takeOver(decks[deckId].gain.gain, Math.min(Math.max(value, 0), 1), RAMP.manualFaderTau)
  }

  function setMasterLevel(value) {
    takeOver(master.gain, Math.min(Math.max(value, 0), 1.2), RAMP.manualFaderTau)
  }

  // ── jog wheel: top touch = vinyl hold/scratch; edge turn = pitch bend ───────

  const jog = {
    a: {held: false, wasPlaying: false, bend: 0, decay: null},
    b: {held: false, wasPlaying: false, bend: 0, decay: null},
  }

  // ── real scratch: an AudioWorklet per deck reads the mono PCM back and forth
  // at the platter's velocity (reverse included) into the deck's own chain ─────
  const sr = ctx.sampleRate
  const scratch = {
    a: {node: null, loaded: null, active: false, pos: 0, wasPlaying: false, token: 0, rate: 3},
    b: {node: null, loaded: null, active: false, pos: 0, wasPlaying: false, token: 0, rate: 3},
  }
  const autoScratch = {a: null, b: null}

  ensureScratchModule(ctx)
    .then(() => {
      for (const id of ["a", "b"]) {
        const node = new AudioWorkletNode(ctx, "scratch-processor", {
          numberOfInputs: 0,
          numberOfOutputs: 1,
          outputChannelCount: [2],
        })
        // A little louder than the deck's own music: Lucas keeps channel
        // volume maxed and mixes on the crossfader, so a unity scratch sat at
        // exactly the track's level and got buried.
        const g = ctx.createGain()
        g.gain.value = RAMP.scratchGain
        node.connect(g)
        g.connect(decks[id].hpf) // parallel with the media source; silent when idle
        scratch[id].node = node
      }
    })
    .catch(() => {}) // no worklet → the jog falls back to the silent scrub below

  // Ship the current track's PCM to the deck's scratch node (once per track).
  function scratchArm(deckId) {
    const s = scratch[deckId]
    const deck = decks[deckId]
    if (!s.node || deck.trackId == null) return false
    // Every arm begins with a stop: if any race ever ate a session's "stop",
    // the worklet would still hold its stale read head — this guarantees the
    // arming scrub lands on an inactive worklet and resets the head. (Callers
    // must only arm decks they own; a live session's audio dies here.)
    s.node.port.postMessage({type: "stop"})
    if (s.loaded === deck.trackId) return true
    const pcm = getScratchPcm(deck.trackId)
    if (!pcm) return false // not decoded yet — the waveform load fills the cache
    const copy = pcm.slice()
    s.node.port.postMessage({type: "load", pcm: copy}, [copy.buffer])
    s.loaded = deck.trackId
    return true
  }

  // Command the hand's position; the worklet reconstructs the velocity from the
  // timestamps (and stops on its own when the commands go quiet — a held hand).
  function scratchScrub(deckId, posSamples) {
    const s = scratch[deckId]
    // Clamp inside the track: scratching past the end must never let the release
    // seek fire `ended` and advance the set.
    const maxPos = (decks[deckId].el.duration || 0) * sr
    s.pos = Math.min(Math.max(posSamples, 0), maxPos > 0 ? maxPos : posSamples)
    if (s.node) s.node.port.postMessage({type: "scrub", position: s.pos, t: performance.now()})
  }

  // Stop scratching: hand the position back to the media element and (maybe) run.
  function scratchEnd(deckId, resume) {
    const s = scratch[deckId]
    const deck = decks[deckId]
    if (!s.active) return
    s.active = false
    if (s.node) s.node.port.postMessage({type: "stop"})
    if (s.token === deck.loadToken && deck.trackId != null) {
      // Never hand back AT/past the end — that would fire `ended` and skip on.
      const durS = deck.el.duration || 0
      const t = s.pos / sr
      deck.el.currentTime = Math.max(durS ? Math.min(t, durS - 0.3) : t, 0)
      if (resume) deck.el.play().catch(() => {})
    }
  }

  function applyRate(deck) {
    deck.el.playbackRate = Math.max(deck.baseRate * (1 + jog[deck.id].bend), 0.0625)
  }

  function cancelBend(deckId) {
    const j = jog[deckId]
    j.bend = 0
    if (j.decay) {
      clearInterval(j.decay)
      j.decay = null
    }
  }

  // Touch (platter top on hardware, or a mouse-drag on the on-screen wheel) grabs
  // the record: playback becomes an AUDIBLE scratch driven by the hand. Without
  // the decoded PCM yet, it degrades to the old silent scrub.
  function jogTouch(deckId, held) {
    const deck = decks[deckId]
    const j = jog[deckId]
    if (held === j.held) return
    const s = scratch[deckId]
    // A scratch-drop transition owns the deck's worklet (active with no
    // auto-scratch): refuse the grab — the jog would fight its command stream
    // and its release would steal the transition's stop.
    if (held && s.active && !autoScratch[deckId]) return
    j.held = held
    if (deck.trackId == null) return
    if (held) {
      cancelBend(deckId)
      stopAutoScratch(deckId)
      j.wasPlaying = deck.audible()
      j.heldToken = deck.loadToken
      if (j.wasPlaying) deck.el.pause()
      if (scratchArm(deckId)) {
        s.active = true
        s.wasPlaying = j.wasPlaying
        s.token = deck.loadToken
        scratchScrub(deckId, deck.el.currentTime * sr)
        // The crossfader stays the DJ's — a jog scratch NEVER moves it. Lucas
        // works the fader by hand to open/close the scratch (transform/chop
        // cuts), so scratching a deck the crossfader has cut is silent until he
        // brings the fader over. (This used to auto-slide to center 0.5 for
        // audibility, which fought the hand and parked the fader in the middle.)
      }
    } else {
      if (s.active) {
        scratchEnd(deckId, j.wasPlaying)
      } else if (j.wasPlaying && j.heldToken === deck.loadToken && deck.trackId != null) {
        // Fallback path (no PCM): resume only what was actually held.
        deck.el.play().catch(() => {})
      }
      j.wasPlaying = false
    }
  }

  function jogTurn(deckId, delta) {
    const deck = decks[deckId]
    if (deck.trackId == null) return
    if (deck._braking) return // the brake owns playbackRate until it finishes
    const j = jog[deckId]
    const s = scratch[deckId]
    if (s.active && j.held) {
      // Real scratch (and only when the JOG owns the session — a scratch-drop
      // transition or an auto-scratch must not be fought over the worklet):
      // move the record; the worklet turns the position stream into velocity.
      scratchScrub(deckId, Math.max(s.pos + delta * RAMP.jogScratchSamples, 0))
      return
    }
    if (j.held || !deck.audible()) {
      // Fallback (no PCM/worklet) or fine seek while paused: nudge the position.
      const step = j.held ? RAMP.scratchStepS : RAMP.scratchStepS * 6
      deck.el.currentTime = Math.max(deck.el.currentTime + delta * step, 0)
      return
    }
    // Edge nudge while playing: bend the tempo, then decay back to base —
    // never a position jump (that skip was audible).
    j.bend = Math.min(Math.max(j.bend + delta * RAMP.bendStep, -RAMP.bendMax), RAMP.bendMax)
    applyRate(deck)
    if (!j.decay) {
      j.decay = setInterval(() => {
        j.bend *= RAMP.bendDecay
        if (Math.abs(j.bend) < 0.003) {
          j.bend = 0
          clearInterval(j.decay)
          j.decay = null
        }
        applyRate(deck)
      }, 60)
    }
  }

  // ── auto-scratch: hold a pad → the idle deck scratches a chosen pattern; the
  // speed bar drives the tempo; transform/chop cut the real crossfader in time ─
  function startAutoScratch(deckId, pattern) {
    const deck = decks[deckId]
    if (deck.trackId == null) return {ok: false, reason: "empty"}
    if (jog[deckId].held) return {ok: false, reason: "held"}
    stopAutoScratch(deckId)
    // Still active after the stop = a scratch-drop transition owns the deck
    // (mid-run its outgoing deck is paused, so the pad's "idle deck" pick can
    // land here). Refuse — arming would kill its audio and split its fader.
    if (scratch[deckId].active) return {ok: false, reason: "busy"}
    if (!scratchArm(deckId)) return {ok: false, reason: "not_ready"}
    const s = scratch[deckId]
    const center = deck.el.currentTime * sr
    const a = {
      pattern,
      rate: s.rate,
      phase: 0,
      center,
      lastT: ctx.currentTime,
      savedXfade: xfade.pos,
      wasPlaying: deck.audible(),
      timer: null,
    }
    autoScratch[deckId] = a
    s.active = true
    s.token = deck.loadToken
    if (a.wasPlaying) deck.el.pause()
    scratchScrub(deckId, center)
    a.timer = setInterval(() => tickAutoScratch(deckId), 16)
    return {ok: true}
  }

  function tickAutoScratch(deckId) {
    const a = autoScratch[deckId]
    if (!a) return
    const now = ctx.currentTime
    const dt = Math.max(now - a.lastT, 0.001)
    a.phase = (a.phase + a.rate * dt) % 1
    const shape = scratchPattern(a.pattern, a.phase)
    const posSamples = Math.max(a.center + shape.pos * RAMP.scratchDepthS * sr, 0)
    scratchScrub(deckId, posSamples)
    a.lastT = now
    // crossfader gate: 1 = full toward the scratch deck (heard), 0 = cut away.
    // The heard audio lags the commanded phase (~20 ms of smoothing) MORE than
    // the gate path does (~10-15 ms), so gate from a RETARDED phase to land the
    // chops on the strokes the ear actually hears (+1 keeps JS % positive).
    const gate = scratchPattern(a.pattern, (a.phase - a.rate * 0.02 + 1) % 1).gate
    const toScratch = deckId === "a" ? 0 : 1
    const away = deckId === "a" ? 1 : 0
    scratchCrossfade(away + (toScratch - away) * gate)
  }

  function scratchCrossfade(pos) {
    xfade.pos = Math.min(Math.max(pos, 0), 1)
    const g = xfadeGains(xfade.pos)
    const now = ctx.currentTime
    xfade.a.gain.setTargetAtTime(g.a, now, 0.004)
    xfade.b.gain.setTargetAtTime(g.b, now, 0.004)
    emit("xfadePos", {pos: xfade.pos, automated: true})
  }

  // Normal pad release: put the fader back where the DJ had it and hand playback
  // back to the media element.
  function stopAutoScratch(deckId) {
    const a = autoScratch[deckId]
    if (!a) return
    clearInterval(a.timer)
    autoScratch[deckId] = null
    scratch[deckId].pos = a.center // resume where the scratch began, not mid-swing
    scratchEnd(deckId, a.wasPlaying)
    setCrossfader(a.savedXfade) // put the fader back where the DJ had it
    emit("scratchEnded", {deck: deckId})
  }

  // Forcible teardown when something else takes over the deck (a transition, a
  // load): stop both auto- and jog-scratch WITHOUT resuming — the new owner
  // drives the deck. Restores the crossfader only when asked (a load shouldn't
  // leave it chopped; a transition wants to steer it itself).
  function resetScratch(deckId, restoreXfade) {
    const s = scratch[deckId]
    const a = autoScratch[deckId]
    if (a) {
      clearInterval(a.timer)
      autoScratch[deckId] = null
      if (restoreXfade) setCrossfader(a.savedXfade)
    }
    if (s.active) {
      s.active = false
      if (s.node) s.node.port.postMessage({type: "stop"})
      emit("scratchEnded", {deck: deckId})
    }
  }

  function setAutoScratchRate(deckId, rate) {
    scratch[deckId].rate = Math.max(rate, 0.2)
    if (autoScratch[deckId]) autoScratch[deckId].rate = scratch[deckId].rate
  }

  function scratchReady(deckId) {
    return !!(scratch[deckId].node && decks[deckId].trackId != null && getScratchPcm(decks[deckId].trackId))
  }

  // The live scratch read-head in seconds while a scratch is active (so the
  // on-screen vinyl can spin WITH the scratch), else null.
  function scratchPosSec(deckId) {
    const s = scratch[deckId]
    return s.active ? s.pos / sr : null
  }

  // ── beat loops (pads AUTO/MANUAL da controladora + chips na tela) ───────────

  const loopTimers = {a: null, b: null}

  function clearLoop(deck) {
    deck.loop = {on: false, startMs: null, endMs: null, beats: null}
    if (loopTimers[deck.id]) {
      clearInterval(loopTimers[deck.id])
      loopTimers[deck.id] = null
    }
    emit("loopState", {deck: deck.id, ...deck.loop})
  }

  function armLoopChecker(deck) {
    if (loopTimers[deck.id]) return
    loopTimers[deck.id] = setInterval(() => {
      const loop = deck.loop
      if (!loop.on || loop.endMs == null) return
      const pos = deck.positionMs()
      const last = loop._lastPos
      loop._lastPos = pos
      if (pos < loop.endMs) return
      // Natural overrun = we CROSSED the edge playing (small forward step —
      // robust to interval throttling); anything else was a deliberate seek,
      // and a loop must never fence the track.
      const crossed = last != null && last < loop.endMs && pos - last < 1500
      if (crossed || pos <= loop.endMs + 400) {
        deck.el.currentTime = loop.startMs / 1000
        loop._lastPos = loop.startMs
      } else {
        clearLoop(deck)
      }
    }, 20)
  }

  function beatMs(deck) {
    const bpm = deck.bpm ? deck.bpm * deck.el.playbackRate : null
    return bpm ? 60_000 / bpm : 500
  }

  // A loop must end before the track does, or `ended` never fires wrapped and
  // the boundary logic starves.
  function clampLoopEnd(deck, endMs) {
    const durMs = (deck.el.duration || 0) * 1000
    return durMs ? Math.min(endMs, durMs - 100) : endMs
  }

  function beatLoop(deckId, beats) {
    const deck = decks[deckId]
    if (deck.trackId == null) return
    if (deck.loop.on && deck.loop.beats === beats) {
      clearLoop(deck)
      return
    }
    const start = deck.positionMs()
    deck.loop = {
      on: true,
      startMs: start,
      endMs: clampLoopEnd(deck, start + beats * beatMs(deck)),
      beats,
    }
    armLoopChecker(deck)
    emit("loopState", {deck: deckId, ...deck.loop})
  }

  function loopControl(deckId, action) {
    const deck = decks[deckId]
    if (deck.trackId == null) return
    const loop = deck.loop
    if (action === "in") {
      deck.loop = {on: false, startMs: deck.positionMs(), endMs: null, beats: null}
    } else if (action === "out" && loop.startMs != null) {
      const endMs = clampLoopEnd(deck, Math.max(deck.positionMs(), loop.startMs + 30))
      deck.loop = {...loop, on: true, endMs, beats: null}
      armLoopChecker(deck)
    } else if (action === "toggle" && loop.endMs != null) {
      deck.loop = {...loop, on: !loop.on}
      if (deck.loop.on) armLoopChecker(deck)
    } else if (action === "half" && loop.endMs != null) {
      const len = Math.max((loop.endMs - loop.startMs) / 2, 30)
      // O tamanho mudou — não é mais o loop do pad de N tempos.
      deck.loop = {...loop, endMs: loop.startMs + len, beats: null}
    }
    emit("loopState", {deck: deckId, ...deck.loop})
  }

  watchOutgoing(decks.a)
  watchOutgoing(decks.b)
  wireOutputs()

  return {
    ctx,
    decks,

    resume() {
      if (ctx.state === "suspended") ctx.resume()
    },

    loadDeck(deckId, track, {autoplay = false, atMs = 0} = {}) {
      const deck = decks[deckId]
      // A new record on the platter ends any scratch (auto or jog) on this deck.
      resetScratch(deckId, true)
      if (!deck.load(track, atMs)) return false
      // A fresh load is a fresh instrument — loop off (chips/região avisados),
      // FX neutros, tempo natural. Vale para preload manual também.
      resetChain(deck)
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
      // A jog-held, auto-scratching or scratch-DROP-owned deck is IN THE DJ'S
      // HANDS — loading over it would make the release play a different track
      // than the one scratching. The scratch[].active case is the palette
      // Rasgo/Rebobina killer: right after those fire, the server's next hint
      // arrives while the outgoing deck is still mid-scratch (it looks idle —
      // paused, not audible); loading over it aborted the deferred drop and
      // the incoming deck never started. Dead air, stuck crossfader, frozen
      // scratch visuals. The hint parks as pending and re-arms after the drop.
      if (deck.audible() || jog[idle].held || autoScratch[idle] || scratch[idle].active) {
        return false
      }
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
      if (to.el.error) return {ok: false, reason: "target_error"}
      if (!to.audible() && !to.ready()) return {ok: false, reason: "target_loading"}
      this.resume()
      fireTransition(decks[fromId], to, {type: type, to_ms: null}, "manual", "palette")
      return {ok: true, from: fromId, to: to.id, type}
    },

    // The fire point AUTO is actually watching — engine-clamped against the real
    // media duration, plus any postponement. The countdown and the waveform flag
    // paint THIS number, never the server's (which can disagree on VBR files).
    firePointMs() {
      const hint = state.hint
      const active = state.activeDeck
      if (!hint || !hint.transition || !active) return null
      return clampFromMs(hint.transition["from_ms"], decks[active]) + state.postponeMs
    },

    // "Ainda não!" — push the AUTO fire point forward for this boundary only.
    // Postponed past the end of the track, the `ended` fallback still advances.
    postponeFire(ms) {
      if (this.firePointMs() == null) return null
      state.postponeMs += ms
      return this.firePointMs()
    },

    // "Agora!" — fire the armed hint immediately with its planned type/to_ms
    // (the keyboard cousin of AUTO's own fire; works with AUTO off too).
    fireHint() {
      const hint = state.hint
      const active = state.activeDeck
      if (state.lastFireAt && performance.now() - state.lastFireAt < 400) {
        return {ok: false, reason: "too_fast"}
      }
      if (!hint || !hint.transition || !active || !decks[active].audible()) {
        return {ok: false, reason: "no_hint"}
      }
      if (!hintFireable(hint)) return {ok: false, reason: "target_loading"}
      const from = decks[active]
      if (state.firedForTrack === from.trackId) return {ok: false, reason: "too_fast"}
      this.resume()
      boundaryOnce(from.trackId, () => fireTransition(from, decks[hint.deck], hint.transition, "manual", "hint"))
      return {ok: true, type: hint.transition["type"] || "cut"}
    },

    // Panic rescue: undo a transition that just fired — the outgoing deck comes
    // back on air with a neutral chain, the incoming is pulled off, and the
    // server hears transitionCancelled to rewind the set pointer.
    cancelTransition() {
      if (!state.lastFireAt || performance.now() - state.lastFireAt > 30_000) {
        return {ok: false, reason: "nothing"}
      }
      const rescued = decks[otherId(state.activeDeck)]
      const dropped = decks[state.activeDeck]
      if (rescued.trackId == null) return {ok: false, reason: "nothing"}
      state.transitionToken++ // cancels every scheduled pause/ramp of the fired run
      settleTransitionParams(rescued)
      settleTransitionParams(dropped)
      const now = ctx.currentTime
      rescued.gain.gain.linearRampToValueAtTime(1, now + 0.25)
      rescued.dry.gain.linearRampToValueAtTime(1, now + 0.25)
      rescued.echoSend.gain.linearRampToValueAtTime(0, now + 0.25)
      rescued.hpf.frequency.linearRampToValueAtTime(10, now + 0.2)
      rescued.lpf.frequency.linearRampToValueAtTime(20_000, now + 0.2)
      // A brake mid-flight left the rate collapsed — restore the deck's own.
      rescued.el.preservesPitch = true
      rescued.el.playbackRate = rescued.baseRate
      if (rescued.el.paused) rescued.play()
      dropped.pause()
      setCrossfader(rescued.id === "a" ? 0 : 1)
      state.activeDeck = rescued.id
      state.firedForTrack = null
      state.postponeMs = 0
      state.lastFireAt = null
      emit("fxReset", {deck: rescued.id})
      emit("transitionCancelled", {trackId: rescued.trackId, deck: rescued.id})
      return {ok: true}
    },

    playPause(deckId) {
      const deck = decks[deckId]
      if (jog[deckId].held) return // nunca dar play embaixo da mão do DJ
      this.resume()
      if (deck.audible()) {
        deck.pause()
      } else if (deck.trackId) {
        // Manual restart takes ownership: cancel stale transition cleanups and
        // resume with a SANE chain — a stop mid-echo/filter may have frozen
        // dry at zero or the filter swept; resuming must always sound clean.
        state.transitionToken++
        settleTransitionParams(deck)
        const now = ctx.currentTime
        if (deck.gain.gain.value < 0.05) deck.gain.gain.setValueAtTime(1, now)
        deck.dry.gain.linearRampToValueAtTime(1, now + 0.2)
        deck.echoSend.gain.linearRampToValueAtTime(0, now + 0.2)
        deck.hpf.frequency.linearRampToValueAtTime(10, now + 0.15)
        deck.lpf.frequency.linearRampToValueAtTime(20_000, now + 0.15)
        deck.play()
        state.activeDeck = deckId
        state.firedForTrack = null
        state.postponeMs = 0
        emit("deckStarted", {deck: deckId, trackId: deck.trackId})
      }
    },

    cueTo(deckId, ms) {
      const deck = decks[deckId]
      if (deck.trackId == null) return
      // A deliberate jump past the loop end EXITS the loop — the 20ms checker
      // must not read the landing spot as a natural overrun and snap back.
      if (deck.loop.on && deck.loop.endMs != null && ms >= deck.loop.endMs) {
        clearLoop(deck)
      }
      // The cue OWNS the start position now — neither a stale armed to_ms nor
      // an auto-fired transition may yank the deck elsewhere afterwards.
      deck._pendingSeekMs = null
      deck._cued = true
      deck.whenReady(() => {
        // Never seek AT/past the end: the element would fire `ended` and the
        // boundary logic would advance the set off a mere waveform click.
        const durMs = (deck.el.duration || 0) * 1000
        const clamped = durMs ? Math.min(ms, durMs - 300) : ms
        deck.el.currentTime = Math.max(clamped, 0) / 1000
      })
    },

    // Jog físico e de tela: topo segurado = vinil na mão; borda = nudge.
    jogTouch,
    jogTurn,
    startAutoScratch,
    stopAutoScratch,
    setAutoScratchRate,
    scratchReady,
    scratchPosSec,

    // Loops de batida (pads AUTO) e loop manual (in/out/liga/metade).
    beatLoop,
    loopControl,

    loopState(deckId) {
      return {...decks[deckId].loop}
    },

    sync(deckId) {
      const other = decks[otherId(deckId)]
      return decks[deckId].syncTo(other.bpm ? other.bpm * other.baseRate : null)
    },

    setRate(deckId, rate) {
      const deck = decks[deckId]
      deck.baseRate = Math.min(Math.max(rate, 1 - PITCH_RATE_CLAMP), 1 + PITCH_RATE_CLAMP)
      applyRate(deck)
    },

    // ── efeitos de performance (coisas que a controladora não tem) ─────────────

    // Filtro bipolar: -1 = afogado no low-pass, 0 = neutro, +1 = só ar (high-pass).
    setFilter(deckId, value) {
      const deck = decks[deckId]
      const v = Math.min(Math.max(value, -1), 1)
      const now = ctx.currentTime
      deck.settleParam(deck.lpf.frequency)
      deck.settleParam(deck.hpf.frequency)
      const lpfHz = v < 0 ? 20_000 * Math.pow(150 / 20_000, -v) : 20_000
      const hpfHz = v > 0 ? 10 * Math.pow(4_000 / 10, v) : 10
      deck.lpf.frequency.setTargetAtTime(lpfHz, now, 0.03)
      deck.hpf.frequency.setTargetAtTime(hpfHz, now, 0.03)
    },

    // Eco manual: abre o send do delay (já sincronizado ao BPM no load).
    setEchoSend(deckId, value) {
      const deck = decks[deckId]
      const now = ctx.currentTime
      deck.settleGain(deck.echoSend)
      deck.echoSend.gain.setTargetAtTime(Math.min(Math.max(value, 0), 1) * 0.9, now, 0.02)
    },

    // "Tom": tilt EQ grave↔agudo. v<0 puxa grave e abafa agudo (quente),
    // v>0 o contrário (brilhante). Nodes próprios — não encosta no bass_swap.
    setTone(deckId, value) {
      const deck = decks[deckId]
      const v = Math.min(Math.max(value, -1), 1)
      const now = ctx.currentTime
      deck.settleParam(deck.toneBass.gain)
      deck.settleParam(deck.toneTreble.gain)
      deck.toneBass.gain.setTargetAtTime(-v * RAMP.toneMaxDb, now, 0.03)
      deck.toneTreble.gain.setTargetAtTime(v * RAMP.toneMaxDb, now, 0.03)
    },

    // Modo VINIL: o pitch passa a mudar a afinação junto com o tempo.
    // O flag persiste por SYNC/freio — só o reset da cadeia (novo load) desliga.
    setVinylMode(deckId, on) {
      const deck = decks[deckId]
      deck.vinylMode = on
      deck.el.preservesPitch = !on
      applyRate(deck)
    },

    // Ejeta um deck parado: solta a mídia e zera a cadeia. Recusado no ar.
    eject(deckId) {
      const deck = decks[deckId]
      if (deck.audible() || jog[deckId].held) return false
      deck.trackId = null
      deck.bpm = null
      deck.durationMs = null
      deck.el.removeAttribute("src")
      deck.el.load()
      resetChain(deck)
      if (state.hint && state.hint.deck === deckId) state.hint = null
      return true
    },

    // PUNCH ("estourado"): abaixa o threshold e sobe o drive juntos — em 0 o
    // compressor não pega nada (transparente), no talo esmaga e engorda.
    setPunch(value) {
      const now = ctx.currentTime
      const v = Math.min(Math.max(value, 0), 1)
      punchComp.threshold.setTargetAtTime(-24 * v, now, 0.05)
      punch.gain.cancelScheduledValues(now)
      punch.gain.setTargetAtTime(1 + v * 1.2, now, 0.05)
    },

    setCrossfader,
    setCrossfaderCurve,
    setDeckLevel,
    setMasterLevel,

    // "Comprimento" das transições, em segundos de referência (o crossfade base).
    // Escala TODAS as transições em volta desse número; aceita valor quebrado.
    setTransitionLength(seconds) {
      const s = Math.min(Math.max(seconds, 1.5), 20)
      state.transitionScale = s / REF_LEN_S
      return s
    },

    transitionLengthS() {
      return REF_LEN_S * state.transitionScale
    },

    // ── headphone cue (PFL) ────────────────────────────────────────────────────

    togglePfl(deckId) {
      cue.on[deckId] = !cue.on[deckId]
      const now = ctx.currentTime
      const g = cue[deckId].gain
      g.cancelScheduledValues(now)
      g.setTargetAtTime(cue.on[deckId] ? 1 : 0, now, 0.01)
      emit("pflState", {...cue.on})
      return cue.on[deckId]
    },

    pflState() {
      return {...cue.on}
    },

    setCueLevel(value) {
      const now = ctx.currentTime
      cue.bus.gain.cancelScheduledValues(now)
      cue.bus.gain.setTargetAtTime(Math.min(Math.max(value, 0), 1.2), now, RAMP.manualFaderTau)
    },

    // The routable phones stream (fallback when the output device is stereo).
    cueStream() {
      return cueStreamDest.stream
    },

    cueMode() {
      return {mode: cue.mode, maxChannels: ctx.destination.maxChannelCount || 2}
    },

    // Point the WHOLE context at another output device (e.g. the controller's
    // 4-channel interface) and rewire main/phones for what it offers.
    async setOutputDevice(deviceId) {
      if (typeof ctx.setSinkId === "function") {
        await ctx.setSinkId(deviceId)
        wireOutputs()
      }
      return this.cueMode()
    },

    stopAll() {
      state.transitionToken++ // no in-flight cleanup may outlive a stop
      decks.a.pause()
      decks.b.pause()
      // Full clean stop: no frozen mid-transition FX, no ghost resume from a
      // jog release, chips/sliders told via the resetChain events.
      for (const d of ["a", "b"]) {
        jog[d].wasPlaying = false
        cancelBend(d)
        resetChain(decks[d])
      }
      state.activeDeck = null
      state.hint = null
    },

    // Pause without losing state — used when another audio source (o player
    // global) takes over; loads and the armed hint survive. Params settle at
    // their CURRENT values; resuming via playPause re-sanitizes the chain.
    pauseAll() {
      state.transitionToken++
      decks.a.pause()
      decks.b.pause()
      for (const d of ["a", "b"]) {
        jog[d].wasPlaying = false
        settleTransitionParams(decks[d])
      }
    },

    snapshot() {
      const deckSnap = (deck) => ({
        trackId: deck.trackId,
        posMs: deck.positionMs(),
        durMs: (deck.el.duration || 0) * 1000,
        playing: deck.audible(),
      })

      return {
        activeDeck: state.activeDeck,
        audibleDeck: audibleDeckId(),
        auto: state.autoOn,
        xfadePos: xfade.pos,
        postponeMs: state.postponeMs,
        hintReady: hintFireable(state.hint),
        a: deckSnap(decks.a),
        b: deckSnap(decks.b),
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
      for (const d of ["a", "b"]) {
        if (loopTimers[d]) clearInterval(loopTimers[d])
        if (jog[d].decay) clearInterval(jog[d].decay)
        // Scratch timers outlive the hook otherwise (setInterval keeps posting
        // to a torn-down worklet after unmount).
        if (autoScratch[d]) clearInterval(autoScratch[d].timer)
      }
      decks.a.pause()
      decks.b.pause()
      decks.a.destroyGraph()
      decks.b.destroyGraph()
      const nodes = [
        xfade.a,
        xfade.b,
        punch,
        punchComp,
        master,
        masterAnalyser,
        cue.a,
        cue.b,
        cue.bus,
        ...outputNodes,
      ]
      for (const node of nodes) {
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
