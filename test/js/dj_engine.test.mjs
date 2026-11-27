import assert from "node:assert/strict"
import test from "node:test"
import {createEngine} from "../../assets/js/dj/engine.js"
import {loadPeaks} from "../../assets/js/dj/waveform.js"

// Media events and the clock are controlled independently: decoding can stall
// while wall time advances, and canplay can arrive after a stop or a new hint.
class Media extends EventTarget {
  paused = true
  ended = false
  readyState = 3
  currentTime = 0
  duration = 60
  playbackRate = 1
  plays = 0
  load() { this.ended = false; this.currentTime = 0 }
  removeAttribute(name) { delete this[name] }
  play() { this.plays++; this.paused = false; this.ended = false; return Promise.resolve() }
  pause() { this.paused = true }
  at(seconds) { this.currentTime = seconds; this.dispatchEvent(new Event("timeupdate")) }
  end() {
    this.currentTime = this.duration
    this.paused = this.ended = true
    this.dispatchEvent(new Event("ended"))
  }
  ready() { this.readyState = 3; this.dispatchEvent(new Event("canplay")) }
}

class Param {
  value = 1
  setValueAtTime(value) { this.value = value }
  linearRampToValueAtTime(value) { this.value = value }
  exponentialRampToValueAtTime(value) { this.value = value }
  setTargetAtTime(value) { this.value = value }
  cancelScheduledValues() {}
}

class AudioNodeStub {
  constructor() {
    for (const name of ["gain", "frequency", "delayTime", "threshold", "ratio", "knee", "attack", "release"]) {
      this[name] = new Param()
    }
  }
  connect() {}
  disconnect() {}
}

class Context {
  currentTime = 0
  destination = {maxChannelCount: 2}
  sampleRate = 8000
  audioWorklet = {addModule: async () => {}}
  createMediaElementSource() { return new AudioNodeStub() }
  createBiquadFilter() { return new AudioNodeStub() }
  createMediaStreamDestination() { return new AudioNodeStub() }
  createDynamicsCompressor() { return new AudioNodeStub() }
  createGain() { return new AudioNodeStub() }
  createAnalyser() { return new AudioNodeStub() }
  createDelay() { return new AudioNodeStub() }
}

function booth(t, callbacks = {}) {
  t.mock.timers.enable({apis: ["setTimeout", "setInterval", "Date"], now: 1000})
  t.mock.method(performance, "now", () => Date.now())
  globalThis.window = {AudioContext: Context}
  globalThis.requestAnimationFrame = () => 1
  globalThis.cancelAnimationFrame = () => {}
  const a = new Media(), b = new Media()
  const advances = [], ends = []
  const engine = createEngine({deckElA: a, deckElB: b, callbacks: {
    transitionStarted: event => advances.push(event),
    trackEnded: event => ends.push(event),
    ...callbacks
  }})
  t.after(() => engine.destroy())
  const track = id => ({id, src: id, duration_ms: 60_000, bpm: 120})
  engine.loadDeck("a", track("one"), {autoplay: true})
  engine.setAuto(true)
  const hint = (transition, id = "two") => engine.armHint({track: track(id), transition})
  const breath = {type: "echo", breather: true, from_ms: 56_000, to_ms: 500, gap_ms: 2500}
  return {a, b, engine, hint, breath, advances, ends, tick: ms => t.mock.timers.tick(ms)}
}

async function scratchBooth(t, id) {
  const commands = []
  globalThis.AudioWorkletNode = class extends AudioNodeStub {
    port = {postMessage: message => commands.push(message)}
  }
  t.after(() => { delete globalThis.AudioWorkletNode })
  const rig = booth(t)
  t.mock.method(globalThis, "fetch", async () => new Response(new ArrayBuffer(0)))
  const samples = new Float32Array(8 * 8000)
  await loadPeaks(id, id, {decodeAudioData: async () => ({
    sampleRate: 8000, duration: 8, numberOfChannels: 1, getChannelData: () => samples
  })})
  return {...rig, commands}
}

test("a missed AUTO window still waits the full breather after ended", t => {
  const {a, b, hint, breath, advances, tick} = booth(t)
  hint(breath)
  a.end()
  tick(2499)
  assert.equal(b.plays, 0)
  assert.equal(advances.length, 0)
  tick(1)
  assert.equal(b.plays, 1)
  assert.equal(b.currentTime, 0.5)
  assert.equal(advances.length, 1)
})

test("AUTO uses the media's real end and waits through a stalled final phrase", t => {
  const {a, b, hint, breath, advances, engine, tick} = booth(t)
  hint({...breath, from_ms: 36_000})
  assert.equal(engine.firePointMs(), 56_000)
  a.at(56)
  tick(12_000)
  assert.equal(a.paused, false)
  assert.equal(b.plays, 0)
  assert.equal(advances.length, 0)
  a.end()
  assert.equal(engine.snapshot().breather.remainingMs, 2500)
  assert.equal(engine.postponeFire(1000), 3500)
  tick(2600)
  assert.equal(b.plays, 0)
  assert.equal(engine.fireHint().ok, true)
  tick(5000)
  assert.equal(b.plays, 1)
  assert.equal(advances.length, 1)
})

test("a set edit during the gap plays the current successor once", t => {
  const {a, b, hint, breath, advances, tick} = booth(t)
  hint(breath)
  a.at(56)
  a.end()
  hint({...breath, to_ms: 1500}, "replacement")
  tick(2500)
  assert.deepEqual(advances.map(e => e.toTrackId), ["replacement"])
  assert.equal(b.currentTime, 1.5)
})

test("ended waits for the authorized preload to become playable", t => {
  const {a, b, hint, advances, ends} = booth(t)
  hint(null)
  b.readyState = 1
  a.end()
  assert.equal(ends.length, 0)
  assert.equal(b.plays, 0)
  b.ready()
  b.ready()
  assert.deepEqual(advances.map(e => e.toTrackId), ["two"])
  assert.equal(b.plays, 1)
})

test("stop cancels a buffered autoplay and a pending breather", t => {
  const {a, b, hint, breath, engine, tick} = booth(t)
  hint(breath)
  a.at(56)
  a.end()
  engine.stopAll()
  tick(10_000)
  assert.equal(b.plays, 0)
  a.readyState = 1
  engine.loadDeck("a", {id: "restart", src: "restart"}, {autoplay: true})
  engine.stopAll()
  a.ready()
  assert.equal(a.paused, true)
})

test("rescue cannot play a new preload in place of the outgoing record", t => {
  const {a, b, hint, engine, advances} = booth(t)
  hint({type: "cut", from_ms: 50_000})
  a.at(50)
  assert.equal(b.plays, 1)
  assert.equal(hint(null, "three"), "a")
  assert.equal(engine.cancelTransition().ok, false)
  assert.equal(a.plays, 1)
  assert.equal(advances.length, 1)
})

test("starting a set routes the first deck to the audience after the fader was left on B", t => {
  const {engine} = booth(t)
  engine.setCrossfader(1)
  engine.stopAll()
  engine.loadDeck("a", {id: "first", src: "first"}, {autoplay: true})
  assert.equal(engine.snapshot().xfadePos, 0)
})

test("manual early breather fades the phrase, keeps the set live, then releases once", t => {
  const {a, b, hint, breath, engine, advances, tick} = booth(t)
  engine.setAuto(false)
  hint(breath)
  a.at(20)
  assert.equal(engine.fireHint().ok, true)
  tick(4000)
  tick(350)
  assert.equal(a.paused, true)
  assert.equal(b.paused, true)
  assert.equal(engine.sessionDeck(), "a")
  tick(2500)
  assert.equal(engine.sessionDeck(), "b")
  assert.equal(b.plays, 1)
  assert.deepEqual(advances.map(e => e.origin), ["hint"])
})

test("a cleared, loading or stopped successor never steals playback later", t => {
  const {a, b, hint, breath, engine, advances, ends, tick} = booth(t)
  hint(breath)
  b.readyState = 1
  a.end()
  tick(2500)
  assert.equal(b.plays, 0)
  engine.clearHint()
  b.ready()
  assert.equal(b.plays, 0)
  assert.equal(ends.length, 1)
  assert.equal(advances.length, 0)
})

test("reconnecting during an overlap follows the incoming deck in both directions", t => {
  const {a, b, hint, engine, tick} = booth(t)
  hint({type: "crossfade", from_ms: 48_000})
  a.at(48)
  assert.equal(a.paused || b.paused, false)
  assert.equal(engine.sessionDeck(), "b")
  tick(9000)
  hint({type: "crossfade", from_ms: 48_000}, "three")
  b.at(48)
  assert.equal(a.paused || b.paused, false)
  assert.equal(engine.sessionDeck(), "a")
})

test("a cancelled AUTO blend stays on the rescued track inside the same fire window", t => {
  const {a, hint, engine, advances} = booth(t)
  const next = {type: "crossfade", from_ms: 50_000}
  hint(next)
  a.at(50)
  assert.equal(engine.cancelTransition().ok, true)
  hint(next)
  a.at(51)
  assert.deepEqual(advances.map(e => e.toTrackId), ["two"])
  assert.equal(engine.sessionDeck(), "a")
})

test("manual fire takes a sequential hint directly even with AUTO off", t => {
  const {a, b, hint, engine, advances} = booth(t)
  hint(null)
  engine.setAuto(false)
  a.at(22)
  assert.equal(engine.fireHint().ok, true)
  assert.equal(b.plays, 1)
  assert.deepEqual(advances.map(e => e.type), ["cut"])
})

test("postponing during the final phrase extends the upcoming gap", t => {
  const {a, b, hint, breath, engine, tick} = booth(t)
  hint(breath)
  a.at(56)
  assert.equal(engine.postponeFire(1000), 3500)
  a.end()
  tick(3499)
  assert.equal(b.plays, 0)
  tick(1)
  assert.equal(b.plays, 1)
})

test("CUE returns a playing deck to its marker and previews only while held", t => {
  const {engine, a} = booth(t)
  engine.stopAll()
  engine.loadDeck("a", {id: "intro", src: "intro", markers: [{type: "intro", ms: 2100}]}, {autoplay: true})
  a.at(25)
  engine.cueButton("a", true)
  assert.equal(a.paused, true)
  assert.equal(a.currentTime, 2.1)
  engine.cueButton("a", false)
  engine.cueButton("a", true)
  assert.equal(a.paused, false)
  a.at(2.9)
  engine.cueButton("a", false)
  assert.equal(a.paused, true)
  assert.equal(a.currentTime, 2.1)
})

test("a temporary cue belongs to its deck and PLAY latches a held preview", t => {
  const {engine, a, b} = booth(t)
  engine.loadDeck("b", {id: "preview", src: "preview"})
  engine.cueTo("b", 3500)
  engine.cueButton("b", true)
  engine.cueButton("b", false)
  assert.equal(b.plays, 0)
  engine.cueButton("b", true)
  assert.equal(engine.sessionDeck(), "a")
  assert.equal(b.plays, 1)
  b.at(4)
  engine.playPause("b")
  engine.cueButton("b", false)
  assert.equal(b.paused, false)
  assert.equal(b.plays, 1)
  assert.equal(b.currentTime, 4)
  assert.equal(engine.sessionDeck(), "b")
  assert.equal(a.paused, false)
  engine.cueButton("b", true)
  assert.equal(b.currentTime, 3.5)
  assert.equal(b.paused, true)
})

test("releasing CUE before canplay never starts the preview later", t => {
  const {engine, b} = booth(t)
  engine.loadDeck("b", {id: "preview", src: "preview"})
  b.readyState = 1
  engine.cueButton("b", true)
  engine.cueButton("b", false)
  b.ready()
  assert.equal(b.plays, 0)
  assert.equal(engine.sessionDeck(), "a")
})

test("manual LOAD cannot replace a platter that the DJ is holding", t => {
  const {engine, b} = booth(t)
  engine.loadDeck("b", {id: "original", src: "original"})
  engine.jogTouch("b", true)
  assert.equal(engine.loadDeck("b", {id: "replacement", src: "replacement"}), false)
  assert.equal(b.src, "original")
  engine.jogTouch("b", false)
  assert.equal(engine.loadDeck("b", {id: "replacement", src: "replacement"}), true)
})

test("a manual crossfader move wins over the second phase of a bass swap", t => {
  const {engine, hint, tick} = booth(t)
  hint({type: "bass_swap", from_ms: 50_000})
  assert.equal(engine.fireHint().ok, true)
  tick(300)
  engine.setCrossfader(0.27)
  tick(15_000)
  tick(5000)
  assert.equal(engine.snapshot().xfadePos, 0.27)
})

test("AUTO waits for the DJ to release the armed platter at the end of the other deck", t => {
  const {engine, a, b, hint, advances} = booth(t)
  hint(null)
  engine.jogTouch("b", true)
  a.end()
  assert.equal(b.plays, 0)
  engine.jogTouch("b", false)
  assert.equal(b.plays, 1)
  assert.equal(advances.length, 1)
})

test("taking a preloaded deck live from CUE consumes its own hint", t => {
  const {engine, b, hint, advances} = booth(t)
  hint({type: "cut", from_ms: 50_000})
  engine.cueButton("b", true)
  engine.playPause("b")
  engine.cueButton("b", false)
  b.at(50)
  assert.equal(engine.snapshot().activeDeck, "b")
  assert.equal(advances.length, 0)
  assert.equal(b.plays, 1)
})

test("PLAY starts at the temporary cue marked with the jog on a freshly loaded track", t => {
  const {engine, b, hint} = booth(t)
  hint(null)
  engine.jogTurn("b", 48)
  const mark = b.currentTime
  engine.cueButton("b", true)
  engine.cueButton("b", false)
  engine.playPause("b")
  assert.equal(b.currentTime, mark)
})

test("updating a transition for the loaded track preserves its temporary cue", t => {
  const {engine, b, hint} = booth(t)
  hint(null)
  engine.cueTo("b", 2100)
  engine.cueButton("b", true)
  engine.cueButton("b", false)
  hint({type: "cut", from_ms: 50_000, to_ms: 0})
  engine.cueButton("b", true)
  assert.equal(b.currentTime, 2.1)
  assert.equal(b.paused, false)
})

test("stopping the incoming deck with CUE keeps a manual fader setting during the overlap", t => {
  const {engine, a, b, hint, tick} = booth(t)
  hint({type: "crossfade", from_ms: 48_000})
  a.at(48)
  engine.setCrossfader(0.36)
  engine.cueButton("b", true)
  engine.cueButton("b", false)
  tick(15_000)
  assert.equal(a.paused, false)
  assert.equal(b.paused, true)
  assert.equal(engine.snapshot().xfadePos, 0.36)
})

test("releasing the platter after CUE cannot restart a finished preview", t => {
  const {engine, b, hint} = booth(t)
  hint(null)
  engine.cueButton("b", true)
  engine.jogTouch("b", true)
  engine.cueButton("b", false)
  engine.jogTouch("b", false)
  assert.equal(b.paused, true)
  assert.equal(b.plays, 1)
})

test("grabbing a nudged deck keeps it live and releases it at its set tempo", t => {
  const {engine, a, tick} = booth(t)
  engine.setRate("a", 1.04)
  engine.jogTurn("a", 8)
  assert.ok(a.playbackRate > 1.04)
  engine.jogTouch("a", true)
  assert.equal(engine.sessionDeck(), "a")
  assert.equal(a.paused, true)
  engine.jogTouch("a", false)
  tick(180)
  assert.equal(a.paused, false)
  assert.equal(a.playbackRate, 1.04)
})

test("manual platter placement survives PLAY and AUTO on a preloaded cue", t => {
  const {engine, a, b, hint} = booth(t)
  hint({type: "cut", to_ms: 4000, from_ms: 50_000})
  engine.jogTurn("b", 4)
  const mark = b.currentTime
  assert.ok(mark > 4 && mark < 4.5)
  a.at(50)
  assert.equal(b.currentTime, mark)
  engine.playPause("b")
  engine.jogTurn("b", -1)
  const earlier = b.currentTime
  engine.playPause("b")
  assert.ok(earlier < mark)
  assert.equal(b.currentTime, earlier)
})

test("a buffered start waits for platter release even when canplay arrives under the hand", t => {
  const {engine, b} = booth(t)
  b.readyState = 0
  engine.loadDeck("b", {id: "queued", src: "queued"}, {autoplay: true, atMs: 8000})
  engine.jogTouch("b", true)
  engine.jogTurn("b", 4)
  b.ready()
  assert.equal(b.plays, 0)
  engine.jogTouch("b", false)
  assert.equal(b.plays, 1)
  assert.ok(b.currentTime > 8 && b.currentTime < 8.2)
})

test("scrubbing up to the end of a paused deck cannot skip to the following track", t => {
  const {engine, a, ends} = booth(t)
  engine.playPause("a")
  a.at(59.98)
  engine.jogTurn("a", 7)
  assert.ok(a.currentTime < 60)
  assert.equal(ends.length, 0)
})

test("SYNC matches the reference pitch, cancels the receiving nudge, and keeps the beat placement", t => {
  const {engine, a, b, hint, tick} = booth(t)
  hint(null)
  engine.playPause("b")
  a.at(10.25)
  b.at(12.04)
  engine.setRate("a", 1.05)
  engine.jogTurn("a", -8)
  engine.jogTurn("b", 8)
  assert.equal(engine.sync("b"), true)
  tick(60)
  assert.equal(b.playbackRate, 1.05)
  assert.equal(b.currentTime, 12.04)
  assert.equal(a.currentTime, 10.25)
  assert.ok(a.playbackRate < 1.05)
})

test("SYNC reports its limit and keeps a closer manual tempo when the target is out of range", t => {
  const {engine, b, hint} = booth(t)
  hint(null)
  engine.setRate("a", 1.2)
  assert.equal(engine.sync("b"), false)
  assert.equal(b.playbackRate, 1.08)
  engine.setRate("b", 1.18)
  assert.equal(engine.sync("b"), false)
  assert.equal(b.playbackRate, 1.18)
  engine.setRate("b", 1.2)
  assert.equal(engine.sync("b"), true)
  assert.equal(b.playbackRate, 1.2)
})

test("a loaded replacement cannot inherit the previous track's decaying pitch bend", t => {
  const {engine, a, tick} = booth(t)
  engine.jogTurn("a", 12)
  engine.playPause("a")
  engine.loadDeck("a", {id: "new", src: "new"}, {autoplay: true})
  tick(60)
  assert.equal(a.playbackRate, 1)
})

test("rescuing a vinyl brake restores the DJ's pitch and key-lock setting permanently", t => {
  const {engine, a, hint, tick} = booth(t)
  hint(null)
  engine.setRate("a", 1.06)
  engine.setVinylMode("a", true)
  assert.equal(engine.fireManual("brake").ok, true)
  tick(120)
  assert.equal(engine.cancelTransition().ok, true)
  tick(2000)
  assert.equal(a.playbackRate, 1.06)
  assert.equal(a.preservesPitch, false)
})

test("rescuing a bass swap restores the outgoing low end after the bass has crossed", t => {
  const {engine, a, b, hint, tick} = booth(t)
  hint(null)
  assert.equal(engine.fireManual("bass_swap").ok, true)
  tick(4500)
  assert.ok(engine.decks.a.bass.gain.value < 0)
  assert.equal(engine.cancelTransition().ok, true)
  tick(15_000)
  assert.equal(engine.decks.a.bass.gain.value, 0)
  assert.equal(a.paused, false)
  assert.equal(b.paused, true)
})

test("a four-beat loop spans four source beats after pitching the track", t => {
  const {engine, a} = booth(t)
  engine.setRate("a", 1.2)
  a.at(8)
  engine.beatLoop("a", 4)
  assert.equal(engine.loopState("a").endMs, 10_000)
})

test("jogging a paused deck beyond a loop keeps the new beat placement", t => {
  const {engine, a, tick} = booth(t)
  a.at(8)
  engine.beatLoop("a", 1)
  engine.playPause("a")
  engine.jogTurn("a", 18)
  tick(20)
  assert.ok(a.currentTime > 8.5)
  assert.equal(engine.loopState("a").on, false)
})

test("one turn of the held DJ2GO2 maps to 1.8 seconds even before scratch audio is decoded", t => {
  const {engine, b, hint} = booth(t)
  hint({to_ms: 4000})
  engine.jogTouch("b", true)
  for (let n = 0; n < 4; n++) engine.jogTurn("b", 59)
  assert.ok(Math.abs(b.currentTime - 5.8) < 0.0001)
  engine.jogTurn("b", -59)
  engine.jogTouch("b", false)
  engine.playPause("b")
  assert.ok(Math.abs(b.currentTime - 5.35) < 0.0001)
})

test("letting go after a completed crossfade does not restart the retired deck", t => {
  const {engine, a, b, hint, tick} = booth(t)
  hint({type: "crossfade", from_ms: 48_000})
  a.at(48)
  engine.jogTouch("a", true)
  tick(9000)
  engine.jogTouch("a", false)
  assert.equal(a.paused, true)
  assert.equal(b.paused, false)
  assert.equal(hint(null, "three"), "a")
})

test("a playing platter held by hand can receive the set when the other deck ends", t => {
  const {engine, a, b, hint, ends} = booth(t)
  hint(null)
  engine.playPause("b")
  engine.setAuto(false)
  engine.jogTouch("a", true)
  b.end()
  assert.equal(engine.sessionDeck(), "a")
  assert.equal(ends.length, 0)
  engine.jogTouch("a", false)
  assert.equal(a.paused, false)
})

test("eject clears a waiting jog position before the next record", t => {
  const {engine, b, hint} = booth(t)
  b.readyState = 0
  hint({to_ms: 8000})
  engine.jogTurn("b", 2)
  assert.equal(engine.eject("b"), true)
  assert.equal(engine.decks.b.platterTime(), 0)
  b.ready()
  assert.equal(b.currentTime, 0)
})

test("adjusting an entry before metadata waits for the actual audio duration", t => {
  const {engine, b} = booth(t)
  b.readyState = 0
  b.duration = NaN
  engine.loadDeck("b", {id: "vbr", src: "vbr", duration_ms: 20_000}, {atMs: 25_000})
  engine.jogTurn("b", 5)
  b.duration = 60
  b.ready()
  assert.ok(Math.abs(b.currentTime - 25.18) < .001)
})

test("a beat loop on a preloaded deck starts at the visible entry, even before canplay", t => {
  const {engine, b, hint} = booth(t)
  b.readyState = 0
  hint({type: "cut", to_ms: 8000, from_ms: 50_000})
  engine.beatLoop("b", 4)
  assert.equal(engine.loopState("b").startMs, 8000)
  assert.equal(engine.loopState("b").endMs, 10_000)
  b.ready()
  engine.playPause("b")
  assert.equal(b.currentTime, 8)
})

test("late loop checks keep beat phase, even if a background timer misses several laps", t => {
  const {engine, a, tick} = booth(t)
  a.at(10)
  engine.beatLoop("a", 1)
  a.currentTime = 10.518
  tick(20)
  assert.ok(Math.abs(a.currentTime - 10.018) < 0.000001)
  a.currentTime = 12.625
  tick(20)
  assert.equal(a.currentTime, 10.125)
  assert.equal(engine.loopState("a").on, true)
})

test("a hot cue inside the loop keeps it, and an earlier hot cue exits it immediately", t => {
  const {engine, a} = booth(t)
  a.at(10)
  engine.beatLoop("a", 4)
  engine.cueTo("a", 11_000)
  assert.equal(engine.loopState("a").on, true)
  engine.cueTo("a", 0)
  assert.equal(a.currentTime, 0)
  assert.equal(engine.loopState("a").on, false)
})

test("a pad jump to the AUTO mark does not advance on a timeupdate before seeked", t => {
  const {engine, a, b, hint} = booth(t)
  hint({type: "cut", from_ms: 48_000})
  engine.cueTo("a", 48_000)
  a.at(48)
  assert.equal(b.plays, 0)
  engine.cueTo("a", 46_000)
  a.at(46.1)
  a.at(48)
  assert.equal(b.plays, 1)
})

test("AUTO respects a held loop until the DJ releases it", t => {
  const {engine, a, b, hint} = booth(t)
  hint({type: "cut", from_ms: 48_000})
  a.at(47)
  engine.beatLoop("a", 4)
  a.at(48)
  assert.equal(b.plays, 0)
  engine.beatLoop("a", 4)
  a.at(48.1)
  assert.equal(b.plays, 1)
})

test("a manual transition releases the outgoing loop and keeps the incoming loop and breather", t => {
  const {engine, a, b, hint, breath, tick} = booth(t)
  hint(breath)
  a.at(55)
  engine.beatLoop("a", 8)
  engine.beatLoop("b", 4)
  assert.equal(engine.fireHint().ok, true)
  assert.equal(engine.loopState("a").on, false)
  assert.equal(engine.loopState("b").on, true)
  a.end()
  tick(2499)
  assert.equal(b.plays, 0)
  tick(1)
  assert.equal(b.plays, 1)
})

test("a native end before the loop timer wraps the deck without advancing or undoing a pause", t => {
  const {engine, a, b, hint, ends} = booth(t)
  hint(null)
  a.at(56)
  engine.beatLoop("a", 8)
  a.end()
  assert.equal(a.currentTime, 56)
  assert.equal(a.paused, false)
  assert.equal(b.plays, 0)
  engine.pauseAll()
  a.end()
  assert.equal(a.paused, true)
  assert.equal(b.plays, 0)
  assert.deepEqual(ends, [])
  assert.equal(engine.sessionDeck(), null)
})

test("an oversized loop leaves a shorter valid loop intact and never truncates a beat", t => {
  const {engine, a} = booth(t)
  a.at(59.2)
  engine.beatLoop("a", 1)
  engine.beatLoop("a", 4)
  assert.deepEqual(engine.loopState("a"), {on: true, beats: 1, startMs: 59_200, endMs: 59_700})
})

test("provisional beat loops are checked against the real duration when it arrives", t => {
  const {engine, b, hint} = booth(t)
  b.readyState = 0
  b.duration = NaN
  hint({type: "cut", from_ms: 48_000, to_ms: 8000})
  engine.beatLoop("b", 8)
  assert.equal(engine.loopState("b").on, true)
  b.duration = 10
  b.dispatchEvent(new Event("durationchange"))
  assert.equal(engine.loopState("b").on, false)
  assert.equal(b.plays, 0)
})

test("a revised set hint keeps a loop set by hand at the prepared entry", t => {
  const {engine, b, hint} = booth(t)
  hint({type: "cut", from_ms: 48_000, to_ms: 8000})
  engine.beatLoop("b", 4)
  hint({type: "cut", from_ms: 49_000, to_ms: 0})
  engine.playPause("b")
  assert.equal(b.currentTime, 8)
})

test("the transport cue recognizes a saved manual marker without a type", t => {
  const {engine} = booth(t)
  engine.loadDeck("b", {id: "old", src: "old", markers: [
    {type: "outro", ms: 0}, {ms: 2750, label: "Entrada"}, {type: "intro", ms: 7000}
  ]})
  assert.equal(engine.decks.b.cueMs, 2750)
})

test("a saved hot cue in the last 300 ms lands on the marker and remains paused", t => {
  const {engine, b, hint, ends} = booth(t)
  hint(null)
  engine.cueTo("b", 59_880)
  assert.equal(b.currentTime, 59.88)
  assert.equal(b.paused, true)
  assert.deepEqual(ends, [])
})

test("a loop seek completing after the pad is released does not suppress AUTO", t => {
  const {engine, a, b, hint, tick} = booth(t)
  hint({type: "cut", from_ms: 48_000})
  a.at(47.75)
  engine.beatLoop("a", 1)
  a.currentTime = 48.55
  tick(20)
  engine.beatLoop("a", 1)
  a.dispatchEvent(new Event("seeked"))
  a.at(48.1)
  assert.equal(b.plays, 1)
})

test("a hot cue under a held jog moves the scratch head and the released platter together", async t => {
  const {engine, b, commands} = await scratchBooth(t, "vinyl")
  engine.loadDeck("b", {id: "vinyl", src: "vinyl"})
  engine.jogTouch("b", true)
  engine.cueTo("b", 6500)
  assert.equal(engine.scratchPosSec("b"), 6.5)
  assert.deepEqual(commands.slice(-2).map(m => m.type), ["stop", "scrub"])
  engine.jogTouch("b", false)
  assert.equal(b.currentTime, 6.5)
  assert.equal(b.paused, true)
})

test("invalid stored tempo is displayed as unknown and uses the fallback beat length", t => {
  const {engine} = booth(t)
  for (const bpm of [-120, NaN, Infinity]) {
    engine.loadDeck("b", {id: "bad-tempo", src: "record", bpm})
    assert.equal(engine.decks.b.bpm, null)
    engine.beatLoop("b", 4)
    assert.equal(engine.loopState("b").endMs - engine.loopState("b").startMs, 2000)
    assert.equal(engine.sync("b"), false)
  }
})

test("pausing the incoming deck during a blend leaves the outgoing record on air", t => {
  const {engine, a, b, hint, tick} = booth(t)
  hint({type: "crossfade", from_ms: 48_000})
  a.at(48)
  tick(500)
  engine.playPause("b")
  tick(12_000)
  assert.equal(a.paused, false)
  assert.equal(b.paused, true)
  assert.equal(engine.sessionDeck(), "a")
  assert.equal(engine.snapshot().xfadePos, 0)
})

test("releasing the scratch pad starts the waiting AUTO track at its prepared entry", async t => {
  const {engine, a, b, advances, hint} = await scratchBooth(t, "scratch-entry")
  hint({type: "cut", from_ms: 48_000, to_ms: 5000}, "scratch-entry")
  assert.equal(engine.startAutoScratch("b", "baby").ok, true)
  a.end()
  assert.equal(b.plays, 0)
  engine.stopAutoScratch("b")
  assert.equal(b.plays, 1)
  assert.equal(b.currentTime, 5)
  assert.deepEqual(advances.map(event => event.toTrackId), ["scratch-entry"])
})

test("a delayed vinyl drop reserves its receiving record until the handoff lands", t => {
  const {engine, a, b, hint, advances, tick} = booth(t)
  a.at(30)
  hint({type: "brake", from_ms: 48_000, to_ms: 2400})
  assert.equal(engine.fireHint().ok, true)
  assert.equal(b.plays, 0)
  assert.equal(engine.loadDeck("b", {id: "wrong", src: "wrong"}), false)
  assert.equal(engine.eject("b"), false)
  assert.equal(engine.sessionDeck(), "b")
  engine.cueButton("b", true)
  engine.jogTouch("b", true)
  assert.equal(b.plays, 0)
  tick(3000)
  assert.equal(b.currentTime, 2.4)
  assert.equal(b.plays, 1)
  assert.equal(engine.snapshot().b.trackId, advances[0].toTrackId)
  engine.stopAll()
  assert.equal(engine.eject("b"), true)
})

test("stopping a vinyl drop releases the reserved deck without a delayed restart", t => {
  const {engine, b, hint, tick} = booth(t)
  hint({type: "brake", from_ms: 48_000})
  engine.fireHint()
  engine.stopAll()
  assert.equal(engine.loadDeck("b", {id: "new", src: "new"}), true)
  tick(3000)
  assert.equal(b.plays, 0)
})

test("the incoming record also stays reserved throughout a scratch drop", async t => {
  const {engine, a, b, hint, tick} = await scratchBooth(t, "one")
  a.at(3)
  hint(null, "next")
  assert.equal(engine.fireManual("scratch_cut").ok, true)
  assert.equal(b.plays, 0)
  assert.equal(engine.eject("b"), false)
  assert.equal(engine.sessionDeck(), "b")
  tick(1100)
  assert.equal(b.plays, 1)
  assert.equal(engine.snapshot().b.trackId, "next")
})

for (const type of ["fade", "crossfade", "echo", "filter", "lowpass", "bass_swap", "brake"]) {
  test(`${type} cleanup leaves the next record available for headphone preview`, t => {
    const {engine, a, b, hint, tick} = booth(t)
    hint(null)
    assert.equal(engine.fireManual(type).ok, true)
    engine.playPause("a")
    assert.equal(hint(null, "three"), "a")
    engine.setRate("a", 1.06)
    engine.cueButton("a", true)
    assert.equal(a.paused, false)
    tick(12_000)
    tick(1000) // let the echo tail finish
    assert.equal(b.paused, false)
    assert.equal(a.paused, false)
    assert.equal(a.playbackRate, 1.06)
    engine.cueButton("a", false)
    assert.equal(a.paused, true)
  })
}

test("the tail of a scratch drop preserves the next record's prepared loop", async t => {
  const {engine, a, b, hint, tick} = await scratchBooth(t, "one")
  a.at(3)
  hint(null)
  assert.equal(engine.fireManual("scratch_cut").ok, true)
  tick(1100)
  assert.equal(b.plays, 1)
  assert.equal(hint(null, "three"), "a")
  engine.beatLoop("a", 4)
  tick(300)
  assert.equal(engine.loopState("a").on, true)
})

test("a breather releases the planned track without resetting a reload during the gap", t => {
  const {engine, a, b, hint, breath, advances, tick} = booth(t)
  hint(breath)
  a.at(56)
  a.end()
  assert.equal(engine.loadDeck("a", {id: "three", src: "three", bpm: 120}), true)
  engine.beatLoop("a", 4)
  tick(2500)
  assert.equal(b.plays, 1)
  assert.deepEqual(advances.map(event => event.toTrackId), ["two"])
  assert.equal(engine.loopState("a").on, true)
})

test("rescuing a scratch drop immediately returns the record to the jog", async t => {
  const {engine, a, b, hint, tick} = await scratchBooth(t, "one")
  a.at(3)
  hint(null)
  assert.equal(engine.fireManual("scratch_cut").ok, true)
  assert.equal(engine.cancelTransition().ok, true)
  engine.jogTouch("a", true)
  engine.jogTurn("a", 59)
  tick(1100)
  assert.equal(a.paused, true)
  assert.ok(Math.abs(engine.scratchPosSec("a") - 3.45) < 0.001)
  engine.jogTouch("a", false)
  assert.equal(a.paused, false)
  assert.ok(Math.abs(a.currentTime - 3.45) < 0.001)
  assert.equal(b.plays, 0)
})

test("stopping a scratch drop cannot silence a new scratch pad on its next tick", async t => {
  const {engine, b, hint, tick, commands} = await scratchBooth(t, "one")
  hint(null)
  assert.equal(engine.fireManual("scratch_cut").ok, true)
  engine.stopAll()
  assert.equal(engine.startAutoScratch("a", "baby").ok, true)
  const firstCommand = commands.length
  tick(100)
  assert.ok(commands.slice(firstCommand).every(command => command.type === "scrub"))
  assert.notEqual(engine.scratchPosSec("a"), null)
  engine.stopAutoScratch("a")
  assert.equal(engine.scratchPosSec("a"), null)
  assert.equal(b.plays, 0)
})

test("stopping an echo turns off its indicator once", t => {
  const lights = []
  const {engine, hint, tick} = booth(t, {echoState: ({on}) => lights.push(on)})
  hint(null)
  assert.equal(engine.fireManual("echo").ok, true)
  engine.stopAll()
  assert.deepEqual(lights, [true, false])
  tick(12_000)
  assert.deepEqual(lights, [true, false])
})

test("a rescued echo cannot turn off the next echo early", t => {
  const lights = []
  const {engine, hint, tick} = booth(t, {echoState: ({on}) => lights.push(on)})
  hint(null)
  assert.equal(engine.fireManual("echo").ok, true)
  tick(2000)
  assert.equal(engine.cancelTransition().ok, true)
  assert.equal(engine.fireManual("echo").ok, true)
  tick(5000)
  assert.deepEqual(lights, [true, false, true])
  tick(2000)
  assert.deepEqual(lights, [true, false, true, false])
})

test("an early bass swap rescue leaves the incoming deck ready to play with flat bass", t => {
  const {engine, b, hint} = booth(t)
  hint(null)
  assert.equal(engine.fireManual("bass_swap").ok, true)
  // The stub applies future ramps immediately. Web Audio still reads -24 dB before the swap.
  engine.decks.b.bass.gain.value = -24
  assert.equal(engine.cancelTransition().ok, true)
  engine.playPause("b")
  assert.equal(b.paused, false)
  assert.equal(engine.decks.b.bass.gain.value, 0)
})

for (const type of ["crossfade", "fade", "filter", "lowpass", "echo", "bass_swap", "brake"]) {
  test(`holding CUE on the same outgoing record survives ${type} cleanup`, t => {
    const {engine, a, b, hint, tick} = booth(t)
    hint(null)
    assert.equal(engine.fireManual(type).ok, true)
    engine.cueButton("a", true)
    engine.cueButton("a", false)
    engine.cueButton("a", true)
    assert.equal(a.paused, false)
    engine.setRate("a", 1.06)
    tick(12_000)
    tick(1000)
    assert.equal(a.paused, false)
    assert.equal(a.playbackRate, 1.06)
    assert.equal(b.paused, false)
    engine.cueButton("a", false)
    assert.equal(a.paused, true)
    assert.equal(engine.sessionDeck(), "b")
  })
}
