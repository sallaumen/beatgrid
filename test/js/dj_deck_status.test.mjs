import assert from "node:assert/strict"
import test from "node:test"
import {paintDeckStatus} from "../../assets/js/dj/deck_status.js"

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
