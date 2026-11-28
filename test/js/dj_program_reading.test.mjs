import assert from "node:assert/strict"
import test from "node:test"
import {createProgramMeter} from "../../assets/js/dj/passage_meter.js"

test("the room keeps only the latest handoff, anchors on its audio clock and releases its tap", async t => {
  const instances = []
  class Meter {
    port = {sent: [], postMessage(value) { this.sent.push(value) }, close() { this.closed = true }}
    constructor(_, name, options) { this.options = options; instances.push(this) }
    disconnect() { this.closed = true }
  }
  const previous = globalThis.AudioWorkletNode
  globalThis.AudioWorkletNode = Meter
  t.after(() => { if (previous) globalThis.AudioWorkletNode = previous; else delete globalThis.AudioWorkletNode })
  const ctx = {currentTime: 10, audioWorklet: {addModule: async () => {}}}
  const input = {connect() {}, disconnect() {}}, history = createProgramMeter(ctx, input)
  const readings = []
  await history.start()
  await history.start()
  assert.equal(instances.length, 1)
  const tap = instances[0]
  assert.equal(tap.options.numberOfOutputs, 0)
  history.read("cut", .008, 120, x => readings.push(x))
  const first = tap.port.sent.at(-1)
  ctx.currentTime = 12
  history.read("blend", 6, 125, x => readings.push(x))
  const second = tap.port.sent.at(-1)
  assert.ok(second.start < 12 && second.end > 18)
  const deliver = (request, count = Math.ceil((request.end - request.start) * 100)) =>
    tap.port.onmessage({data: {id: request.id, first: request.start,
      frames: new Float32Array(3 * count), frameSeconds: .01}})
  deliver(first)
  assert.deepEqual(readings, [])
  deliver(second)
  assert.equal(readings[0].kind, "blend")
  assert.equal(readings[0].changeAt, 12 - second.start)
  assert.equal(readings[0].overlap, 6)
  assert.equal(readings[0].bpm, 125)
  history.read("cut", .24, 120, x => readings.push(x))
  const third = tap.port.sent.at(-1)
  history.cancel()
  deliver(third)
  assert.equal(readings.length, 1)
  history.read("cut", .008, 120, x => readings.push(x))
  deliver(tap.port.sent.at(-1), 120)
  assert.equal(readings.at(-1), null, "a missing tail must never supply a score")
  const staleError = tap.onprocessorerror
  history.stop()
  await history.start()
  ctx.currentTime = 2
  history.read("cut", .008, 120, x => readings.push(x))
  assert.equal(instances[1].port.sent.length, 0, "four full seconds of outgoing audio are required")
  ctx.currentTime = 20
  history.read("cut", .008, 120, x => readings.push(x))
  staleError()
  assert.equal(instances[1].closed, undefined, "an error from the old route cannot retire its replacement")
  history.stop()
  assert.equal(tap.port.closed, true)
  assert.equal(tap.closed, true)
})

test("a route removed during registration never connects a tap to the old output", async t => {
  const previous = globalThis.AudioWorkletNode
  globalThis.AudioWorkletNode = class { constructor() { assert.fail("stale processor") } }
  t.after(() => { if (previous) globalThis.AudioWorkletNode = previous; else delete globalThis.AudioWorkletNode })
  const gate = Promise.withResolvers()
  const ctx = {audioWorklet: {addModule: () => gate.promise}}, input = {connect() { assert.fail("stale input") }}
  const history = createProgramMeter(ctx, input)
  const opening = history.start()
  await Promise.resolve()
  history.stop()
  gate.resolve()
  await opening
  let reading
  history.read("cut", .008, 120, data => { reading = data })
  assert.equal(reading, null)
})

test("room peak changes survive a score request and clear immediately when its route closes", async t => {
  let tap
  const previous = globalThis.AudioWorkletNode
  globalThis.AudioWorkletNode = class {
    port = {postMessage() {}, close() {}}
    constructor(_, name, options) { tap = this; this.options = options }
    disconnect() {}
  }
  t.after(() => { if (previous) globalThis.AudioWorkletNode = previous; else delete globalThis.AudioWorkletNode })
  const shown = [], readings = []
  const ctx = Object.assign(new EventTarget(), {state: "running", currentTime: 10, audioWorklet: {addModule: async () => {}}})
  const history = createProgramMeter(ctx, {connect() {}, disconnect() {}}, db => shown.push(db))
  await history.start()
  assert.equal(tap.options.processorOptions.monitorPeak, true)
  const first = tap.port.onmessage
  history.read("cut", .01, 120, result => readings.push(result))
  first({data: {peakDbtp: 1.2}})
  first({data: {peakDbtp: .4}})
  history.cancel()
  assert.deepEqual(readings, [])
  assert.deepEqual(shown, [1.2, .4])
  history.stop()
  history.stop()
  await history.start()
  first({data: {peakDbtp: 2.1}})
  assert.deepEqual(shown, [1.2, .4, null], "late packets from the former room must stay silent")
  tap.port.onmessage({data: {peakDbtp: .1}})
  ctx.state = "interrupted"
  ctx.dispatchEvent(new Event("statechange"))
  tap.port.onmessage({data: {peakDbtp: 2.1}})
  assert.deepEqual(shown, [1.2, .4, null, .1, null], "an interrupted audio clock cannot keep or replay an old warning")
  ctx.state = "running"
  ctx.dispatchEvent(new Event("statechange"))
  tap.port.onmessage({data: {peakDbtp: .1}})
  tap.onprocessorerror()
  assert.deepEqual(shown, [1.2, .4, null, .1, null, .1, null])
})
