import test from "node:test"
import assert from "node:assert/strict"
import {createRecordSource} from "../../assets/js/dj/record_source.js"

test("locked tempo keeps the pitch, stereo polarity and intended duration at both pitch extremes", () => {
  const sr = 24000, hz = 330
  const ctx = {currentTime: 0, createGain: () => ({connect() {}, disconnect() {}}),
    createBuffer(n, length) {
      const channels = Array.from({length: n}, () => new Float32Array(length))
      return {sampleRate: sr, duration: length / sr, length, numberOfChannels: n, getChannelData: i => channels[i]}
    }, createBufferSource() {
      return {playbackRate: {}, connect() {}, disconnect() {}, stop() {}, start(at) { chunks.push([at, this]) }}
    }}
  const chunks = []
  const input = ctx.createBuffer(2, sr * 4)
  for (let i = 0; i < input.length; i++) {
    input.getChannelData(0)[i] = Math.sin(2 * Math.PI * i * hz / sr)
    input.getChannelData(1)[i] = -input.getChannelData(0)[i]
  }
  for (const rate of [0.8, 1.2]) {
    chunks.length = 0
    const source = createRecordSource(ctx, input, {rate, vinyl: false})
    source.start(0, 0.25, 3)
    let crossings = 0, n = 0, last = 0, ends = 0
    source.onended = () => ends++
    for (const [at, voice] of chunks) {
      const [l, r] = [0, 1].map(i => voice.buffer.getChannelData(i))
      assert.ok(Math.abs(at - n / sr) < 0.001)
      for (let i = 0; i < l.length; i++) {
        if (l[i] > 0 && last <= 0) crossings++
        assert.ok(Math.abs(l[i] + r[i]) < 0.0001)
        last = l[i]
      }
      n += l.length
      voice.onended()
    }
    assert.ok(Math.abs(n / sr - 3 / rate) < 0.001)
    assert.ok(Math.abs(crossings * sr / n - hz) < 2)
    assert.equal(ends, 1)
  }
})
