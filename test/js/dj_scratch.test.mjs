import test from "node:test"
import assert from "node:assert/strict"
import vm from "node:vm"
import {SCRATCH_WORKLET} from "../../assets/js/dj/scratch.js"

function stroke(sampleRate) {
  let Processor
  vm.runInNewContext(SCRATCH_WORKLET, {sampleRate, AudioWorkletProcessor: class { port = {} },
    registerProcessor(_, type) { Processor = type }})
  const scratch = new Processor()
  const send = data => scratch.port.onmessage({data})
  const pcm = Float32Array.from({length: sampleRate * 3}, (_, i) => .7 * Math.sin(2 * Math.PI * 55 * i / sampleRate))
  send({type: "load", pcm})
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
