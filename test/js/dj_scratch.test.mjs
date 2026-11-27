import test from "node:test"
import assert from "node:assert/strict"
import vm from "node:vm"
import {SCRATCH_WORKLET} from "../../assets/js/dj/scratch.js"

function loadRecord(sampleRate, toneHz) {
  let Processor
  vm.runInNewContext(SCRATCH_WORKLET, {sampleRate, AudioWorkletProcessor: class { port = {} },
    registerProcessor(_, type) { Processor = type }})
  const scratch = new Processor()
  const send = data => scratch.port.onmessage({data})
  const pcm = Float32Array.from({length: sampleRate * 3}, (_, i) => .7 * Math.sin(2 * Math.PI * toneHz * i / sampleRate))
  send({type: "load", pcm})
  return {scratch, send}
}

function stroke(sampleRate) {
  const {scratch, send} = loadRecord(sampleRate, 55)
  const block = new Float32Array(Math.round(.01 * sampleRate))
  let power = 0, count = 0
  for (let step = 0; step < 120; step++) {
    const t = step / 100
    const pos = 1 + Math.min(t, .7) - Math.max(0, Math.min(t - .7, .28))
    if (step <= 98) send({type: "scrub", position: pos * sampleRate, t: 1000 * t})
    scratch.process([], [[block]])
    if (step >= 30 && step < 70) {
      for (const s of block) power += s * s
      count += block.length
    }
  }
  return {db: 10 * Math.log10(power / count), position: scratch.x / sampleRate}
}

test("the same hand movement preserves low end and the held record position across sound-card rates", () => {
  const reference = stroke(48000)
  for (const rate of [24000, 44100, 96000]) {
    const actual = stroke(rate)
    assert.ok(Math.abs(actual.db - reference.db) < .15, rate + " Hz changed the bass level")
    assert.ok(Math.abs(actual.position - reference.position) < .001, rate + " Hz moved the held record")
  }
})

function quarterTurnHz(direction, {timestampStep = 0, batchSize = 1, clockScale = 1} = {}) {
  const sampleRate = 48000
  const {scratch, send} = loadRecord(sampleRate, 220)
  const samples = new Float32Array(sampleRate * .18)
  const tickSeconds = 1.8 / 236
  let tick = 0
  for (let offset = 0; offset < samples.length; offset += 128) {
    const now = offset * 1000 / sampleRate
    while (tick <= 59 && Math.ceil(tick / batchSize) * batchSize * 2.5 <= now) {
      const t = tick * 2.5
      const stamp = timestampStep ? Math.floor(t / timestampStep) * timestampStep : t
      send({type: "scrub", position: (1.5 + direction * tick * tickSeconds) * sampleRate, t: stamp * clockScale})
      tick++
    }
    scratch.process([], [[samples.subarray(offset, offset + 128)]])
  }
  // Count periods in the middle of the sweep, after the needle has picked up speed.
  const crossings = []
  for (let i = sampleRate * .05; i < sampleRate * .115; i++) {
    if (samples[i] < 0 && samples[i + 1] >= 0) {
      crossings.push(i - samples[i] / (samples[i + 1] - samples[i]))
    }
  }
  return sampleRate * (crossings.length - 1) / (crossings.at(-1) - crossings[0])
}

test("a fast quarter turn plays at the hand's pitch in both directions", () => {
  // 59 ticks in 147.5 ms = 1/4 of the DJ2GO2 wheel = 450 ms of record.
  for (const direction of [-1, 1]) {
    const measuredHz = quarterTurnHz(direction)
    assert.ok(Math.abs(measuredHz - 671.19) < 35, direction + " gave " + measuredHz + " Hz")
  }
})

test("fast timestamped sweeps survive batched or millisecond-rounded MIDI delivery", () => {
  for (const timestampStep of [0, 1]) {
    const measuredHz = quarterTurnHz(1, {timestampStep, batchSize: 4})
    assert.ok(Math.abs(measuredHz - 671.19) < 35, timestampStep + " ms gave " + measuredHz + " Hz")
  }
})

test("a batch of unreadable intervals is as restrained as coincident input timestamps", () => {
  const frozen = quarterTurnHz(1, {timestampStep: 1000, batchSize: 4})
  const jitter = quarterTurnHz(1, {clockScale: .01, batchSize: 4})
  assert.ok(frozen > 0 && frozen < 671.19)
  assert.equal(jitter, frozen)
})
