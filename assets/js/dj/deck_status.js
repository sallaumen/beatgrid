const LABELS = {
  empty: "Vazio",
  loading: "Carregando",
  ready: "Pronto",
  playing: "Tocando",
  preview: "Pré-escuta",
  scratch: "Scratch",
  ended: "Fim",
  error: "Erro de áudio",
}

function mediaState(deck, scratchPosition) {
  if (deck.trackId == null) return "empty"
  // The worklet owns the platter while scratching, even though the media is paused.
  if (scratchPosition != null) return "scratch"
  if (!deck.entry) {
    if (deck.stoppedRecordingState) return deck.stoppedRecordingState
    if (deck.el.error) return "error"
    if (deck.ended()) return "ended"
    if (!deck.ready()) return "loading"
  }
  if (!deck.audible()) return "ready"
  return deck.cueState === "preview" ? "preview" : "playing"
}

export function paintDeckStatus(readout, deck, scratchPosition) {
  const state = mediaState(deck, scratchPosition)
  if (readout.dataset.state === state) return
  readout.dataset.state = state
  readout.textContent = LABELS[state]
}

export function paintPitchWait(label, deck) {
  if (!label) return
  const waiting = deck.pitchOnResume ? "Pitch ao retomar" : "Pitch pendente"
  const text = deck.pitchPending ? waiting : ""
  if (label.textContent === text) return
  label.textContent = text
  if (text && deck.pitchOnResume) label.title = "A forma de onda falhou. O pitch escolhido entra na próxima reprodução."
  else if (text) label.title = "O pitch escolhido entra quando a forma de onda carregar."
  else label.removeAttribute("title")
}

export function syncFeedback(deck, other, matched) {
  const tempo = (deck.bpm * deck.baseRate).toFixed(1).replace(".", ",")
  const target = (other.bpm * other.baseRate).toFixed(1).replace(".", ",")
  const name = deck.id.toUpperCase()
  const result = deck.pitchPending ? `SYNC solicitado no deck ${name} para ${tempo} BPM` : `Deck ${name} em ${tempo} BPM`
  if (!matched) return `${result}. O alvo de ${target} BPM está fora do alcance de ±8% do SYNC.`
  if (other.pitchPending) return `${result}. O alvo ainda está pendente no deck ${other.id.toUpperCase()}.`
  return deck.pitchPending ? result : `SYNC no deck ${name} · ${tempo} BPM`
}

export function paintLoopRegion(region, deck) {
  if (!region) return
  const {on, startMs, endMs} = deck.loop
  const durationMs = Number.isFinite(deck.el.duration) ? deck.el.duration * 1000 : deck.durationMs
  if (!on || endMs == null || !(durationMs > 0)) {
    region.style.display = "none"
    return
  }
  region.style.left = `${startMs / durationMs * 100}%`
  region.style.width = `${(endMs - startMs) / durationMs * 100}%`
  region.style.display = "block"
}
