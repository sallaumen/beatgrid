import assert from "node:assert/strict"
import test from "node:test"
import {decode, isControllerPort} from "../../assets/js/dj/midi_map.js"

test("both tempo faders have exact neutral at the middle and keep their direction", () => {
  for (const [ch, deck] of [[0xb0, "a"], [0xb1, "b"]]) {
    for (const [cc, value] of [[0, 1], [63, 0.5], [64, 0.5], [127, 0]]) {
      assert.deepEqual(decode([ch, 9, cc]), {type: "pitch", deck, value})
    }
    assert.ok(decode([ch, 9, 62]).value > 0.5)
    assert.ok(decode([ch, 9, 65]).value < 0.5)
    assert.deepEqual(decode([ch, 6, 3]), {type: "jog_turn", deck, delta: 3})
    assert.deepEqual(decode([ch, 6, 64]), {type: "jog_turn", deck, delta: 64})
    assert.deepEqual(decode([ch, 6, 125]), {type: "jog_turn", deck, delta: -3})
  }
})

test("the Touch ports are recognized independently of other connected MIDI devices", () => {
  assert.ok(isControllerPort({name: "Numark DJ2GO2 Touch"}))
  assert.ok(isControllerPort({name: "DJ2GO2 Touch MIDI 1"}))
  assert.equal(isControllerPort({manufacturer: "Numark", name: "Mixtrack Pro"}), false)
  assert.equal(isControllerPort({name: "USB MIDI Keyboard"}), false)
})

test("LOAD and CUE each route presses and both MIDI release encodings to the correct deck", () => {
  for (const [status, note, action] of [
    [0x9f, 2, {type: "load_a"}], [0x9f, 3, {type: "load_b"}],
    [0x90, 1, {type: "cue", deck: "a"}], [0x91, 1, {type: "cue", deck: "b"}]
  ]) {
    assert.deepEqual(decode([status, note, 127]), {...action, pressed: true})
    assert.deepEqual(decode([status, note, 0]), {...action, pressed: false})
    assert.deepEqual(decode([status - 16, note, 64]), {...action, pressed: false})
  }
  for (const value of [0, 64, 127]) {
    assert.deepEqual(decode([0xbf, 8, value]), {type: "crossfader", value: value / 127})
  }
})
