import assert from "node:assert/strict"
import test from "node:test"
import {mountPassageComparison} from "../../assets/js/dj/passage_comparison.js"
import {neutralMix} from "../../assets/js/dj/deck_mix.js"

const pair = {from: "a", to: "b", fromLoad: 2, toLoad: 7}
const plan = {exit: 32, inStart: 4, lead: 3, duration: 7, blend: 2, mix: {out: neutralMix, into: neutralMix}}
const result = score => ({score, summary: "Leitura", metrics: []})

function setup(kinds = ["cut", "blend"]) {
  const events = [], labels = kinds.map(kind => ({dataset: {scoreFor: kind}}))
  const details = {
    clear() { events.push(["clear"]) },
    listening() { events.push(["listening"]) },
    show(value, options) { events.push(["show", value, options]) }
  }
  let selected = "cut"
  const view = mountPassageComparison(details, labels, () => selected)
  view.bind(pair, plan, 120)
  return {view, labels, events, select(kind) { selected = kind; view.select() }}
}

test("changing kind and headphone side retains each completed score, including unscored audio", () => {
  const {view, labels, events, select} = setup()
  const cut = result(0), blend = result(null)
  view.begin("cut").finish(cut)
  assert.deepEqual(labels.map(n => n.textContent), ["0/100", "Falta ouvir"])
  select("blend")
  assert.deepEqual(events.at(-1), ["clear"])
  view.begin("blend").finish(blend)
  assert.deepEqual(labels.map(n => n.textContent), ["0/100", "Sem nota"])
  select("cut")
  assert.deepEqual(events.at(-1), ["show", cut, {restored: true}])
  select("cut") // panning changes the monitor destination only
  assert.equal(labels[1].textContent, "Sem nota")
})

test("current take wins once; cancelling a repeat keeps the previous result", () => {
  const {view, labels, events} = setup()
  const first = result(80)
  view.begin("cut").finish(first)
  const late = view.begin("cut")
  late.cancel()
  assert.deepEqual(events.at(-1), ["show", first, {restored: true}])
  const current = view.begin("cut")
  late.finish(result(100))
  late.cancel()
  assert.deepEqual(events.at(-1), ["listening"])
  current.finish(result(65))
  current.finish(result(100))
  assert.equal(labels[0].textContent, "65/100")
  view.begin("cut").unavailable()
  assert.equal(labels[0].textContent, "65/100")
  const [, kept, options] = events.at(-1)
  assert.equal(kept.score, 65)
  assert.match(kept.summary, /anterior/)
  assert.equal(options.announcement, kept.summary)
  assert.equal(options.restored, true)
})

test("new mixes, deck loads, directions, timing and tempo drop both readings and reject late work", () => {
  const changes = [
    [{...pair, fromLoad: 3}, plan, 120], [{...pair, toLoad: 8}, plan, 120],
    [{...pair, from: "b", to: "a"}, plan, 120], [pair, plan, 126],
    ...["inStart", "exit", "blend", "lead", "duration"].map(key => [pair, {...plan, [key]: plan[key] + 0.2}, 120]),
    ...["out", "into"].flatMap(side =>
      Object.keys(neutralMix).map(key => {
        const next = key === "vinyl" ? !neutralMix[key] : neutralMix[key] + 0.03
        return [pair, {...plan, mix: {...plan.mix, [side]: {...neutralMix, [key]: next}}}, 120]
      })
    )
  ]
  for (const change of changes) {
    const {view, labels, select} = setup()
    view.begin("cut").finish(result(80))
    select("blend")
    view.begin("blend").finish(result(65))
    const late = view.begin("blend")
    view.bind({...pair}, structuredClone(plan), 120)
    assert.equal(labels[0].textContent, "80/100")
    view.bind(...change)
    late.finish(result(100))
    assert.ok(labels.every(n => n.hidden))
  }
})

test("missing audio clears the last pair before another can be measured", () => {
  const {view, labels} = setup()
  view.begin("cut").finish(result(100))
  view.bind(pair, null, 120)
  assert.ok(labels.every(n => n.hidden))
})

test("an unavailable capture stays distinct from an unheard or inconclusive take", () => {
  const {view, labels, events, select} = setup()
  view.begin("cut").unavailable()
  assert.ok(labels.every(n => !n.hidden))
  assert.deepEqual(labels.map(n => n.textContent), ["Sem medição", "Falta ouvir"])
  assert.equal(events.at(-1)[1].score, null)
  assert.match(events.at(-1)[1].summary, /medir/)
  select("blend")
  view.begin("blend").finish(result(null))
  assert.deepEqual(labels.map(n => n.textContent), ["Sem medição", "Sem nota"])
  select("cut")
  assert.match(events.at(-1)[1].summary, /medir/)
  assert.equal(events.at(-1)[2].announcement, "")
  view.begin("cut").finish(result(85))
  assert.equal(labels[0].textContent, "85/100")
  view.bind({...pair, fromLoad: 8}, plan, 120)
  assert.ok(labels.every(n => n.hidden))
})

test("measurements of a linear blend never label a compensated rendition of the same cue", () => {
  const {view, labels} = setup()
  view.begin("blend").finish(result(60))
  view.bind(pair, {...plan, blendCurve: {correlation: 0, outPeak: .22, inPeak: .24}}, 120)
  assert.ok(labels.every(label => label.hidden))
})

test("arming takes only the completed reading of the selected version", () => {
  const {view, select} = setup()
  const heard = result(95)
  view.begin("cut").finish(heard)
  select("blend")
  assert.equal(view.reading(), null)
  select("cut")
  const armed = view.reading()
  assert.equal(armed, heard)
  view.begin("cut").unavailable()
  assert.equal(view.reading(), null)
  view.bind(pair, {...plan, inStart: 7}, 120)
  view.begin("cut").finish(result(30))
  assert.equal(armed.score, 95)
})

test("the third kind keeps its own reading across headphone comparisons and drops it after a cue change", () => {
  const {view, labels, select} = setup(["cut", "blend", "bass_swap"])
  for (const [kind, score] of [["cut", 85], ["bass_swap", null], ["blend", 64]]) {
    select(kind)
    view.begin(kind).finish(result(score))
  }
  assert.deepEqual(labels.map(label => label.textContent), ["85/100", "64/100", "Sem nota"])
  select("bass_swap")
  assert.deepEqual(view.reading(), result(null))
  view.bind(pair, {...plan, inStart: 11}, 120)
  assert.equal(view.reading(), null)
  assert.ok(labels.every(label => label.hidden))
})
