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

class Context extends EventTarget {
  currentTime = 0
  destination = {maxChannelCount: 2}
  sampleRate = 8000
  audioWorklet = {addModule: async () => {}}
  createChannelMerger() { return new AudioNodeStub() }
  createChannelSplitter() { return new AudioNodeStub() }
  createMediaElementSource() { return new AudioNodeStub() }
  createBiquadFilter() { return new AudioNodeStub() }
  createBufferSource() { return Object.assign(new AudioNodeStub(), {playbackRate: new Param(), start() {}, stop() {}}) }
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

function pendingCut(t, fromId = "a", callbacks = {}) {
  const rig = booth(t, callbacks)
  const {engine} = rig
  if (fromId === "b") {
    engine.stopAll()
    engine.loadDeck("b", {id: "one", src: "one", duration_ms: 60_000}, {autoplay: true})
  }
  const toId = fromId === "a" ? "b" : "a"
  const from = rig[fromId], to = rig[toId]
  const next = {type: "cut", from_ms: 48_000, to_ms: 1500}
  rig.hint(next)
  const attempts = []
  const play = Promise.withResolvers()
  t.mock.method(to, "play", () => {
    attempts.push(to.currentTime)
    // HTMLMediaElement may clear paused before playback actually starts.
    to.paused = false
    return play.promise
  })
  from.at(48)
  return {...rig, fromId, toId, from, to, next, play, attempts}
}

for (const fromId of ["a", "b"]) {
  test(`cut from ${fromId} keeps the room until the receiver starts and publishes once`, async t => {
    const {engine, from, to, toId, play, attempts, advances, ends, tick} = pendingCut(t, fromId)
    assert.equal(from.paused, false)
    assert.equal(engine.sessionDeck(), fromId)
    assert.equal(engine.snapshot().xfadePos, fromId === "a" ? 0 : 1)
    tick(900)
    from.at(48.9)
    assert.equal(engine.fireManual("cut").ok, false)
    assert.equal(attempts.length, 1)
    assert.deepEqual(advances, [])
    from.end()
    assert.deepEqual(ends, [])
    play.resolve()
    await Promise.resolve()
    assert.equal(engine.sessionDeck(), toId)
    assert.deepEqual(advances.map(e => e.deck), [toId])
    assert.equal(to.currentTime, 1.5)
  })

  test(`a refused cut from ${fromId} keeps the outgoing record and can be retried`, async t => {
    const rig = pendingCut(t, fromId)
    const {engine, from, to, toId, play, attempts, advances, tick} = rig
    play.reject(new Error("start refused"))
    await Promise.resolve()
    assert.equal(from.paused, false)
    assert.equal(to.paused, true)
    assert.equal(engine.sessionDeck(), fromId)
    assert.deepEqual(advances, [])
    from.at(48.2)
    assert.equal(attempts.length, 1)
    tick(1000)
    to.play.mock.restore()
    assert.equal(engine.fireHint().ok, true)
    await Promise.resolve()
    assert.equal(from.paused, true)
    assert.deepEqual(advances.map(e => e.deck), [toId])
  })
}

for (const action of ["rescue", "stop", "replace", "clear", "pause"]) {
  test(`${action} revokes an unconfirmed cut even if its play resolves late`, async t => {
    const cancelled = []
    const {engine, from, to, next, hint, play, advances} =
      pendingCut(t, "a", {transitionCancelled: event => cancelled.push(event)})
    if (action === "rescue") assert.equal(engine.cancelTransition().ok, true)
    if (action === "stop") engine.stopAll()
    if (action === "replace") assert.equal(hint(next, "third"), "b")
    if (action === "clear") engine.clearHint()
    if (action === "pause") engine.playPause("a")
    play.resolve()
    await Promise.resolve()
    assert.deepEqual(advances, [])
    assert.deepEqual(cancelled, [])
    assert.equal(to.paused, true)
    assert.equal(from.paused, ["stop", "pause"].includes(action))
    if (action === "replace") assert.equal(engine.snapshot().b.trackId, "third")
  })
}

test("a failed receiver after the outgoing ends releases the session exactly once", async t => {
  const {from, play, engine, ends, advances} = pendingCut(t)
  from.end()
  play.reject(new Error("receiver refused after the last frame"))
  await Promise.resolve()
  from.end()
  assert.deepEqual(ends.map(e => e.trackId), ["one"])
  assert.deepEqual(advances, [])
  assert.equal(engine.sessionDeck(), null)
})

test("replacing the receiver after the outgoing ends retries the replacement once", async t => {
  const {from, to, hint, next, play, advances} = pendingCut(t)
  from.end()
  to.play.mock.restore()
  hint(next, "new")
  to.ready()
  await Promise.resolve()
  play.resolve()
  await Promise.resolve()
  assert.deepEqual(advances.map(e => e.toTrackId), ["new"])
})

test("a duplicate lookahead or resting MIDI fader doesn't revoke a cut", async t => {
  const {engine, hint, next, play, advances} = pendingCut(t)
  assert.equal(hint(next), "b")
  engine.setCrossfader(1 / 127, 1 / 127)
  play.resolve()
  await Promise.resolve()
  assert.deepEqual(advances.map(e => e.toTrackId), ["two"])
})

test("the fader takes over a pending cut and a late rejection leaves the new load alone", async t => {
  const refused = []
  const {engine, from, play, advances} = pendingCut(t, "a", {cutRefused: e => refused.push(e)})
  engine.setCrossfader(.35)
  assert.equal(engine.loadDeck("b", {id: "replacement", src: "replacement"}), true)
  play.reject(new Error("old play stopped"))
  await Promise.resolve()
  assert.equal(from.paused, false)
  assert.equal(engine.snapshot().xfadePos, .35)
  assert.equal(engine.snapshot().b.trackId, "replacement")
  assert.deepEqual(advances, [])
  assert.deepEqual(refused, [])
})

test("a scratch without decoded audio waits for its fallback cut to start", async t => {
  const {a, b, engine, advances, hint} = booth(t)
  hint(null)
  t.mock.method(b, "play", () => Promise.reject(new Error("receiver not playing")))
  assert.equal(engine.fireManual("scratch_cut").ok, true)
  await Promise.resolve()
  assert.equal(a.paused, false)
  assert.deepEqual(advances, [])
})

test("media errors report whether the source was playing before the pause", t => {
  const reports = []
  const {a, engine} = booth(t, {deckError: event => reports.push(event)})
  engine.playPause("a")
  a.error = {code: 3}
  a.dispatchEvent(new Event("error"))
  assert.equal(reports.at(-1).wasPlaying, false)

  a.error = null
  engine.playPause("a")
  a.error = {code: 3}
  a.dispatchEvent(new Event("error"))
  assert.equal(reports.at(-1).wasPlaying, true)
})

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

test("ended waits for the authorized preload to become playable", async t => {
  const {a, b, hint, advances, ends} = booth(t)
  hint(null)
  b.readyState = 1
  a.end()
  assert.equal(ends.length, 0)
  assert.equal(b.plays, 0)
  b.ready()
  b.ready()
  await Promise.resolve()
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

test("rescue cannot play a new preload in place of the outgoing record", async t => {
  const {a, b, hint, engine, advances} = booth(t)
  hint({type: "cut", from_ms: 50_000})
  a.at(50)
  assert.equal(b.plays, 1)
  await Promise.resolve()
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

test("manual fire takes a sequential hint directly even with AUTO off", async t => {
  const {a, b, hint, engine, advances} = booth(t)
  hint(null)
  engine.setAuto(false)
  a.at(22)
  assert.equal(engine.fireHint().ok, true)
  assert.equal(b.plays, 1)
  await Promise.resolve()
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

test("AUTO waits for the DJ to release the armed platter at the end of the other deck", async t => {
  const {engine, a, b, hint, advances} = booth(t)
  hint(null)
  engine.jogTouch("b", true)
  a.end()
  assert.equal(b.plays, 0)
  engine.jogTouch("b", false)
  assert.equal(b.plays, 1)
  await Promise.resolve()
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
  await Promise.resolve()
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

test("a manual LOAD distinguishes a silent gap from a session waiting for its next record", t => {
  const {engine, a, b, hint, breath, ends} = booth(t)
  const third = {id: "three", src: "three", bpm: 120}
  hint(null)
  b.readyState = 1
  a.end()
  assert.equal(engine.loadDeck("a", third), false)
  engine.stopAll()
  assert.equal(engine.loadDeck("a", {id: "one", src: "one"}, {autoplay: true}), true)
  hint(breath)
  b.ready()
  assert.equal(engine.loadDeck("a", third), false)
  a.end()
  assert.equal(engine.loadDeck("a", third), true)
  assert.equal(engine.snapshot().breather.fromTrackId, "one")
  engine.clearHint()
  assert.deepEqual(ends, [{trackId: "one"}])
  assert.equal(engine.snapshot().a.trackId, "three")
})

for (const method of ["LOAD", "set preload"]) {
  test(`replacing the outgoing record via ${method} turns off its echo light immediately`, t => {
    const lights = []
    const {engine, a, b, hint, tick} = booth(t, {echoState: ({on}) => lights.push(on)})
    hint(null)
    assert.equal(engine.fireManual("echo").ok, true)
    engine.playPause("a")
    assert.deepEqual(lights, [true])
    if (method === "LOAD") {
      assert.equal(engine.loadDeck("a", {id: "three", src: "three"}), true)
    } else {
      assert.equal(hint(null, "three"), "a")
    }
    assert.deepEqual(lights, [true, false])
    tick(12_000)
    assert.deepEqual(lights, [true, false])
    assert.equal(a.paused, true)
    assert.equal(b.paused, false)
  })
}

test("a browser without output selection cannot confirm a switch to the controller", async t => {
  const {engine} = booth(t)
  await assert.rejects(engine.setOutputDevice("numark"))
})

test("unplugging and reconnecting the four-channel output rewires the PFL during playback", t => {
  const modes = []
  const {a, engine} = booth(t, {cueMode: ({mode}) => modes.push(mode)})
  const {ctx} = engine
  engine.togglePfl("b")
  const changeChannels = count => {
    ctx.destination.maxChannelCount = count
    ctx.dispatchEvent(new Event("sinkchange"))
  }
  t.after(() => { ctx.destination.maxChannelCount = 2 })
  changeChannels(4)
  assert.equal(ctx.destination.channelCount, 4)
  changeChannels(2)
  assert.equal(ctx.destination.channelCount, 2)
  changeChannels(4)
  assert.equal(ctx.destination.channelCount, 4)
  assert.deepEqual(modes, ["stereo", "quad", "stereo", "quad"])
  assert.deepEqual(engine.pflState(), {a: false, b: true})
  assert.equal(a.paused, false)
})

for (const type of ["fade", "filter", "lowpass", "echo", "bass_swap", "brake"]) {
  test(`a loop prepared on the outgoing record survives ${type} cleanup`, t => {
    const {engine, a, b, hint, tick} = booth(t)
    hint(null)
    assert.equal(engine.fireManual(type).ok, true)
    if (!a.paused) engine.playPause("a")
    engine.cueTo("a", 1250)
    engine.beatLoop("a", 2)
    tick(12_000)
    tick(1000)
    assert.deepEqual(engine.loopState("a"), {on: true, startMs: 1250, endMs: 2250, beats: 2})
    assert.equal(a.paused, true)
    assert.equal(b.paused, false)
    assert.equal(engine.loadDeck("a", {id: "fresh", src: "fresh"}), true)
    assert.equal(engine.loopState("a").on, false)
  })
}

test("AUTO fits its crossfade to the section remaining after a prepared hot cue", t => {
  const {engine, a, b, tick} = booth(t)
  engine.armHint({
    track: {id: "next", src: "next", markers: [{type: "cue", ms: 6000}]},
    transition: {type: "crossfade", from_ms: 48_000, to_ms: 0},
  })
  engine.cueTo("b", 4000)
  a.at(48)
  assert.equal(b.currentTime, 4)
  tick(1900)
  assert.equal(a.paused, false)
  tick(400)
  assert.equal(a.paused, true)
  assert.equal(b.paused, false)
})

for (const playing of [false, true]) {
  test(`a hot cue moves the scratch pattern and its ${playing ? "playing" : "paused"} release point`, async t => {
    const {engine, b, tick} = await scratchBooth(t, "pad-record")
    engine.loadDeck("b", {id: "pad-record", src: "pad-record"}, {autoplay: playing})
    engine.cueTo("b", 1250)
    assert.equal(engine.startAutoScratch("b", "baby").ok, true)
    engine.cueTo("b", 4000)
    assert.equal(engine.scratchPosSec("b"), 4)
    tick(50)
    assert.ok(Math.abs(engine.scratchPosSec("b") - 4) < 0.2)
    engine.stopAutoScratch("b")
    assert.equal(b.currentTime, 4)
    assert.equal(b.paused, !playing)
  })
}

function preparePassage(rig, kind = "blend") {
  const {engine, hint} = rig
  hint({type: "echo", from_ms: 42_000, to_ms: 0})
  const pair = {from: "a", to: "b", fromLoad: engine.decks.a.loadToken, toLoad: engine.decks.b.loadToken}
  return engine.armPassage(pair, {outgoing: {duration: 60}, incoming: {duration: 60}, outStart: 45, lead: 3, inStart: 2.5, blend: 2}, kind)
}

test("arming reserves the pair without touching either transport, even at the AUTO boundary", t => {
  const rig = booth(t)
  const {a, b, engine, advances} = rig
  const initial = engine.snapshot()
  assert.equal(preparePassage(rig).ok, true)
  a.at(43)
  assert.equal(engine.snapshot().xfadePos, initial.xfadePos)
  assert.equal(engine.snapshot().auto, true)
  assert.equal(b.currentTime, 0)
  assert.equal(b.plays, 0)
  assert.deepEqual(advances, [])
  assert.equal(engine.fireHint().ok, false)
  assert.equal(engine.fireManual("cut").ok, false)
  a.at(49)
  assert.equal(engine.confirmPassage().ok, false)
  assert.equal(a.currentTime, 49)
  assert.equal(b.plays, 0)
  a.end()
  assert.equal(b.plays, 0)
  assert.deepEqual(rig.ends.map(e => e.trackId), ["one"])
})

test("only confirmation lets the saved entry and overlap take the room at the outgoing point", async t => {
  const rig = booth(t)
  const {a, b, engine, advances} = rig
  preparePassage(rig)
  a.at(40)
  assert.equal(engine.confirmPassage().ok, true)
  assert.equal(engine.confirmPassage().ok, false)
  a.at(47.95)
  assert.equal(b.plays, 0)
  assert.equal(a.currentTime, 47.95)
  a.at(48)
  await Promise.resolve()
  assert.equal(b.plays, 1)
  assert.equal(b.currentTime, 2.5)
  assert.equal(a.currentTime, 48)
  assert.deepEqual(advances.map(x => [x.deck, x.origin, x.type]), [["b", "rehearsal", "blend"]])
  rig.tick(1950)
  assert.equal(a.paused, false)
  rig.tick(100)
  assert.equal(a.paused, true)
  assert.equal(b.paused, false)
  assert.equal(engine.snapshot().auto, true)
})

test("discard and replacement invalidate a confirmed passage with AUTO off", t => {
  const rig = booth(t)
  const {a, b, engine, advances} = rig
  engine.setAuto(false)
  for (const replace of [false, true]) {
    a.at(40)
    preparePassage(rig, "cut")
    assert.equal(engine.confirmPassage().ok, true)
    if (replace) engine.loadDeck("b", {id: "another", src: "another"})
    else engine.disarmPassage()
    a.at(48)
    rig.tick(1000)
    assert.equal(b.plays, 0)
    assert.equal(engine.passage(), null)
  }
  assert.deepEqual(advances, [])
})

test("late, rejected or cancelled starts leave the outgoing record playing and never take the room", async t => {
  const rig = booth(t)
  const {engine, a, b, advances, tick} = rig
  for (const action of ["late", "reject", "disarm"]) {
    let start, reject
    b.play = () => new Promise((yes, no) => { start = yes; reject = no })
    a.at(40)
    assert.ok(preparePassage(rig).ok)
    engine.confirmPassage()
    a.at(48)
    if (action === "disarm") engine.disarmPassage()
    if (action === "late") { a.at(49); tick(1000) }
    if (action === "reject") reject(new Error("media error"))
    else start()
    await Promise.resolve()
    tick(3000)
    assert.equal(a.paused, false, action)
    assert.equal(engine.snapshot().xfadePos, 0, action)
    assert.deepEqual(advances, [], action)
    engine.disarmPassage()
  }
})

test("a rehearsed cut works from B to A and ignores the transition-length knob", async t => {
  const {engine, a, b, advances, tick} = booth(t)
  engine.stopAll()
  engine.loadDeck("b", {id: "two", src: "two"}, {autoplay: true})
  engine.loadDeck("a", {id: "one", src: "one"})
  const pair = {from: "b", to: "a", fromLoad: engine.decks.b.loadToken, toLoad: engine.decks.a.loadToken}
  assert.ok(engine.armPassage(pair, {outgoing: {duration: 60}, incoming: {duration: 60}, outStart: 10, lead: 3, inStart: 1.25, blend: 2}, "cut").ok)
  engine.setTransitionLength(15)
  engine.confirmPassage()
  b.at(13)
  b.at(13)
  await Promise.resolve()
  assert.equal(a.currentTime, 1.25)
  tick(7)
  assert.equal(b.paused, false)
  tick(1)
  assert.equal(b.paused, true)
  assert.deepEqual(advances.map(e => [e.deck, e.type]), [["a", "cut"]])
})


test("live edits withdraw the confirmation without losing either saved deck mix", async t => {
  const rig = booth(t)
  const {engine, a, b, tick, advances} = rig
  preparePassage(rig)
  const {pair, plan} = engine.passage()
  const out = {...engine.deckMix("a"), vinyl: true, rate: 1.1, level: 0.6, tone: 0.4}
  const into = {...engine.deckMix("b"), vinyl: true, rate: 0.9, level: 0.25, filter: -0.5}
  assert.ok(engine.armPassage(pair, {...plan, mix: {out, into}}, "cut").ok)
  assert.equal(a.playbackRate, 1)
  assert.equal(engine.decks.b.gain.gain.value, 1)
  assert.ok(engine.confirmPassage().ok)
  engine.setDeckLevel("b", 0.8)
  assert.equal(engine.passage().phase, "armed")
  assert.equal(engine.passage().plan.mix.into.level, 0.25)
  tick(49_000)
  assert.equal(b.plays, 0)
  assert.ok(engine.confirmPassage().ok)
  a.at(48)
  await Promise.resolve()
  assert.equal(advances.length, 1)
  assert.equal(a.playbackRate, 1.1)
  assert.equal(b.playbackRate, 0.9)
  assert.equal(b.preservesPitch, false)
  assert.equal(engine.decks.a.toneBass.gain.value, -3.6)
  assert.equal(engine.decks.b.gain.gain.value, 0.25)
  assert.deepEqual(engine.deckMix("b"), into)
  engine.setTone("b", -1)
  assert.equal(engine.deckMix("b").tone, -1)
})


test("reopening a confirmed version only withdraws its authorization when the draft is edited", t => {
  const rig = booth(t)
  preparePassage(rig)
  const saved = rig.engine.passage()
  rig.engine.confirmPassage()
  assert.equal(saved.phase, "confirmed")
  rig.engine.editPassageMix()
  assert.equal(rig.engine.passage(), saved)
  assert.equal(saved.phase, "armed")
  assert.equal(saved.review, "draft")
  rig.a.at(48)
  rig.tick(3000)
  assert.equal(rig.b.plays, 0)
})

for (const action of ["pitch", "vinyl", "jog", "loop", "pause", "destroy"]) {
  test(action + " takes ownership from the rehearsed record at the audible position", async t => {
    const rig = booth(t)
    const {engine, a, b, tick} = rig
    preparePassage(rig, "cut")
    engine.confirmPassage()
    a.at(48)
    await Promise.resolve()
    const deck = engine.decks.b
    assert.ok(deck.entry)
    engine.ctx.currentTime += 0.8
    assert.equal(b.currentTime, 2.5)
    const heard = deck.positionMs() / 1000
    if (action === "pitch") engine.setRate("b", 1.06)
    if (action === "vinyl") engine.setVinylMode("b", true)
    if (action === "jog") engine.jogTouch("b", true)
    if (action === "loop") {
      engine.beatLoop("b", 1)
      engine.ctx.currentTime += 0.52
      tick(20)
    }
    if (action === "pause") engine.pauseAll()
    if (action === "destroy") engine.destroy()
    assert.equal(deck.entry, null)
    assert.equal(deck.mediaGain.gain.value, 1)
    assert.ok(Math.abs(b.currentTime - heard - (action === "loop" ? 0.02 : 0)) < 0.001)
  })
}

test("the rehearsed record owns its natural end, even if the native ended event arrives twice", async t => {
  const rig = booth(t)
  const {engine, a, b, ends, tick} = rig
  const create = engine.ctx.createBufferSource.bind(engine.ctx)
  let incoming
  t.mock.method(engine.ctx, "createBufferSource", () => (incoming = create()))
  preparePassage(rig, "cut")
  engine.confirmPassage()
  a.at(48)
  await Promise.resolve()
  tick(20)
  b.end()
  assert.deepEqual(ends, [])
  incoming.onended()
  b.end()
  assert.deepEqual(ends.map(event => event.trackId), ["two"])
})

test("the next AUTO window follows the audible recording when the muted media clock stalls", async t => {
  const rig = booth(t)
  const {engine, a, b, tick, hint, advances} = rig
  preparePassage(rig, "cut")
  engine.confirmPassage()
  a.at(48)
  await Promise.resolve()
  tick(20)
  hint({type: "cut", from_ms: 32_000, to_ms: 0}, "three")
  b.seeking = true
  engine.ctx.currentTime += 30
  tick(250)
  await Promise.resolve()
  assert.deepEqual(advances.map(x => x.toTrackId), ["two", "three"])
})

for (const action of ["crossfader", "touch outgoing", "touch incoming", "nudge outgoing", "seek incoming", "cue incoming", "cue outgoing"]) {
  test(action + " withdraws an old confirmation and keeps the recorded choice", async t => {
    const rig = booth(t)
    const {engine, a, b, tick, advances} = rig
    engine.setAuto(false)
    preparePassage(rig)
    const saved = engine.passage()
    assert.ok(engine.confirmPassage().ok)
    a.at(40)
    if (action === "crossfader") engine.setCrossfader(0.5)
    if (action.startsWith("touch")) {
      const deck = action.endsWith("incoming") ? "b" : "a"
      engine.jogTouch(deck, true)
      engine.jogTouch(deck, false)
    }
    if (action === "nudge outgoing") engine.jogTurn("a", 1)
    if (action === "seek incoming") engine.jogTurn("b", 1)
    if (action.startsWith("cue")) {
      const deck = action.endsWith("incoming") ? "b" : "a"
      engine.cueButton(deck, true)
      engine.cueButton(deck, false)
      if (deck === "a") engine.playPause(deck)
    }
    assert.equal(engine.passage(), saved)
    assert.equal(saved.phase, "armed")
    a.at(48)
    tick(100)
    await Promise.resolve()
    assert.deepEqual(advances, [])
    assert.equal(b.paused, true)
    assert.ok(engine.confirmPassage().ok)
    await Promise.resolve()
    assert.equal(advances.length, 1)
    assert.equal(b.currentTime, 2.5)
  })
}

test("one MIDI step of fader or pitch chatter keeps the confirmation until movement accumulates", async t => {
  const rig = booth(t)
  const {engine, a, advances} = rig
  preparePassage(rig)
  engine.confirmPassage()
  for (const step of [1, 0, 1]) {
    engine.setCrossfader(step / 127, 1 / 127)
    engine.setRate("b", 1 + step * .4 / 126, .4 / 126)
    assert.equal(engine.passage().phase, "confirmed")
  }
  engine.setCrossfader(2 / 127, 1 / 127)
  assert.equal(engine.passage().phase, "armed")
  engine.confirmPassage()
  engine.setRate("b", 1 + 2 * .4 / 126, .4 / 126)
  assert.equal(engine.passage().phase, "armed")
  a.at(48)
  await Promise.resolve()
  assert.deepEqual(advances, [])
})

test("a repeated MIDI position during decoder startup cannot unmute or cancel the saved entry", async t => {
  const rig = booth(t)
  const {engine, a, b, advances} = rig
  let started
  b.play = () => new Promise(done => { started = done })
  preparePassage(rig)
  engine.confirmPassage()
  a.at(48)
  for (const step of [0, 1, 0]) engine.setCrossfader(step / 127, 1 / 127)
  assert.equal(engine.passage().phase, "starting")
  started()
  await Promise.resolve()
  assert.equal(advances.length, 1)
})

test("the next playing notification cannot undo a manual takeover during decoder startup", async t => {
  const rig = booth(t)
  const {engine, a, b, advances} = rig
  let started
  b.play = () => new Promise(done => { started = done })
  preparePassage(rig)
  engine.confirmPassage()
  a.at(48)
  engine.setCrossfader(0.4)
  started()
  await Promise.resolve()
  assert.equal(engine.passage().phase, "armed")
  assert.deepEqual(advances, [])
  assert.equal(engine.snapshot().xfadePos, 0.4)
})

test("CUE past the rehearsed exit leaves the record paused at its cue and the saved passage missed", async t => {
  const rig = booth(t)
  const {engine, a, b, tick, advances} = rig
  preparePassage(rig)
  const saved = engine.passage()
  engine.decks.a.cueMs = 49_000
  assert.ok(engine.confirmPassage().ok)
  a.at(40)
  engine.cueButton("a", true)
  assert.equal(engine.confirmPassage().ok, false)
  engine.cueButton("a", false)
  tick(20_000)
  await Promise.resolve()
  assert.equal(a.paused, true)
  assert.equal(a.currentTime, 49)
  assert.equal(engine.passage(), saved)
  assert.equal(saved.phase, "missed")
  assert.equal(saved.plan.inStart, 2.5)
  assert.equal(engine.confirmPassage().ok, false)
  assert.equal(b.plays, 0)
  assert.deepEqual(advances, [])
})

test("the screen still accepts precise crossfader and pitch changes within one MIDI step", t => {
  const rig = booth(t)
  const {engine} = rig
  preparePassage(rig)
  assert.ok(engine.confirmPassage().ok)
  engine.setCrossfader(0.002)
  assert.equal(engine.snapshot().xfadePos, 0.002)
  assert.equal(engine.passage().phase, "armed")
  assert.ok(engine.confirmPassage().ok)
  engine.setRate("b", 1.001)
  assert.equal(engine.deckMix("b").rate, 1.001)
  assert.equal(engine.passage().phase, "armed")
})

test("confirmation schedules the saved blend at the same gain heard on headphones", async t => {
  const {a, b, engine, hint} = booth(t)
  hint({type: "echo", from_ms: 42_000, to_ms: 0})
  const pair = {from: "a", to: "b", fromLoad: engine.decks.a.loadToken, toLoad: engine.decks.b.loadToken}
  const curve = {correlation: 0, outPeak: .2, inPeak: .25}
  const plan = {outgoing: {duration: 60}, incoming: {duration: 60}, outStart: 45, lead: 3, inStart: 2.5, blend: 2, blendCurve: curve}
  assert.equal(engine.armPassage(pair, plan, "blend").ok, true)
  engine.editPassageMix()
  assert.equal(engine.passage().plan.blendCurve, curve)
  assert.equal(engine.confirmPassage().ok, true)
  const ramps = [], midpoint = engine.ctx.currentTime + 1
  t.mock.method(Param.prototype, "linearRampToValueAtTime", function(value, time) { ramps.push([value, time]); this.value = value })
  a.at(48)
  await Promise.resolve()
  assert.equal(b.plays, 1)
  const middle = ramps.filter(([gain, time]) => time === midpoint && Math.abs(gain - Math.SQRT1_2) < 1e-6)
  assert.equal(middle.length, 2)
})

test("a manual echo after arming keeps the heard blend saved until the tail clears", t => {
  const rig = booth(t)
  const {engine} = rig
  preparePassage(rig)
  const {pair, plan} = engine.passage()
  const heard = {...plan, blendCurve: {correlation: 0, outPeak: .2, inPeak: .25}}
  assert.equal(engine.armPassage(pair, heard, "blend").ok, true)
  assert.equal(engine.confirmPassage().ok, true)
  engine.setEchoSend("a", .5)
  assert.equal(engine.passage().phase, "armed")
  assert.equal(engine.passage().plan, heard)
  assert.equal(engine.confirmPassage().ok, false)
  engine.setEchoSend("a", 0)
  assert.equal(engine.confirmPassage().ok, false)
  engine.ctx.currentTime += 15
  assert.equal(engine.confirmPassage().ok, true)
})

test("SYNC keeps the rehearsed recording when the effective tempo already matches", async t => {
  const rig = booth(t)
  const {engine, a, b, tick} = rig
  preparePassage(rig, "cut")
  engine.confirmPassage()
  a.at(48)
  await Promise.resolve()
  tick(12)
  const deck = engine.decks.b
  deck.bpm = engine.decks.a.bpm = 120
  const recorded = deck.entry
  assert.ok(recorded)
  engine.ctx.currentTime += 1
  assert.ok(engine.sync("b"))
  assert.equal(deck.entry, recorded)
  assert.equal(deck.mediaGain.gain.value, 0)
  assert.equal(b.currentTime, 2.5)
  assert.equal(deck.positionMs(), 3500)

  engine.decks.a.bpm = 126
  assert.ok(engine.sync("b"))
  assert.equal(deck.entry, null)
  assert.equal(deck.mediaGain.gain.value, 1)
  assert.equal(b.currentTime, 3.5)
  assert.equal(b.playbackRate, 1.05)
})
