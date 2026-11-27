import test from "node:test"
import assert from "node:assert/strict"
import {pulseSync} from "../../assets/js/dj/deck_mix.js"

test("the private pulse ratio only offers an attainable rate for one beat against two", () => {
  assert.deepEqual(pulseSync(1, 133.81, 66.98), {factor: 2, bpm: 133.96, rate: 133.96 / 133.81})
  assert.deepEqual(pulseSync(1, 76.4, 155.76), {factor: .5, bpm: 77.88, rate: 77.88 / 76.4})
  for (const [bpm, target] of [[100, 184], [100, 216], [100, 46], [100, 54]]) {
    assert.ok(pulseSync(1, bpm, target), "both ends of the ±8% reach are inclusive")
  }
  for (const [bpm, target] of [[100, 100], [100, 112], [100, 150], [100, 183.99],
    [100, 216.01], [100, 54.01], [100, 45.99], [100, 400], [0, 120], [120, null], [120, Infinity]]) {
    assert.equal(pulseSync(1, bpm, target), null)
  }
})
