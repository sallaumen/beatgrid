import {mountCueAssist} from "./cue_assist.js"
import {measurePassage, preparePassageMeter} from "./passage_meter.js"
import {mountPassageComparison} from "./passage_comparison.js"
import {scorePassage} from "./passage_score.js"
import {mountPassageScore} from "./passage_score_view.js"
import {getDeckAudio} from "./waveform.js"
import {syncedRate} from "./deck_mix.js"
import {planRehearsal, recordTime, rehearsalGains} from "./rehearsal.js"

function text(el, value) {
  if (el.textContent !== value) el.textContent = value
}

function drawLane(canvas, wave, plan, kind, incoming) {
  const width = Math.max(1, canvas.clientWidth)
  const height = canvas.clientHeight
  const scale = window.devicePixelRatio || 1
  canvas.width = Math.round(width * scale)
  canvas.height = Math.round(height * scale)
  const g = canvas.getContext("2d")
  g.scale(scale, scale)
  g.fillStyle = incoming ? "#5ad1a0" : "#ffb020"
  const mid = height / 2
  for (let x = 0; x < width; x++) {
    const t = x / width * plan.duration
    const side = incoming ? "into" : "out"
    const pos = recordTime(plan, side, t)
    const gain = rehearsalGains(plan, kind, t)[incoming ? 1 : 0]
    const amp = gain * plan.mix[side].level * (wave.peaks[Math.floor(pos * wave.bps)] || 0) * mid
    g.fillRect(x, mid - amp, 1, Math.max(1, 2 * amp))
  }
  g.fillStyle = "#eef0f5"
  g.fillRect(width * plan.lead / plan.duration, 0, 1, height)
}

export function mountRehearsal({root, engine, tracks, waves, hint, hasPhones}) {
  const dialog = root.querySelector("dialog")
  const listen = dialog.querySelector("[data-listen]")
  const status = dialog.querySelector("[role=status]")
  const seconds = n => n.toLocaleString("pt-BR", {maximumFractionDigits: 2}) + " s"
  const timing = dialog.querySelector("[data-timing]")
  const cursor = dialog.querySelector("[data-cursor]")
  const pan = dialog.querySelector("select")
  const lanes = [...dialog.querySelectorAll("canvas")]
  const arm = dialog.querySelector("[data-arm]")
  const reservation = root.querySelector("[data-reservation]")
  const confirm = root.querySelector("[data-confirm]")
  const passageState = root.querySelector("[data-passage-state]")
  const open = root.querySelector("[aria-haspopup=dialog]")
  const transport = engine.rehearsal
  const score = mountPassageScore(dialog.querySelector("#dj-rehearsal-score"))
  const strips = [...dialog.querySelectorAll("[data-side]")]
  let lastChoice, lastPhase, lastEdit, mix, mixNote = ""
  let pair, plan, lastDeckCue, failure, pending = false, request = 0
  const kind = () => dialog.querySelector('input[name="dj-rehearse-kind"]:checked').value
  const comparison = mountPassageComparison(score, [...dialog.querySelectorAll("[data-score-for]")], kind)
  const assist = mountCueAssist(dialog.querySelector("[data-cue-assist]"), {audition: tryEntry, refresh: update})

  function stop() {
    request++
    pending = false
    transport.stop()
    comparison.select()
  }

  function draw() {
    if (!plan) {
      for (const lane of lanes) lane.width = lane.width
      return
    }
    text(timing, "Entrada em " + seconds(plan.lead) + " · " + (kind() === "cut" ? "corte" : "mistura de " + seconds(plan.blend)))
    drawLane(lanes[0], waves[pair.from], plan, kind(), false)
    drawLane(lanes[1], waves[pair.to], plan, kind(), true)
  }

  function boothMix() {
    return {out: engine.deckMix(pair.from), into: engine.deckMix(pair.to)}
  }

  function paintMix() {
    for (const strip of strips) {
      const side = strip.dataset.side, settings = mix[side]
      const id = side === "out" ? pair.from : pair.to
      const bpm = engine.decks[id].bpm
      text(strip.querySelector("[data-mix-deck]"), "Deck " + id.toUpperCase())
      text(strip.querySelector("[data-tempo]"), bpm ? (bpm * settings.rate).toLocaleString("pt-BR", {maximumFractionDigits: 1}) + " BPM" : "BPM desconhecido")
      strip.querySelector("[data-sync]").disabled = !engine.decks[pair.from].bpm || !engine.decks[pair.to].bpm
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
    stop()
    plan = next
    failure = ""
    draw()
    update()
    if (hasPhones()) play()
  }

  function editMix(next) {
    if (!plan) return
    engine.editPassageMix()
    mixNote = ""
    mix = next
    plan = withEntry(plan.inStart, plan.originalEntry)
    try {
      transport.edit(plan, kind(), Number(pan.value))
    } catch {
      stop()
      failure = "Não foi possível ouvir este ajuste. Tente novamente."
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
      reservation.hidden = !choice
      if (choice) {
        const {plan, kind, exitMs, pair, phase} = choice
        const name = kind === "cut" ? "Corte" : "Mistura de quatro tempos"
        const state = {armed: "Armada", confirmed: "Confirmada", starting: "Entrando na pista",
          missed: "O ponto ensaiado já passou", failed: "A entrada não ficou pronta"}
        const review = {live: "A cabine mudou. Confirme para usar os ajustes salvos", draft: "Versão salva · aguarda nova confirmação"}
        const label = phase === "armed" && choice.review ? review[choice.review] : state[phase]
        text(passageState, label + " · " + name + " · " + pair.from.toUpperCase() + " em " +
          seconds(exitMs / 1000) + " → " + pair.to.toUpperCase() + " em " + seconds(plan.inStart))
        confirm.hidden = confirm.disabled = phase !== "armed"
      }
    }
    if (!dialog.open) return
    const from = engine.audibleDeck() || engine.snapshot().activeDeck || "a"
    const to = from === "a" ? "b" : "a"
    const a = engine.decks[from], b = engine.decks[to]
    const out = tracks[from], into = tracks[to]
    const saved = choice?.pair.from === from && choice.pair.fromLoad === a.loadToken &&
      choice.pair.toLoad === b.loadToken ? choice : null
    if (pair?.from !== from || pair.fromLoad !== a.loadToken || pair.toLoad !== b.loadToken) {
      stop()
      assist.reset()
      lastDeckCue = null
      pair = {from, to, fromLoad: a.loadToken, toLoad: b.loadToken}
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
      text(dialog.querySelector("[data-in]"), label(to, into))
      draw()
    }
    const ready = waves[from]?.peaks && waves[to]?.peaks
    if (!plan && ready && out && into && !a.el.error && !b.el.error) {
      const outgoing = getDeckAudio(out.id), incoming = getDeckAudio(into.id)
      if (outgoing && incoming) {
        const armed = hint()?.deck === to && hint()?.track.id === into.id
        const point = armed ? engine.firePointMs() : null
        const outro = out.markers?.find(m => m.type === "outro")?.ms
        const exit = point ?? outro
        plan = saved?.plan ?? planRehearsal(outgoing, incoming, exit == null ? null : exit / 1000, b.platterTime(), a.bpm, mix)
        if (plan) draw()
      }
    }
    // The saved version owns its cue. A fresh draft follows an explicit move on the idle deck.
    const deckCue = b.platterTime()
    if (!saved && plan && !b.audible() && lastDeckCue != null && Math.abs(deckCue - lastDeckCue) > 0.001) {
      stop()
      plan = withEntry(deckCue, null)
      draw()
    }
    lastDeckCue = deckCue
    comparison.bind(pair, plan, a.bpm)
    for (const strip of strips) strip.disabled = !plan
    const phones = hasPhones()
    assist.update({plan, pair, kind: kind(), outBpm: a.bpm, intoBpm: b.bpm, deckCue, phones})
    const elapsed = transport.elapsed()
    let message = failure
    if (!out || !into) message = "Carregue uma faixa em cada deck para ensaiar."
    else if (a.el.error || b.el.error || waves[from]?.failed || waves[to]?.failed) message = "Não foi possível ler o áudio de um dos decks."
    else if (!ready) message = "Preparando as ondas das duas faixas…"
    else if (!plan) message = "Reposicione o deck de entrada antes do fim da faixa."
    else if (!phones) message = "Escolha uma saída separada em Fone (cue) para ouvir."
    if (message && (elapsed !== null || pending)) stop()
    const playing = transport.elapsed() !== null
    const listening = playing ? "Tocando só no fone." : pending ? "Abrindo o fone…" : "Pronto para ouvir no fone."
    const review = choice?.review === "draft" ? " A versão anterior está salva e aguarda confirmação." : ""
    text(status, message || [listening + review, mixNote].filter(Boolean).join(" "))
    listen.disabled = !plan || !phones || !!a.el.error || !!b.el.error || pending
    arm.disabled = !plan || !a.audible() || b.audible() || !b.ready() || !!b.el.error ||
      a.positionMs() > Math.round(plan.exit * 1000) || choice?.phase === "starting"
    if (plan && a.audible() && a.positionMs() > plan.exit * 1000 && !playing) {
      text(status, "O ponto ensaiado já passou nesta faixa.")
    }
    text(arm, choice ? "Atualizar passagem" : "Armar esta passagem")
    text(listen, playing ? "Parar ensaio" : "Ouvir no fone")
    cursor.hidden = !playing
    if (playing) cursor.style.left = Math.min(100, 100 * elapsed / plan.duration) + "%"
  }

  arm.onclick = () => {
    update()
    if (arm.disabled) return
    if (engine.armPassage(pair, plan, kind()).ok) {
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
      text(passageState, "Solte os controles dos decks antes de confirmar a passagem.")
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
  dialog.onclose = () => { stop(); assist.reset(); pair = plan = null }
  dialog.onchange = e => {
    if (e.target.matches("[data-mix]")) return
    stop(); failure = ""; draw(); update()
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
      const other = side === "out" ? "into" : "out"
      const a = engine.decks[pair.from].bpm, b = engine.decks[pair.to].bpm
      const bpm = side === "out" ? a : b
      const target = (side === "out" ? b : a) * mix[other].rate
      const rate = syncedRate(mix[side].rate, bpm, target)
      editMix({...mix, [side]: {...mix[side], rate}})
      if (Math.abs(rate * bpm - target) > 0.01) {
        mixNote = "O alvo está fora do alcance de ±8% do SYNC."
        update()
      }
    }
  }
  dialog.querySelector("[data-copy-mix]").onclick = () => { if (plan) editMix(boothMix()) }
  async function play() {
    if (transport.elapsed() !== null) { stop(); update(); return }
    failure = ""
    update()
    if (listen.disabled) return
    const id = ++request
    pending = true
    try {
      await engine.ctx.resume()
      update()
      if (id !== request || !dialog.open || !hasPhones()) return
      transport.play(plan, kind(), Number(pan.value), 0, (node, timing) => {
        const take = comparison.begin(timing.kind)
        const bpm = engine.decks[pair.from].bpm * plan.mix.out.rate
        const cancel = measurePassage(engine.ctx, node, {...timing, bpm}, data => {
          if (!dialog.open || id !== request) return
          if (data) take.finish(scorePassage(data))
          else take.unavailable()
        })
        return () => { cancel(); take.cancel() }
      })
    } catch {
      if (id === request) failure = "Não foi possível iniciar o ensaio. Tente novamente."
    } finally {
      if (id === request) pending = false
      update()
    }
  }
  listen.onclick = play
  const resize = new ResizeObserver(() => { if (dialog.open) draw() })
  resize.observe(lanes[0])
  return {update, stop, destroy() { stop(); assist.reset(); score.destroy(); resize.disconnect(); if (dialog.open) dialog.close() }}
}
