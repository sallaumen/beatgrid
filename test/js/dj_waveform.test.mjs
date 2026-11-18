import assert from "node:assert/strict"
import test from "node:test"
import {loadPeaks, getScratchPcm} from "../../assets/js/dj/waveform.js"

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
