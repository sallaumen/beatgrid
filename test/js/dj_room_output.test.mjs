import test from "node:test"
import assert from "node:assert/strict"
import {watchRoomOutput} from "../../assets/js/dj/outputs.js"

const device = id => ({deviceId: id, label: id.toUpperCase()})
const inventory = (...ids) => ids.map(device)

function rig(id = "usb") {
  const changes = [], ctx = {sinkId: id, state: "running", setSinkId() {}, async resume() { this.state = "running" }}
  const route = watchRoomOutput(ctx, available => changes.push(available))
  route.observe(inventory("default", "communications", "usb", "bt"))
  return {route, ctx, changes}
}

for (const [old, next] of [["usb", "bt"], ["bt", "usb"]]) {
  test(`a missing ${old} needs an explicit destination, even after reconnection`, async () => {
    const {ctx, route, changes} = rig(old)
    ctx.state = "suspended"
    route.observe(inventory("default", "communications", next))
    route.observe(inventory("default", next))
    assert.equal(route.missing.deviceId, old)
    assert.deepEqual(changes, [false])
    route.observe(inventory("default", old, next))
    assert.equal(route.missing.deviceId, old)
    assert.equal(ctx.state, "suspended")
    ctx.sinkId = next
    assert.equal(await route.selected(next, route.choice()), true)
    assert.deepEqual(changes, [false, true])
    assert.equal(ctx.state, "running")
    assert.equal(route.missing, null)
  })
}

test("a rejected, vanished or superseded resume cannot release the saved passage", async () => {
  const {ctx, route, changes} = rig()
  route.interrupt()
  ctx.state = "suspended"
  ctx.sinkId = "bt"
  ctx.resume = async () => { throw Error("driver unavailable") }
  assert.equal(await route.selected("bt", route.choice()), false)
  const pending = Promise.withResolvers()
  ctx.resume = () => pending.promise
  const first = route.selected("bt", route.choice())
  route.choice()
  ctx.state = "running"; pending.resolve()
  assert.equal(await first, false)
  route.observe(inventory("usb", "default"))
  assert.equal(await route.selected("bt", route.choice()), false)
  assert.deepEqual(changes, [false])
})

test("without a proven physical room, aliases and unsupported browsers keep their existing behavior", () => {
  for (const id of ["", "default", "communications"]) {
    const {route, changes} = rig(id)
    route.observe([]); route.interrupt()
    assert.equal(route.missing, null)
    assert.deepEqual(changes, [])
  }
  const ctx = {sinkId: "usb"}
  const route = watchRoomOutput(ctx, () => assert.fail("unsupported"))
  route.observe(inventory("usb")); route.observe([]); route.interrupt()
  assert.equal(route.missing, null)
})

test("an unexpected default sink does not replace the chosen PA before the device list catches up", async () => {
  const {ctx, route, changes} = rig()
  ctx.sinkId = ""
  route.observe(inventory("default", "usb", "bt"))
  route.observe(inventory("default", "bt"))
  assert.equal(route.missing?.deviceId, "usb")
  assert.deepEqual(changes, [false])
  assert.equal(await route.selected("", route.choice()), true)
  assert.deepEqual(changes, [false, true])
})
