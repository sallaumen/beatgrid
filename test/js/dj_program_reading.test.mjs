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
