import assert from "node:assert/strict"
import test from "node:test"
import {paintDeckStatus, paintLoopRegion, paintPitchWait, syncFeedback} from "../../assets/js/dj/deck_status.js"

test("each waveform follows the mounted deck across loading, preview, scratch and eject", () => {
  const deck = {trackId: null, el: {}, ready: () => false, audible: () => false}
  const readout = {dataset: {}}
  const state = (scratchPosition = null) => {
    paintDeckStatus(readout, deck, scratchPosition)
    return [readout.dataset.state, readout.textContent]
  }

  assert.deepEqual(state(), ["empty", "Vazio"])
  deck.trackId = "intro"
  assert.deepEqual(state(), ["loading", "Carregando"])
  deck.ready = () => true
  assert.deepEqual(state(), ["ready", "Pronto"])

  deck.cueState = "preview"
  deck.audible = () => true
  assert.deepEqual(state(), ["preview", "Pré-escuta"])
  deck.cueState = null
  assert.deepEqual(state(), ["playing", "Tocando"])
  deck.audible = () => false
  assert.deepEqual(state(0), ["scratch", "Scratch"])
  deck.el.ended = true
  assert.deepEqual(state(), ["ended", "Fim"])
  deck.el.error = {code: 3}
  assert.deepEqual(state(), ["error", "Erro de áudio"])
  deck.trackId = null
  assert.deepEqual(state(), ["empty", "Vazio"])
})

test("the animation loop only announces an actual state change", () => {
  const deck = {trackId: "intro", el: {}, ready: () => false}
  let writes = 0
  const readout = {dataset: {}, set textContent(value) { writes++ }}
  paintDeckStatus(readout, deck, null)
  paintDeckStatus(readout, deck, null)
  assert.equal(writes, 1)
})

test("the pitch note changes only on entering or leaving the wait", () => {
  let text = "", writes = 0
  const label = {get textContent() { return text }, set textContent(value) { text = value; writes++ },
    removeAttribute(key) { delete this[key] }}
  const deck = {pitchPending: true}
  paintPitchWait(label, deck)
  paintPitchWait(label, deck)
  assert.equal(text, "Pitch pendente")
  assert.equal(writes, 1)
  deck.pitchOnResume = true
  paintPitchWait(label, deck)
  assert.equal(text, "Pitch ao retomar")
  assert.match(label.title, /próxima reprodução/)
  deck.pitchPending = false
  paintPitchWait(label, deck)
  assert.equal(text, "")
  assert.equal(label.title, undefined, "an empty description must not announce a pending change")
  assert.equal(writes, 3)
})

test("SYNC describes a requested tempo while either deck still awaits its audio", () => {
  const deck = {id: "b", bpm: 100, baseRate: 1.06, pitchPending: true}
  const other = {id: "a", bpm: 106, baseRate: 1}
  assert.match(syncFeedback(deck, other, true), /solicitado.*106,0 BPM/)
  other.bpm = 130
  assert.match(syncFeedback(deck, other, false), /solicitado.*106,0 BPM.*130,0 BPM.*±8%/)
  deck.pitchPending = false
  assert.match(syncFeedback(deck, other, false), /Deck B em 106,0 BPM/)
  other.pitchPending = true
  assert.match(syncFeedback(deck, other, true), /alvo.*pendente no deck A/i)
})

test("an armed loop region follows the playable duration as metadata arrives", () => {
  const region = {style: {}}
  const deck = {durationMs: 60_000, el: {duration: NaN}, loop: {on: true, startMs: 2000, endMs: 4000}}
  paintLoopRegion(region, deck)
  assert.equal(parseFloat(region.style.width).toFixed(2), "3.33")
  deck.el.duration = 40
  paintLoopRegion(region, deck)
  assert.deepEqual(region.style, {left: "5%", width: "5%", display: "block"})

  deck.loop.on = false
  paintLoopRegion(region, deck)
  assert.equal(region.style.display, "none")
})
