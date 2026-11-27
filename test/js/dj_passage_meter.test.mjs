import test from "node:test"
import assert from "node:assert/strict"
import vm from "node:vm"
import {METER_PROCESSOR} from "../../assets/js/dj/passage_meter.js"

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
