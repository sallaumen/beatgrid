import test from "node:test"
import assert from "node:assert/strict"
import {mountPassageScore} from "../../assets/js/dj/passage_score_view.js"

function fixture() {
  const element = () => ({
    children: [], dataset: {}, hidden: false, textContent: "",
    replaceChildren(...nodes) { this.children = nodes }
  })
  const nodes = Object.fromEntries(
    ["panel", "total", "number", "readable", "scale", "summary", "metrics", "announce", "pair", "reference", "reference-label", "reference-metrics"].map(key => [key, element()])
  )
  nodes.title = {textContent: "Nota da passagem"}
  const metric = () => {
    const row = element()
    for (const key of ["label", "value", "state"]) row[key] = element()
    row.querySelector = selector => row[selector.slice(14, -1)]
    return row
  }
  nodes.template = {content: {firstElementChild: {cloneNode: metric}}}
  const root = {ownerDocument: {createElement: element}, querySelector: selector => nodes[selector.slice(12, -1)]}
  return {view: mountPassageScore(root), nodes}
}

test("one completed measurement replaces the listening state and publishes the real digits together", () => {
  const {view, nodes} = fixture()
  view.listening()
  assert.equal(nodes.panel.hidden, false)
  assert.equal(nodes.total.hidden, true)
  assert.equal(nodes.announce.textContent, "Medindo a passagem.")
  const summary = "O pulso se manteve durante a troca."
  const result = {score: 84, summary, metrics: [{id: "pulse", label: "Pulso", value: "12 ms", state: "good"}]}
  view.show(result)
  assert.equal(nodes.number.children.map(d => d.textContent).join(""), "84")
  assert.equal(nodes.total.hidden, false)
  assert.equal(nodes.scale.hidden, false)
  assert.equal(nodes.summary.textContent, summary)
  assert.match(nodes.announce.textContent, /84 de 100/)
  const [row] = nodes.metrics.children
  assert.equal(row.label.textContent, "Pulso")
  assert.equal(row.value.textContent, "12 ms")
  const digits = nodes.number.children
  view.show(result)
  assert.equal(nodes.number.children, digits)
})

test("insufficient evidence, zero and clearing cannot leave a previous score or animation", () => {
  const {view, nodes} = fixture()
  view.show({score: 0, metrics: [], summary: "Houve silêncio."})
  assert.equal(nodes.number.children[0].textContent, "0")
  view.show({score: null, metrics: [], summary: "Trecho curto para medir o pulso."})
  assert.equal(nodes.number.textContent, "Sem nota")
  assert.equal(nodes.scale.hidden, true)
  assert.equal(nodes.metrics.hidden, true)
  assert.doesNotMatch(nodes.announce.textContent, /de 100/)
  view.clear()
  assert.equal(nodes.panel.hidden, true)
  assert.equal(nodes.announce.textContent, "")
  view.destroy()
  view.show({score: 99, summary: "Resposta de um ensaio anterior.", metrics: []})
  assert.equal(nodes.panel.hidden, true)
})

test("revisiting a measured kind renders its details quietly without animating again", () => {
  const {view, nodes} = fixture()
  view.show({score: 75, metrics: [], summary: "Houve uma queda de nível."}, {restored: true})
  assert.equal(nodes.number.textContent, "75")
  assert.deepEqual(nodes.number.children, [])
  assert.equal(nodes.announce.textContent, "")
  assert.equal(nodes.summary.textContent, "Houve uma queda de nível.")
})

test("the room compares only the audition attached to the played version", () => {
  const {view, nodes} = fixture()
  const metric = {id: "level", label: "Nível", value: "Variação de 0,1 dB", state: "good"}
  const reference = {pair: "Corte · Um → Dois", hearing: {score: 100, metrics: [metric]}}
  const room = {score: 65, summary: "Entrada mais baixa", metrics: [{...metric, value: "15,6 dB abaixo", state: "poor"}]}
  view.show(room, {reference})
  assert.equal(nodes.pair.textContent, reference.pair)
  assert.equal(nodes.reference.hidden, false)
  assert.equal(nodes["reference-label"].textContent, "No fone · 100/100")
  assert.equal(nodes["reference-metrics"].children[0].value.textContent, metric.value)
  assert.equal(nodes.metrics.children[0].value.textContent, "15,6 dB abaixo")

  view.show({...room}, {reference: {pair: "Mistura · Três → Quatro", hearing: {score: null, metrics: [metric]}}})
  assert.equal(nodes["reference-label"].textContent, "No fone · sem nota")
  view.show({...room}, {reference: {pair: "Corte · Quatro → Cinco", hearing: null}})
  assert.equal(nodes.reference.hidden, true)
  assert.equal(nodes["reference-metrics"].children.length, 0)
  assert.equal(nodes.pair.textContent, "Corte · Quatro → Cinco")
})

test("intentional effects announce the observations without an empty numeric grade", () => {
  const {view, nodes} = fixture()
  const pair = "Fade em AUTO · Saída → Entrada"
  view.show({score: null, descriptive: true, metrics: [], summary: "Entrada 6 dB abaixo"}, {reference: {pair}})
  assert.equal(nodes.total.hidden, true)
  assert.equal(nodes.summary.textContent, "Entrada 6 dB abaixo")
  assert.match(nodes.announce.textContent, /Fade em AUTO.*Entrada 6 dB abaixo/)
  assert.doesNotMatch(nodes.announce.textContent, /Sem nota|de 100/)
  view.show({score: 80, metrics: [], summary: "Pulso alinhado"}, {reference: {pair: "Corte manual"}})
  assert.equal(nodes.total.hidden, false)
})

test("the final grade stays readable when revisiting a score without another live announcement", () => {
  const {view, nodes} = fixture()
  const result = {score: 65, summary: "Queda de nível na mistura.", metrics: []}
  view.show(result, {restored: true})
  assert.equal(nodes.readable.textContent, "65 de 100")
  assert.equal(nodes.announce.textContent, "")
  view.show({...result, score: null})
  assert.equal(nodes.readable.textContent, "Sem nota")
})
