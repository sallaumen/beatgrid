import assert from "node:assert/strict"
import test from "node:test"
import {loadPeaks} from "../../assets/js/dj/waveform.js"

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
