import test from "node:test"
import assert from "node:assert/strict"
import {updateComparisonChoice} from "../../assets/js/dj/rehearsal_choices.js"

function chooser(value) {
  return {value, options: ["cut", "blend", "bass_swap"].map(value => ({value}))}
}

test("the second headphone take is explicit, distinct and keeps the operator's valid choice", () => {
  const select = chooser("blend")
  updateComparisonChoice(select, "cut", true)
  assert.equal(select.value, "blend")
  assert.deepEqual(select.options.filter(o => !o.disabled).map(o => o.value), ["blend", "bass_swap"])
  select.value = "bass_swap"
  updateComparisonChoice(select, "blend", true)
  assert.equal(select.value, "bass_swap")
  updateComparisonChoice(select, "bass_swap", true)
  assert.equal(select.value, "blend")
  assert.ok(select.options.find(o => o.value === "bass_swap").hidden)
})

test("a short window keeps the original one-click pair and omits the unavailable bass comparison", () => {
  const select = chooser("bass_swap")
  updateComparisonChoice(select, "blend", false)
  assert.equal(select.value, "cut")
  assert.deepEqual(select.options.filter(o => !o.hidden).map(o => o.value), ["cut"])
  updateComparisonChoice(select, "cut", false)
  assert.equal(select.value, "blend")
})
