import assert from "node:assert/strict"
import test from "node:test"
import {hotCues} from "../../assets/js/dj/hot_cues.js"

test("pads expose four different positions and prefer the DJ's label on a shared beat", () => {
  const markers = [
    {ms: 8000, type: "outro", source: "auto"}, {ms: 8000, label: "Virada"},
    {ms: -10}, {ms: 0}, {ms: 16000}, {ms: 20000}, {ms: 24000}
  ]
  const pads = hotCues(markers)
  assert.deepEqual(pads.map(m => m.ms), [0, 8000, 16000, 20000])
  assert.equal(pads[1].label, "Virada")
  assert.equal(markers[0].type, "outro")
})

test("pads only recall positions inside the loaded audio, including its last millisecond", () => {
  const markers = [0, 7950, 7999, 8000, 12000].map(ms => ({ms}))
  assert.deepEqual(hotCues(markers, 8000).map(m => m.ms), [0, 7950, 7999])
  assert.deepEqual(hotCues(markers, 0), [])
})
