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
