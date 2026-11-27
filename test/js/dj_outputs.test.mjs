import assert from "node:assert/strict"
import test from "node:test"
import {activateHeadphones, headphoneOutput, separateOutputs, unlockOutputNames} from "../../assets/js/dj/outputs.js"

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

for (const [previous, requested] of [["usb", "bluetooth"], ["bluetooth", "usb"]]) {
  test(`a refused move to ${requested} restores the proven ${previous} headphone stream`, async () => {
    const pending = Promise.withResolvers(), stream = {}, attempted = []
    const audio = {
      sinkId: previous, srcObject: null, paused: true,
      async setSinkId(id) { attempted.push(id); await pending.promise; this.sinkId = id },
      pause() { this.paused = true },
      async play() { this.paused = false }
    }
    const changing = activateHeadphones(audio, stream, requested, previous, () => true)
    assert.equal(audio.srcObject, null)
    pending.reject(new Error("device unavailable"))
    assert.equal(await changing, previous)
    assert.equal(audio.srcObject, stream)
    assert.equal(audio.paused, false)
    assert.deepEqual(attempted, [requested])
  })
}

test("a late switch cannot start the cue or restore it onto the new room output", async () => {
  const pending = Promise.withResolvers(), played = []
  const audio = {
    sinkId: "usb", srcObject: null,
    async setSinkId(id) { await pending.promise; this.sinkId = id },
    pause() {},
    async play() { played.push(this.sinkId) }
  }
  let current = true
  const switching = activateHeadphones(audio, {}, "bluetooth", "usb", () => current)
  current = false
  pending.resolve()
  assert.equal(await switching, null)
  assert.equal(audio.srcObject, null)
  assert.deepEqual(played, [])
})

test("a play failure after the sink has changed restores audio only to an available private device", async () => {
  for (const available of [false, true]) {
    const stream = {}, played = []
    const audio = {
      sinkId: "old", srcObject: null,
      async setSinkId(id) { this.sinkId = id },
      pause() {},
      async play() {
        played.push(this.sinkId)
        if (this.sinkId === "new") throw new Error("play rejected")
      }
    }
    const actual = await activateHeadphones(audio, stream, "new", "old", id => id === "new" || available)
    assert.equal(actual, available ? "old" : null)
    assert.deepEqual(played, available ? ["new", "old"] : ["new"])
    assert.equal(audio.srcObject, available ? stream : null)
  }
})
