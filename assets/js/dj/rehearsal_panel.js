import {createBlendReview} from "./blend_measurement.js"
import {mountCueAssist} from "./cue_assist.js"
import {measurePassage, preparePassageMeter} from "./passage_meter.js"
import {mountPassageComparison, rehearsalKey} from "./passage_comparison.js"
import {scorePassage} from "./passage_score.js"
import {mountPassageScore, renderPassageDifferences} from "./passage_score_view.js"
import {getDeckAudio} from "./waveform.js"
import {pulseSync, syncedRate} from "./deck_mix.js"
import {updateComparisonChoice} from "./rehearsal_choices.js"
import {planRehearsal, rehearsalBassWindow, rehearsalOverlap} from "./rehearsal.js"
import {drawRehearsalBass, drawRehearsalWaves} from "./rehearsal_waves.js"

function text(el, value) {
  if (el.textContent !== value) el.textContent = value
}

export function mountRehearsal({root, engine, tracks, waves, hint, hasPhones, waitingForNext = () => false}) {
  const dialog = root.querySelector("dialog")
  const listen = dialog.querySelector("[data-listen]")
  const both = dialog.querySelector("[data-listen-both]")
  const replay = dialog.querySelector("[data-replay-final]")
  const status = dialog.querySelector("[role=status]")
  const seconds = n => n.toLocaleString("pt-BR", {maximumFractionDigits: 2}) + " s"
  const timing = dialog.querySelector("[data-timing]")
  const cursor = dialog.querySelector("[data-cursor]")
  const pan = dialog.querySelector("[data-pan]")
  const second = dialog.querySelector("[data-compare-with]")
  const bassChoice = dialog.querySelector('input[value="bass_swap"]')
  const bassLimit = dialog.querySelector("[data-bass-limit]")
  const bassPlot = dialog.querySelector("[data-bass-plot]")
  const bass = dialog.querySelector("[data-bass]")
  const names = new Map([...second.options].map(option => [option.value, option]))
  const name = (kind, short = false) => short ? names.get(kind).dataset.short : names.get(kind).text
  const bassRecallHint = "Leve o crossfader até o deck que sai e espere o eco ou a troca de graves terminar."
  const lanes = [...dialog.querySelectorAll("canvas[data-wave]")]
  const gains = dialog.querySelector("[data-gains]")
  const arm = dialog.querySelector("[data-arm]")
  const pickOther = dialog.querySelector("[data-select-compared]")
  const reservation = root.querySelector("[data-reservation]")
  const confirm = root.querySelector("[data-confirm]")
  const passageState = root.querySelector("[data-passage-state]")
  const open = root.querySelector("[aria-haspopup=dialog]")
  const transport = engine.rehearsal
  const blendReview = createBlendReview()
  const score = mountPassageScore(dialog.querySelector("#dj-rehearsal-score"))
  const strips = [...dialog.querySelectorAll("[data-side]")]
  const copyMix = dialog.querySelector("[data-copy-mix]")
  let lastChoice, lastPhase, lastEdit, lastAudition, originalAudition, mix, mixNote = ""
  let pair, plan, lastDeckCue, failure, pending = false, request = 0
  const kind = () => dialog.querySelector('input[name="dj-rehearse-kind"]:checked').value
  let sequence = null
  const heardKind = () => sequence?.kind ?? kind()
  const differenceTable = dialog.querySelector("#dj-heard-differences")
  const comparison = mountPassageComparison(score, [...dialog.querySelectorAll("[data-score-for]")], kind, name,
    value => renderPassageDifferences(differenceTable, value))
  const assist = mountCueAssist(dialog.querySelector("[data-cue-assist]"), {audition: tryEntry, refresh: update})

  // At most one small revision marker per transition; never retain its decoded audio.
  const edited = new Map()
  function editedVersion(transition) {
    const marker = edited.get(transition)
    return marker?.key === comparison.settingsKey() ? marker : null
  }

  function stop(byHand = false) {
    request++
    const wasComparing = sequence !== null
    sequence = null
    pending = false
    if (byHand) transport.stopListening()
    else transport.stop()
    comparison.select()
    if (wasComparing) draw()
  }

  function draw() {
    const transition = heardKind()
    bassPlot.hidden = !(plan?.fullBlend && transition === "bass_swap")
    if (!plan) {
      for (const lane of [...lanes, gains]) lane.width = lane.width
      gains.setAttribute("aria-label", "Volume dos decks")
      return
    }
    const overlap = rehearsalOverlap(plan, transition)
    let interval = transition === "cut"
      ? "Corte em " + seconds(plan.lead) + " · " + Math.round(overlap * 1000) + " ms"
      : "Mistura de " + seconds(plan.lead) + " a " + seconds(plan.lead + overlap)
    if (!bassPlot.hidden) {
      const {start, swap, end} = rehearsalBassWindow(plan)
      const from = pair.from.toUpperCase(), to = pair.to.toUpperCase()
      interval += " · Grave " + from + " → " + to + " em " + seconds(swap) + " (3º tempo)"
      bass.setAttribute("aria-label", "O grave do deck " + to + " abre de " + seconds(start) + " a " +
        seconds(swap) + ". O grave do deck " + from + " recua até " + seconds(end) + ".")
      drawRehearsalBass(bass, plan, window.devicePixelRatio || 1)
    }
    text(timing, interval)
    const percent = value => Math.round(100 * value) + "%"
    const {out, into} = plan.mix
    const leaving = out.level === 0 ? "Saída sem volume." : "A saída vai de " + percent(out.level) + " a zero."
    const entering = into.level === 0 ? "Entrada sem volume." : "A entrada vai de zero a " + percent(into.level) + "."
    gains.setAttribute("aria-label", leaving + " " + entering)
    drawRehearsalWaves(lanes, gains, [waves[pair.from], waves[pair.to]], plan, transition, window.devicePixelRatio || 1)
  }

  const draftKey = () => rehearsalKey(pair, plan, engine.decks[pair.from].bpm, null)

  function keepDraft() {
    blendReview.lock()
    lastAudition = {key: draftKey(), curve: plan.blendCurve}
  }

  function prepareDraft(reopen = false) {
    blendReview.lock()
    if (!plan) return
    if (reopen && lastAudition?.key === draftKey()) {
      if (lastAudition.curve) plan = {...plan, blendCurve: lastAudition.curve}
      return
    }
    if (transport.elapsed() !== null) { keepDraft(); return }
    if (!engine.canMeasureBlend(pair, plan.mix)) return
    const draft = plan
    blendReview.prepare(draft, curve => {
      if (!dialog.open || plan !== draft || !engine.canMeasureBlend(pair, plan.mix)) return
      plan = {...draft, blendCurve: curve}
      draw()
    })
  }

  function boothMix() {
    return {out: engine.deckMix(pair.from), into: engine.deckMix(pair.to)}
  }

  function syncTarget(side) {
    const out = side === "out", id = out ? pair.from : pair.to, reference = out ? pair.to : pair.from
    const bpm = engine.decks[id].bpm
    const target = engine.decks[reference].bpm * mix[out ? "into" : "out"].rate
    return {id, reference, bpm, target, pulse: pulseSync(mix[side].rate, bpm, target)}
  }

  function paintMix() {
    for (const strip of strips) {
      const side = strip.dataset.side, settings = mix[side]
      const {id, reference, bpm, pulse} = syncTarget(side)
      text(strip.querySelector("[data-mix-deck]"), "Deck " + id.toUpperCase())
      text(strip.querySelector("[data-tempo]"), bpm ? (bpm * settings.rate).toLocaleString("pt-BR", {maximumFractionDigits: 1}) + " BPM" : "BPM desconhecido")
      strip.querySelector("[data-sync]").disabled = !engine.decks[pair.from].bpm || !engine.decks[pair.to].bpm
      const alternate = strip.querySelector("[data-pulse-sync]")
      alternate.hidden = !pulse
      if (pulse) {
        const beats = pulse.factor === 2 ? "2 batidas" : "1 batida"
        const other = pulse.factor === 2 ? "1" : "2"
        const tempo = pulse.bpm.toLocaleString("pt-BR", {maximumFractionDigits: 1})
        text(alternate, `Ouvir a ${tempo} BPM · ${beats} do ${id.toUpperCase()} por ${other} do ${reference.toUpperCase()}`)
      }
      for (const control of strip.querySelectorAll("[data-mix]")) {
        const key = control.dataset.mix
        if (key === "vinyl") { control.checked = settings.vinyl; continue }
        const value = key === "rate" ? (settings.rate - 1) * 100 : settings[key] * 100
        control.value = value
        text(strip.querySelector(`[data-readout="${key}"]`), Number(value.toFixed(1)).toLocaleString("pt-BR") + "%")
      }
    }
  }

  function withEntry(entry, originalEntry) {
    const next = planRehearsal(plan.outgoing, plan.incoming, plan.exit, entry, engine.decks[pair.from].bpm, mix)
    return next && originalEntry != null ? {...next, originalEntry} : next
  }

  function tryEntry(entry, originalEntry) {
    if (!plan) return
    const next = withEntry(entry, originalEntry)
    if (!next) return
    engine.editPassageMix()
    if (originalEntry != null) originalAudition = {key: draftKey(), curve: plan.blendCurve}
    stop(true)
    plan = next
    if (originalEntry == null && originalAudition?.key === draftKey()) {
      blendReview.lock()
      plan = {...plan, blendCurve: originalAudition.curve}
    } else prepareDraft()
    failure = ""
    draw()
    update()
    if (hasPhones()) play()
  }

  function editMix(next) {
    if (!plan) return
    const transition = kind()
    const before = transport.elapsed() !== null || editedVersion(transition) ? draftKey() : null
    if (sequence) stop()
    engine.editPassageMix()
    failure = mixNote = ""
    mix = next
    plan = withEntry(plan.inStart, plan.originalEntry)
    try {
      if (kind() === "bass_swap" && !plan?.fullBlend) stop()
      else transport.edit(plan, kind(), Number(pan.value))
    } catch {
      stop()
      failure = "Não foi possível ouvir este ajuste. Tente novamente."
    }
    prepareDraft()
    if (plan && before) {
      const key = draftKey()
      if (key !== before) edited.set(transition, {key})
    }
    paintMix()
    draw()
    update()
  }

  function update() {
    const choice = engine.passage()
    if (choice !== lastChoice || choice?.phase !== lastPhase || choice?.review !== lastEdit) {
      lastChoice = choice
      lastPhase = choice?.phase
      lastEdit = choice?.review
      if (!choice && reservation.contains(document.activeElement)) open.focus({preventScroll: true})
      reservation.hidden = !choice
      if (choice) {
        const {plan, kind, exitMs, pair, phase} = choice
        const state = {armed: "Armada", confirmed: "Confirmada", starting: "Preparando a entrada",
          missed: "O ponto ensaiado já passou", failed: "A entrada não ficou pronta"}
        const review = {live: "A cabine mudou. Confirme para usar os ajustes salvos", draft: "Versão salva · aguarda nova confirmação"}
        const label = phase === "armed" && choice.review ? review[choice.review] : state[phase]
        text(passageState, label + " · " + name(kind, kind === "cut") + " · " + pair.from.toUpperCase() + " em " +
          seconds(exitMs / 1000) + " → " + pair.to.toUpperCase() + " em " + seconds(plan.inStart))
        confirm.hidden = confirm.disabled = phase !== "armed"
      }
    }
    if (!dialog.open) return
    const waiting = waitingForNext()
    const from = (waiting ? engine.sessionDeck() : engine.audibleDeck()) || engine.snapshot().activeDeck || "a"
    const to = from === "a" ? "b" : "a"
    const a = engine.decks[from], b = engine.decks[to]
    const out = tracks[from], into = waiting ? null : tracks[to]
    const toLoad = waiting ? null : b.loadToken
    const saved = !waiting && choice?.pair.from === from && choice.pair.fromLoad === a.loadToken &&
      choice.pair.toLoad === b.loadToken ? choice : null
    if (pair?.from !== from || pair.fromLoad !== a.loadToken || pair.toLoad !== toLoad) {
      stop()
      blendReview.lock()
      assist.reset()
      lastDeckCue = null
      pair = {from, to, fromLoad: a.loadToken, toLoad}
      plan = null
      mix = saved?.plan.mix ?? boothMix()
      if (saved) {
        dialog.querySelector(`input[value="${saved.kind}"]`).checked = true
        comparison.select()
      }
      paintMix()
      failure = mixNote = ""
      text(timing, "")
      const label = (d, track) => "Deck " + d.toUpperCase() + " · " + (track?.title || "vazio")
      text(dialog.querySelector("[data-out]"), label(from, out))
      text(dialog.querySelector("[data-in]"), waiting ? "Deck " + to.toUpperCase() + " · aguardando a próxima faixa" : label(to, into))
      draw()
    }
    const ready = waves[from]?.peaks && waves[to]?.peaks
    if (!plan && ready && out && into) {
      const outgoing = getDeckAudio(out.id), incoming = getDeckAudio(into.id)
      if (outgoing && incoming) {
        const armed = hint()?.deck === to && hint()?.track.id === into.id
        const point = armed ? engine.firePointMs() : null
        const outro = out.markers?.find(m => m.type === "outro")?.ms
        const exit = point ?? outro
        plan = saved?.plan ?? planRehearsal(outgoing, incoming, exit == null ? null : exit / 1000, b.platterTime(), a.bpm, mix)
        if (plan) {
          if (!saved) prepareDraft(true)
          draw()
        }
      }
    }
    // The saved version owns its cue. A fresh draft follows an explicit move on the idle deck.
    const deckCue = b.platterTime()
    if (!saved && plan && !b.audible() && lastDeckCue != null && Math.abs(deckCue - lastDeckCue) > 0.001) {
      stop()
      plan = withEntry(deckCue, null)
      prepareDraft()
      draw()
    }
    lastDeckCue = deckCue
    comparison.bind(pair, plan, a.bpm)
    const phones = hasPhones()
    copyMix.disabled = !plan
    for (const strip of strips) {
      strip.disabled = !plan
      strip.querySelector("[data-pulse-sync]").disabled = !plan || !phones || pending
    }
    assist.update({plan, pair, kind: kind(), outBpm: a.bpm, intoBpm: b.bpm, deckCue, phones})
    const fullBlend = !!plan?.fullBlend
    const shortBass = kind() === "bass_swap" && !fullBlend
    bassChoice.disabled = !fullBlend
    bassLimit.hidden = !plan || fullBlend
    const other = comparison.alternative()
    updateComparisonChoice(second, kind(), fullBlend)
    if (other && second.value !== other) second.value = other
    second.disabled = !plan || !!sequence
    const elapsed = transport.elapsed()
    let message = failure
    if (waiting) message = "A próxima faixa precisa estar no deck para ensaiar."
    else if (!out || !into) message = "Carregue uma faixa em cada deck para ensaiar."
    else if (waves[from]?.failed || waves[to]?.failed) message = "Não foi possível ler o áudio de um dos decks."
    else if (!ready) message = "Preparando as ondas para liberar os ajustes e a escuta no fone…"
    else if (!plan) message = "Reposicione o deck de entrada antes do fim da faixa."
    else if (shortBass) message = "Escolha corte ou mistura, ou reposicione a entrada para caberem quatro tempos."
    else if (!phones) message = "Escolha uma saída separada em Fone (cue) para ouvir."
    if (message && (elapsed !== null || pending || sequence)) stop()
    const playing = transport.elapsed() !== null
    const comparisonStatus = sequence && `${sequence.index + 1} de 2 no fone · ${name(sequence.kind)}.`
    const listening = comparisonStatus || (playing ? "Tocando só no fone." : pending ? "Abrindo o fone…" : comparison.summary() || "Pronto para ouvir no fone.")
    const review = choice?.review === "draft" ? " A versão anterior está salva e aguarda confirmação." : ""
    const finalMix = editedVersion(kind()) ? "Ao armar, estes ajustes valem desde o início da passagem." : ""

    const unavailable = !plan || shortBass || !phones
    listen.disabled = unavailable || pending || !!sequence
    replay.hidden = !finalMix
    replay.disabled = !finalMix || unavailable || !!sequence
    both.disabled = unavailable || (!sequence && (pending || playing))
    text(both, sequence ? "Parar comparação" : "Ouvir as duas")
    arm.disabled = !!sequence || shortBass || !plan || !a.audible() || b.audible() || !b.ready() || !!b.el.error ||
      a.positionMs() > Math.round(plan.exit * 1000) || choice?.phase === "starting"
    if (plan && a.audible() && a.positionMs() > plan.exit * 1000 && !playing && !sequence) {
      message = "O ponto ensaiado já passou nesta faixa."
    }
    const reload = plan && b.el.error ? "Recarregue o deck " + to.toUpperCase() + " para armar a passagem." : ""
    text(status, [message || listening + review, !message && reload, !message && mixNote, finalMix].filter(Boolean).join(" "))
    pickOther.hidden = !other
    if (other) {
      text(pickOther, "Escolher " + name(other, true))
      text(arm, (choice ? "Atualizar com " : "Armar ") + name(kind(), true))
    } else text(arm, choice ? "Atualizar passagem" : "Armar esta passagem")
    text(listen, playing && !sequence ? "Parar ensaio" : "Ouvir no fone")
    cursor.hidden = !playing
    if (playing) cursor.style.left = Math.min(100, 100 * elapsed / plan.duration) + "%"
  }

  pickOther.onclick = () => {
    const other = comparison.alternative()
    if (other) dialog.querySelector(`input[value="${other}"]`).click()
  }

  arm.onclick = () => {
    update()
    if (arm.disabled) return
    keepDraft()
    if (plan.blendCurve && kind() === "blend" && !engine.canMeasureBlend(pair, plan.mix)) {
      failure = "A cabine mudou. No ensaio, copie os ajustes atuais e ouça a mistura novamente."
      update()
      return
    }
    if (kind() === "bass_swap" && !engine.canRecallBass(pair)) {
      failure = bassRecallHint
      update()
      return
    }
    const title = id => tracks[id]?.title || "Deck " + id.toUpperCase()
    const reference = {pair: name(kind(), true) + " · " + title(pair.from) + " → " + title(pair.to), hearing: comparison.reading()}
    if (engine.armPassage(pair, plan, kind(), reference).ok) {
      dialog.close()
      update()
      passageState.focus()
    } else {
      failure = "Deixe a faixa que sai tocando e o deck de entrada livre para armar."
      update()
    }
  }
  confirm.onclick = () => {
    if (!engine.confirmPassage().ok && engine.passage()?.phase === "armed") {
      const saved = engine.passage()
      if (saved.kind === "bass_swap" && !engine.canRecallBass(saved.pair)) text(passageState, bassRecallHint)
      else text(passageState, saved.kind === "blend" && saved.plan.blendCurve && !engine.canMeasureBlend(saved.pair, saved.plan.mix)
        ? "A cabine mudou. No ensaio, copie os ajustes atuais e ouça a mistura novamente."
        : "Solte os controles dos decks antes de confirmar a passagem.")
    }
    update()
    passageState.focus()
  }
  root.querySelector("[data-disarm]").onclick = () => {
    engine.disarmPassage()
    update()
    open.focus()
  }
  open.onclick = () => {
    preparePassageMeter(engine.ctx)
    pair = null
    // WebKit does not focus a clicked button. Give the native dialog its return target.
    open.focus({preventScroll: true})
    dialog.showModal()
    update()
  }
  dialog.querySelector("[data-close]").onclick = () => dialog.close()
  dialog.onclose = () => { blendReview.lock(); stop(true); assist.reset(); pair = plan = null }
  dialog.onchange = e => {
    if (e.target.matches("[data-mix]")) return
    if (e.target === second) { comparison.clearSummary(); update(); return }
    if (e.target.name === "dj-rehearse-kind" && comparison.alternative()) comparison.select(true)
    else stop(true)
    failure = ""
    draw()
    update()
  }
  for (const strip of strips) {
    const side = strip.dataset.side
    strip.oninput = e => {
      const key = e.target.dataset.mix
      if (!key || !plan) return
      const value = key === "vinyl" ? e.target.checked : Number(e.target.value) / 100 + (key === "rate" ? 1 : 0)
      editMix({...mix, [side]: {...mix[side], [key]: value}})
    }
    strip.querySelector("[data-sync]").onclick = () => {
      const {bpm, target} = syncTarget(side)
      const rate = syncedRate(mix[side].rate, bpm, target)
      if (rate !== mix[side].rate) editMix({...mix, [side]: {...mix[side], rate}})
      if (Math.abs(rate * bpm - target) > 0.01) {
        mixNote = "O alvo está fora do alcance de ±8% do SYNC."
        update()
      }
    }
    strip.querySelector("[data-pulse-sync]").onclick = () => {
      if (!plan || !hasPhones() || pending) return
      const {pulse} = syncTarget(side)
      if (!pulse) return
      stop()
      if (pulse.rate !== mix[side].rate) editMix({...mix, [side]: {...mix[side], rate: pulse.rate}})
      return play()
    }
  }
  copyMix.onclick = () => { if (plan) editMix(boothMix()) }
  function playTake(transition, id, keepPhones) {
    let measured
    const reading = new Promise(resolve => { measured = resolve })
    const marker = editedVersion(transition)
    const audio = transport.play(plan, transition, Number(pan.value), 0, (node, timing) => {
      const take = comparison.begin(transition)
      const bpm = engine.decks[pair.from].bpm * plan.mix.out.rate
      const cancel = measurePassage(engine.ctx, node, {...timing, bpm}, data => {
        if (dialog.open && id === request) {
          if (data) take.finish(scorePassage(data))
          else take.unavailable()
        }
        measured(true)
      })
      return () => { cancel(); take.cancel(); measured(false) }
    }, keepPhones).then(ended => {
      if (ended && marker && dialog.open && id === request && marker === editedVersion(transition)) {
        const focused = document.activeElement === replay
        edited.delete(transition)
        update()
        if (focused) (arm.disabled ? listen : arm).focus()
      }
      return ended
    })
    // The render thread may deliver its last reading just after the sound ends.
    return Promise.all([audio, reading]).then(([ended, reported]) => ended && reported)
  }

  async function play(compare = false, restart = false) {
    if (sequence || (!restart && transport.elapsed() !== null)) { stop(true); update(); return }
    failure = ""
    update()
    if (listen.disabled) return
    keepDraft()
    comparison.clearSummary()
    const id = ++request
    const first = kind()
    const kinds = compare ? [first, second.value] : [first]
    pending = true
    let compared = false
    try {
      if (compare) sequence = {kind: first, index: 0}
      update()
      await engine.ctx.resume()
      for (const [index, transition] of kinds.entries()) {
        update()
        if (id !== request || !dialog.open || !hasPhones()) return
        if (compare) {
          sequence = {kind: transition, index}
          draw()
        }
        const heard = playTake(transition, id, index + 1 < kinds.length)
        pending = false
        update()
        if (!compare || !(await heard)) break
        compared = index === kinds.length - 1
      }
    } catch {
      if (id === request) failure = "Não foi possível iniciar o ensaio. Tente novamente."
    } finally {
      if (id === request) {
        pending = false
        if (sequence) {
          sequence = null
          transport.stopListening()
          if (compared) comparison.finishPair(kinds)
          else comparison.select()
          draw()
        }
      }
      update()
    }
  }
  listen.onclick = () => play()
  both.onclick = () => play(true)
  replay.onclick = () => {
    if (!replay.hidden && !replay.disabled && !pending) return play(false, true)
  }
  const resize = new ResizeObserver(() => { if (dialog.open) draw() })
  resize.observe(lanes[0])
  return {update, stop, name, destroy() { blendReview.lock(); stop(); assist.reset(); score.destroy(); resize.disconnect(); if (dialog.open) dialog.close() }}
}
