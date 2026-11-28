import assert from "node:assert/strict"
import test from "node:test"
import {prepareCompressorDelay, measuredCompressorDelay} from "../../assets/js/dj/compressor_delay.js"

test("the room delay is measured once per live context, away from the room even if measurement fails", async t => {
  let renders = 0, latency = 384, fail = false
  class OfflineProbe {
    constructor(channels, length, rate) { this.length = length; this.sampleRate = rate }
    createBuffer(_, length = this.length) { const data = new Float32Array(length); return {getChannelData: () => data} }
    createBufferSource() {
      return this.source = {set buffer(value) { this.samples = value.getChannelData(0).slice() }, connect() {}, start() {}}
    }
    createDynamicsCompressor() { return {connect() {}} }
    async startRendering() {
      renders++
      if (fail) throw Error("unavailable")
      const samples = this.createBuffer()
      const out = samples.getChannelData(0)
      out.set(this.source.samples.subarray(0, out.length - latency), latency)
      return samples
    }
  }
  const original = Object.getOwnPropertyDescriptor(globalThis, "OfflineAudioContext")
  Object.defineProperty(globalThis, "OfflineAudioContext", {value: OfflineProbe, configurable: true})
  t.after(() => {
    if (original) Object.defineProperty(globalThis, "OfflineAudioContext", original)
    else delete globalThis.OfflineAudioContext
  })
  const ac = {sampleRate: 48000}
  assert.equal(measuredCompressorDelay(ac), null)
  await Promise.all([prepareCompressorDelay(ac), prepareCompressorDelay(ac)])
  assert.equal(measuredCompressorDelay(ac), 384 / 48000)
  assert.equal(renders, 1)
  fail = true
  const other = {sampleRate: 96000}
  await prepareCompressorDelay(other)
  assert.equal(measuredCompressorDelay(other), null)
  assert.equal(measuredCompressorDelay(ac), .008)
})
