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
  if (deck.el.error) return "error"
  // The worklet owns the platter while scratching, even though the media is paused.
  if (scratchPosition != null) return "scratch"
  if (deck.el.ended) return "ended"
  if (!deck.ready()) return "loading"
  if (!deck.audible()) return "ready"
  return deck.cueState === "preview" ? "preview" : "playing"
}

export function paintDeckStatus(readout, deck, scratchPosition) {
  const state = mediaState(deck, scratchPosition)
  if (readout.dataset.state === state) return
  readout.dataset.state = state
  readout.textContent = LABELS[state]
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
