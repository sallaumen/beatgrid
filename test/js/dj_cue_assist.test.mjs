import assert from "node:assert/strict"
import {test} from "node:test"
import {mountCueAssist} from "../../assets/js/dj/cue_assist.js"

function booth(entry = 10, rate = 1, duration = 65, bpm = 120) {
  const nodes = new Map()
  const document = {activeElement: null}
  const section = {ownerDocument: document, querySelector(selector) {
    if (!nodes.has(selector)) {
      const node = {hidden: false, textContent: "", focus() { if (!this.disabled) document.activeElement = this }}
      let disabled = false
      Object.defineProperty(node, "disabled", {get: () => disabled, set(value) {
        disabled = value
        if (disabled && document.activeElement === node) document.activeElement = null
      }})
      nodes.set(selector, node)
    }
    return nodes.get(selector)
  }}
  const get = name => section.querySelector(["earlier", "later"].includes(name) ? "[data-cue-step=" + name + "]" : "[data-cue-" + name + "]")
  const saved = {inStart: entry, exit: 50, outgoing: {}, incoming: {duration, sampleRate: 48000}, mix: {out: {rate: 1}, into: {rate}}}
  let draft = saved, cancelling = 0
  const pair = {}, replies = [], hearings = []
  const assist = mountCueAssist(section, {manual: section, analyze(_decks, done) { replies.push(done); return () => cancelling++ },
    audition(entry, originalEntry) { hearings.push(entry); draft = {...draft, inStart: entry, originalEntry}; refresh() }})
  function refresh(options = {}) {assist.update({plan: draft, pair, kind: "blend", outBpm: bpm, intoBpm: bpm,
    deckCue: 10, phones: true, ...options})}
  refresh()
  return {saved, replies, hearings, get, refresh, assist, cancelled: () => cancelling,
    active: () => document.activeElement}
}

const candidate = {entry: 10.125, recordDelta: .125, wallDelta: .125}

test("keyboard focus survives analysis and moves to the available response", () => {
  const b = booth()
  const check = b.get("check")
  check.focus()
  check.onclick()
  assert.equal(check.disabled, false)
  assert.equal(check.ariaDisabled, "true")
  assert.equal(b.active(), check)
  check.onclick()
  assert.equal(b.replies.length, 1)
  b.replies[0](candidate)
  assert.equal(b.active(), b.get("try"))

  const withoutPhones = booth()
  withoutPhones.refresh({phones: false})
  const unavailableCheck = withoutPhones.get("check")
  unavailableCheck.focus()
  unavailableCheck.onclick()
  withoutPhones.replies[0](candidate)
  assert.equal(withoutPhones.active(), withoutPhones.get("note"))
})
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

test("manual steps move an attack by 25 ms at the incoming pitch with no BPM or automatic proposal", () => {
  const rate = .956684
  const b = booth(.740, rate, 65, null)
  assert.equal(b.get("check").disabled, true)
  const earlier = b.get("earlier"), later = b.get("later")
  earlier.focus()
  for (let n = 1; n <= 3; n++) {
    earlier.onclick()
    assert.ok(Math.abs(b.hearings.at(-1) - (.740 + n * .025 * rate)) < 1e-12)
    assert.equal(b.active(), earlier)
  }
  assert.match(b.get("offset").textContent, /75 ms mais cedo/)
  assert.equal(b.saved.inStart, .740)
  assert.deepEqual(b.replies, [])
  for (let n = 0; n < 3; n++) later.onclick()
  assert.equal(b.hearings.at(-1), .740)
  assert.equal(b.get("restore").hidden, true)
  assert.match(b.get("offset").textContent, /original/i)
})

test("beginning, short files and the headphone route allow only complete playable steps", () => {
  const b = booth(0, 1, .05)
  const earlier = b.get("earlier"), later = b.get("later")
  assert.equal(later.ariaDisabled, "true")
  later.onclick()
  assert.deepEqual(b.hearings, [])
  earlier.focus()
  earlier.onclick()
  assert.equal(b.hearings.at(-1), .025)
  assert.equal(earlier.ariaDisabled, "true")
  assert.equal(b.active(), earlier)
  earlier.onclick()
  assert.equal(b.hearings.length, 1)
  b.refresh({phones: false})
  later.onclick()
  assert.equal(b.hearings.length, 1)
  b.refresh({phones: true})
  later.onclick()
  assert.equal(b.hearings.at(-1), 0)
  const short = booth(0, 1.08, .020)
  assert.equal(short.get("earlier").ariaDisabled, "true")
  assert.equal(short.get("later").ariaDisabled, "true")
})

test("manual refinement of an automatic suggestion restores the very first CUE", () => {
  const b = booth()
  b.get("check").onclick()
  b.replies[0](candidate)
  b.get("try").onclick()
  b.get("earlier").onclick()
  b.get("earlier").onclick()
  b.get("restore").onclick()
  assert.equal(b.hearings.at(-1), b.saved.inStart)
  assert.equal(b.get("restore").hidden, true)
})

test("an earlier step never consumes the fourth beat reserved for a bass swap", () => {
  const b = booth(1, 1, 3.01)
  b.refresh({kind: "bass_swap", plan: {...b.saved, fullBlend: true, blend: 2}})
  b.get("earlier").onclick()
  assert.equal(b.get("earlier").ariaDisabled, "true")
  assert.deepEqual(b.hearings, [])
  b.refresh({kind: "cut"})
  assert.equal(b.get("earlier").ariaDisabled, "false")
})
