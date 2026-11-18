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
