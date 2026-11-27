import assert from "node:assert/strict"
import {test} from "node:test"
import {analyzeCuePair, copyCueWindow} from "../../assets/js/dj/cue_phase.js"

function audio({sampleRate = 12000, duration = 26, delay = 0, bpm = 120, type = "beats", antiphase = false} = {}) {
  const n = Math.round(sampleRate * duration), channels = [new Float32Array(n), new Float32Array(n)]
  for (let i = 0; i < n; i++) {
    const time = i / sampleRate
    const period = 60 / bpm / (type === "eighths" ? 2 : 1)
    const since = ((time - 0.1 - delay) % period + period) % period
    const kick = Math.exp(-27 * since) * Math.sin(2 * Math.PI * (54 * since + 0.85 * (1 - Math.exp(-50 * since))))
    const strike = Math.exp(-180 * since) * Math.sin(4600 * Math.PI * since)
    const tone = .025 * Math.sin(570 * Math.PI * time)
    const sample = type === "silence" ? 0 : type === "sine" ? tone : tone + .5 * kick + .16 * strike
    channels[0][i] = sample
    channels[1][i] = antiphase ? -sample : sample
  }
  return {sampleRate, duration, length: n, numberOfChannels: 2, getChannelData: i => channels[i],
    copyFromChannel(target, i, start) {target.set(channels[i].subarray(start, start + target.length))}}
}
const beat = audio()
const clip = (buffer, cue, bpm = 120, rate = 1) => copyCueWindow(buffer, cue, bpm, rate)
const run = (out, into) => analyzeCuePair({out, into})

test("a cue suggestion refers to the original incoming file in both directions", () => {
  for (const delta of [0.125, -0.125]) {
    const candidate = run(clip(beat, 15.1), clip(beat, 15.1 - delta))
    assert.ok(Math.abs(candidate.entry - 15.1) < 0.01)
    assert.ok(Math.abs(candidate.recordDelta - delta) < 0.01)
  }
})

test("changing speed reports the audible shift separately from record time", () => {
  const fast = audio({bpm: 132}), period = 60 / 132
  const anchor = 0.1 + 33 * period
  const candidate = run(clip(beat, 15.1), clip(fast, anchor - period / 4, 132, 120 / 132))
  assert.ok(Math.abs(candidate.recordDelta - period / 4) < 0.012)
  assert.ok(Math.abs(candidate.wallDelta - 0.125) < 0.012)
})

test("empty, already aligned, half-beat, subdivision and competing octave evidence give no advice", () => {
  const out = clip(beat, 15.1)
  for (const into of [clip(beat, 15.1), clip(beat, 14.85), clip(audio({type: "eighths"}), 15),
    clip(audio({type: "silence"}), 15), clip(audio({type: "sine"}), 15), clip(beat, 14.975, 120, 1.1)]) assert.equal(run(out, into), null)
  assert.equal(run(clip(beat, 15.1, 240), clip(beat, 14.88, 240)), null)
})

test("48 kHz antiphase stereo uses private bounded copies at the ends of the record", () => {
  const stereo = audio({sampleRate: 48000, antiphase: true}), into = audio({sampleRate: 48000, delay: .125})
  const localChannel = stereo.getChannelData(0)
  stereo.getChannelData = () => assert.fail("The render buffer must only receive bounded copyFromChannel reads")
  const a = clip(stereo, 25.1), b = clip(into, .1)
  assert.ok(Math.abs(run(a, b).recordDelta - .125) < .012)
  assert.ok(a.channels[0].length < 12.6 * 48000)
  assert.notEqual(a.channels[0].buffer, localChannel.buffer)
  assert.equal(run(a, clip(audio({delay: -.125}), .01)), null)
  assert.equal(clip(beat, 26), null)
  assert.equal(clip(audio({duration: 7}), 1), null)
})

test("the dedicated worker receives private slices and a cancelled result cannot reach the draft", async t => {
  const {startCueAnalysis} = await import("../../assets/js/dj/cue_analysis.js")
  const workers = []
  class Worker {
    constructor(url) { this.url = url; workers.push(this) }
    postMessage(data, transfer) { this.data = structuredClone(data, {transfer}) }
    terminate() { this.terminated = true }
  }
  const originalWorker = globalThis.Worker
  globalThis.Worker = Worker
  t.after(() => { if (originalWorker) globalThis.Worker = originalWorker; else delete globalThis.Worker })
  const original = beat.getChannelData(0)
  const tracks = {out: {buffer: beat, cue: 15.1, bpm: 120, rate: 1},
    into: {buffer: beat, cue: 14.975, bpm: 120, rate: 1}}
  let result = "waiting"
  const cancel = startCueAnalysis(tracks, value => {result = value})
  const [worker] = workers
  const url = await (await fetch(worker.url)).text()
  const replies = []
  const scope = {postMessage: data => replies.push(data)}
  new Function("self", url)(scope)
  scope.onmessage({data: worker.data})
  assert.ok(Math.abs(replies[0].entry - 15.1) < .01)
  assert.equal(original.byteLength, beat.length * 4)
  const late = worker.onmessage
  cancel()
  late({data: replies[0]})
  assert.equal(worker.terminated, true)
  assert.equal(result, "waiting")
})
