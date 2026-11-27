import assert from "node:assert/strict"
import test from "node:test"
import {observeRoomPassage} from "../../assets/js/dj/passage_meter.js"

function booth(positionMs = 8000) {
  const ctx = {currentTime: 10}, input = {}, results = []
  let capture, deliver, cancels = 0
  const choice = {kind: "blend", exitMs: 18000, plan: {lead: 3, blend: 2, mix: {out: {rate: 1.05}}}}
  const deck = {bpm: 110, positionMs: () => positionMs, playbackRate: 1.25}
  const read = observeRoomPassage(ctx, input, choice, deck, value => results.push(value), (clock, bus, window, report) => {
    assert.equal(clock, ctx)
    assert.equal(bus, input)
    capture = window
    deliver = report
    return () => { cancels++ }
  })
  return {read, capture, results, get cancels() { return cancels }, deliver: data => deliver(data)}
}

// Each frame carries its actual sound-card timestamp so a forecast shift is observable.
function recording(window) {
  const frameSeconds = 0.01
  const frames = Array.from({length: Math.round((window.end - window.start) / frameSeconds)},
    (_, i) => ({time: window.start + i * frameSeconds}))
  return {frames, frameSeconds, changeAt: window.change - window.start}
}

test("the program reading follows the actual handoff and excludes the guard audio", () => {
  for (const drift of [-0.54, 0, 0.54]) {
    const b = booth()
    assert.equal(b.capture.change, 18)
    assert.equal(b.capture.overlap, 2)
    assert.equal(b.capture.bpm, 115.5)
    const arrived = 18 + drift
    b.read.arrive(arrived)
    b.deliver(recording(b.capture))
    const [take] = b.results
    assert.ok(take, "a complete recording with drift " + drift)
    assert.ok(Math.abs(take.changeAt - 3) < 0.001)
    assert.equal(take.frames.length, 700)
    assert.ok(Math.abs(take.frames[0].time - (arrived - 3)) < 0.001)
    assert.ok(Math.abs(take.frames.at(-1).time - (arrived + 3.99)) < 0.001)
  }
})

test("a late confirmation uses the available lead on the sound card", () => {
  for (const startup of [0, 0.03]) {
    const b = booth(17000)
    b.read.arrive(10.8)
    b.deliver(recording({...b.capture, start: b.capture.start + startup}))
    const [take] = b.results
    assert.ok(take)
    assert.ok(Math.abs(take.changeAt - (0.8 - startup)) < 0.001)
    assert.equal(take.frames.length, 480 - Math.round(100 * startup))
  }
})

test("abandoned and missed transitions never publish the scheduled window as a live reading", () => {
  const b = booth()
  b.deliver(recording(b.capture))
  assert.deepEqual(b.results, [])
  const canceled = booth()
  canceled.read.cancel()
  canceled.read.arrive(18)
  canceled.deliver(recording(canceled.capture))
  assert.deepEqual(canceled.results, [])
  assert.equal(canceled.cancels, 1)
})

test("a stall or missing frames cannot turn a partial capture into a room reading", () => {
  for (const arrival of [16, 20]) {
    const b = booth()
    b.read.arrive(arrival)
    b.deliver(recording(b.capture))
    assert.deepEqual(b.results, [null])
  }
  const b = booth()
  b.read.arrive(18.5)
  const truncated = recording(b.capture)
  truncated.frames.length -= 120
  b.deliver(truncated)
  assert.deepEqual(b.results, [null])
})

test("drafting after confirmation releases the room tap and keeps the armed plan", async () => {
  const {createPassage} = await import("../../assets/js/dj/passage.js")
  const a = {loadToken: 1, positionMs: () => 0, playbackRate: 1}, b = {loadToken: 2}
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
