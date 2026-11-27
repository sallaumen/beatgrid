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

import {applyFilter, applyTone, createEq, neutralMix, setMixParam, syncedRate} from "./deck_mix.js"
import {recallSplice} from "./record_source.js"
import {startDecodedEntry} from "./decoded_entry.js"
import {createPassage} from "./passage.js"
import {createProgramMeter, observeRoomPassage} from "./passage_meter.js"
import {scheduleBlend} from "./blend_curve.js"
import {createRehearsal, CUT_OVERLAP_S, rehearsalOverlap, scheduleRehearsalBass} from "./rehearsal.js"
import {getDeckAudio, getScratchPcm, retainScratch} from "./waveform.js"
import {ensureScratchModule, scratchPattern} from "./scratch.js"

const RAMP = Object.freeze({
  manualFaderTau: 0.01, // s — smoothing for hand moves (kills zipper noise)
  nativeCutS: 0.24, // a cold media decoder can reach the graph after play() resolves
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
  jogTickS: 1.8 / 236, // DJ2GO2 Touch: 236 ticks per turn at 33⅓ rpm
  jogSeekStepS: 0.036, // faster search with the paused platter's outer edge
  scratchDepthS: 0.16,
  scratchGain: 1.5, // the scratched deck sits ~3.5 dB above its own music (Lucas mixes at max on the crossfader)
  // Scratch DROP transitions — runs last WHOLE beats of the outgoing track
  // (knob-scaled), so a fire on the count drops on a count. Stroke depths are
  // seconds of record travel; the gate retard matches tickAutoScratch's (the
  // heard audio lags the commanded head by ~20ms of smoothing).
  rasgoDepthS: 0.1,
  chirpDepthS: 0.14,
  transformDuty: 0.55, // fraction of each 1/8-note chop the dry path stays open
  dropGateRetardS: 0.02,
  // An early-fired breather rides the echo over the CURRENT phrase this long
  // before dissolving into the gap (mirrors the server's 4s fire lead).
  breatherMaxTailS: 4,
  breatherEchoMix: 0.30,
  breatherEchoFeedback: 0.42,
  echoReleaseMs: 8,
  dropEchoSend: 0.3, // chop kinds ring into the deck's delay — subtler than a full echo-out
  dropTailFadeS: 0.35, // echoTail kinds: the last chop's tail bleeds under the incoming
})

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
    this.playToken = 0
    this.playPending = false

    this.gain = ctx.createGain() // deck level fader
    Object.assign(this, createEq(ctx))
    this.controls = {...neutralMix}
    this.baseRate = 1 // tempo alvo (pitch fader / SYNC); o bend do jog decai para cá
    this.vinylMode = false // TOM: pitch muda a afinação; sobrevive a SYNC/brake
    this.loop = {on: false, startMs: null, endMs: null, beats: null}
    this.dry = ctx.createGain()
    this.echoSend = ctx.createGain()
    this.feedback = ctx.createGain()
    this.channel = ctx.createGain() // post-fader channel bus (metered)
    this.analyser = ctx.createAnalyser()
    this.analyser.fftSize = 256
    this._meterBuf = new Uint8Array(this.analyser.fftSize)

    this.echoSend.gain.value = 0
    this.echoTailUntil = 0
    this.feedback.gain.value = RAMP.echoFeedback

    sourceFor(el).disconnect()
    this.dropCue = null
    this.mediaGain = ctx.createGain()
    sourceFor(el).connect(this.mediaGain)
    this.mediaGain.connect(this.hpf)
    this.toneTreble.connect(this.dry)
    this.toneTreble.connect(this.echoSend)
    this.connectDelay(0)
    this.dry.connect(this.channel)
    this.channel.connect(this.analyser)
    this.channel.connect(this.gain) // fader AFTER the cue/meter tap (pre-fader listen)
  }

  connectDelay(seconds) {
    this.delay = this.ctx.createDelay(2)
    this.delay.delayTime.value = seconds
    this.echoSend.connect(this.delay)
    this.delay.connect(this.feedback)
    this.feedback.connect(this.delay)
    this.delay.connect(this.channel)
  }

  releaseBreatherEcho() {
    const old = this.delay, now = this.ctx.currentTime
    this.settleGain(this.echoSend)
    this.echoSend.gain.setValueAtTime(0, now)
    this.echoSend.disconnect(old)
    this.feedback.disconnect(old)
    old.disconnect()
    // Only the old delay's buffered sound fades out. A new load or a quick
    // rescue has its own empty delay, even if it happens during these 8 ms.
    const release = this.ctx.createGain()
    old.connect(release)
    release.connect(this.channel)
    release.gain.setValueAtTime(1, now)
    release.gain.linearRampToValueAtTime(0, now + RAMP.echoReleaseMs / 1000)
    this.connectDelay(old.delayTime.value)
    this.settleGain(this.feedback)
    this.feedback.gain.setValueAtTime(RAMP.echoFeedback, now)
    this.echoTailUntil = now + RAMP.echoReleaseMs / 1000
    setTimeout(() => {
      old.disconnect()
      release.disconnect()
    }, RAMP.echoReleaseMs)
  }

  // Loading is REFUSED while audible — the incoming track belongs on the idle deck.
  load(track, atMs = 0) {
    if (this.audible()) return false
    this.useMedia(false)
    this.playPending = false
    this.wantsPlayback = false
    this.cueState = null
    const markers = (track.markers || []).filter(m =>
      m.type !== "outro" && Number.isFinite(m.ms) && m.ms >= 0)
    this.cueMs = markers.length ? Math.min(...markers.map(m => m.ms)) : atMs
    const token = ++this.loadToken
    this.trackId = track.id
    this.title = track.title
    this.bpm = Number.isFinite(track.bpm) && track.bpm > 0 ? track.bpm : null
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
    this._seekGuard = false
    this._seekQueued = false
    this.el.src = track.src
    this.el.load()
    this._pendingSeekMs = atMs
    this._readyToken = token
    retainScratch(this, track.id)
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

  play(atMs = null, started, failed) {
    this.wantsPlayback = true
    if (atMs != null) this._pendingSeekMs = atMs
    const token = ++this.playToken
    this.playPending = !this.ready()
    this.whenReady(() => {
      if (token !== this.playToken) return
      this.useMedia()
      this.playPending = false
      const seek = this._pendingSeekMs
      this._pendingSeekMs = null
      if (seek != null) {
        const target = this.clampPosition(seek / 1000)
        if (target !== this.el.currentTime) {
          this._seekGuard = true
          this.el.currentTime = target
        }
      }
      this.el.play().then(started, failed || (() => {}))
    })
  }

  // The native transport opens behind both buses. Keep the platter parked at
  // the chosen cue while the outgoing record performs its gesture.
  primeDrop(cue) {
    this.dropCue = cue
    this.mediaGain.gain.setValueAtTime(0, this.ctx.currentTime)
  }

  playDecoded(buffer, offset, mix) {
    if (this.dropCue !== null) {
      this.dropCue = null
      this._cued = false
      if (this.el.currentTime !== offset) this.el.currentTime = offset
      if (this.el.paused) this.el.play().catch(() => {}) // the recording owns the audible start
    }
    this.useMedia(false)
    this.decodedTransport(buffer, offset, mix)
  }

  preparePassageAudio(buffer, offset, mix, outgoing = false, splice) {
    if (outgoing && this.entry) return this.entry.prepareRecall(buffer, offset, mix, splice)
    return this.decodedTransport(buffer, offset, mix, {outgoing, splice})
  }

  decodedTransport(buffer, offset, mix, stage) {
    let progressTimer
    const entry = startDecodedEntry(this.ctx, this.el, buffer, offset, this.hpf, this.mediaGain, ended => {
      clearInterval(progressTimer)
      this.entry = null
      if (ended) this.recordEnded()
    }, mix, () => this.wantsPlayback && this.loop.on && this.recordEnded(), stage)
    // Muted media can stall without a timeupdate while the record reaches its AUTO point.
    const own = () => {
      this.entry = entry
      progressTimer = setInterval(this.recordProgress, 100)
    }
    if (stage) return {launch(when, head) { entry.launch(when, head); own() }, discard: entry.discard}
    own()
  }

  get playbackRate() {
    return this.entry?.rate() ?? this.el.playbackRate
  }

  useMedia(sync = true) {
    this.entry?.release(sync)
    this.entry = null
  }

  seek(seconds, positionAfter) {
    const recording = this.entry
    if (recording) {
      recording.seek(seconds, positionAfter)
    } else if (this.wantsPlayback && this.audible() && !this.stopBrake && seconds !== this.el.currentTime) {
      const buffer = getDeckAudio(this.trackId)
      if (buffer && seconds < buffer.duration) {
        // A compressed media seek can report the requested time while playing a different sample.
        let prepared
        try {
          prepared = this.preparePassageAudio(buffer, seconds, {rate: this.playbackRate, vinyl: this.vinylMode}, true)
          prepared.launch(this.ctx.currentTime, seconds)
        } catch { prepared?.discard() }
      }
    }
    this.el.currentTime = seconds
    if (recording && this.wantsPlayback && this.el.paused) this.el.play().catch(() => {})
  }

  pause() {
    this.wantsPlayback = false
    this.playToken++
    this.playPending = false
    this.el.pause()
    if (this.dropCue !== null) {
      this.el.currentTime = this.dropCue
      this.dropCue = null
      this.mediaGain.gain.setValueAtTime(1, this.ctx.currentTime)
    }
    this.useMedia()
  }

  audible() {
    return this.dropCue === null && (!!this.entry || (!this.el.paused && !this.el.ended)) && !this.el.error && this.trackId != null
  }

  seeking() {
    return this._seekQueued || (!this.entry && this.el.seeking)
  }

  ended() {
    return !this.entry && this.el.ended
  }

  positionMs() {
    return Math.round((this.dropCue ?? this.entry?.position() ?? this.el.currentTime) * 1000)
  }

  platterTime() {
    return this._pendingSeekMs == null ? (this.dropCue ?? this.entry?.position() ?? this.el.currentTime) : this._pendingSeekMs / 1000
  }

  clampPosition(seconds) {
    const duration = this.el.duration
    return Math.max(duration ? Math.min(seconds, duration - 0.001) : seconds, 0)
  }

  // SYNC: match this deck's tempo to `targetBpm`; the rate KEEPS for the rest of
  // the track (the old engine's snap-back at handoff was audible), reset on load.
  syncTo(targetBpm) {
    if (!this.bpm || !targetBpm) return false
    const rate = targetBpm / this.bpm
    const previous = this.baseRate
    this.baseRate = syncedRate(previous, this.bpm, targetBpm)
    if (this.entry && previous === this.baseRate) this.entry.nudge(this.baseRate)
    else this.useMedia()
    this.el.preservesPitch = !this.vinylMode
    this.el.playbackRate = this.baseRate
    return Math.abs(this.baseRate - rate) < 1e-9
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
      this.mediaGain,
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
  const pfl = ctx.createGain()
  cue.a.connect(pfl)
  cue.b.connect(pfl)
  pfl.connect(cue.bus)
  const rehearsal = createRehearsal(ctx, cue.bus, pfl)
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

  let deviceFeed
  let outputNodes = []
  let routedChannels = 0

  // Wire master (and, on 4-channel interfaces, the cue bus) to the device.
  // DJ2GO2 Touch is a 4-out card: main = channels 1/2, phones = 3/4 — with it
  // as the output device, the browser can feed the room AND the headphones.
  function wireOutputs() {
    const maxCh = ctx.destination.maxChannelCount || 2
    if (maxCh === routedChannels) return
    cancelRoomReading()
    programMeter?.stop()
    rehearsal.stop()
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
      deviceFeed = merger
      outputNodes = [merger, masterSplit, cueSplit]
      cue.mode = "quad"
    } else {
      // Undo any leftover quad destination config from a device switch.
      ctx.destination.channelCountMode = "explicit"
      ctx.destination.channelCount = Math.min(2, Math.max(maxCh, 1))
      ctx.destination.channelInterpretation = "speakers"
      deviceFeed = master
      // The routable fallback only exists in stereo mode — in quad the cue
      // rides channels 3/4 and must not double anywhere else.
      cue.bus.connect(cueStreamDest)
      cue.mode = "stereo"
    }
    if (roomAvailable) deviceFeed.connect(ctx.destination)
    routedChannels = maxCh
    if (roomAvailable && (decks.a.audible() || decks.b.audible())) programMeter?.start()
    emit("cueMode", {mode: cue.mode, maxChannels: maxCh})
  }

  const state = {
    activeDeck: null, // "a" | "b" | null — who owns the set boundary
    hint: null, // {deck, track, transition} armed on the idle deck
    transitionToken: 0,
    firedForTrack: null, // dedupes transition vs ended for one boundary
    rescue: null, // outgoing load that can still be brought back
    pendingEntry: null, // receiving deck reserved until its entry starts
    cancelEntry: null, // revokes an entry waiting for media playback
    waitingForNext: false, // the outgoing ended before the authorized preload was ready
    lastFireAt: null, // performance.now() of the last fired transition
    autoOn: false,
    // "Ainda não!": offset added to the AUTO fire point for the CURRENT
    // boundary only — cleared whenever the boundary advances or changes hands.
    postponeMs: 0,
    // Breather in progress. A null deadline means its outgoing phrase is still playing.
    breatherGap: null,
    stopScratchDrop: null,
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

  let roomAvailable = true
  let roomEnd = null // a single unheard boundary, cleared when the DJ takes over
  const programMeter = callbacks.programScore && createProgramMeter(ctx, masterAnalyser)
  let roomReading = null
  function cancelRoomReading() {
    roomReading?.cancel()
    roomReading = null
  }

  function releaseEchoTail(deck, now) {
    if (deck.echoTailUntil !== Infinity && deck.echoSend.gain.value < 0.0001) return
    const feedback = Math.max(0.01, Math.min(deck.feedback.gain.value, 0.99))
    const repeats = Math.ceil(Math.log(0.0001) / Math.log(feedback))
    deck.echoTailUntil = now + 0.2 + repeats * deck.delay.delayTime.value
  }

  function dryForBlend(deck) {
    return !deck.stopEcho && deck.echoSend.gain.value < 0.0001 && !(ctx.currentTime < deck.echoTailUntil) &&
      Math.abs(deck.dry.gain.value - 1) < 0.001 && Math.abs(deck.bass.gain.value) < 0.01
  }

  function canMeasureBlend(from, to, mix) {
    // Room recall smooths the already-playing deck. Only promise measured headroom
    // when its live path is already neutral and at or below the saved level.
    return punch.gain.value <= 1.001 && punchComp.threshold.value >= -0.01 && master.gain.value <= 1.001 &&
      dryForBlend(from) && dryForBlend(to) && xfade[from.id].gain.value >= 0.999 &&
      from.playbackRate === 1 && from.controls.tone === 0 && from.controls.filter === 0 &&
      Math.abs(from.hpf.frequency.value - 10) < 0.1 && Math.abs(from.lpf.frequency.value - 20_000) < 1 &&
      Math.abs(from.toneBass.gain.value) < 0.01 && Math.abs(from.toneTreble.gain.value) < 0.01 &&
      from.gain.gain.value <= (mix?.out.level ?? 1) + 0.001
  }

  // Echo tails and a live bass effect aren't part of the saved deck controls.
  // An exchange can be recalled once the room is back on a clean outgoing deck.
  function bassReady(from, to) {
    return xfade[from.id].gain.value >= 0.999 && dryForBlend(from) && dryForBlend(to)
  }

  function canRecallPassage(from, to, plan, kind) {
    if (kind === "bass_swap") return bassReady(from, to)
    return kind !== "blend" || !plan?.blendCurve || canMeasureBlend(from, to, plan.mix)
  }

  let preparedPassage = null

  function releasePrepared(choice) {
    if (preparedPassage?.choice !== choice) return
    preparedPassage.discard()
    preparedPassage = null
  }

  function preparePair(choice, from, to, head, mix) {
    const {plan} = choice
    const entry = from.entry, rate = from.playbackRate, vinyl = from.vinylMode
    const incoming = to.preparePassageAudio(plan.incoming, plan.inStart, mix.into)
    let outgoing
    try {
      const splice = recallSplice(choice.splices, plan.outgoing, head, mix.out.rate)
      if (splice || rate !== mix.out.rate || vinyl !== mix.out.vinyl) {
        outgoing = from.preparePassageAudio(plan.outgoing, head, mix.out, true, splice)
      }
    } catch (error) {
      incoming.discard()
      throw error
    }
    return {choice, incoming, outgoing,
      matches: () => from.entry === entry && from.playbackRate === rate && from.vinylMode === vinyl,
      discard() { incoming.discard(); outgoing?.discard() }}
  }

  const passage = createPassage(decks, (from, to, plan, kind) =>
    from.audible() && !deckHeld(from.id) && !from.loop.on && !state.breatherGap &&
    to.trackId != null && !deckBusy(to.id) && !to.el.error && to.ready() &&
    canRecallPassage(from, to, plan, kind), startPassage, {
      confirmed(choice) {
        const {plan, pair} = choice
        const from = decks[pair.from]
        if (plan.mix && from.positionMs() < choice.exitMs) {
          try {
            preparedPassage = preparePair(choice, from, decks[pair.to], plan.exit ?? choice.exitMs / 1000, plan.mix)
          } catch { /* A failed speculative allocation gets one ordinary attempt at the cue. */ }
        }
        if (!callbacks.roomScore) return
        cancelRoomReading()
        roomReading = observeRoomPassage(ctx, masterAnalyser, choice, decks[choice.pair.from], data => {
          roomReading = null
          emit("roomScore", {data, reference: choice.reference})
        })
      },
      abandoned(choice) {
        releasePrepared(choice)
        if (roomReading?.choice === choice) cancelRoomReading()
      }
    })

  function deckMix(id) {
    const deck = decks[id]
    return {...deck.controls, rate: deck.baseRate, vinyl: deck.vinylMode}
  }

  function recallControls(deck, mix) {
    cancelBend(deck.id)
    deck.baseRate = mix.rate
    deck.vinylMode = mix.vinyl
    if (deck.el.preservesPitch !== !mix.vinyl) deck.el.preservesPitch = !mix.vinyl
    if (deck.el.playbackRate !== mix.rate) deck.el.playbackRate = mix.rate
    deck.controls = {...mix}
  }

  function scheduleDeckMix(deck, mix, smooth, now) {
    applyFilter(deck, mix.filter, now, smooth)
    applyTone(deck, mix.tone, now, smooth)
    setMixParam(deck.gain.gain, mix.level, now, smooth)
  }

  function startPassage(from, to, choice, complete) {
    const {plan, kind} = choice
    const fade = rehearsalOverlap(plan, kind)
    const mix = plan.mix ?? {out: deckMix(from.id), into: deckMix(to.id)}
    const version = faderVersion
    const mute = xfade[to.id].gain
    const previous = mute.value
    mute.cancelScheduledValues(ctx.currentTime)
    mute.setValueAtTime(0, ctx.currentTime)
    const restore = () => {
      if (to.playToken === playToken) to.pause()
      if (version === faderVersion) mute.setValueAtTime(previous, ctx.currentTime)
    }
    to.play(plan.inStart * 1000, () => {
      const owned = to.playToken === playToken && !deckHeld(from.id) && !deckHeld(to.id) &&
        canRecallPassage(from, to, plan, kind)
      if (!owned || passage.current() !== choice || choice.phase !== "starting") return complete(false)
      let prepared, now, atMs, token
      let landed = false
      try {
        if (preparedPassage?.choice === choice && preparedPassage.matches()) {
          prepared = preparedPassage
          preparedPassage = null
        } else {
          releasePrepared(choice)
          prepared = preparePair(choice, from, to, from.platterTime(), mix)
        }
        landed = complete(true, () => {
          token = interruptTransition({startingPassage: true})
          settleTransitionParams(to)
          const head = from.platterTime()
          const liveHead = Math.max(head, plan.exit ?? choice.exitMs / 1000)
          now = ctx.currentTime + (liveHead - head) / from.playbackRate
          atMs = Math.round(liveHead * 1000)
          prepared.incoming.launch(now, plan.inStart)
          prepared.outgoing?.launch(now, liveHead)
        })
      } catch { complete(false) } finally {
        if (!landed) prepared?.discard()
      }
      if (!landed) return
      state.lastFireAt = performance.now()
      state.rescue = {deck: from.id, load: from.loadToken}
      state.faderVersion = faderVersion
      to._cued = false
      to.dry.gain.setValueAtTime(1, now)
      to.bass.gain.setValueAtTime(0, now)
      scheduleDeckMix(from, mix.out, true, now)
      scheduleDeckMix(to, mix.into, false, now)
      const outGain = xfade[from.id].gain
      const outLevel = outGain.value
      outGain.cancelScheduledValues(now)
      const curve = kind === "blend" && plan.blendCurve
      if (kind === "bass_swap") {
        scheduleRehearsalBass(from.bass.gain, "out", now, fade, now)
        scheduleRehearsalBass(to.bass.gain, "into", now, fade, now)
      }
      scheduleBlend(outGain, curve, 0, now, fade, now, outLevel)
      scheduleBlend(mute, curve, 1, now, fade, now)
      if (roomReading?.choice === choice) roomReading.arrive(now)
      animateXfadePos(sideOf(to.id), fade)
      after(fade, () => finishOutgoing(from, token))
      // Decoder rate setters and UI callbacks may run synchronously. The CUE,
      // EQ and both faders must already be on the audio clock before these.
      recallControls(from, mix.out)
      recallControls(to, mix.into)
      rehearsal.stop()
      clearLoop(to)
      handoff(from, to, {fromTrackId: from.trackId, deck: to.id, type: kind,
        mode: "manual", origin: "rehearsal", atMs})
      emit("mixApplied", {deck: from.id, mix: mix.out})
      emit("mixApplied", {deck: to.id, mix: mix.into})
    }, () => complete(false))
    const playToken = to.playToken
    return restore
  }

  // ── boundary handling: ONE advance per track, whatever triggers it ──────────

  function boundaryOnce(trackId, fn) {
    if (state.firedForTrack === trackId) return
    state.firedForTrack = trackId
    fn()
  }

  const mediaEvents = new AbortController()

  function watchOutgoing(deck) {
    const listen = (event, fn) => deck.el.addEventListener(event, fn, {signal: mediaEvents.signal})
    deck.recordProgress = () => maybeFire(deck)
    listen("playing", () => { if (roomAvailable) programMeter?.start() })
    listen("timeupdate", () => { if (!deck.entry) deck.recordProgress() })
    // A deck going silent is the moment a queued hint can claim it. Event-driven
    // on purpose: rAF loops don't run in background tabs, and re-arming the next
    // track must not depend on the page being visible.
    listen("pause", () => {
      if (!sessionDeck()) programMeter?.stop()
      if (!deckBusy(deck.id)) emit("deckFreed", {deck: deck.id})
    })
    deck.recordEnded = () => {
      if (!deck.wantsPlayback) return
      if (deck.loop.on) {
        const wrapped = wrapLoop(deck)
        if (wrapped && !deck.entry && deck.el.paused) deck.play()
        return wrapped
      }
      if (deck.id !== state.activeDeck || deck.cueState) return
      if (state.breatherGap) return state.breatherGap.beginGap()
      handleEnded(deck)
    }
    listen("ended", () => {
      if (deck.ended()) deck.recordEnded()
      if (!sessionDeck()) programMeter?.stop()
    })
    listen("seeking", () => { if (!deck.entry) passage.seek(deck, deck.positionMs()) })
    listen("canplay", () => retryReadyHint(deck))
    listen("durationchange", () => {
      emit("durationChanged", {deck: deck.id})
      if (deck.loop.on && deck.loop.beats && !loopFits(deck, deck.loop.endMs)) {
        const beats = deck.loop.beats
        clearLoop(deck)
        emit("loopTooLong", {deck: deck.id, beats})
      }
    })
    listen("error", () => {
      if (deck.trackId == null) return
      // A fatally-errored element must not keep reading as "audible" — pause it
      // so the deck frees up (deckFreed) and recovery loads are not refused.
      // Capture transport intent before pause() clears it. A media failure on
      // a manually paused source must not command playback of the other deck.
      const trackId = deck.trackId
      state.cancelEntry?.()
      passage.fail()
      const wasPlaying = state.activeDeck === deck.id && Boolean(deck.wantsPlayback || sessionDeck() === deck.id)
      deck.pause()
      emit("deckError", {deck: deck.id, trackId, wasPlaying})
    })
  }

  function retryReadyHint(deck) {
    if (state.hint?.deck !== deck.id || !hintFireable(state.hint)) return
    const gap = activeBreatherGap()
    if (gap && gap.deadline <= performance.now()) gap.start()
    else if (state.waitingForNext) handleEnded(decks[state.activeDeck])
  }

  function handleEnded(deck, trackId = deck.trackId, heldPassage = null) {
    if (state.cancelEntry) return // the receiving play owns this boundary until it settles
    const saved = passage.current()
    if (!roomAvailable) {
      if (saved?.pair.from === deck.id) passage.sourceEnded()
      roomEnd = {deck, trackId, saved}
      return
    }
    // An entry close to EOF can end before the outgoing cut envelope.
    state.rescue?.finishCut?.()
    state.postponeMs = 0
    if (saved?.pair.from === deck.id) {
      // The held take already expired in the missing room and stays available for review.
      if (saved !== heldPassage) passage.sourceEnded()
      boundaryOnce(trackId, () => emit("trackEnded", {trackId}))
      return
    }
    const hint = state.hint
    const other = decks[otherId(deck.id)]
    if (state.autoOn && hint) {
      const breather = hint.transition?.breather
      if (!breather && !hintFireable(hint)) {
        state.waitingForNext = true
        return
      }
      state.waitingForNext = false
      boundaryOnce(deck.trackId, () => {
        const planned = hint.transition?.type
        if (!breather && planned && planned !== "cut") emit("planDowngraded", {planned})
        const transition = breather ? hint.transition : {type: "cut", to_ms: hint.transition?.to_ms ?? 0}
        fireTransition(deck, decks[hint.deck], transition, "auto", "ended")
      })
    } else if ((other.audible() || platterWillResume(other)) && !other.cueState) {
      state.activeDeck = other.id
      state.firedForTrack = null
      emit("deckStarted", {deck: other.id, trackId: other.trackId})
    } else {
      boundaryOnce(trackId, () => emit("trackEnded", {trackId}))
    }
  }

  function sessionDeck() {
    const id = state.activeDeck
    if (!id) return null
    const deck = decks[id]
    if (deck.audible() || deck.playPending || restartingLoop(deck) || platterWillResume(deck) || state.pendingEntry === id || state.cancelEntry || state.breatherGap || roomEnd || state.waitingForNext ||
        (deck.el.ended && deck.wantsPlayback && (!roomAvailable || (state.autoOn && state.hint)))) return id
    return audibleDeckId()
  }

  // A hint deck can only RECEIVE a transition when its media is actually
  // playable — firing into a still-buffering or errored deck is dead air.
  function hintFireable(hint) {
    if (!hint) return false
    const target = decks[hint.deck]
    return !deckHeld(target.id) && target.trackId != null && target.ready() && !target.el.error
  }

  function maybeFire(deck) {
    if (passage.current()?.pair.from === deck.id) return passage.check()
    const hint = state.hint
    if (!roomAvailable || !state.autoOn || !hint || deck.id !== state.activeDeck) return
    if (deck.seeking()) return
    // pause() and scrubbing both fire 'timeupdate' — a jog-held (or otherwise
    // silent) deck must never be the source of an automatic transition. Nor may
    // AUTO fire while a scratch is in the DJ's hands (it steers the crossfader).
    if (!deck.audible() || deck.cueState || jog[deck.id].held || autoScratch.a || autoScratch.b) return
    if (!hint.transition) return // sequential entries advance on `ended`
    if (!hintFireable(hint)) return // waits; the ended fallback still covers it

    const fromMs = firePoint(hint.transition, deck)
    const pos = deck.positionMs()
    if (deck._seekGuard) {
      if (pos >= fromMs) return // landed at/past the point: re-enter or let `ended` cut
      deck._seekGuard = false
    }
    // Inside the window only: toggling AUTO on far past the mark must not slam
    // an instant transition — the ended fallback covers the overshoot.
    if (deck.loop.on || pos < fromMs || pos > fromMs + RAMP.autoFireSlackMs) return

    boundaryOnce(deck.trackId, () => fireTransition(deck, decks[hint.deck], hint.transition, "auto", "window"))
  }

  function firePoint(transition, deck) {
    const duration = deck.el.duration
    const mark = transition.breather && Number.isFinite(duration) && duration > 0
      ? (duration - RAMP.breatherMaxTailS) * 1000
      : transition.from_ms
    return clampFromMs(mark, deck) + state.postponeMs
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
    scratch_cut: scratchDrop,
    spinback: scratchDrop,
    chirp: scratchDrop,
    transform: scratchDrop,
    scribble: scratchDrop,
  })

  function fireTransition(from, to, transition, mode, origin) {
    const token = interruptTransition()
    const type = transition["type"] || "cut"
    const breather = transition["breather"] === true
    const run = TRANSITIONS()[type] || cut
    const delayed = !breather && (run === brake || run === scratchDrop)
    if (from.loop.on && !delayed) clearLoop(from)
    state.faderVersion = faderVersion
    state.rescue = {deck: from.id, load: from.loadToken}
    state.lastFireAt = performance.now()
    // A transition owns both decks and the crossfader now — abandon any scratch
    // in progress WITHOUT restoring the fader (the transition steers it).
    resetScratch(from.id, false)
    resetScratch(to.id, false)
    // null → the incoming deck starts wherever it is cued (manual fire); armed
    // hints resolved their to_ms into the pending seek at load time.
    const toMs = transition["to_ms"] ?? null

    const event = {
      fromTrackId: from.trackId,
      toTrackId: to.trackId,
      type,
      deck: to.id,
      mode,
      // Who pulled the trigger (window|ended|hint|palette) and where the
      // outgoing deck REALLY was — the server learns fire points from these.
      origin,
      atMs: Math.round(from.positionMs()),
    }

    // A transition interrupted by this one must not keep steering either deck:
    // kill every scheduled ramp NOW (invariant 2 — a pending ramp-to-zero on
    // the deck going back on air is the dead-air bug from the party).
    settleTransitionParams(from)
    settleTransitionParams(to)
    neutralizeIncoming(to, type)
    // The incoming chain was just washed neutral — tell the UI so the FX
    // sliders don't lie over transparent audio.
    emit("fxReset", {deck: to.id})

    if (breather) {
      breatherOut(from, to, transition, event, token)
      return
    }
    const wasPlaying = to.audible()
    const entryMs = to._cued || wasPlaying || toMs == null ? to.platterTime() * 1000 : toMs
    state.pendingEntry = to.id
    if (run === cut) return receiveEntry(from, to, toMs, cue => cut(from, to, cue, event))

    const audio = delayed && !wasPlaying ? getDeckAudio(to.trackId) : null
    const fallback = cue => {
      if (from.loop.on) clearLoop(from)
      cut(from, to, cue, {...event, type: "cut"})
      emit("dropUnavailable")
    }
    if (delayed && ((!wasPlaying && (!audio || entryMs >= audio.duration * 1000)) ||
                    (run === scratchDrop && !scratchReady(from.id)))) {
      return receiveEntry(from, to, toMs, fallback)
    }
    if (delayed && !wasPlaying) to.primeDrop(to.clampPosition(entryMs / 1000))
    receiveEntry(from, to, toMs, cue => {
      if (delayed && (from.ended() || (run === scratchDrop && !scratchArm(from.id)))) return fallback(cue)
      if (delayed && from.loop.on) clearLoop(from)
      const effectStart = ctx.currentTime
      const land = (overlap, change) => handoff(from, to, {...event, atMs: from.positionMs()}, overlap, change)
      const position = xfade.pos
      if (delayed) {
        state.pendingEntry = to.id
        state.cancelEntry = (resume = true) => {
          state.cancelEntry = null
          if (resume) restoreOutgoing(from, to, position, wasPlaying)
          else if (!wasPlaying) to.pause()
        }
      }
      const drop = tail => {
        state.cancelEntry = null
        state.pendingEntry = null
        if (audio) to.playDecoded(audio, cue)
        // The primed recording starts here. Include the actual gesture and the
        // fader opening; a deck already playing has no isolated new entry.
        const span = audio && ownsOutgoing(from, token) ? ctx.currentTime - effectStart + tail : null
        setXfadeTo(sideOf(to.id), tail)
        land(span, effectStart)
      }
      state.fireScale = fitScale(from, mode === "auto" ? state.hint : null, entryMs)
      if (state.fireScale < 0.95) emit("transitionSqueezed", {type, factor: state.fireScale})
      const overlap = run(from, to, {token, type, wasPlaying, drop})
      state.fireScale = 1
      if (!delayed) land(overlap)
    })
  }

  function ownsOutgoing(deck, token) {
    const outgoing = state.rescue
    return token === state.transitionToken && outgoing?.deck === deck.id && outgoing.load === deck.loadToken
  }

  function finishOutgoing(deck, token) {
    if (!ownsOutgoing(deck, token)) return
    if (deck.cueState === "preview") {
      // The old effect can end, but CUE now owns playback and pitch.
      deck.stopBrake?.()
      settleTransitionParams(deck)
      neutralizeIncoming(deck, "cut")
    } else {
      deck.pause()
      resetChain(deck)
    }
  }

  function handoff(from, to, event, overlap, change = ctx.currentTime) {
    state.activeDeck = to.id
    state.hint = null
    state.firedForTrack = null
    state.postponeMs = 0
    from._seekGuard = false
    to._seekGuard = false
    if (overlap != null && programMeter && roomAvailable) {
      const kind = event.type === "crossfade" ? "blend" : event.type
      const names = {from: from.title, fromDeck: from.id, into: to.title, toDeck: to.id}
      programMeter.read(kind, overlap, from.bpm * from.playbackRate,
        data => emit("programScore", {data, kind, mode: event.mode, names}), change)
    }
    emit("transitionStarted", {...event, toTrackId: to.trackId})
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
      caps.push(Math.max(durS - from.positionMs() / 1000 - 0.3, 0.4))
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
    to.controls.filter = to.controls.tone = 0
    if (["cut", "crossfade", "brake"].includes(type)) to.controls.level = 1
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

  function riseIncoming(to, riseEndS, wasPlaying = to.audible()) {
    to.controls.level = 1
    const now = ctx.currentTime
    if (!wasPlaying) to.gain.gain.setValueAtTime(0, now)
    to.gain.gain.linearRampToValueAtTime(1, now + riseEndS)
  }

  function cut(from, to, cue, event) {
    const audio = cue == null ? null : getDeckAudio(to.trackId)
    const decoded = audio != null && cue < audio.duration
    if (decoded) to.playDecoded(audio, cue)
    const overlap = decoded || cue == null ? CUT_OVERLAP_S : RAMP.nativeCutS
    const token = state.transitionToken, outgoingPlay = from.playToken
    const finish = () => {
      if (ownsOutgoing(from, token) && from.playToken === outgoingPlay && !from.cueState) from.pause()
    }
    setXfadeTo(sideOf(to.id), overlap, CUT_OVERLAP_S)
    state.rescue.finishCut = finish
    after(overlap, finish)
    handoff(from, to, {...event, atMs: from.positionMs()}, event.type === "cut" ? overlap : null)
  }

  function receiveEntry(from, to, toMs, started) {
    const inGap = Boolean(activeBreatherGap())
    const ready = cue => {
      state.cancelEntry = null
      state.pendingEntry = null
      state.lastFireAt = performance.now()
      started(cue)
    }
    if (to.audible()) return ready(null)

    // canplay and paused=false can both precede the first audible frame.
    // Keep the current record and its set pointer while the receiver starts.
    const cancel = () => {
      state.cancelEntry = null
      state.pendingEntry = null
      if (!inGap) {
        state.rescue = null
        state.firedForTrack = null
        state.waitingForNext = from.ended() && state.autoOn && state.hint != null
        from._seekGuard = true
      }
      if (to.playToken === playToken) to.pause()
    }
    state.cancelEntry = cancel
    const requested = to._cued ? null : toMs
    const cue = to.clampPosition(requested == null ? to.platterTime() : requested / 1000)
    to.play(requested, () => {
      if (state.cancelEntry !== cancel) return
      if (to.playToken !== playToken || to.el.paused || to.el.ended || to.el.error || deckHeld(from.id)) return cancel()
      to._cued = false
      ready(cue)
    }, () => {
      if (state.cancelEntry !== cancel) return
      cancel()
      emit("entryRefused", {deck: to.id})
      if (!inGap && from.ended()) {
        state.waitingForNext = false
        state.hint = null
        boundaryOnce(from.trackId, () => emit("trackEnded", {trackId: from.trackId}))
      }
    })
    const playToken = to.playToken
  }

  function fade(from, to, {token, wasPlaying}) {
    const now = ctx.currentTime
    const outS = dur(RAMP.fadeOutS)
    from.gain.gain.linearRampToValueAtTime(0, now + outS)

    const until = outS + dur(RAMP.fadeInS)
    riseIncoming(to, until, wasPlaying)
    setXfadeTo(sideOf(to.id), outS)

    after(outS + 0.1, () => finishOutgoing(from, token))
    return until
  }

  function crossfade(from, to, {token}) {
    // baseRate, not playbackRate: a transient jog bend (or mid-brake rate)
    // must never become the incoming track's permanent tempo.
    syncTempo(to, from)
    const xfS = dur(RAMP.crossfadeS)
    setXfadeTo(sideOf(to.id), xfS)

    after(xfS + 0.2, () => {
      if (ownsOutgoing(from, token) && from.cueState !== "preview") from.pause()
    })
    return xfS
  }

  // Echo-out, reworked to BREATHE. Timeline (all scaled by the length knob):
  //   1. the delay opens on a QUARTER note — spacious/dub, not a fast ping;
  //   2. the feedback BLOOMS (0.55→0.82) so the repeats sustain into a wash;
  //   3. the outgoing dry holds a beat, then DISSOLVES into that wash;
  //   4. the incoming stays silent, then EMERGES from under the tail (delayed
  //      rise) — the space between old-gone and new-arriving is what makes it
  //      feel fluid instead of a quick crossfade;
  //   5. the tail rings out as the feedback eases back down.
  function echo(from, to, {token, wasPlaying}) {
    const now = ctx.currentTime
    const bpm = from.bpm ? from.bpm * from.playbackRate : null
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
    if (!wasPlaying) {
      to.gain.gain.setValueAtTime(0, now)
      to.gain.gain.setValueAtTime(0, now + inStart)
    }
    to.gain.gain.linearRampToValueAtTime(1, now + inStart + inRise)

    // The crossfader follows the emergence — the wash stays on the outgoing
    // side until the new track has surfaced.
    setXfadeTo(sideOf(to.id), inStart + inRise * 0.8)

    const wetDown = dur(0.6), release = dur(0.7)
    after(total, () => {
      if (!ownsOutgoing(from, token)) return
      const end = ctx.currentTime
      from.settleGain(from.echoSend)
      from.echoSend.gain.linearRampToValueAtTime(0, end + wetDown)
      after(release, () => finishOutgoing(from, token))
    })

    const turnOff = () => {
      clearTimeout(lightTimer)
      from.stopEcho = null
      emit("echoState", {deck: from.id, on: false})
    }
    const lightTimer = after(total + release, turnOff)
    from.stopEcho = turnOff
    emit("echoState", {deck: from.id, on: true, delayMs: Math.round(delayS * 1000)})
    return total + release
  }

  // High-pass sweep: the outgoing track loses its body, thins into air while the
  // next one comes up underneath — the "filtro" every controller has.
  function filter(from, to, {token, wasPlaying}) {
    const now = ctx.currentTime
    const s = dur(RAMP.filterS)
    from.hpf.frequency.setValueAtTime(Math.max(from.hpf.frequency.value, 20), now)
    from.hpf.frequency.exponentialRampToValueAtTime(RAMP.filterTopHz, now + s)
    from.gain.gain.setValueAtTime(from.gain.gain.value, now + s - dur(0.6))
    from.gain.gain.linearRampToValueAtTime(0, now + s)

    riseIncoming(to, s * 0.5, wasPlaying)
    setXfadeTo(sideOf(to.id), s * 0.8)

    after(s + 0.2, () => finishOutgoing(from, token))
    return s + 0.2
  }

  // "Afunda": the mirror of the filter sweep — the outgoing track loses its
  // highs and sinks underwater while the next one surfaces on top.
  function lowpass(from, to, {token, wasPlaying}) {
    const now = ctx.currentTime
    const s = dur(RAMP.lowpassS)
    from.lpf.frequency.setValueAtTime(Math.min(from.lpf.frequency.value, 20_000), now)
    from.lpf.frequency.exponentialRampToValueAtTime(RAMP.lowpassFloorHz, now + s)
    from.gain.gain.setValueAtTime(from.gain.gain.value, now + s - dur(0.6))
    from.gain.gain.linearRampToValueAtTime(0, now + s)

    riseIncoming(to, s * 0.5, wasPlaying)
    setXfadeTo(sideOf(to.id), s * 0.8)

    after(s + 0.2, () => finishOutgoing(from, token))
    return s + 0.2
  }

  // Bass swap: the incoming track rides bodiless over the outgoing groove, then
  // the low end changes hands in one fast move — the forró/house handover.
  function bassSwap(from, to, {token, wasPlaying}) {
    const now = ctx.currentTime
    syncTempo(to, from)

    // Bodiless entry: instant when the deck is idle, a fast dip when the DJ
    // already has it playing (never a hard jump on something audible).
    const overlapS = dur(RAMP.bassOverlapS)
    const moveS = dur(RAMP.bassSwapMoveS)
    if (wasPlaying) to.bass.gain.linearRampToValueAtTime(RAMP.bassCutDb, now + 0.25)
    else to.bass.gain.setValueAtTime(RAMP.bassCutDb, now)
    riseIncoming(to, dur(1.0), wasPlaying)
    setXfadeTo(0.5, dur(1.0))

    const swapAt = now + overlapS
    from.bass.gain.setValueAtTime(0, swapAt)
    from.bass.gain.linearRampToValueAtTime(RAMP.bassCutDb, swapAt + moveS)
    to.bass.gain.setValueAtTime(RAMP.bassCutDb, swapAt)
    to.bass.gain.linearRampToValueAtTime(0, swapAt + moveS)

    const glide = dur(2), until = overlapS + dur(2.4)
    after(overlapS, () => {
      if (token !== state.transitionToken) return
      setXfadeTo(sideOf(to.id), glide)
    })
    after(until, () => {
      if (token !== state.transitionToken) return
      finishOutgoing(from, token)
      // The incoming deck keeps playing — only make sure its shelf sits flat.
      // (No resetChain: that would snap the SYNCed tempo back audibly.)
      to.settleParam(to.bass.gain)
      to.bass.gain.setValueAtTime(0, ctx.currentTime)
    })
    return until
  }

  // Vinyl brake: the platter winds down (pitch drops with it), then the next
  // track slams in. playbackRate is not an AudioParam, so the wind-down is a
  // JS interval — the final pause is timeout-guarded and lands regardless.
  function brake(from, to, {token, drop}) {
    from.useMedia()
    const el = from.el
    const brakeS = dur(RAMP.brakeS)
    cancelBend(from.id) // the wind-down owns playbackRate — no bend ping-pong
    el.preservesPitch = false
    const startRate = el.playbackRate
    const t0 = performance.now()
    const iv = setInterval(() => {
      const p = Math.min((performance.now() - t0) / (brakeS * 1000), 1)
      el.playbackRate = Math.max(startRate * (1 - p) * (1 - p), 0.07)
      if (p >= 1) clearInterval(iv)
    }, 40)
    from.stopBrake = () => {
      clearInterval(iv)
      from.stopBrake = null
      el.preservesPitch = !from.vinylMode
      applyRate(from)
    }

    after(brakeS * 0.65, () => {
      if (token !== state.transitionToken) return
      drop(0.3)
    })
    after(brakeS + 0.05, () => finishOutgoing(from, token))
  }

  // Scratch DROP transitions: scratch the OUTGOING track (real worklet audio)
  // then slam the incoming in at its cued point. Each kind is a spec — a base
  // run length in OUTGOING BEATS (fired on the count, the drop lands on a
  // count), a read-head path, and an optional crossfader gate (in transform/
  // chirp cuts the FADER is the instrument). All paths run at beat-locked
  // rates, so the scratch pitch never changes with the length knob — the knob
  // only buys more beats of scratch.
  const SCRATCH_DROPS = {
    // baby-scratch flourish: two strokes per beat, then the hard drop.
    scratch_cut: {
      beats: 2,
      pos: (p, run) =>
        run.center + RAMP.rasgoDepthS * sr * Math.sin(2 * Math.PI * 2 * run.beats * p),
    },
    // reverse spin-back: a steady ~2x rewind the WHOLE run (no silent
    // accelerate-from-zero start, no aliased over-fast blur), capped at the
    // track head so the platter never pins silent at 0.
    spinback: {
      beats: 2,
      pos: (p, run) => run.center - run.backSamples * p,
    },
    // chirp: one full stroke per beat with the dry path closing on every
    // turnaround — the crisp "bird" cuts (open mid-stroke, shut at the flips,
    // where the head reverses and would smear). Each cut rings in the delay.
    chirp: {
      beats: 2,
      echoTail: true,
      pos: (p, run) =>
        run.center + RAMP.chirpDepthS * sr * Math.sin(2 * Math.PI * run.beats * p),
      gate: (p, run) => {
        const ph = (p * run.beats * 2) % 1
        return ph > 0.12 && ph < 0.88 ? 1 : 0
      },
    },
    // transform: the record crawls forward at half speed while the dry path
    // picota in 1/8 notes — the classic rhythmic chop, echoes filling the gaps.
    transform: {
      beats: 4,
      echoTail: true,
      pos: (p, run) => run.center + 0.5 * run.runS * p * sr,
      gate: (p, run) => ((p * run.beats * 2) % 1 < RAMP.transformDuty ? 1 : 0),
    },
    // scribble: fast tiny wiggles that GROW into the drop — a tension riser.
    scribble: {
      beats: 2,
      pos: (p, run) =>
        run.center + (0.025 + 0.045 * p) * sr * Math.sin(2 * Math.PI * 6 * run.beats * p),
    },
  }

  // Falls back to a plain cut when the outgoing has no decoded PCM/worklet.
  function scratchDrop(from, to, {token, type: kind, wasPlaying, drop}) {
    const spec = SCRATCH_DROPS[kind]
    const s = scratch[from.id]
    const center = from.el.currentTime * sr
    from.el.pause()
    s.active = true
    s.token = from.loadToken
    scratchScrub(from.id, center)
    setXfadeTo(sideOf(from.id), 0.04) // hear only the scratch of the outgoing

    // Whole beats, knob- and squeeze-scaled: beatMs tracks the live rate and
    // falls back to 500ms when the BPM is unknown.
    const beats = Math.min(
      Math.max(Math.round(spec.beats * state.transitionScale * state.fireScale), 1),
      16
    )
    const runS = (beats * beatMs(from)) / (1000 * from.playbackRate)
    const run = {center, beats, runS, backSamples: Math.min(2 * runS * sr, center)}
    const t0 = performance.now()

    // Chop kinds ring: the delay is tuned to the outgoing's quarter note and
    // the send opens for the run. The gate chops the DRY path only — the echo
    // keeps sounding through the still-open channel, and the crossfader stays
    // where the DJ left it (the fader is HIS instrument, never the gate's).
    if (spec.echoTail) {
      const now = ctx.currentTime
      from.delay.delayTime.setTargetAtTime(Math.min(60 / (from.bpm || 120), 1.2), now, 0.03)
      from.settleGain(from.echoSend)
      from.echoSend.gain.setValueAtTime(RAMP.dropEchoSend, now)
    }

    const stop = () => {
      clearInterval(iv)
      state.stopScratchDrop = null
      if (s.active) {
        s.active = false
        if (s.node) s.node.port.postMessage({type: "stop"})
      }
    }

    const finish = () => {
      stop()
      from.pause()
      riseIncoming(to, 0.03, wasPlaying)
      // Echo kinds let the last chop's tail bleed under the incoming for a
      // breath; the dry kinds slam. Either way the incoming is already at full.
      drop(spec.echoTail ? RAMP.dropTailFadeS : 0.06)
      after(0.2, () => ownsOutgoing(from, token) && resetChain(from))
      // The outgoing deck is free the moment the drop lands — announce it, so
      // a hint parked during the run re-arms EVENT-driven. drop() pauses an
      // already-paused element (no `pause` event fires), and the rAF retry
      // freezes in background tabs: audio flow must never ride on rAF.
      emit("deckFreed", {deck: from.id})
    }

    const iv = setInterval(() => {
      if (token !== state.transitionToken) return
      if (s.token !== from.loadToken) {
        // Something loaded over the outgoing deck mid-run (the load's
        // resetScratch already silenced the worklet). The scratch is gone, but
        // the HANDOFF must still land: die without starting the incoming and
        // the room gets dead air with a stuck crossfader. Never touch `from`
        // here — its new owner drives it now.
        clearInterval(iv)
        state.stopScratchDrop = null
        riseIncoming(to, 0.03, wasPlaying)
        drop(0.06)
        return
      }
      const elapsed = (performance.now() - t0) / 1000
      const p = Math.min(elapsed / runS, 1)
      scratchScrub(from.id, spec.pos(p, run))
      if (spec.gate) {
        // Gate from a RETARDED clock (same rule as tickAutoScratch): the heard
        // audio lags the commanded head by ~20ms of smoothing, so the chops
        // must lag too or they land between the strokes the ear hears. The
        // gate drives the DRY gain — resetChain restores it to 1 afterwards.
        const pGate = Math.min(Math.max((elapsed - RAMP.dropGateRetardS) / runS, 0), 1)
        from.dry.gain.setTargetAtTime(spec.gate(pGate, run), ctx.currentTime, 0.004)
      }
      if (p >= 1) finish()
    }, 16)
    state.stopScratchDrop = stop
  }

  // Respiro do salão: a música que sai toca até o FIM DE VERDADE — o eco
  // estica a última frase, a pista fica em silêncio para agradecer e trocar
  // de par, e só então a próxima entra. A regra do forró, não do rádio.
  function breatherOut(from, to, transition, event, token) {
    const style = transition["type"] || "echo"
    const now = ctx.currentTime

    const echoPhrase = style === "echo" && !from.ended()
    if (echoPhrase) {
      // Even perfectly in-phase repeats sum to wet / (1 - feedback).
      // Reserve that share of the dry signal before the pre-fader and room buses.
      const mix = RAMP.breatherEchoMix, feedback = RAMP.breatherEchoFeedback
      from.delay.delayTime.setTargetAtTime(Math.min(60 / (from.bpm || 120), 1.2), now, 0.03)
      from.settleGain(from.feedback)
      from.feedback.gain.setValueAtTime(feedback, now)
      from.settleGain(from.dry)
      from.dry.gain.linearRampToValueAtTime(1 - mix, now + 0.5)
      from.settleGain(from.echoSend)
      from.echoSend.gain.linearRampToValueAtTime(mix * (1 - feedback), now + 0.5)
    } else if (style === "fade") {
      const restS = Math.max((from.el.duration || 0) - from.positionMs() / 1000, 0.5)
      from.gain.gain.linearRampToValueAtTime(0, now + restS)
    }
    // qualquer outro estilo: a música simplesmente acaba, seca — também é lindo

    // Keep the outgoing track as the set pointer through its tail and the gap.
    // A set edit may replace the receiving track while the room is silent.
    const gap = {
      fromTrackId: event.fromTrackId,
      durationMs: Math.max(transition.gap_ms ?? 5000, 0),
      deadline: null,
      timer: null,
      mutedSide: null,
      attemptedLoad: null,
      beginGap() {
        if (token !== state.transitionToken || gap.deadline !== null) return
        clearTimeout(gap.timer)
        const ringing = echoPhrase || from.echoSend.gain.value >= 0.0001 || from.echoTailUntil > ctx.currentTime
        const release = ringing && ownsOutgoing(from, token)
        if (release) {
          from.releaseBreatherEcho()
          if (state.faderVersion === faderVersion) {
            gap.mutedSide = from.id
            const out = xfade[from.id].gain
            from.settleParam(out)
            out.linearRampToValueAtTime(0, ctx.currentTime + RAMP.echoReleaseMs / 1000)
          }
        }
        const wait = gap.durationMs + (release && gap.durationMs > 0 ? RAMP.echoReleaseMs : 0)
        gap.deadline = performance.now() + wait
        gap.timer = setTimeout(gap.start, wait)
      },
      start(retry = false) {
        if (!roomAvailable || token !== state.transitionToken || state.breatherGap !== gap || state.cancelEntry) return
        gap.deadline = performance.now()
        clearTimeout(gap.timer)
        if (!hintFireable(state.hint) || (!retry && gap.attemptedLoad === to.loadToken)) return
        // canplay can repeat after a refusal. Only another load or an explicit
        // retry may release the same silence, even if the old record ended.
        gap.attemptedLoad = to.loadToken
        state.pendingEntry = to.id
        receiveEntry(from, to, state.hint.transition?.to_ms ?? 0, cue => {
          state.breatherGap = null
          if (ownsOutgoing(from, token)) resetChain(from)
          riseIncoming(to, 0.4, cue === null)
          setXfadeTo(sideOf(to.id), 0.3)
          handoff(from, to, event)
          emit("deckFreed", {deck: from.id})
        })
      },
    }
    state.breatherGap = gap

    if (from.ended()) {
      gap.beginGap()
    } else if (event.mode === "manual" && from.el.duration - from.positionMs() / 1000 > RAMP.breatherMaxTailS + 1) {
      // An explicit early fire shortens the current phrase. AUTO always waits
      // for the playing source to end, even if its tempo changes.
      gap.timer = setTimeout(() => {
        from.dry.gain.setTargetAtTime(0, ctx.currentTime, 0.08)
        gap.timer = setTimeout(() => {
          from.pause()
          gap.beginGap()
        }, 350)
      }, RAMP.breatherMaxTailS * 1000)
    }
  }

  function activeBreatherGap() {
    const gap = state.breatherGap
    return gap && gap.deadline !== null ? gap : null
  }

  function interruptTransition({keepPassage = false, resumeOutgoing = true, startingPassage = false} = {}) {
    programMeter?.cancel()
    roomEnd = null
    state.cancelEntry?.(resumeOutgoing)
    if (roomReading?.arrived) cancelRoomReading()
    if (keepPassage) passage.mixChanged()
    else if (!startingPassage) passage.disarm()
    state.stopScratchDrop?.()
    for (const deck of Object.values(decks)) {
      deck.stopBrake?.()
      deck.stopEcho?.()
    }
    const gap = state.breatherGap
    if (gap) {
      clearTimeout(gap.timer)
      if (gap.mutedSide && state.faderVersion === faderVersion) {
        takeOver(xfade[gap.mutedSide].gain, xfadeGains(xfade.pos)[gap.mutedSide], RAMP.manualFaderTau)
      }
    }
    state.breatherGap = null
    state.waitingForNext = false
    state.rescue = null
    state.pendingEntry = null
    return ++state.transitionToken
  }

  // Transition cleanup resets effects only: the DJ may have armed a new loop since fire.
  function resetDeck(deck) {
    passage.disarm()
    rehearsal.stop()
    clearLoop(deck)
    resetChain(deck)
  }

  // Return a silenced deck to a neutral chain: unity gain, open filter, flat
  // shelf, no echo, natural tempo. Only ever called on non-audible decks.
  function resetChain(deck) {
    deck.controls = {...neutralMix}
    const now = ctx.currentTime
    deck.settleGain(deck.gain)
    deck.gain.gain.setValueAtTime(1, now)
    deck.settleGain(deck.dry)
    deck.dry.gain.setValueAtTime(1, now)
    releaseEchoTail(deck, now)
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
    deck.vinylMode = false
    deck.stopEcho?.()
    deck.stopBrake?.()
    cancelBend(deck.id)
    deck.resetRate()
    emit("fxReset", {deck: deck.id})
  }

  // ── crossfader (automated glides + manual takeover) ─────────────────────────

  let faderVersion = 0
  function setXfadeTo(target, seconds, minimum = 0.05) {
    if (state.faderVersion !== faderVersion) return
    const now = ctx.currentTime
    for (const side of ["a", "b"]) {
      const node = xfade[side]
      const current = node.gain.value
      node.gain.cancelScheduledValues(now)
      node.gain.setValueAtTime(current, now)
      node.gain.linearRampToValueAtTime(equalPower(target)[side], now + Math.max(seconds, minimum))
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

  // Either adjacent MIDI code can be reported by a resting fader. Keep the
  // last applied position so a slow move accumulates past one hardware step.
  function reservedMidiJitter(previous, next, step) {
    return step > 0 && passage.current() && Math.abs(next - previous) <= step + Number.EPSILON
  }

  // Manual gesture (UI or MIDI): cancel any automated glide and take over.
  function setCrossfader(pos, midiStep = 0) {
    const next = Math.min(Math.max(pos, 0), 1)
    if (reservedMidiJitter(xfade.pos, next, midiStep)) return
    if (next !== xfade.pos) passage.mixChanged()
    else if (passage.current()?.phase === "starting") return // keep the pending input muted
    if (state.cancelEntry) {
      if (Math.abs(next - xfade.pos) <= midiStep + Number.EPSILON) return
      cancelTransition()
    }
    faderVersion++
    xfadeGlide++
    cancelAnimationFrame(xfadeAnim)
    xfade.pos = next
    const g2 = xfadeGains(xfade.pos)
    const saved = passage.current()
    if (saved?.kind === "blend" && saved.plan.blendCurve && g2[saved.pair.from] < 0.999) passage.mixChanged()
    for (const side of ["a", "b"]) {
      takeOver(xfade[side].gain, g2[side], RAMP.manualFaderTau)
    }
    emit("xfadePos", {pos: xfade.pos, automated: false})
  }

  // Flip the crossfader gain map (smooth blend ↔ sharp scratch cut) and re-map
  // the CURRENT position through it so the change is heard immediately. Only the
  // gains change — xfade.pos (and thus on-air detection) is untouched.
  function setCrossfaderCurve(mode) {
    const next = mode === "sharp" ? "sharp" : "smooth"
    if (xfade.curve !== next) passage.mixChanged()
    xfade.curve = next
    setCrossfader(xfade.pos)
    emit("xfadeCurve", {curve: xfade.curve})
  }

  function setDeckLevel(deckId, value) {
    const deck = decks[deckId]
    const level = Math.min(Math.max(value, 0), 1)
    if (deck.controls.level !== level) passage.mixChanged()
    deck.controls.level = level
    takeOver(deck.gain.gain, level, RAMP.manualFaderTau)
  }

  function setMasterLevel(value) {
    if (value > 1 && passage.current()?.plan.blendCurve) passage.mixChanged()
    takeOver(master.gain, Math.min(Math.max(value, 0), 1.2), RAMP.manualFaderTau)
  }

  // ── jog wheel: top touch = vinyl hold/scratch; edge turn = pitch bend ───────

  const jog = {
    a: {held: false, resumeToken: null, bend: 0, decay: null},
    b: {held: false, resumeToken: null, bend: 0, decay: null},
  }

  // ── real scratch: an AudioWorklet per deck reads the mono PCM back and forth
  // at the platter's velocity (reverse included) into the deck's own chain ─────
  const sr = ctx.sampleRate
  const scratch = {
    a: {node: null, loaded: null, active: false, pos: 0, token: 0, rate: 3},
    b: {node: null, loaded: null, active: false, pos: 0, token: 0, rate: 3},
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
    decks[deckId].useMedia()
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
  function scratchScrub(deckId, posSamples, inputTime) {
    const s = scratch[deckId]
    // Clamp inside the track: scratching past the end must never let the release
    // seek fire `ended` and advance the set.
    const maxPos = (decks[deckId].el.duration || 0) * sr
    s.pos = Math.min(Math.max(posSamples, 0), maxPos > 0 ? maxPos : posSamples)
    if (s.node) s.node.port.postMessage({type: "scrub", position: s.pos,
      t: Number.isFinite(inputTime) ? inputTime : performance.now()})
  }

  // Stop scratching: hand the position back to the media element and (maybe) run.
  function scratchEnd(deckId, resume) {
    const s = scratch[deckId]
    const deck = decks[deckId]
    if (!s.active) return
    s.active = false
    if (s.node) s.node.port.postMessage({type: "stop"})
    if (s.token === deck.loadToken && deck.trackId != null) {
      placePlatter(deck, s.pos / sr)
      if (resume) deck.play()
    }
  }

  function applyRate(deck, nudge = false) {
    const hand = jog[deck.id]
    const rate = Math.max(deck.baseRate * (1 + hand.bend), 0.0625)
    if (!nudge || !hand.bend) hand.rateSample = null
    if (nudge && deck.entry?.nudge(rate)) return
    if (deck.playbackRate === rate) return

    // Some native decoders restart on each new rate. The first nudge is
    // immediate. Coalesce subsequent turns only while that decoder falls
    // behind; a healthy media clock can follow every movement of the hand.
    const last = hand.rateSample
    if (last?.token === deck.playToken && deck.el.currentTime >= last.position) {
      const elapsed = ctx.currentTime - last.clock
      const played = deck.el.currentTime - last.position
      if (elapsed <= 0 || played < elapsed * last.rate * 0.9) return
    }
    deck.useMedia()
    deck.el.playbackRate = rate
    if (nudge && hand.bend) {
      hand.rateSample = {clock: ctx.currentTime, position: deck.el.currentTime, rate, token: deck.playToken}
    }
  }

  function cancelBend(deckId) {
    const j = jog[deckId]
    j.rateSample = null
    j.bend = 0
    if (j.decay) {
      clearInterval(j.decay)
      j.decay = null
    }
  }

  function syncTempo(deck, reference) {
    if (!(deck.bpm > 0 && reference.bpm > 0)) return false
    deck.stopBrake?.()
    cancelBend(deck.id)
    return deck.syncTo(reference.bpm * reference.baseRate)
  }

  // Keep the latest hand position through buffering, PLAY and the next AUTO fire.
  function placePlatter(deck, seconds) {
    const targetMs = deck.clampPosition(seconds) * 1000
    if (Math.abs(deck.platterTime() * 1000 - targetMs) > 1) {
      if (roomEnd?.deck === deck) roomEnd = null
      if (state.pendingEntry === deck.id) state.cancelEntry?.()
      passage.mixChanged()
    }
    passage.seek(deck, targetMs)
    if (deck.loop.on && (targetMs < deck.loop.startMs || targetMs >= deck.loop.endMs)) clearLoop(deck)
    deck._cued = true
    deck._pendingSeekMs = targetMs
    if (deck._seekQueued) return
    deck._seekQueued = true
    const seek = () => {
      deck._seekQueued = false
      if (deck._pendingSeekMs == null) return
      if (deck.id === state.activeDeck) deck._seekGuard = true
      deck.seek(deck.clampPosition(deck._pendingSeekMs / 1000))
      deck._pendingSeekMs = null
    }
    if (deck.entry) seek()
    else deck.whenReady(seek)
  }

  function platterWillResume(deck) {
    return jog[deck.id].resumeToken === deck.playToken
  }

  // Touch (platter top on hardware, or a mouse-drag on the on-screen wheel) grabs
  // the record: playback becomes an AUDIBLE scratch driven by the hand. Without
  // the decoded PCM yet, it degrades to the old silent scrub.
  function jogTouch(deckId, held, inputTime) {
    const deck = decks[deckId]
    const j = jog[deckId]
    if (held === j.held) return
    const s = scratch[deckId]
    // A scratch-drop transition owns the deck's worklet (active with no
    // auto-scratch): refuse the grab — the jog would fight its command stream
    // and its release would steal the transition's stop.
    if (held && (state.pendingEntry === deckId || deck.cueState || deck.stopBrake || (s.active && !autoScratch[deckId]))) return
    j.held = held
    if (deck.trackId == null) {
      if (!held) emit("deckFreed", {deck: deckId})
      return
    }
    if (held) {
      passage.mixChanged()
      cancelBend(deckId)
      applyRate(deck)
      stopAutoScratch(deckId)
      if (deck.audible() || deck.playPending) {
        deck.pause()
        j.resumeToken = deck.playToken
      }
      if (scratchArm(deckId)) {
        s.active = true
        s.token = deck.loadToken
        scratchScrub(deckId, deck.platterTime() * sr, inputTime)
        // The crossfader stays the DJ's — a jog scratch NEVER moves it. Lucas
        // works the fader by hand to open/close the scratch (transform/chop
        // cuts), so scratching a deck the crossfader has cut is silent until he
        // brings the fader over. (This used to auto-slide to center 0.5 for
        // audibility, which fought the hand and parked the fader in the middle.)
      }
    } else {
      const resume = platterWillResume(deck)
      j.resumeToken = null
      if (s.active) {
        scratchEnd(deckId, resume)
      } else if (resume) {
        deck.play()
      }
      releaseDeck(deck)
    }
  }

  function jogTurn(deckId, delta, inputTime) {
    const deck = decks[deckId]
    if (!delta || deck.trackId == null || deck.cueState) return
    if (deck.stopBrake) return // the brake owns playbackRate until it finishes
    const j = jog[deckId]
    const s = scratch[deckId]
    if (s.active && j.held) {
      // Real scratch (and only when the JOG owns the session — a scratch-drop
      // transition or an auto-scratch must not be fought over the worklet):
      // move the record; the worklet turns the position stream into velocity.
      deck._cued = true
      deck._pendingSeekMs = null
      scratchScrub(deckId, s.pos + delta * RAMP.jogTickS * sr, inputTime)
      return
    }
    if (s.active) return // a scratch transition or pad owns the playhead
    if (j.held || !deck.audible()) {
      // Fallback (no PCM/worklet) or fine seek while paused: nudge the position.
      const step = j.held ? RAMP.jogTickS : RAMP.jogSeekStepS
      placePlatter(deck, deck.platterTime() + delta * step)
      return
    }
    // Edge nudge while playing: bend the tempo, then decay back to base —
    // never a position jump (that skip was audible).
    const bend = Math.min(Math.max(j.bend + delta * RAMP.bendStep, -RAMP.bendMax), RAMP.bendMax)
    if (bend !== j.bend) passage.mixChanged()
    j.bend = bend
    applyRate(deck, true)
    if (!j.decay) {
      j.decay = setInterval(() => {
        j.bend *= RAMP.bendDecay
        if (Math.abs(j.bend) < 0.003) {
          j.bend = 0
          clearInterval(j.decay)
          j.decay = null
        }
        applyRate(deck, true)
      }, 60)
    }
  }

  // ── auto-scratch: hold a pad → the idle deck scratches a chosen pattern; the
  // speed bar drives the tempo; transform/chop cut the real crossfader in time ─
  function startAutoScratch(deckId, pattern) {
    const deck = decks[deckId]
    if (deck.trackId == null) return {ok: false, reason: "empty"}
    if (state.pendingEntry === deckId) return {ok: false, reason: "busy"}
    if (deck.cueState || jog[deckId].held) return {ok: false, reason: "held"}
    stopAutoScratch(deckId)
    // Still active after the stop = a scratch-drop transition owns the deck
    // (mid-run its outgoing deck is paused, so the pad's "idle deck" pick can
    // land here). Refuse — arming would kill its audio and split its fader.
    if (scratch[deckId].active) return {ok: false, reason: "busy"}
    if (!scratchArm(deckId)) return {ok: false, reason: "not_ready"}
    const s = scratch[deckId]
    const center = deck.platterTime() * sr
    const a = {
      pattern,
      rate: s.rate,
      phase: 0,
      center,
      lastT: ctx.currentTime,
      savedXfade: xfade.pos,
      faderVersion,
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
    if (a.faderVersion === faderVersion) scratchCrossfade(away + (toScratch - away) * gate)
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
    if (a.faderVersion === faderVersion) setCrossfader(a.savedXfade)
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
      if (restoreXfade && a.faderVersion === faderVersion) setCrossfader(a.savedXfade)
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
      if (deck.audible() && !deck.seeking()) wrapLoop(deck)
    }, 20)
  }

  function wrapLoop(deck) {
    const {on, startMs, endMs} = deck.loop
    const pos = deck.positionMs()
    if (!on || endMs <= startMs || pos < endMs) return false
    // A late timer may have crossed more than one beat. Carry the overrun
    // into this pass so each repetition stays in phase with the other deck.
    const positionAfter = seconds => (startMs + (pos - endMs + seconds * 1000) % (endMs - startMs)) / 1000
    deck.seek(positionAfter(0), positionAfter)
    return true
  }

  function beatMs(deck) {
    return 60_000 / (deck.bpm || 120) // source time, like currentTime and loop points
  }

  function loopFits(deck, endMs) {
    return !Number.isFinite(deck.el.duration) || endMs <= deck.el.duration * 1000
  }

  function restartingLoop(deck) {
    return deck.loop.on && deck.wantsPlayback && deck.ended()
  }

  function beatLoop(deckId, beats) {
    const deck = decks[deckId]
    if (deck.trackId == null) return
    if (deck.loop.on && deck.loop.beats === beats) {
      clearLoop(deck)
      return
    }
    const start = Math.round((scratchPosSec(deckId) ?? deck.platterTime()) * 1000)
    const endMs = start + beats * beatMs(deck)
    if (!loopFits(deck, endMs)) {
      emit("loopTooLong", {deck: deckId, beats})
      return
    }
    deck._cued = true
    deck.loop = {on: true, startMs: start, endMs, beats}
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
      const endMs = Math.max(deck.positionMs(), loop.startMs + 30)
      if (!loopFits(deck, endMs)) return
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

  function deckHeld(id) {
    return Boolean(state.pendingEntry === id || decks[id].cueState || jog[id].held || scratch[id].active)
  }

  function releaseDeck(deck) {
    if (!deckBusy(deck.id)) emit("deckFreed", {deck: deck.id})
    retryReadyHint(deck)
  }

  function deckBusy(id) {
    const deck = decks[id]
    return deck.audible() || deck.playPending || restartingLoop(deck) || deckHeld(id)
  }

  // Panic rescue: undo a transition that just fired — the outgoing deck comes
  // back on air with a neutral chain, the incoming is pulled off, and the
  // server hears transitionCancelled to rewind the set pointer.
  function cancelTransition({keepFader = false} = {}) {
    if (!roomAvailable) return {ok: false, reason: "room_unavailable"}
    if (state.cancelEntry) {
      const outgoing = decks[state.rescue.deck]
      state.cancelEntry()
      if (activeBreatherGap()) return {ok: true} // the old phrase ended on purpose
      state.waitingForNext = false
      if (outgoing.ended()) outgoing.play()
      return {ok: true} // the server still has the outgoing record
    }
    if (!state.lastFireAt || performance.now() - state.lastFireAt > 30_000) {
      return {ok: false, reason: "nothing"}
    }
    const rescue = state.rescue
    if (!rescue) return {ok: false, reason: "nothing"}
    const rescued = decks[rescue.deck]
    const dropped = decks[otherId(rescue.deck)]
    if (!rescued.trackId || rescued.loadToken !== rescue.load) return {ok: false, reason: "nothing"}
    restoreOutgoing(rescued, dropped, keepFader ? xfade.pos : sideOf(rescued.id), false)
    emit("transitionCancelled", {trackId: rescued.trackId, deck: rescued.id})
    return {ok: true}
  }

  function restoreOutgoing(rescued, dropped, position, keepIncoming) {
    const head = state.stopScratchDrop ? scratchPosSec(rescued.id) : null
    const recording = head === null ? null : getDeckAudio(rescued.trackId)
    interruptTransition() // cancels every scheduled pause/ramp of the fired run
    settleTransitionParams(rescued)
    settleTransitionParams(dropped)
    const now = ctx.currentTime
    rescued.gain.gain.linearRampToValueAtTime(1, now + 0.25)
    rescued.dry.gain.linearRampToValueAtTime(1, now + (recording ? 0.02 : 0.25))
    rescued.bass.gain.linearRampToValueAtTime(0, now + 0.25)
    rescued.echoSend.gain.linearRampToValueAtTime(0, now + 0.25)
    rescued.hpf.frequency.linearRampToValueAtTime(10, now + 0.2)
    rescued.lpf.frequency.linearRampToValueAtTime(20_000, now + 0.2)
    // A brake mid-flight left the rate collapsed — restore the deck's own.
    rescued.el.preservesPitch = !rescued.vinylMode
    rescued.el.playbackRate = rescued.baseRate
    if (rescued.el.paused) {
      if (recording && head < recording.duration) {
        rescued.play(head * 1000)
        rescued.playDecoded(recording, head)
      } else {
        rescued.play()
      }
    }
    if (!keepIncoming) {
      dropped.pause()
      dropped.bass.gain.setValueAtTime(0, now)
    }
    setCrossfader(position)
    rescued._seekGuard = true
    state.activeDeck = rescued.id
    state.firedForTrack = null
    state.postponeMs = 0
    state.lastFireAt = null
    emit("fxReset", {deck: rescued.id})
  }

  function pauseTransport(deck) {
    state.cancelEntry?.()
    passage.mixChanged()
    const other = decks[otherId(deck.id)]
    if (roomAvailable && state.activeDeck === deck.id && other.audible() && !other.cueState) {
      // Restore the mix to the outgoing deck, respecting a manual fader takeover.
      const keepFader = state.faderVersion !== faderVersion
      if (state.rescue?.deck === other.id && cancelTransition({keepFader}).ok) return
      state.activeDeck = other.id
      state.hint = null
      state.firedForTrack = null
      emit("deckStarted", {deck: other.id, trackId: other.trackId})
    } else if (state.activeDeck === deck.id && state.breatherGap) {
      interruptTransition()
      settleTransitionParams(deck)
      neutralizeIncoming(deck, "cut")
      state.firedForTrack = null
    }
    deck.pause()
  }

  watchOutgoing(decks.a)
  watchOutgoing(decks.b)
  ctx.addEventListener("sinkchange", wireOutputs, {signal: mediaEvents.signal})
  globalThis.navigator?.mediaDevices?.addEventListener("devicechange", wireOutputs, {signal: mediaEvents.signal})
  wireOutputs()

  return {
    ctx,
    decks,

    resume() {
      if (roomAvailable && ctx.state === "suspended") ctx.resume()
    },

    loadDeck(deckId, track, {autoplay = false, atMs = 0} = {}) {
      if (autoplay && !roomAvailable) return false
      const deck = decks[deckId]
      if (state.pendingEntry === deckId) state.cancelEntry?.()
      // Only a silent breather frees a deck that still owns a live set boundary.
      if (!autoplay && sessionDeck() === deckId && !activeBreatherGap()) return false
      if (deckBusy(deckId) || !deck.load(track, atMs)) return false
      // A fresh load is a fresh instrument — loop off (chips/região avisados),
      // FX neutros, tempo natural. Vale para preload manual também.
      resetDeck(deck)
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
        interruptTransition()
        this.resume()
        setCrossfader(sideOf(deckId))
        deck.play()
        state.activeDeck = deckId
        if (state.hint?.deck === deckId) state.hint = null
        state.firedForTrack = null
        state.postponeMs = 0
        emit("deckStarted", {deck: deckId, trackId: track.id})
      } else {
        retryReadyHint(deck)
      }
      return true
    },

    // The revocable lookahead: (re)load the hint's track on the idle deck. A
    // fresh hint for the same boundary simply replaces the preload — this is
    // how a live set edit swaps the next track before the transition fires.
    armHint(hint) {
      const idle = state.activeDeck === "a" ? "b" : "a"
      const deck = decks[idle]
      if (state.cancelEntry && deck.trackId === hint.track.id) {
        state.hint = {...hint, deck: idle}
        return idle // a repeated lookahead cannot revoke a start already requested
      }
      state.cancelEntry?.()
      // A jog-held, auto-scratching or scratch-DROP-owned deck is IN THE DJ'S
      // HANDS — loading over it would make the release play a different track
      // than the one scratching. The scratch[].active case is the palette
      // Rasgo/Rebobina killer: right after those fire, the server's next hint
      // arrives while the outgoing deck is still mid-scratch (it looks idle —
      // paused, not audible); loading over it aborted the deferred drop and
      // the incoming deck never started. Dead air, stuck crossfader, frozen
      // scratch visuals. The hint parks as pending and re-arms after the drop.
      if (deckBusy(idle)) return false
      const atMs = hint.transition?.to_ms ?? 0
      if (deck.trackId !== hint.track.id || deck.el.error || deck.el.ended) {
        resetDeck(deck)
        deck.load(hint.track, atMs)
      } else if (!deck._cued) {
        deck._pendingSeekMs = atMs
      }
      state.hint = {...hint, deck: idle}
      retryReadyHint(deck)
      return idle
    },

    clearHint() {
      state.hint = null
      if (state.cancelEntry && !state.breatherGap) {
        const from = decks[state.activeDeck]
        state.cancelEntry()
        if (from.ended()) handleEnded(from)
        return
      }
      if (state.breatherGap || state.waitingForNext) {
        const from = decks[state.activeDeck]
        const gap = state.breatherGap
        const originalLoaded = !gap || ownsOutgoing(from, state.transitionToken)
        const final = !originalLoaded || !from.audible()
        interruptTransition()
        if (originalLoaded) {
          settleTransitionParams(from)
          neutralizeIncoming(from, "cut")
        }
        state.firedForTrack = null
        if (final) handleEnded(from, gap?.fromTrackId ?? from.trackId)
      }
    },

    setAuto(on) {
      state.autoOn = on
      if (!on && state.waitingForNext) {
        state.waitingForNext = false
        handleEnded(decks[state.activeDeck])
      }
    },

    // "No ar" for the UI and for manual fires: crossfader side wins when both
    // decks are running.
    rehearsal,
    deckMix,
    canRecallBass: pair => bassReady(decks[pair.from], decks[pair.to]),
    canMeasureBlend: (pair, mix) => canMeasureBlend(decks[pair.from], decks[pair.to], mix),
    armPassage: (pair, plan, kind, reference) => passage.arm(pair, plan, kind, reference, rehearsal.splices(plan, kind)),
    confirmPassage: passage.confirm,
    setRoomOutputAvailable(available) {
      if (roomAvailable === available) return
      roomAvailable = available
      if (!available) {
        // Unplugging can leave a running browser rendering into its default device.
        deviceFeed.disconnect(ctx.destination)
        const gap = activeBreatherGap()
        if (gap && state.cancelEntry) gap.attemptedLoad = null
        state.cancelEntry?.()
        cancelRoomReading()
        programMeter?.stop()
      } else {
        deviceFeed.connect(ctx.destination)
        if (sessionDeck()) programMeter?.start()
      }
      passage.setRoomAvailable(available)
      if (!available) return

      const ended = roomEnd
      roomEnd = null
      const gap = activeBreatherGap(), from = decks[state.activeDeck]
      if (ended) handleEnded(ended.deck, ended.trackId, ended.saved)
      else if (state.waitingForNext && from?.ended()) handleEnded(from)
      else if (gap && gap.deadline <= performance.now()) gap.start()
      else if (from && state.hint?.transition && from.positionMs() >= firePoint(state.hint.transition, from)) {
        // The ordinary AUTO window passed unheard. Keep this record until its next boundary.
        from._seekGuard = true
      }
    },
    editPassageMix() { passage.mixChanged("draft") },
    disarmPassage() {
      const current = passage.current()
      if (current) decks[current.pair.from]._seekGuard = true
      passage.disarm()
    },
    passage: passage.current,
    audibleDeck: audibleDeckId,
    sessionDeck,

    // The DJ pressed a transition button: fire it NOW, from the deck the
    // crossfader says is on air, into the other deck. Works with AUTO on or
    // off — the server hears the same transition_started either way.
    fireManual(type) {
      if (!roomAvailable) return {ok: false, reason: "room_unavailable"}
      if (passage.current()) return {ok: false, reason: "passage_reserved"}
      // Double-click guard: two near-simultaneous fires would reverse the
      // transition that just started and double-advance the boundary.
      if (state.lastFireAt && performance.now() - state.lastFireAt < 400) {
        return {ok: false, reason: "too_fast"}
      }
      const fromId = audibleDeckId()
      if (!fromId) return {ok: false, reason: "no_audible"}
      const to = decks[otherId(fromId)]
      if (to.trackId == null) return {ok: false, reason: "empty_target"}
      if (deckHeld(to.id) || deckHeld(fromId)) return {ok: false, reason: "deck_held"}
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
      return firePoint(hint.transition, decks[active])
    },

    // "Ainda não!" — push the AUTO fire point forward for this boundary only.
    // Postponed past the end of the track, the `ended` fallback still advances.
    // Durante um respiro, W ESTICA o silêncio (a pista ainda está agradecendo)
    // e devolve o novo restante em ms.
    postponeFire(ms) {
      if (passage.current()) return null
      const gap = state.breatherGap
      if (gap) {
        if (gap.deadline === null) {
          gap.durationMs += ms
          return gap.durationMs
        }
        clearTimeout(gap.timer)
        state.cancelEntry?.()
        gap.attemptedLoad = null
        gap.deadline = Math.max(gap.deadline, performance.now()) + ms
        gap.timer = setTimeout(gap.start, Math.max(gap.deadline - performance.now(), 0))
        return Math.max(gap.deadline - performance.now(), 0)
      }
      if (this.firePointMs() == null) return null
      state.postponeMs += ms
      return this.firePointMs()
    },

    // "Agora!" — fire the armed hint immediately with its planned type/to_ms
    // (the keyboard cousin of AUTO's own fire; works with AUTO off too).
    // Durante um respiro, T PULA o resto do silêncio: a próxima entra já.
    fireHint() {
      if (!roomAvailable) return {ok: false, reason: "room_unavailable"}
      if (passage.current()) return {ok: false, reason: "passage_reserved"}
      const gap = activeBreatherGap()
      if (gap) {
        clearTimeout(gap.timer)
        gap.start(true)
        return {ok: true, type: "respiro"}
      }
      const hint = state.hint
      const active = state.activeDeck
      if (state.lastFireAt && performance.now() - state.lastFireAt < 400) {
        return {ok: false, reason: "too_fast"}
      }
      if (!hint || !active || !decks[active].audible()) {
        return {ok: false, reason: "no_hint"}
      }
      if (!hintFireable(hint)) return {ok: false, reason: "target_loading"}
      const from = decks[active]
      if (state.firedForTrack === from.trackId) return {ok: false, reason: "too_fast"}
      this.resume()
      const transition = hint.transition || {type: "cut", to_ms: 0}
      boundaryOnce(from.trackId, () => fireTransition(from, decks[hint.deck], transition, "manual", "hint"))
      return {ok: true, type: transition.type || "cut"}
    },

    cancelTransition,

    playPause(deckId) {
      const deck = decks[deckId]
      if (jog[deckId].held) return // nunca dar play embaixo da mão do DJ
      this.resume()
      if (state.cancelEntry && state.pendingEntry === deckId) {
        cancelTransition()
        return
      }
      const latchPreview = deck.cueState === "preview"
      if (!roomAvailable && (latchPreview || (!deck.audible() && !deck.playPending))) return
      deck.cueState = null
      if (!latchPreview && (deck.audible() || deck.playPending)) {
        pauseTransport(deck)
      } else if (deck.trackId) {
        // Manual restart takes ownership: cancel stale transition cleanups and
        // resume with a SANE chain — a stop mid-echo/filter may have frozen
        // dry at zero or the filter swept; resuming must always sound clean.
        interruptTransition({keepPassage: true})
        settleTransitionParams(deck)
        const now = ctx.currentTime
        if (deck.gain.gain.value < 0.05) deck.gain.gain.setValueAtTime(1, now)
        deck.dry.gain.linearRampToValueAtTime(1, now + 0.2)
        deck.bass.gain.linearRampToValueAtTime(0, now + 0.15)
        deck.echoSend.gain.linearRampToValueAtTime(0, now + 0.2)
        deck.hpf.frequency.linearRampToValueAtTime(10, now + 0.15)
        deck.lpf.frequency.linearRampToValueAtTime(20_000, now + 0.15)
        if (!latchPreview || (!deck.audible() && !deck.playPending)) deck.play()
        state.activeDeck = deckId
        if (state.hint?.deck === deckId) state.hint = null
        state.firedForTrack = null
        state.postponeMs = 0
        emit("deckStarted", {deck: deckId, trackId: deck.trackId})
      }
    },

    cueButton(deckId, pressed) {
      const deck = decks[deckId]
      if (!pressed) {
        const held = deck.cueState
        deck.cueState = null
        if (held === "preview") {
          deck.pause()
          this.cueTo(deckId, deck.cueMs)
        }
        if (held) releaseDeck(deck)
        return
      }
      if (!deck.trackId || deckHeld(deckId)) return
      passage.mixChanged()
      deck.cueState = "held"
      const atMs = Math.round(deck.platterTime() * 1000)
      if (deck.audible() || deck.playPending) {
        pauseTransport(deck)
        this.cueTo(deckId, deck.cueMs)
      } else if ((deck._cued || deck._pendingSeekMs == null) && Math.abs(atMs - deck.cueMs) > 20) {
        deck.cueMs = atMs
        deck._cued = true
      } else {
        this.resume()
        deck.cueState = "preview"
        deck._cued = true
        deck.play(deck.cueMs)
      }
    },

    cueTo(deckId, ms) {
      const deck = decks[deckId]
      if (deck.trackId == null) return
      placePlatter(deck, ms / 1000)
      const pattern = autoScratch[deckId]
      if (scratch[deckId].active && (jog[deckId].held || pattern)) {
        // Reset the worklet head on a jump; a held pattern also releases at its center.
        const position = deck.clampPosition(ms / 1000) * sr
        if (pattern) pattern.center = position
        scratch[deckId].node.port.postMessage({type: "stop"})
        scratchScrub(deckId, position)
      }
    },

    // Jog físico e de tela: topo segurado = vinil na mão; borda = nudge.
    jogTouch,
    jogTurn,
    startAutoScratch,
    stopAutoScratch(deckId) {
      if (!autoScratch[deckId]) return
      stopAutoScratch(deckId)
      releaseDeck(decks[deckId])
    },
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
      const before = decks[deckId].baseRate
      const ok = syncTempo(decks[deckId], decks[otherId(deckId)])
      if (before !== decks[deckId].baseRate) passage.mixChanged()
      return ok
    },

    setRate(deckId, rate, midiStep = 0) {
      const deck = decks[deckId]
      const next = Math.min(Math.max(rate, 1 - PITCH_RATE_CLAMP), 1 + PITCH_RATE_CLAMP)
      if (reservedMidiJitter(deck.baseRate, next, midiStep)) return
      deck.stopBrake?.()
      if (deck.baseRate !== next) passage.mixChanged()
      deck.baseRate = next
      applyRate(deck)
    },

    // ── efeitos de performance (coisas que a controladora não tem) ─────────────

    // Filtro bipolar: -1 = afogado no low-pass, 0 = neutro, +1 = só ar (high-pass).
    setFilter(deckId, value) {
      const deck = decks[deckId]
      const v = Math.min(Math.max(value, -1), 1)
      if (deck.controls.filter !== v) passage.mixChanged()
      deck.controls.filter = v
      applyFilter(deck, v, ctx.currentTime)
    },

    // Eco manual: abre o send do delay (já sincronizado ao BPM no load).
    setEchoSend(deckId, value) {
      const deck = decks[deckId]
      const now = ctx.currentTime
      const send = Math.min(Math.max(value, 0), 1) * 0.9
      if (send > 0) deck.echoTailUntil = Infinity
      else releaseEchoTail(deck, now)
      if (passage.current()?.plan.blendCurve && send > 0) passage.mixChanged()
      deck.settleGain(deck.echoSend)
      deck.echoSend.gain.setTargetAtTime(send, now, 0.02)
    },

    // "Tom": tilt EQ grave↔agudo. v<0 puxa grave e abafa agudo (quente),
    // v>0 o contrário (brilhante). Nodes próprios — não encosta no bass_swap.
    setTone(deckId, value) {
      const deck = decks[deckId]
      const v = Math.min(Math.max(value, -1), 1)
      if (deck.controls.tone !== v) passage.mixChanged()
      deck.controls.tone = v
      applyTone(deck, v, ctx.currentTime)
    },

    // Modo VINIL: o pitch passa a mudar a afinação junto com o tempo.
    // O flag persiste por SYNC/freio — só o reset da cadeia (novo load) desliga.
    setVinylMode(deckId, on) {
      const deck = decks[deckId]
      deck.stopBrake?.()
      if (deck.vinylMode !== on) {
        passage.mixChanged()
        deck.useMedia()
      }
      deck.vinylMode = on
      deck.el.preservesPitch = !on
      applyRate(deck)
    },

    // Ejeta um deck parado: solta a mídia e zera a cadeia. Recusado no ar.
    eject(deckId) {
      const deck = decks[deckId]
      if (deckBusy(deckId)) return false
      deck.pause()
      deck.loadToken++
      deck.trackId = null
      deck._pendingSeekMs = null
      deck.bpm = null
      deck.durationMs = null
      deck.el.removeAttribute("src")
      deck.el.load()
      retainScratch(deck, null)
      resetDeck(deck)
      if (state.hint && state.hint.deck === deckId) this.clearHint()
      return true
    },

    // PUNCH ("estourado"): abaixa o threshold e sobe o drive juntos — em 0 o
    // compressor não pega nada (transparente), no talo esmaga e engorda.
    setPunch(value) {
      const now = ctx.currentTime
      const v = Math.min(Math.max(value, 0), 1)
      if (v > 0 && passage.current()?.plan.blendCurve) passage.mixChanged()
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
      return {mode: cue.mode, maxChannels: routedChannels}
    },

    // Point the WHOLE context at another output device (e.g. the controller's
    // 4-channel interface) and rewire main/phones for what it offers.
    async setOutputDevice(deviceId) {
      rehearsal.stop()
      const previous = ctx.sinkId, wasRunning = ctx.state === "running"
      try {
        await ctx.setSinkId(deviceId)
      } catch (error) {
        const needsResume = () => roomAvailable && !mediaEvents.signal.aborted && ctx.state === "suspended" && ctx.sinkId === previous
        // A driver can fail after suspending the renderer. Keep output controls
        // available even if resuming the original room needs another gesture.
        if (wasRunning && needsResume()) {
          ctx.resume().catch(() => { if (needsResume()) emit("roomOutputSuspended") })
        }
        throw error
      }
      if (!mediaEvents.signal.aborted) wireOutputs()
      return this.cueMode()
    },

    stopAll() {
      programMeter?.stop()
      interruptTransition({resumeOutgoing: false}) // no in-flight cleanup may outlive a stop
      decks.a.pause()
      decks.b.pause()
      // Full clean stop: no frozen mid-transition FX, no ghost resume from a
      // jog release, chips/sliders told via the resetChain events.
      for (const d of ["a", "b"]) {
        decks[d].cueState = null
        resetScratch(d, true)
        cancelBend(d)
        resetDeck(decks[d])
      }
      state.activeDeck = null
      state.hint = null
    },

    // Pause without losing state — used when another audio source (o player
    // global) takes over; loads and the armed hint survive. Params settle at
    // their CURRENT values; resuming via playPause re-sanitizes the chain.
    pauseAll() {
      programMeter?.stop()
      rehearsal.stop()
      interruptTransition({resumeOutgoing: false})
      decks.a.pause()
      decks.b.pause()
      for (const d of ["a", "b"]) {
        decks[d].cueState = null
        resetScratch(d, true)
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
        waitingForNext: state.waitingForNext,
        breatherTail: Boolean(state.breatherGap && state.breatherGap.deadline === null),
        breather: (() => {
          const gap = activeBreatherGap()
          return gap ? {fromTrackId: gap.fromTrackId, remainingMs: Math.max(gap.deadline - performance.now(), 0)} : null
        })(),
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
      programMeter?.stop()
      rehearsal.stop()
      mediaEvents.abort()
      interruptTransition({resumeOutgoing: false})
      state.activeDeck = null
      state.hint = null
      xfadeGlide++
      cancelAnimationFrame(xfadeAnim)
      for (const d of ["a", "b"]) {
        retainScratch(decks[d], null)
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
        pfl,
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
    return setTimeout(fn, seconds * 1000)
  }
}
