import assert from "node:assert/strict"
import test from "node:test"
import {audioDecodeFailed, loadPeaks, getScratchPcm, mountDeckWave, retainScratch} from "../../assets/js/dj/waveform.js"

function audioFixture(t, left, right, sampleRate) {
  const fetch = t.mock.method(globalThis, "fetch", async () => new Response(new ArrayBuffer(0)))
  const ctx = {decodeAudioData: async () => ({
    duration: left.length / sampleRate, sampleRate, numberOfChannels: 2,
    getChannelData: channel => channel === 0 ? left : right
  })}
  return {ctx, fetch}
}

test("short transients and the last samples land in their actual time bucket", async t => {
  const left = new Float32Array(101), right = new Float32Array(101)
  right[1] = -0.75
  left[100] = 0.5
  const {ctx} = audioFixture(t, left, right, 101)
  const {peaks} = await loadPeaks("percussion", "/percussion", ctx)
  assert.equal(peaks[0], 0.75)
  assert.equal(peaks[49], 0.5)
})

test("a later waveform request retries a failed track and clears its error", async t => {
  const samples = new Float32Array(800)
  const {ctx, fetch} = audioFixture(t, samples, samples, 8000)
  fetch.mock.mockImplementationOnce(async () => new Response(null, {status: 503}))
  await assert.rejects(loadPeaks("retry-wave", "/retry", ctx))
  assert.equal(audioDecodeFailed("retry-wave"), true)
  await loadPeaks("retry-wave", "/retry", ctx)
  assert.equal(audioDecodeFailed("retry-wave"), false)
  assert.ok(getScratchPcm("retry-wave"))
  assert.equal(fetch.mock.callCount(), 2)
})

test("returning to a track restores scratch PCM and shares one decode between decks", async t => {
  const samples = Float32Array.of(0.5)
  const {ctx, fetch} = audioFixture(t, samples, samples, 8000)
  for (const id of ["record", "b", "c", "d", "e"]) await loadPeaks(id, id, ctx)
  assert.equal(getScratchPcm("record"), null)
  const [a, b] = await Promise.all([loadPeaks("record", "record", ctx), loadPeaks("record", "record", ctx)])
  assert.equal(a, b)
  assert.deepEqual(getScratchPcm("record"), samples)
  assert.equal(fetch.mock.callCount(), 6)
})

test("browsing on the idle platter keeps the other platter scratchable until it is released", async t => {
  const owner = {}
  const samples = Float32Array.of(1)
  const {ctx} = audioFixture(t, samples, samples, 8000)
  retainScratch(owner, "on-air")
  t.after(() => retainScratch(owner, null))
  await loadPeaks("on-air", "on-air", ctx)
  for (let n = 0; n < 6; n++) await loadPeaks("preview" + n, "preview", ctx)
  assert.deepEqual(getScratchPcm("on-air"), samples)
  retainScratch(owner, null)
  await loadPeaks("replacement", "replacement", ctx)
  assert.equal(getScratchPcm("on-air"), null)
})

test("the scratch recording keeps opposite-polarity and one-sided instruments at their natural level", async t => {
  const sr = 8000
  const note = Float32Array.from({length: sr}, (_, i) => Math.sin(2 * Math.PI * i * 93 / sr) * 0.6)
  const silent = new Float32Array(sr)
  for (const [name, left, right] of [
    ["opposed", note, note.map(v => -v)], ["left", note, silent], ["right", silent, note],
    ["dual", note, note], ["reversal", note, note.map((v, i) => i < 3304 ? v : -v)]
  ]) {
    const {ctx, fetch} = audioFixture(t, left, right, sr)
    await loadPeaks("scratch-" + name, name, ctx)
    fetch.mock.restore()
    const pcm = getScratchPcm("scratch-" + name)
    assert.ok(Math.max(...pcm) <= 0.601, name + " overflow")
    for (const i of [47, 1151, 5131, 7253]) assert.ok(Math.abs(pcm[i] - note[i]) < 0.001, name + " lost its note")
    if (name === "reversal") {
      const step = Math.max(...pcm.slice(3250, 3360).map((v, j) => Math.abs(v - pcm[j + 3249])))
      assert.ok(step < 0.06, "switching phase should not click")
    }
  }
})

test("quick changes on the idle deck release downloads after its last owner moves on", async t => {
  const live = {}, idle = {}
  t.after(() => { retainScratch(live, null); retainScratch(idle, null) })
  const gate = Promise.withResolvers()
  let decodes = 0
  const ctx = {decodeAudioData: async () => {
    decodes++
    return {duration: .001, sampleRate: 8000, numberOfChannels: 1, getChannelData: () => new Float32Array(8)}
  }}
  const requests = []
  t.mock.method(globalThis, "fetch", async (url, {signal} = {}) => {
    requests.push({url, signal})
    await gate.promise
    signal?.throwIfAborted()
    return new Response(new ArrayBuffer(1))
  })
  retainScratch(live, "quick-live")
  const liveAudio = loadPeaks("quick-live", "quick-live", ctx)
  retainScratch(idle, "quick-live")
  const shared = loadPeaks("quick-live", "quick-live", ctx)
  const pending = []
  for (let i = 0; i < 12; i++) {
    const id = "quick-idle-" + i
    retainScratch(idle, id)
    pending.push(loadPeaks(id, id, ctx).then(() => "ready", error => error.name))
  }
  gate.resolve()
  const results = await Promise.all(pending)
  assert.deepEqual(results, [...Array(11).fill("AbortError"), "ready"])
  assert.equal(await liveAudio, await shared)
  assert.equal(decodes, 2)
  assert.equal(requests.filter(request => request.signal.aborted).length, 11)
})

test("an abandoned decode cannot touch its audio buffer or evict a newly loaded copy", async t => {
  const owner = {}
  t.after(() => retainScratch(owner, null))
  const begun = Promise.withResolvers(), result = Promise.withResolvers()
  t.mock.method(globalThis, "fetch", async () => new Response(new ArrayBuffer(0)))
  retainScratch(owner, "revisited-during-decode")
  const old = loadPeaks("revisited-during-decode", "old", {decodeAudioData() { begun.resolve(); return result.promise }})
    .then(() => "ready", error => error.name)
  await begun.promise
  retainScratch(owner, null)
  retainScratch(owner, "revisited-during-decode")
  const fresh = {duration: .001, sampleRate: 8000, numberOfChannels: 1, getChannelData: () => new Float32Array(8)}
  const replacement = loadPeaks("revisited-during-decode", "new", {decodeAudioData: async () => fresh})
  let abandonedReads = 0
  result.resolve({...fresh, getChannelData() { abandonedReads++; return new Float32Array(8) }})
  assert.equal(await old, "AbortError")
  await replacement
  assert.equal(abandonedReads, 0)
  assert.ok(getScratchPcm("revisited-during-decode"))
})

test("a parked platter keeps its drawing until a visible input or the canvas changes", () => {
  let paints = 0
  const ctx = {clearRect() { paints++ }, beginPath() {}, moveTo() {}, lineTo() {}, stroke() {}, fillRect() {}, fill() {}, closePath() {}, fillText() {}}
  const canvas = Object.assign(new EventTarget(), {clientWidth: 80, clientHeight: 16, getContext: () => ctx})
  const wave = mountDeckWave(canvas)
  wave.resize(2)
  let state = {entry: {peaks: Float32Array.of(0.3), bps: 50, durationS: 10}, posS: 2,
    windowS: 16, bpm: 105, gridPhaseMs: 0, markers: [], loop: {on: false}, accent: "#ffb020", playing: false}
  const paint = () => wave.draw({...state, loop: {...state.loop}})
  paint()
  paint()
  wave.resize(2)
  paint()
  assert.equal(paints, 1)

  for (const change of [
    {posS: 2.004}, {bpm: 107}, {windowS: 17}, {markers: [{ms: 1000, type: "cue"}]},
    {gridPhaseMs: 20}, {fireMs: 3500}, {loop: {on: true, startMs: 2000, endMs: 2400}},
    {loop: {on: true, startMs: 2010, endMs: 2400}}, {loop: {on: true, startMs: 2010, endMs: 2800}},
    {loop: {on: false}}, {entry: {...state.entry}}, {accent: "#5ad1a0"}
  ]) {
    const before = paints
    state = {...state, ...change}
    paint()
    paint()
    assert.equal(paints, before + 1)
  }

  const before = paints
  for (let i = 0; i < 6; i++) {
    state = {...state, playing: true, posS: 3 + i / 60}
    paint()
  }
  state = {...state, playing: false}
  paint()
  paint()
  assert.equal(paints, before + 7)

  canvas.clientWidth = 240
  wave.resize(2)
  canvas.clientWidth = 80
  wave.resize(2)
  paint()
  assert.equal(canvas.width, 160)
  assert.equal(paints, before + 8)
  canvas.dispatchEvent(new Event("contextrestored"))
  paint()
  assert.equal(paints, before + 9)
  wave.destroy()
})
