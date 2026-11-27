import assert from "node:assert/strict"
import test from "node:test"
import {observeRoomPassage} from "../../assets/js/dj/passage_meter.js"

function booth() {
  const ctx = {currentTime: 10}, input = {}, results = []
  let capture, deliver, cancels = 0
  const choice = {kind: "blend", exitMs: 18000, plan: {lead: 3, blend: 2, mix: {out: {rate: 1.05}}}}
  const deck = {bpm: 110, positionMs: () => 8000, el: {playbackRate: 1.25}}
  const read = observeRoomPassage(ctx, input, choice, deck, value => results.push(value), (clock, bus, window, report) => {
    assert.equal(clock, ctx)
    assert.equal(bus, input)
    capture = window
    deliver = report
    return () => { cancels++ }
  })
  return {read, capture, results, get cancels() { return cancels }, deliver: data => deliver(data)}
}

test("the program reading grades the actual handoff on the audio clock, after the master", () => {
  const b = booth()
  assert.equal(b.capture.change, 18)
  assert.equal(b.capture.start, 15)
  assert.equal(b.capture.overlap, 2)
  assert.equal(b.capture.bpm, 115.5)
  b.read.arrive(18.08)
  b.deliver({changeAt: 3, frames: [{}], frameSeconds: 0.01})
  assert.ok(Math.abs(b.results[0].changeAt - 3.08) < 1e-6)
})

test("abandoned and missed transitions never publish the scheduled window as a live reading", () => {
  const b = booth()
  b.deliver({changeAt: 3})
  assert.deepEqual(b.results, [])
  const canceled = booth()
  canceled.read.cancel()
  canceled.read.arrive(18)
  canceled.deliver({changeAt: 3})
  assert.deepEqual(canceled.results, [])
  assert.equal(canceled.cancels, 1)
})

test("a stall cannot turn unrelated audio into a room reading", () => {
  const b = booth()
  b.read.arrive(20)
  b.deliver({changeAt: 3})
  assert.deepEqual(b.results, [null])
})

test("drafting after confirmation releases the room tap and keeps the armed plan", async () => {
  const {createPassage} = await import("../../assets/js/dj/passage.js")
  const a = {loadToken: 1, positionMs: () => 0, el: {playbackRate: 1}}, b = {loadToken: 2}
  const observed = []
  const p = createPassage({a, b}, () => true, () => assert.fail("too early"), {
    confirmed: take => observed.push(["confirmed", take]),
    abandoned: take => observed.push(["abandoned", take])
  })
  p.arm({from: "a", to: "b", fromLoad: 1, toLoad: 2}, {exit: 20}, "cut")
  const armed = p.current()
  assert.deepEqual(observed, [])
  try {
    p.confirm()
    p.mixChanged("draft")
    assert.equal(p.current(), armed)
    assert.equal(armed.phase, "armed")
    assert.equal(armed.review, "draft")
    assert.deepEqual(observed, [["confirmed", armed], ["abandoned", armed]])
  } finally { p.disarm() }
})
