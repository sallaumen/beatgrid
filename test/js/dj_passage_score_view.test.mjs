import test from "node:test"
import assert from "node:assert/strict"
import {mountPassageScore} from "../../assets/js/dj/passage_score_view.js"

function fixture() {
  const element = () => ({
    children: [], dataset: {}, hidden: false, textContent: "",
    replaceChildren(...nodes) { this.children = nodes }
  })
  const nodes = Object.fromEntries(
    ["panel", "total", "number", "scale", "summary", "metrics", "announce"].map(key => [key, element()])
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
