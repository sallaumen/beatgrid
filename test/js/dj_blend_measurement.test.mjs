import assert from "node:assert/strict"
import test from "node:test"
import {createBlendReview, measuredBlend, measureBlendCurve} from "../../assets/js/dj/blend_measurement.js"

test("an analysis finishing after a listen or replacement cannot change the chosen curve", async () => {
  let finish, started
  const beginning = new Promise(resolve => { started = resolve })
  const review = createBlendReview(() => { started(); return new Promise(resolve => { finish = resolve }) }, 0)
  const results = []
  review.prepare({}, curve => results.push(curve))
  await beginning
  review.lock()
  finish({correlation: 0, outPeak: .2, inPeak: .2})
  await new Promise(resolve => setTimeout(resolve, 5))
  assert.deepEqual(results, [])
})

test("replacement uses the new deck pair and ignores an older completed render", async () => {
  let finish, started
  const beginning = new Promise(resolve => { started = resolve })
  const review = createBlendReview(id => id === 1
    ? (started(), new Promise(resolve => { finish = resolve }))
    : Promise.resolve({id}), 0)
  const results = []
  review.prepare(1, curve => results.push(curve))
  await beginning
  const ready = new Promise(resolve => review.prepare(2, curve => { results.push(curve); resolve() }))
  finish({id: 1})
  await ready
  assert.deepEqual(results, [{id: 2}])
})

test("short, boosted EQ, muted or stretched windows never start an offline render", async () => {
  const {planRehearsal} = await import("../../assets/js/dj/rehearsal.js")
  const {neutralMix} = await import("../../assets/js/dj/deck_mix.js")
  const buffer = {duration: 8, sampleRate: 48000, numberOfChannels: 2}
  const old = globalThis.OfflineAudioContext
  globalThis.OfflineAudioContext = class { constructor() { throw Error("unexpected render") } }
  try {
    for (const into of [{...neutralMix, level: 0}, {...neutralMix, tone: .2}, {...neutralMix, filter: -.2}, {...neutralMix, rate: 1.04}]) {
      assert.equal(await measureBlendCurve(planRehearsal(buffer, buffer, 3, 0, 120, {out: neutralMix, into})), null)
    }
    assert.equal(await measureBlendCurve(planRehearsal(buffer, buffer, 7.8, 0, 120)), null)
  } finally {
    if (old === undefined) delete globalThis.OfflineAudioContext
    else globalThis.OfflineAudioContext = old
  }
})

test("measured stereo stems protect polarity, near-rail peaks and silent entries", async () => {
  const sr = 48000, frames = sr * 3
  const sine = hz => Float32Array.from({length: frames}, (_, n) => .23 * Math.sin(2 * Math.PI * n * hz / sr))
  const a = sine(223), b = sine(337)
  const plan = {blend: 2, mix: {out: {level: 1}, into: {level: 1}}}
  const measure = tracks => measuredBlend(plan, {sampleRate: sr, getChannelData: i => tracks[i]})
  const good = await measure([a, a, b, b])
  assert.ok(good.correlation < .001)
  assert.ok(good.inPeak >= .229 && good.inPeak < .231)
  assert.equal(await measure([a, a, a, a]), null)
  assert.equal(await measure([a, a, a.map(x => -x), a]), null)
  assert.equal(await measure([a, a, new Float32Array(frames), new Float32Array(frames)]), null)
  const hotA = a.map(x => 4*x), hotB = b.map(x => 4*x)
  assert.equal(await measure([hotA, hotA, hotB, hotB]), null)
  assert.equal(await measuredBlend(plan, {sampleRate: sr, getChannelData: i => [a, a, b, b][i]}, () => false), null)
})
