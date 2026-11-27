import assert from "node:assert/strict"
import test from "node:test"
import {neutralMix} from "../../assets/js/dj/deck_mix.js"
import {planRehearsal} from "../../assets/js/dj/rehearsal.js"
import {mountRehearsal} from "../../assets/js/dj/rehearsal_panel.js"
import {loadPeaks} from "../../assets/js/dj/waveform.js"

function control() {
  const children = new Map()
  const context = {scale() {}, fillRect() {}, setLineDash() {}, beginPath() {}, moveTo() {}, lineTo() {}, stroke() {}}
  return {dataset: {}, style: {}, clientWidth: 2, clientHeight: 8, setAttribute() {},
    getContext: () => context, querySelectorAll: () => [],
    querySelector(key) {
      if (!children.has(key)) children.set(key, control())
      return children.get(key)
    }}
}

test("SYNC keeps a confirmed private take until the rehearsal tempo actually changes", async t => {
  const root = control(), dialog = root.querySelector("dialog"), strip = control()
  strip.dataset.side = "into"
  dialog.querySelectorAll = key => key === "[data-side]" ? [strip] : []
  dialog.querySelector('input[name="dj-rehearse-kind"]:checked').value = "cut"
  globalThis.window = {devicePixelRatio: 1}
  globalThis.ResizeObserver = class { observe() {} disconnect() {} }
  t.after(() => { delete globalThis.ResizeObserver; delete globalThis.window })
  t.mock.method(globalThis, "fetch", async () => new Response(new ArrayBuffer(1)))
  const audio = {duration: 12, numberOfChannels: 1, sampleRate: 50, getChannelData: () => new Float32Array(600)}
  const decode = {decodeAudioData: async () => audio}
  const a = {id: "sync-out"}, b = {id: "sync-in"}
  const waves = {a: await loadPeaks(a.id, a.id, decode), b: await loadPeaks(b.id, b.id, decode)}
  const deck = playing => ({bpm: 133.01, el: {}, loadToken: 1, audible: () => playing,
    positionMs: () => 1000, platterTime: () => 1, ready: () => true})
  const mix = {out: {...neutralMix, rate: .97}, into: {...neutralMix, rate: .97}}
  const saved = {pair: {from: "a", to: "b", fromLoad: 1, toLoad: 1}, kind: "cut",
    phase: "confirmed", exitMs: 7000, plan: planRehearsal(audio, audio, 7, 1, 133.01, mix)}
  const heard = []
  const engine = {decks: {a: deck(true), b: deck(false)}, audibleDeck: () => "a",
    passage: () => saved, canMeasureBlend: () => false,
    editPassageMix() { saved.phase = "armed" },
    rehearsal: {elapsed: () => null, stop() {}, edit(plan) { heard.push(plan) }}}
  const panel = mountRehearsal({root, engine, waves, tracks: {a, b}, hint: () => null, hasPhones: () => true})
  dialog.open = true
  panel.update()
  strip.querySelector("[data-sync]").onclick()
  assert.equal(saved.phase, "confirmed")
  assert.equal(heard.length, 0)
  engine.decks.a.bpm = 135
  strip.querySelector("[data-sync]").onclick()
  assert.equal(saved.phase, "armed")
  assert.equal(heard.length, 1)
  assert.equal(heard[0].mix.into.rate, 135 * .97 / 133.01)
  assert.equal(saved.plan.mix.into.rate, .97)
})
