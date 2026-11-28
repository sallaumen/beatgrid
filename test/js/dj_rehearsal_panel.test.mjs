import assert from "node:assert/strict"
import test from "node:test"
import {neutralMix} from "../../assets/js/dj/deck_mix.js"
import {mountRehearsal} from "../../assets/js/dj/rehearsal_panel.js"
import {loadPeaks} from "../../assets/js/dj/waveform.js"

function panelElements() {
  const nodes = new Map()
  const drawing = {scale() {}, setLineDash() {}, beginPath() {}, moveTo() {}, lineTo() {}, stroke() {}, fillRect() {}}
  function element(selector) {
    if (!nodes.has(selector)) nodes.set(selector, {
      querySelector: element, querySelectorAll: () => [], dataset: {}, style: {}, focus() {}, contains: () => false,
      setAttribute() {}, clientWidth: 10, clientHeight: 8, getContext: () => drawing,
      showModal() { this.open = true }, close() { this.open = false; this.onclose() }
    })
    return nodes.get(selector)
  }
  element('[data-compare-with]').options = ["cut", "blend", "bass_swap"].map(value => ({value, text: value, dataset: {short: value}}))
  element('input[name="dj-rehearse-kind"]:checked').value = "cut"
  return element
}

test("decoded headphone auditions survive a media error while arming still requires a working receiver", async t => {
  globalThis.ResizeObserver = class { observe() {} disconnect() {} }
  globalThis.window = {devicePixelRatio: 1}
  globalThis.document = {activeElement: null}
  t.after(() => { delete globalThis.ResizeObserver; delete globalThis.window; delete globalThis.document })
  const sample = new Float32Array(240)
  const audio = {duration: 12, sampleRate: 20, length: sample.length, numberOfChannels: 1, getChannelData: () => sample}
  const tracks = {a: {id: "out"}, b: {id: "in"}}, waves = {}
  t.mock.method(globalThis, "fetch", async () => new Response(new ArrayBuffer(1)))
  for (const side of ["a", "b"]) waves[side] = await loadPeaks(tracks[side].id, side, {decodeAudioData: async () => audio})
  const deck = playing => ({el: {}, bpm: 120, loadToken: 1, audible: () => playing, ready: () => true, platterTime: () => 0, positionMs: () => 0})
  const decks = {a: deck(true), b: deck(false)}
  let elapsed = null
  const engine = {ctx: {}, decks, passage: () => null, audibleDeck: () => "a", deckMix: () => neutralMix,
    canMeasureBlend: () => false, rehearsal: {elapsed: () => elapsed, stopListening() { elapsed = null }, stop() { elapsed = null }}}
  const el = panelElements()
  const panel = mountRehearsal({root: el("root"), tracks, waves, engine, hasPhones: () => true, hint: () => null})
  t.after(() => panel.destroy())
  decks.a.el.error = {code: 3}
  el("[aria-haspopup=dialog]").onclick()
  assert.equal(el("[data-listen]").disabled, false)
  assert.equal(el("[data-listen-both]").disabled, false)
  assert.equal(el("[data-arm]").disabled, false)

  elapsed = 1
  decks.b.el.error = {code: 3}
  panel.update()
  assert.equal(el("[data-listen]").disabled, false)
  assert.equal(el("[data-arm]").disabled, true)
  assert.equal(elapsed, 1)
  assert.match(el("[role=status]").textContent, /Tocando só no fone/)
  assert.match(el("[role=status]").textContent, /deck B/i)

  decks.b.loadToken++
  waves.b = {failed: true}
  panel.update()
  assert.equal(elapsed, null)
  assert.equal(el("[data-listen]").disabled, true)
  assert.match(el("[role=status]").textContent, /ler o áudio/)
})
