import {getDeckAudio} from "./waveform.js"
import {planRehearsal, rehearsalGains} from "./rehearsal.js"

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
    const recordTime = incoming ? plan.inStart + t - plan.lead : plan.outStart + t
    const gain = rehearsalGains(plan, kind, t)[incoming ? 1 : 0]
    const amp = gain * (wave.peaks[Math.floor(recordTime * wave.bps)] || 0) * mid
    g.fillRect(x, mid - amp, 1, Math.max(1, 2 * amp))
  }
  g.fillStyle = "#eef0f5"
  g.fillRect(width * plan.lead / plan.duration, 0, 1, height)
}

export function mountRehearsal({root, engine, tracks, waves, hint, hasPhones}) {
  const dialog = root.querySelector("dialog")
  const listen = dialog.querySelector("[data-listen]")
  const status = dialog.querySelector("[role=status]")
  const timing = dialog.querySelector("[data-timing]")
  const cursor = dialog.querySelector("[data-cursor]")
  const pan = dialog.querySelector("select")
  const lanes = [...dialog.querySelectorAll("canvas")]
  const transport = engine.rehearsal
  let pair, plan, failure, pending = false, request = 0
  const kind = () => dialog.querySelector("input:checked").value

  function stop() {
    request++
    pending = false
    transport.stop()
  }

  function draw() {
    if (!plan) {
      for (const lane of lanes) lane.width = lane.width
      return
    }
    drawLane(lanes[0], waves[pair.from], plan, kind(), false)
    drawLane(lanes[1], waves[pair.to], plan, kind(), true)
  }

  function update() {
    if (!dialog.open) return
    const from = engine.audibleDeck() || engine.snapshot().activeDeck || "a"
    const to = from === "a" ? "b" : "a"
    const a = engine.decks[from], b = engine.decks[to]
    const out = tracks[from], into = tracks[to]
    if (pair?.from !== from || pair.a !== a.loadToken || pair.b !== b.loadToken) {
      stop()
      pair = {from, to, a: a.loadToken, b: b.loadToken}
      plan = null
      failure = ""
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
        plan = planRehearsal(outgoing, incoming, exit == null ? null : exit / 1000, b.platterTime(), a.bpm)
        if (plan) {
          const seconds = n => n.toLocaleString("pt-BR", {maximumFractionDigits: 1}) + " s"
          text(timing, "Linha de entrada em " + seconds(plan.lead) + " · trecho de " + seconds(plan.duration))
          draw()
        }
      }
    }
    const phones = hasPhones()
    const elapsed = transport.elapsed()
    let message = failure
    if (!out || !into) message = "Carregue uma faixa em cada deck para ensaiar."
    else if (a.el.error || b.el.error || waves[from]?.failed || waves[to]?.failed) message = "Não foi possível ler o áudio de um dos decks."
    else if (!ready) message = "Preparando as ondas das duas faixas…"
    else if (!plan) message = "Reposicione o deck de entrada antes do fim da faixa."
    else if (!phones) message = "Escolha uma saída separada em Fone (cue) para ouvir."
    if (message && (elapsed !== null || pending)) stop()
    const playing = transport.elapsed() !== null
    text(status, message || (playing ? "Tocando só no fone." : pending ? "Abrindo o fone…" : "Pronto para ouvir no fone."))
    listen.disabled = !plan || !phones || !!a.el.error || !!b.el.error || pending
    text(listen, playing ? "Parar ensaio" : "Ouvir no fone")
    cursor.hidden = !playing
    if (playing) cursor.style.left = Math.min(100, 100 * elapsed / plan.duration) + "%"
  }

  root.querySelector("[aria-haspopup=dialog]").onclick = () => {
    pair = null
    dialog.showModal()
    update()
  }
  dialog.querySelector("[data-close]").onclick = () => dialog.close()
  dialog.onclose = () => { stop(); pair = plan = null }
  dialog.onchange = () => { stop(); failure = ""; draw(); update() }
  listen.onclick = async () => {
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
      transport.play(plan, kind(), Number(pan.value))
    } catch {
      if (id === request) failure = "Não foi possível iniciar o ensaio. Tente novamente."
    } finally {
      if (id === request) pending = false
      update()
    }
  }
  const resize = new ResizeObserver(() => { if (dialog.open) draw() })
  resize.observe(lanes[0])
  return {update, stop, destroy() { stop(); resize.disconnect(); if (dialog.open) dialog.close() }}
}
