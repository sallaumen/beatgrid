import assert from "node:assert/strict"
import test from "node:test"
import {planRehearsal} from "../../assets/js/dj/rehearsal.js"
import {observeRoomPassage} from "../../assets/js/dj/passage_meter.js"

const fullPlan = {lead: 3, blend: 2, duration: 7, mix: {out: {rate: 1.05}}}

function booth(positionMs = 8000, kind = "blend", plan = fullPlan) {
  const ctx = {currentTime: 10}, input = {}, results = []
  let capture, deliver, cancels = 0
  const choice = {kind, exitMs: 18000, plan}
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

test("the room measures the same excerpt heard in the headphones for every kind and file ending", () => {
  for (const incoming of [{duration: 8}, {duration: 2.3091}]) {
    for (const kind of ["cut", "blend", "bass_swap"]) {
      const plan = planRehearsal({duration: 23}, incoming, 18, 1, 120)
      if (kind === "bass_swap" && !plan.fullBlend) continue
      const b = booth(8000, kind, plan)
      const arrived = 18.25
      b.read.arrive(arrived)
      b.deliver(recording(b.capture))
      const [take] = b.results
      assert.ok(take)
      const fullFrames = Math.floor(plan.duration * 100)
      assert.equal(take.frames.length, fullFrames, kind)
      assert.equal(take.changeAt, plan.lead)
      assert.equal(take.frames.at(-1).time.toFixed(2), (arrived - plan.lead + (fullFrames - 1) / 100).toFixed(2))
    }
  }
})

test("a decoded platter measures the rehearsed sample after the measured room delay", () => {
  const sr = 48000, now = 10, point = 18.00041, head = 8.00017, rate = 1.052
  const target = now + (point - head) / rate, delay = 288 / sr
  const plan = {...fullPlan, exit: point}, choice = {kind: "blend", exitMs: Math.round(point * 1000), plan}
  const deck = {playbackRate: rate, bpm: 110, positionMs: () => Math.round(head * 1000),
    entry: {position: at => head + (at - now) * rate}}
  for (const late of [0, .03465]) {
    let window, deliver, results = []
    const read = observeRoomPassage({currentTime: now, sampleRate: sr}, {}, choice, deck,
      (data, comparable) => results.push({data, comparable}), (ctx, input, w, done) => {
        window = w; deliver = done; return () => {}
      }, delay)
    assert.equal(Math.round(window.start * sr), Math.round((target + delay - 3) * sr))
    const first = Math.round(window.start * sr) / sr
    const measured = recording({...window, start: first})
    deliver(measured)
    assert.equal(results.length, 0)
    read.arrive(target + late)
    assert.equal(results.length, 1)
    assert.equal(results[0].comparable, late === 0)
    assert.equal(results[0].data.frames.length, 700)
    assert.ok(Math.abs(results[0].data.changeAt - 3) <= (late ? .005 : 1 / sr))
  }
})

test("a queued tempo change or late confirmation keeps the guarded room reading", () => {
  const sr = 48000, now = 10
  for (const [head, queuedChange] of [[8.1234, true], [17.9, false]]) {
    const position = at => head + (at - now) + (queuedChange && at > now + .5 ? .120 : 0)
    const plan = {...fullPlan, exit: 18.0004}
    const choice = {kind: "cut", exitMs: 18000, plan}
    const deck = {playbackRate: 1, bpm: 120, positionMs: () => Math.round(head * 1000), entry: {position}}
    let window
    observeRoomPassage({currentTime: now, sampleRate: sr}, {}, choice, deck, () => {},
      (_ctx, _input, w) => { window = w; return () => {} }, .006)
    assert.equal(window.start, Math.max(now, now + (18000 - deck.positionMs()) / 1000 - 4))
  }
})

test("a late opening still measures the music it heard without comparing it to the complete headphones", () => {
  const ctx = {currentTime: 1, sampleRate: 48000}
  const choice = {kind: "cut", exitMs: 10000, plan: {...fullPlan, exit: 10}}
  const deck = {playbackRate: 1, bpm: 120, positionMs: () => 1000, entry: {position: at => at}}
  let capture, deliver, result
  const read = observeRoomPassage(ctx, {}, choice, deck, (value, comparable) => { result = {value, comparable} },
    (_clock, _bus, window, done) => { capture = window; deliver = done; return () => {} }, .006)
  const first = capture.start + .024
  read.arrive(10)
  deliver(recording({...capture, start: first}))
  assert.equal(result.comparable, false)
  assert.equal(result.value.frames.length, 697)
  assert.ok(Math.abs(result.value.changeAt - 2.976) < 1e-6)
})
