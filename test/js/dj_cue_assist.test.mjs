import assert from "node:assert/strict"
import {test} from "node:test"
import {mountCueAssist} from "../../assets/js/dj/cue_assist.js"

function booth() {
  const nodes = new Map()
  const section = {querySelector(selector) {
    if (!nodes.has(selector)) nodes.set(selector, {hidden: false, disabled: false, textContent: "", focus() {}})
    return nodes.get(selector)
  }}
  const get = name => section.querySelector("[data-cue-" + name + "]")
  const saved = {inStart: 10, exit: 50, outgoing: {}, incoming: {}, mix: {out: {rate: 1}, into: {rate: 1}}}
  let draft = saved, cancelling = 0
  const pair = {}, replies = [], hearings = []
  const assist = mountCueAssist(section, {analyze(_decks, done) { replies.push(done); return () => cancelling++ },
    audition(entry, originalEntry) { hearings.push(entry); draft = {...draft, inStart: entry, originalEntry}; refresh() }})
  function refresh(options = {}) {assist.update({plan: draft, pair, kind: "blend", outBpm: 120, intoBpm: 120,
    deckCue: 10, phones: true, ...options})}
  refresh()
  return {saved, replies, hearings, get, refresh, assist, cancelled: () => cancelling}
}

const candidate = {entry: 10.125, recordDelta: .125, wallDelta: .125}
test("analysis, trying and restoring use a private draft while the saved entry remains untouched", () => {
  const b = booth()
  b.get("check").onclick()
  b.replies[0](candidate)
  assert.deepEqual(b.hearings, [])
  assert.match(b.get("note").textContent, /125 ms mais cedo/)
  b.get("try").onclick()
  assert.deepEqual(b.hearings, [10.125])
  assert.equal(b.saved.inStart, 10)
  assert.equal(b.get("restore").hidden, false)
  b.get("restore").onclick()
  assert.deepEqual(b.hearings, [10.125, 10])
})

test("a late answer after a different deck, cue, tempo, mix revision or closure cannot be used", () => {
  for (const change of [{pair: {}}, {deckCue: 9}, {intoBpm: 122}, {kind: "cut"}, {plan: null}, "rate"]) {
    const b = booth()
    b.get("check").onclick()
    b.refresh(change === "rate" ? {plan: {...b.saved, mix: {...b.saved.mix, into: {rate: 1.07}}}} : change)
    b.replies[0](candidate)
    assert.equal(b.get("try").hidden, true)
    assert.ok(b.cancelled() > 0)
    assert.deepEqual(b.hearings, [])
  }
})

test("uncertain material and a lost headphone route never start a trial", () => {
  const b = booth()
  b.get("check").onclick()
  b.replies[0](null)
  assert.equal(b.get("try").hidden, true)
  assert.match(b.get("note").textContent, /sem ajuste confiável/i)
  b.get("check").onclick()
  b.replies[1](candidate)
  b.refresh({phones: false})
  assert.equal(b.get("try").disabled, true)
  b.get("try").onclick()
  assert.deepEqual(b.hearings, [])
  b.assist.reset()
  assert.equal(b.get("try").hidden, true)
})
