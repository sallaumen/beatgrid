import assert from "node:assert/strict"
import test from "node:test"
import {neutralMix} from "../../assets/js/dj/deck_mix.js"
import {planRehearsal} from "../../assets/js/dj/rehearsal.js"
import {mountRehearsal} from "../../assets/js/dj/rehearsal_panel.js"
import {loadPeaks} from "../../assets/js/dj/waveform.js"

function control() {
  const children = new Map()
  const context = {scale() {}, fillRect() {}, setLineDash() {}, beginPath() {}, moveTo() {}, lineTo() {}, stroke() {}}
  return {dataset: {}, style: {}, clientWidth: 2, clientHeight: 8, setAttribute() {}, focus() {}, close() { this.open = false; this.onclose?.() },
    getContext: () => context, querySelectorAll: () => [],
    querySelector(key) {
      if (!children.has(key)) children.set(key, control())
      return children.get(key)
    }}
}

async function privateTake(t, outBpm = 133.01, intoBpm = 133.01) {
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
  const deck = (playing, bpm) => ({bpm, el: {}, loadToken: 1, audible: () => playing,
    positionMs: () => 1000, platterTime: () => 1, ready: () => true})
  const mix = {out: {...neutralMix, rate: .97}, into: {...neutralMix, rate: .97}}
  const saved = {pair: {from: "a", to: "b", fromLoad: 1, toLoad: 1}, kind: "cut",
    phase: "confirmed", exitMs: 7000, plan: planRehearsal(audio, audio, 7, 1, 133.01, mix)}
  const heard = [], auditions = []
  let phones = true
  const engine = {ctx: {resume: async () => {}}, decks: {a: deck(true, outBpm), b: deck(false, intoBpm)}, audibleDeck: () => "a",
    passage: () => saved, canMeasureBlend: () => false,
    editPassageMix() { saved.phase = "armed" },
    armPassage(_pair, plan) { saved.plan = plan; return {ok: true} },
    rehearsal: {elapsed: () => null, stop() {}, edit(plan) { heard.push(plan) }, play(plan) { auditions.push(plan); return Promise.resolve(true) }}}
  const panel = mountRehearsal({root, engine, waves, tracks: {a, b}, hint: () => null, hasPhones: () => phones})
  dialog.open = true
  panel.update()
  return {strip, panel, engine, heard, saved, auditions, dialog, setPhones(value) { phones = value; panel.update() }}
}

test("SYNC keeps a confirmed private take until the rehearsal tempo actually changes", async t => {
  const {strip, saved, heard, engine} = await privateTake(t)
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

for (const [out, into, multiplier, relation] of [
  [66.98, 133.81, 2, "2 batidas do B por 1 do A"],
  [155.76, 76.4, .5, "1 batida do B por 2 do A"]
]) {
  test("the rehearsal auditions " + relation + " and only replaces the saved mix on Update", async t => {
    const {strip, saved, auditions, dialog, setPhones} = await privateTake(t, out, into)
    const choice = strip.querySelector("[data-pulse-sync]")
    const bpm = out * .97 * multiplier
    assert.equal(choice.hidden, false)
    assert.match(choice.textContent, new RegExp(relation))
    assert.ok(choice.textContent.includes(bpm.toLocaleString("pt-BR", {maximumFractionDigits: 1}) + " BPM"))
    setPhones(false)
    assert.equal(choice.disabled, true)
    await choice.onclick()
    assert.equal(auditions.length, 0)
    setPhones(true)
    const before = saved.plan
    await choice.onclick()
    assert.equal(auditions.length, 1)
    const audition = auditions[0]
    assert.equal(audition.inStart, before.inStart)
    assert.equal(audition.exit, before.exit)
    assert.equal(audition.mix.out.rate, .97)
    assert.equal(audition.mix.into.rate, bpm / into)
    assert.equal(saved.plan, before)
    dialog.querySelector("[data-arm]").onclick()
    assert.equal(saved.plan, audition)
  })
}

test("ordinary SYNC never shows or invokes the alternate headphone count", async t => {
  const {strip, auditions, saved} = await privateTake(t)
  const choice = strip.querySelector("[data-pulse-sync]")
  assert.equal(choice.hidden, true)
  await choice.onclick()
  assert.equal(auditions.length, 0)
  assert.equal(saved.phase, "confirmed")
})

test("auditioning an already matched private pulse keeps the confirmed version", async t => {
  const {strip, saved, auditions} = await privateTake(t, 60, 120)
  await strip.querySelector("[data-pulse-sync]").onclick()
  assert.deepEqual(auditions, [saved.plan])
  assert.equal(saved.phase, "confirmed")
})
