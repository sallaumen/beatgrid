import test from "node:test"
import assert from "node:assert/strict"
import vm from "node:vm"
import {METER_PROCESSOR, measurePassage} from "../../assets/js/dj/passage_meter.js"

test("the meter windows actual stereo samples on the audio clock and sees opposite polarity and digital overs", () => {
  let Meter, data
  const scope = {sampleRate: 1000, currentFrame: 0,
    AudioWorkletProcessor: class { port = {postMessage(value) { data = value }} },
    registerProcessor(_, type) { Meter = type }}
  vm.runInNewContext(METER_PROCESSOR, scope)
  const tap = new Meter({processorOptions: {start: 0.013, end: 0.043}})
  for (let i = 0; i < 3; i++) {
    scope.currentFrame = 16 * i
    const ch = Float32Array.from({length: 16}, (_, j) => scope.currentFrame + j < 23 ? 0 : 1.1)
    assert.equal(tap.process([[ch, ch.map(v => -v)]]), i < 2)
  }
  assert.equal(data.first, 0.013)
  assert.equal(data.frameSeconds, 0.01)
  assert.deepEqual(Array.from(data.frames.subarray(0, 3)), [0, 0, 0])
  assert.ok(Math.abs(data.frames[3] - 1.1) < 1e-5 && data.frames[4] > 1 && data.frames[5] > 0)
  assert.equal(data.frames.length, 9)
})

test("the same audible attack has the same weight on different sound cards", () => {
  // The first 10 ms of a 0.5-amplitude 12 kHz sine on the right. Its stereo RMS
  // is 0.25 and its attack at the meter's reference spacing is sqrt(2) times that.
  const expectedOnset = 0.25 * (1 + 2 * Math.SQRT2)
  for (const sampleRate of [48000, 96000, 44100, 88200, 192000]) {
    let Meter, result
    const scope = {sampleRate, currentFrame: 0, AudioWorkletProcessor: class {
      port = {postMessage(value) { result = value }}
    }, registerProcessor(_, type) { Meter = type }}
    vm.runInNewContext(METER_PROCESSOR, scope)
    const tap = new Meter({processorOptions: {start: 0, end: 0.02}})
    const onsetFrame = sampleRate / 100
    for (let at = 0; at < 2 * onsetFrame; at += 128) {
      scope.currentFrame = at
      const right = Float32Array.from({length: 128}, (_, i) =>
        at + i < onsetFrame ? 0 : 0.5 * Math.sin(2 * Math.PI * 12000 * (at + i - onsetFrame) / sampleRate))
      tap.process([[new Float32Array(128), right]])
    }
    assert.deepEqual(Array.from(result.frames.subarray(0, 3)), [0, 0, 0])
    assert.ok(Math.abs(result.frames[3] - 0.25) < 1e-6, `RMS at ${sampleRate} Hz`)
    assert.ok(Math.abs(result.frames[5] - expectedOnset) < 0.03, `onset ${result.frames[5]} at ${sampleRate} Hz`)
  }
})

test("a final render quantum after transfer cannot publish the same recording twice", () => {
  let Meter
  const messages = []
  const scope = {
    sampleRate: 1000, currentFrame: 0,
    AudioWorkletProcessor: class {
      port = {postMessage(message, transfer) { messages.push(structuredClone(message, {transfer})) }}
    },
    registerProcessor(_, type) { Meter = type }
  }
  vm.runInNewContext(METER_PROCESSOR, scope)
  const tap = new Meter({processorOptions: {start: 0, end: 0.016}})
  const input = [[new Float32Array(16).fill(0.25)]]
  assert.equal(tap.process(input), false)
  scope.currentFrame = 16
  assert.equal(tap.process(input), false)
  assert.equal(tap.process([]), false)
  assert.equal(messages.length, 1)
  assert.equal(messages[0].frames[0], 0.25)
})

test("the program tap keeps a bounded stereo envelope and retrieves only a requested time range", () => {
  let Meter
  const messages = []
  const scope = {
    sampleRate: 1000, currentFrame: 0, AudioWorkletProcessor: class {
      port = {postMessage(message, transfer) { messages.push(structuredClone(message, {transfer})) }}
    }, registerProcessor(_, type) { Meter = type }
  }
  vm.runInNewContext(METER_PROCESSOR, scope)
  const tap = new Meter({processorOptions: {historySeconds: 0.2}})
  function render(from, to) {
    for (let at = from; at < to; at += 10) {
      scope.currentFrame = at
      const s = new Float32Array(10).fill((at / 10) % 4 === 0 ? 0.5 : 0.1)
      assert.equal(tap.process([[s, s.map(v => -v)]]), true)
    }
  }
  render(0, 320)
  assert.equal(messages.length, 0)
  tap.port.onmessage({data: {id: 1, start: .22, end: .36}})
  render(320, 360)
  assert.equal(messages.length, 1)
  assert.equal(messages[0].id, 1)
  assert.equal(messages[0].first, .22)
  assert.equal(messages[0].frameSeconds, .01)
  assert.equal(messages[0].frames.length, 14 * 3)
  for (const [i, peak] of Array.from(messages[0].frames).filter((_,i) => i % 3 === 1).entries()) {
    assert.ok(Math.abs(peak - ((22 + i) % 4 === 0 ? .5 : .1)) < 1e-6)
  }
  tap.port.onmessage({data: {id: 2, start: .1, end: .38}})
  render(360, 400)
  assert.equal(messages[1].frames.length, 0, "overwritten history cannot grade a different phrase")
  tap.port.onmessage({data: {id: 3, start: .34, end: .46}})
  tap.port.onmessage({data: null})
  render(400, 470)
  assert.equal(messages.length, 2)
  tap.port.onmessage({data: "stop"})
  assert.equal(tap.process([]), false)
})

test("both the private and rolling meters see an inter-sample over on either clear stereo channel", () => {
  for (const rolling of [false, true]) for (const channel of [0, 1]) {
    let Meter, result
    const sr = 48000
    const scope = {sampleRate: sr, currentFrame: 0, AudioWorkletProcessor: class {
      port = {postMessage(value) { result = value }}
    }, registerProcessor(_, type) { Meter = type }}
    vm.runInNewContext(METER_PROCESSOR, scope)
    const tap = new Meter({processorOptions: rolling ? {historySeconds: 0.04} : {start: 0, end: 0.12}})
    if (rolling) tap.port.onmessage({data: {id: 1, start: 0.09, end: 0.12}})
    for (let k = 0; k < sr * .12; k += 128) {
      scope.currentFrame = k
      const signal = [new Float32Array(128), new Float32Array(128)]
      for (let i = 0; i < 128; i++) {
        signal[channel][i] = 1.16 * Math.sin(Math.PI / 2 * (k + i + .5))
      }
      tap.process([signal])
    }
    assert.ok(result)
    const sample = Array.from(result.frames).filter((_, i) => i % 3 === 1)
    assert.ok(sample.every(p => p > .81 && p < .83))
    assert.equal(result.truePeaks?.length, sample.length)
    assert.ok(Array.from(result.truePeaks).every(p => 20 * Math.log10(p) > 1.1 && 20 * Math.log10(p) < 1.55))
  }
})

test("only the room announces recent true peaks, coalescing steady overs and clearing after four seconds", () => {
  for (const channel of [0, 1]) {
    let Meter
    const reports = []
    const sampleRate = 48000
    const scope = {sampleRate, currentFrame: 0, AudioWorkletProcessor: class {
      port = {postMessage(value) { reports.push({at: scope.currentFrame / sampleRate, ...value}) }}
    }, registerProcessor(_, type) { Meter = type }}
    vm.runInNewContext(METER_PROCESSOR, scope)
    const tap = new Meter({processorOptions: {historySeconds: 32, monitorPeak: true}})
    const signal = [new Float32Array(128), new Float32Array(128)]
    // Sample peaks stay below 0 dBFS. Only one side has a reconstructed over.
    for (let at = 0; at < sampleRate * 7; at += 128) {
      scope.currentFrame = at
      for (let i = 0; i < 128; i++) signal[channel][i] =
        (.25 + .91 * Math.max(0, Math.min(1, (2 - (at + i) / sampleRate) * 100))) * Math.sin(Math.PI / 2 * (at + i + .5))
      tap.process([signal])
    }
    assert.equal(reports.length, 2, "one warning and one recovery, including sustained overs")
    assert.ok(reports[0].peakDbtp > 1 && reports[0].peakDbtp < 1.6)
    assert.ok(reports[0].at < 0.51)
    assert.equal(reports[1].peakDbtp, null)
    assert.ok(reports[1].at >= 5.9 && reports[1].at < 6.52)
  }
})

test("resuming the room forgets the old warning but preserves the score window and hears another over", () => {
  let Meter
  const messages = []
  const scope = {sampleRate: 1000, currentFrame: 0, AudioWorkletProcessor: class {
    port = {postMessage(value) { messages.push(value) }}
  }, registerProcessor(_, type) { Meter = type }}
  vm.runInNewContext(METER_PROCESSOR, scope)
  const tap = new Meter({processorOptions: {historySeconds: 32, monitorPeak: true}})
  function renderUntil(at, amplitude) {
    while (scope.currentFrame < at) {
      const s = new Float32Array(10).fill(amplitude)
      tap.process([[s]])
      scope.currentFrame += 10
    }
  }
  renderUntil(400, 1.1)
  renderUntil(500, 0)
  assert.ok(messages[0].peakDbtp > 0)
  tap.port.onmessage({data: {id: 2, start: 0, end: .75}})
  tap.port.onmessage({data: "resetPeak"})
  renderUntil(1200, 0)
  assert.equal(messages.length, 2, "nothing from the old room is announced after resume")
  assert.equal(messages[1].id, 2)
  assert.ok(Math.max(...messages[1].truePeaks) > 1, "the pending score preserves its original peaks")
  renderUntil(1600, 1.1)
  assert.ok(messages[2].peakDbtp > 0)
})

test("completed, failed, cancelled and timed-out meters release both callbacks from the audio host", async t => {
  t.mock.timers.enable({apis: ["setTimeout"]})
  let node, closures = 0, reports = 0
  globalThis.AudioWorkletNode = class {
    constructor() {
      node = this
      this.port = {postMessage() {}, close() { closures++ }}
    }
    disconnect() {}
  }
  t.after(() => { delete globalThis.AudioWorkletNode })
  const ctx = {currentTime: 0, audioWorklet: {async addModule() {}}}
  const source = {connect() {}, disconnect() {}}
  for (const end of ["complete", "failed", "cancelled", "timeout"]) {
    const cancel = measurePassage(ctx, source, {start: 0, end: 1}, () => reports++)
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(typeof node.port.onmessage, "function")
    assert.equal(typeof node.onprocessorerror, "function")
    if (end === "complete") node.port.onmessage({data: {first: 0, frames: [1, 1, 1], frameSeconds: .01}})
    if (end === "failed") node.onprocessorerror()
    if (end === "cancelled") cancel()
    if (end === "timeout") t.mock.timers.tick(3001)
    assert.equal(node.port.onmessage, null, end)
    assert.equal(node.onprocessorerror, null, end)
    cancel()
  }
  assert.equal(reports, 3)
  assert.equal(closures, 4)
})
