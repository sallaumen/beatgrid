import assert from "node:assert/strict"
import test from "node:test"
import {neutralMix} from "../../assets/js/dj/deck_mix.js"
import {planRehearsal} from "../../assets/js/dj/rehearsal.js"
import {mountRehearsal} from "../../assets/js/dj/rehearsal_panel.js"
import {loadPeaks} from "../../assets/js/dj/waveform.js"

function control() {
  const children = new Map()
  const context = {scale() {}, fillRect() {}, setLineDash() {}, beginPath() {}, moveTo() {}, lineTo() {}, stroke() {}}
  return {dataset: {}, style: {}, clientWidth: 2, clientHeight: 8, replaceChildren() {}, setAttribute() {}, focus() {}, close() { this.open = false; this.onclose?.() },
    getContext: () => context, querySelectorAll: () => [],
    querySelector(key) {
      if (!children.has(key)) children.set(key, control())
      return children.get(key)
    }}
}

async function privateTake(t, outBpm = 133.01, intoBpm = 133.01, analysisAudio = null) {
  const root = control(), dialog = root.querySelector("dialog"), strip = control()
  const second = dialog.querySelector("[data-compare-with]")
  second.options = [["cut", "Corte"], ["blend", "Mistura"], ["bass_swap", "Troca de graves"]]
    .map(([value, text]) => ({value, text, dataset: {short: text}}))
  second.value = "blend"
  strip.dataset.side = "into"
  dialog.querySelectorAll = key => key === "[data-side]" ? [strip] : []
  dialog.querySelector('input[name="dj-rehearse-kind"]:checked').value = "cut"
  globalThis.window = {devicePixelRatio: 1}
  globalThis.ResizeObserver = class { observe() {} disconnect() {} }
  t.after(() => { delete globalThis.ResizeObserver; delete globalThis.window })
  t.mock.method(globalThis, "fetch", async () => new Response(new ArrayBuffer(1)))
  const audio = analysisAudio ?? {duration: 12, numberOfChannels: 1, sampleRate: 50, getChannelData: () => new Float32Array(600)}
  const decode = {decodeAudioData: async () => audio}
  const prefix = analysisAudio ? "analysis" : "sync"
  const a = {id: prefix + "-out"}, b = {id: prefix + "-in"}
  const waves = {a: await loadPeaks(a.id, a.id, decode), b: await loadPeaks(b.id, b.id, decode)}
  const deck = (playing, bpm) => ({bpm, el: {}, loadToken: 1, audible: () => playing,
    positionMs: () => 1000, platterTime: () => 1, ready: () => true})
  const mix = {out: {...neutralMix, rate: .97}, into: {...neutralMix, rate: .97}}
  const saved = {pair: {from: "a", to: "b", fromLoad: 1, toLoad: 1}, kind: "cut",
    phase: "confirmed", exitMs: 7000, plan: planRehearsal(audio, audio, 7, 1, outBpm, mix)}
  const heard = [], auditions = []
  let phones = true, waiting = false
  const engine = {ctx: {resume: async () => {}}, decks: {a: deck(true, outBpm), b: deck(false, intoBpm)}, audibleDeck: () => "a",
    sessionDeck: () => "a", deckMix: () => neutralMix,
    passage: () => saved, canMeasureBlend: () => false,
    editPassageMix() { saved.phase = "armed" },
    armPassage(_pair, plan) { saved.plan = plan; return {ok: true} },
    rehearsal: {elapsed: () => null, stop() {}, stopListening() {}, edit(plan) { heard.push(plan) }, play(plan) { auditions.push(plan); return Promise.resolve(true) }}}
  const panel = mountRehearsal({root, engine, waves, tracks: {a, b}, hint: () => null, hasPhones: () => phones, waitingForNext: () => waiting})
  dialog.open = true
  panel.update()
  return {strip, panel, engine, heard, saved, auditions, dialog, setWaiting(value) { waiting = value; panel.update() }, setPhones(value) { phones = value; panel.update() }}
}

test("a queued successor keeps the previous track out of the audition and its mix controls", async t => {
  const {dialog, strip, auditions, setWaiting} = await privateTake(t)
  setWaiting(true)
  assert.match(dialog.querySelector("[data-in]").textContent, /aguardando a próxima faixa/)
  assert.equal(strip.disabled, true)
  for (const selector of ["[data-listen]", "[data-listen-both]", "[data-arm]"]) {
    assert.equal(dialog.querySelector(selector).disabled, true)
  }
  await dialog.querySelector("[data-listen]").onclick()
  assert.equal(auditions.length, 0)
  setWaiting(false)
  assert.equal(strip.disabled, false)
  assert.equal(dialog.querySelector("[data-listen]").disabled, false)
})

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

function interactiveTake(t, fixture) {
  const {engine, dialog, strip, panel} = fixture
  const plays = []
  let current
  Object.assign(engine.rehearsal, {
    elapsed: () => current ? 1.5 : null,
    stop() { if (current) finish(false) },
    stopListening() { this.stop() },
    play(plan, kind, pan, skip, observe) {
      if (current) finish(false)
      const cancel = observe({}, {start: 0, change: 3, end: 7, overlap: 2, kind})
      const audio = new Promise(resolve => { current = {resolve, cancel} })
      plays.push({kind, plan, skip})
      return audio
    }
  })
  function finish(complete = true) {
    const take = current
    current = null
    if (!complete) take.cancel()
    take.resolve(complete)
  }
  globalThis.document = {activeElement: null}
  t.after(() => { delete globalThis.document })
  const select = kind => {
    dialog.querySelector('input[name="dj-rehearse-kind"]:checked').value = kind
    dialog.onchange({target: {name: "dj-rehearse-kind", matches: () => false}})
  }
  const adjust = value => strip.oninput({target: {dataset: {mix: "level"}, value}})
  const listen = dialog.querySelector("[data-listen]"), replay = dialog.querySelector("[data-replay-final]")
  const message = () => dialog.querySelector("[role=status]").textContent
  const settle = async () => { await new Promise(resolve => setImmediate(resolve)); panel.update() }
  return {plays, finish, select, adjust, listen, replay, message, settle}
}

test("only a complete listen to the final settings of the edited transition dismisses its replay", async t => {
  const fixture = await privateTake(t)
  const {plays, finish, select, adjust, listen, replay, message, settle} = interactiveTake(t, fixture)
  const {dialog, saved} = fixture
  const original = saved.plan
  adjust(84) // Editing a stopped draft does not ask for a replay.
  assert.equal(replay.hidden, true)
  await listen.onclick()
  adjust(62)
  assert.equal(replay.hidden, false)
  assert.match(message(), /ajustes.*desde o início/i)
  assert.equal(dialog.querySelector("[data-arm]").disabled, false)
  await replay.onclick()
  assert.equal(plays.at(-1).skip, 0)
  assert.equal(plays.at(-1).plan.mix.into.level, .62)
  await listen.onclick() // Stop midway.
  await settle()
  assert.equal(replay.hidden, false)
  select("blend")
  assert.equal(replay.hidden, true)
  await listen.onclick()
  finish()
  await settle()
  select("cut")
  assert.equal(replay.hidden, false)
  await replay.onclick()
  adjust(51)
  finish() // The pre-edit take finished, but its beginning had different settings.
  await settle()
  assert.equal(replay.hidden, false)
  assert.equal(saved.plan, original)
  const both = dialog.querySelector("[data-listen-both]")
  const comparison = both.onclick()
  await settle()
  assert.equal(plays.at(-1).kind, "cut")
  finish()
  await settle()
  assert.equal(plays.at(-1).kind, "blend")
  finish()
  await comparison
  assert.equal(replay.hidden, true)
  assert.doesNotMatch(message(), /ajustes.*desde o início/i)
  assert.equal(saved.plan, original)
})

test("the replay follows the headphone route and can be skipped when explicitly arming", async t => {
  const fixture = await privateTake(t)
  const {adjust, listen, replay, message, settle} = interactiveTake(t, fixture)
  const {dialog, saved, setPhones} = fixture
  const original = saved.plan
  await listen.onclick()
  adjust(89)
  setPhones(false)
  await settle()
  assert.equal(replay.disabled, true)
  assert.match(message(), /saída separada/)
  assert.match(message(), /ajustes.*desde o início/i)
  assert.equal(saved.plan, original)
  assert.equal(dialog.querySelector("[data-arm]").disabled, false)
  dialog.querySelector("[data-arm]").onclick()
  assert.equal(saved.plan.mix.into.level, .89)
})

test("a keyboard replay moves focus to the adjacent arm button only if its own button still holds focus", async t => {
  const fixture = await privateTake(t)
  const {adjust, listen, replay, finish, settle} = interactiveTake(t, fixture)
  const arm = fixture.dialog.querySelector("[data-arm]")
  arm.focus = () => { document.activeElement = arm }
  for (const [level, focus] of [[74, replay], [55, fixture.strip]]) {
    await listen.onclick()
    adjust(level)
    document.activeElement = replay
    await replay.onclick()
    document.activeElement = focus
    finish()
    await settle()
    assert.equal(replay.hidden, true)
    assert.equal(document.activeElement, focus === replay ? arm : focus)
  }
})

test("a completed headphone comparison lets the DJ pick either heard version before updating the reservation", async t => {
  const fixture = await privateTake(t)
  const {dialog, engine, saved} = fixture
  const {plays, finish, select, adjust, message, settle} = interactiveTake(t, fixture)
  const other = dialog.querySelector("[data-select-compared]")
  const second = dialog.querySelector("[data-compare-with]")
  const selected = dialog.querySelector('input[name="dj-rehearse-kind"]:checked')
  const arm = dialog.querySelector("[data-arm]")
  const applied = []
  engine.armPassage = (_pair, _plan, kind) => { applied.push(kind); return {ok: true} }
  engine.canRecallBass = () => true
  for (const kind of ["cut", "bass_swap"]) dialog.querySelector(`input[value="${kind}"]`).click = () => select(kind)
  second.value = "bass_swap"
  const original = saved.plan
  const pairing = dialog.querySelector("[data-listen-both]").onclick()
  await settle()
  const duringFirst = other.hidden
  finish()
  await settle()
  const duringSecond = other.hidden
  finish()
  await pairing
  assert.equal(arm.textContent, "Atualizar com Corte")
  assert.equal(duringFirst, true)
  assert.equal(duringSecond, true)
  assert.equal(other.hidden, false)
  assert.equal(other.textContent, "Escolher Troca de graves")
  const comparison = message()
  const stopAudio = t.mock.method(engine.rehearsal, "stopListening")
  other.onclick()
  assert.equal(selected.value, "bass_swap")
  assert.equal(second.value, "cut")
  assert.equal(message(), comparison)
  assert.equal(arm.textContent, "Atualizar com Troca de graves")
  assert.equal(other.textContent, "Escolher Corte")
  other.onclick()
  assert.equal(selected.value, "cut")
  select("bass_swap") // The ordinary radio has the same effect as the shortcut.
  assert.equal(arm.textContent, "Atualizar com Troca de graves")
  assert.deepEqual(plays.map(p => p.kind), ["cut", "bass_swap"])
  assert.equal(stopAudio.mock.callCount(), 0)
  assert.equal(saved.phase, "confirmed")
  assert.equal(saved.plan, original)
  assert.deepEqual(applied, [])
  arm.onclick()
  assert.deepEqual(applied, ["bass_swap"])
  dialog.open = true
  adjust(81)
  fixture.panel.update()
  assert.equal(other.hidden, true)
})

test("repeated private attack edits keep the audible deck, saved CUE and original blend curve", async t => {
  const {panel, dialog, engine, saved, auditions, setWaiting} = await privateTake(t, null, null)
  const original = saved.plan
  const curve = {correlation: .35, maxGain: 1.12}
  saved.plan = {...original, blendCurve: curve}
  setWaiting(true)
  setWaiting(false)
  const manual = dialog.querySelector("[data-cue-manual]")
  const earlier = manual.querySelector("[data-cue-step=earlier]")
  const later = manual.querySelector("[data-cue-step=later]")
  const originalCue = engine.decks.b.platterTime()
  for (let i = 0; i < 3; i++) earlier.onclick()
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(auditions.length, 1)
  assert.ok(Math.abs(auditions[0].inStart - original.inStart - 3 * .025 * original.mix.into.rate) < 1e-12)
  assert.equal(saved.plan.inStart, original.inStart)
  assert.equal(saved.plan.blendCurve, curve)
  assert.equal(engine.decks.b.platterTime(), originalCue)
  for (let i = 0; i < 3; i++) later.onclick()
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(auditions.length, 2)
  assert.equal(auditions.at(-1).inStart, original.inStart)
  assert.equal(auditions.at(-1).blendCurve, curve)
  assert.equal(auditions.at(-1).originalEntry, undefined)
  earlier.onclick()
  await new Promise(resolve => setImmediate(resolve))
  panel.update()
  dialog.querySelector("[data-arm]").onclick()
  assert.equal(saved.plan.inStart, auditions.at(-1).inStart)
  assert.equal(engine.decks.b.platterTime(), originalCue)
})

test("refining an automatic CUE during playback returns to the saved curve on restore", async t => {
  const samples = new Float32Array(16 * 12000)
  const audio = {duration: 16, numberOfChannels: 1, sampleRate: 12000, length: samples.length,
    getChannelData: () => samples, copyFromChannel: (dest, _, start) => dest.set(samples.subarray(start, start + dest.length))}
  globalThis.Worker = class {
    postMessage() { queueMicrotask(() => this.onmessage({data: {entry: 1.1, wallDelta: .1}})) }
    terminate() {}
  }
  t.after(() => { delete globalThis.Worker })
  const fixture = await privateTake(t, 120, 120, audio)
  const {dialog, saved} = fixture
  const {plays, listen, settle} = interactiveTake(t, fixture)
  const curve = saved.plan.blendCurve = {gain: 1.2}
  const assist = dialog.querySelector("[data-cue-assist]")
  assist.querySelector("[data-cue-check]").onclick()
  await settle()
  assist.querySelector("[data-cue-try]").onclick()
  await settle()
  assert.equal(plays.at(-1).plan.inStart, 1.1)
  const earlier = dialog.querySelector("[data-cue-manual]").querySelector("[data-cue-step=earlier]")
  earlier.onclick()
  earlier.onclick()
  earlier.onclick()
  await settle()
  assert.equal(plays.length, 2)
  assert.equal(plays.at(-1).plan.originalEntry, 1)
  assert.equal(saved.plan.inStart, 1)
  assist.querySelector("[data-cue-restore]").onclick()
  await settle()
  assert.equal(plays.length, 3)
  assert.equal(plays.at(-1).plan.inStart, 1)
  assert.equal(plays.at(-1).plan.blendCurve, curve)
  await listen.onclick()
})
