import assert from "node:assert/strict"
import test from "node:test"
import {execFileSync} from "node:child_process"
import {fileURLToPath} from "node:url"
import {mountPassageComparison} from "../../assets/js/dj/passage_comparison.js"
import {scorePassage} from "../../assets/js/dj/passage_score.js"
import {neutralMix} from "../../assets/js/dj/deck_mix.js"

const pair = {from: "a", to: "b", fromLoad: 2, toLoad: 7}
const plan = {exit: 32, inStart: 4, lead: 3, duration: 7, blend: 2, mix: {out: neutralMix, into: neutralMix}}
const result = score => ({score, summary: "Leitura", metrics: []})

function setup(kinds = ["cut", "blend"]) {
  const differences = [], events = [], labels = kinds.map(kind => ({dataset: {scoreFor: kind}}))
  const details = {
    clear() { events.push(["clear"]) },
    listening() { events.push(["listening"]) },
    show(value, options) { events.push(["show", value, options]) }
  }
  let selected = "cut"
  const view = mountPassageComparison(details, labels, () => selected, (kind, short) =>
    ({cut: short ? "Corte" : "Corte na entrada", blend: short ? "Mistura" : "Mistura de quatro tempos",
      bass_swap: "Troca de graves"})[kind], value => differences.push(value))
  view.bind(pair, plan, 120)
  return {view, labels, events, differences, select(kind, keepComparison) { selected = kind; view.select(keepComparison) }}
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
  assert.deepEqual(events.at(-1), ["show", cut, {reference: {pair: "Corte na entrada"}, restored: true}])
  select("cut") // panning changes the monitor destination only
  assert.equal(labels[1].textContent, "Sem nota")
})

test("current take wins once; cancelling a repeat keeps the previous result", () => {
  const {view, labels, events} = setup()
  const first = result(80)
  view.begin("cut").finish(first)
  const late = view.begin("cut")
  late.cancel()
  assert.deepEqual(events.at(-1), ["show", first, {reference: {pair: "Corte na entrada"}, restored: true}])
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

test("monitoring the alternative keeps the chosen score in view and identifies both results", () => {
  const {view, events, select} = setup()
  const chosen = result(100)
  view.begin("cut").finish(chosen)
  const last = events.at(-1)
  const other = view.begin("blend")
  assert.equal(events.at(-1), last)
  other.finish(result(65))
  assert.equal(events.at(-1), last)
  view.finishPair(["cut", "blend"])
  assert.equal(view.summary(), "Corte na entrada 100/100 · Mistura de quatro tempos 65/100.")
  assert.equal(view.reading(), chosen)
  select("blend")
  assert.equal(view.summary(), "")
  assert.equal(view.reading().score, 65)
  view.begin("cut").unavailable()
  view.finishPair(["blend", "cut"])
  assert.equal(view.summary(), "Mistura de quatro tempos 65/100 · Corte na entrada sem medição.")
  view.bind(pair, {...plan, inStart: 3}, 120)
  assert.equal(view.summary(), "")
})

test("a finished comparison can keep its score without pinning either decoded track", () => {
  const fixture = fileURLToPath(new URL("./fixtures/collected_passage_audio.mjs", import.meta.url))
  execFileSync(process.execPath, ["--expose-gc", fixture])
})

// A held note has level and headroom even when there are no beats to grade.
function sustained(kind, centerGain = 1, peak = 0.4, truePeak = true) {
  const overlap = kind === "cut" ? 0.01 : 2
  const frames = Array.from({length: Math.round((5 + overlap) * 100)}, (_, i) => {
    const inMix = i >= 300 && i < Math.round((3 + overlap) * 100)
    const rms = 0.15 * (inMix ? centerGain : 1)
    const amplitude = inMix ? peak : 0.4
    return {rms, onset: 0, peak: amplitude, ...(truePeak ? {truePeak: amplitude} : {})}
  })
  return scorePassage({frames, frameSeconds: 0.01, changeAt: 3, overlap, kind, bpm: 120})
}

test("two ungraded listens show only the measured differences and leave the chosen take intact", () => {
  const {view, differences} = setup()
  const first = sustained("cut")
  const second = sustained("blend", 0.25, 0.98)
  assert.equal(first.score, null)
  assert.equal(second.score, null)
  view.begin("cut").finish(first)
  view.begin("blend").finish(second)
  view.finishPair(["cut", "blend"])
  const contrast = differences.at(-1)
  assert.deepEqual(contrast.names, ["Corte", "Mistura"])
  assert.deepEqual(contrast.rows.map(({first, second}) => [first.value, second.value]), [
    ["Variação de 0 dB", "Queda de 12 dB na mistura"],
    ["Pico estimado de -8 dBTP", "Pico estimado de -0,2 dBTP"]
  ])
  assert.equal(view.reading(), first)
  assert.match(view.summary(), /diferenças de nível e margem de pico/)
  assert.equal(differences.filter(Boolean).length, 1)
  view.bind({...pair}, plan, 120)
  assert.equal(differences.filter(Boolean).length, 1)
  view.begin("blend").unavailable()
  view.finishPair(["cut", "blend"])
  assert.equal(differences.at(-1), null)
  assert.deepEqual(view.reading(), first)
})

test("switching between two ungraded takes retains their measured contrast until the pair changes", () => {
  const {view, differences, select} = setup(["cut", "blend", "bass_swap"])
  const cut = sustained("cut"), bass = sustained("bass_swap", 0.25)
  view.begin("cut").finish(cut)
  view.begin("bass_swap").finish(bass)
  view.finishPair(["cut", "bass_swap"])
  const summary = view.summary(), contrast = differences.at(-1)
  assert.equal(view.alternative(), "bass_swap")
  select("bass_swap", true)
  assert.equal(view.reading(), bass)
  assert.equal(view.alternative(), "cut")
  assert.equal(view.summary(), summary)
  assert.equal(differences.at(-1), contrast)
  select("blend", true)
  assert.equal(view.alternative(), null)
  assert.equal(view.summary(), "")
  assert.equal(differences.at(-1), null)
})

test("distinct findings at the same severity compare, equivalent diagnoses and missing readings stay quiet", () => {
  const {view, differences} = setup(["cut", "blend", "bass_swap"])
  function compare(first, second) {
    view.begin("bass_swap").finish(first)
    view.begin("blend").finish(second)
    view.finishPair(["bass_swap", "blend"])
    return differences.at(-1)
  }
  assert.equal(compare(sustained("blend"), sustained("blend", 1.15, 0.5)), null)
  assert.equal(compare(sustained("blend", 0.23), sustained("blend", 0.26)), null)
  assert.equal(compare(sustained("blend", 1, 0.4, false), sustained("blend", 1, 0.99)), null)
  const drop = sustained("bass_swap", 0.2), surge = sustained("blend", 2.6, 0.75)
  const contrasting = compare(drop, surge)
  assert.deepEqual(contrasting.names, ["Troca de graves", "Mistura"])
  assert.deepEqual(contrasting.rows.map(row => [row.first.state, row.second.state]), [["poor", "poor"]])
  assert.match(contrasting.rows[0].first.value, /Queda/)
  assert.match(contrasting.rows[0].second.value, /Subida/)
  view.bind(pair, {...plan, inStart: 7}, 120)
  assert.equal(differences.at(-1), null)
})

test("the comparison names which take kept its level through a measured dip", () => {
  const {view} = setup(["cut", "blend", "bass_swap"])
  const cut = sustained("cut"), quiet = sustained("bass_swap", 0.2)
  view.begin("cut").finish(cut)
  view.begin("bass_swap").finish(quiet)
  for (const kinds of [["cut", "bass_swap"], ["bass_swap", "cut"]]) {
    view.finishPair(kinds)
    assert.match(view.summary(), /Corte sustentou melhor o volume no meio da passagem\./)
    assert.equal(view.reading(), cut)
  }
  view.begin("bass_swap").finish(sustained("bass_swap", 1.1))
  view.finishPair(["cut", "bass_swap"])
  assert.doesNotMatch(view.summary(), /sustentou melhor/)
  view.begin("bass_swap").finish(quiet)
  view.begin("cut").unavailable()
  view.finishPair(["cut", "bass_swap"])
  assert.doesNotMatch(view.summary(), /sustentou melhor/)
})
