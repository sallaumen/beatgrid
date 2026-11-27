import assert from "node:assert/strict"
import test from "node:test"
import {headphoneOutput, separateOutputs, unlockOutputNames} from "../../assets/js/dj/outputs.js"

const outputs = [
  {deviceId: "default", groupId: "speakers"},
  {deviceId: "pa", groupId: "speakers"},
  {deviceId: "phones", groupId: "usb"},
]

test("the room and headphone stream must have distinct stereo outputs", () => {
  assert.equal(separateOutputs("pa", "pa", outputs), false)
  assert.equal(separateOutputs("", "pa", outputs), false)
  assert.equal(separateOutputs("pa", "default", outputs), false)
  assert.equal(separateOutputs("", "phones", outputs), true)
  assert.equal(separateOutputs("phones", "pa", outputs), true)
  assert.equal(separateOutputs("phones", "missing", outputs), false)
})

test("an unidentified default cannot be used to establish a private headphone route", () => {
  const unnamed = outputs.map(output => ({...output, groupId: ""}))
  assert.equal(separateOutputs("", "phones", unnamed), false)
  assert.equal(separateOutputs("pa", "phones", unnamed), true)
})

test("listing outputs releases a microphone granted after the device-list timeout", async t => {
  t.mock.timers.enable({apis: ["setTimeout"]})
  const permission = Promise.withResolvers()
  const listed = unlockOutputNames({getUserMedia: () => permission.promise})
  t.mock.timers.tick(3000)
  await listed

  const stopped = []
  permission.resolve({getTracks: () => [1, 2].map(id => ({stop: () => stopped.push(id)}))})
  await Promise.resolve()
  assert.deepEqual(stopped, [1, 2])
})

for (const alias of ["default", "communications"]) {
  test(`the ${alias} headphone choice is pinned before Bluetooth can fall back to the room`, () => {
    for (const [room, phones] of [["pa", "bt"], ["bt", "pa"]]) {
      const listed = [{deviceId: alias, groupId: phones}, ...[room, phones].map(id => ({deviceId: id, groupId: id}))]
      assert.equal(separateOutputs(room, alias, listed), false, "a moving sink cannot carry private audio")
      const sink = headphoneOutput(room, alias, listed)
      assert.equal(sink, phones)
      listed[0].groupId = room
      assert.equal(separateOutputs(room, sink, listed), true)
      assert.equal(headphoneOutput(room, alias, listed), null)
    }
  })
}

test("headphone aliases require a unique named endpoint in their physical group", () => {
  const alias = {deviceId: "default", groupId: "usb"}
  const room = {deviceId: "pa", groupId: "speakers"}
  const phones = {deviceId: "bt", groupId: "usb"}
  assert.equal(headphoneOutput("pa", "default", [room, alias]), null)
  assert.equal(headphoneOutput("pa", "default", [room, alias, phones, {...phones, deviceId: "usb-2"}]), null)
  assert.equal(headphoneOutput("pa", "default", [room, {...alias, groupId: ""}, {...phones, groupId: ""}]), null)
  assert.equal(headphoneOutput("pa", "bt", [room, phones]), "bt")
})
