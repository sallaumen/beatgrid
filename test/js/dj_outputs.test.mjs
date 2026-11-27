import assert from "node:assert/strict"
import test from "node:test"
import {separateOutputs} from "../../assets/js/dj/outputs.js"

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
