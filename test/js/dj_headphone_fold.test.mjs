import assert from "node:assert/strict"
import test from "node:test"
import {prepareHeadphoneFold, scheduleHeadphoneFold} from "../../assets/js/dj/headphone_fold.js"

const sampleRate = 24000
function recording(signal) {
  const data = [new Float32Array(sampleRate), new Float32Array(sampleRate)]
  for (let i = 0; i < sampleRate; i++) {
    const a = 0.7 * Math.cos(2 * Math.PI * 440 * i / sampleRate)
    const b = 0.5 * Math.sin(2 * Math.PI * 733 * i / sampleRate)
    const [left, right] = signal(a, b, i / sampleRate)
    data[0][i] = left
    data[1][i] = right
  }
  return {sampleRate, numberOfChannels: 2, getChannelData: i => data[i], data}
}

function schedule(signal, offset = 0, duration = 1, rate = 1) {
  const buffer = recording(signal)
  const parameter = () => ({
    events: [],
    setValueAtTime(gain, time) { this.events.push([gain, time]) },
    linearRampToValueAtTime(gain, time) { this.events.push([gain, time]) }
  })
  const left = parameter(), right = parameter()
  scheduleHeadphoneFold(left, right, buffer, 4, offset, duration, rate)
  return {left: left.events, right: right.events}
}

test("one ear folds both stereo channels within peak headroom and keeps isolated sources audible", () => {
  for (const [signal, gains] of [
    [(a) => [a, a], [0.5, 0.5]], [(a) => [a, -a], [0.5, -0.5]],
    [(a) => [a, 0], [1, 0]], [(a) => [0, a], [0, 1]],
    [(a, b) => [a, b], [0.5, 0.5]]
  ]) {
    const {left, right} = schedule(signal)
    assert.deepEqual([left[0][0], right[0][0]], gains)
    assert.equal(left[0][1], 4)
    assert.equal(right[0][1], 4)
  }
})

test("reversing polarity crosses through one unchanged channel without a gain jump", () => {
  const {left, right} = schedule((a, _b, t) => [a, t < 0.413 ? a : -a])
  const middle = left.findIndex(([gain, t]) => gain === 1 && Math.abs(t - 4.413) < 0.001)
  assert.ok(middle > 0)
  assert.equal(right[middle][0], 0)
  assert.deepEqual([left.at(-1)[0], right.at(-1)[0]], [0.5, -0.5])
  left.forEach(([coefficient, t], index) => {
    assert.ok(Math.abs(coefficient) + Math.abs(right[index][0]) <= 1.000001)
    if (index > 0) assert.ok(t >= left[index - 1][1])
  })
})

test("a cue and playback rate describe record time for the scheduled fold", () => {
  const {left, right} = schedule((a, _b, t) => t < 0.6 ? [0, a] : [a, 0], 0.4, 0.4, 1.25)
  assert.deepEqual([left[0][0], right[0][0]], [0, 1])
  assert.deepEqual([left.at(-1)[0], right.at(-1)[0]], [1, 0])
  assert.ok(Math.abs(left.at(-1)[1] - 4.16) < 0.045)
})

test("replaying and adjusting pitch use the profile already built while decoding the track", () => {
  const buffer = recording((a, _b, t) => [a, t < 0.413 ? a : -a])
  prepareHeadphoneFold(buffer, ...buffer.data)
  buffer.getChannelData = () => { throw new Error("reading full-length PCM on a live control") }
  const left = {setValueAtTime() {}, linearRampToValueAtTime() {}}
  for (const rate of [0.92, 1, 1.08]) {
    let first
    const right = {setValueAtTime(value) { first ??= value }, linearRampToValueAtTime() {}}
    scheduleHeadphoneFold(left, right, buffer, 14, 0.65, 0.2, rate)
    assert.equal(first, -0.5)
  }
})
