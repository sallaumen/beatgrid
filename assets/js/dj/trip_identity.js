// The payload already carries the same normalized display key as the server.
// A hint can also be loaded in a deck; repeating that ID is not ambiguity.
export function tripVersionPath(track, candidates) {
  if (!track?.rel_path || !track.identity_key) return ""
  const [title, artist] = track.identity_key
  const ambiguous = candidates.some(other =>
    other && other.id !== track.id &&
    other.identity_key?.[0] === title && other.identity_key?.[1] === artist
  )
  return ambiguous ? track.rel_path : ""
}

// Transport state comes from the engine's logical active deck and media state,
// not from merely having a track loaded (or a preview held in headphones).
export function tripTransportLabel(snapshot, deck) {
  if (snapshot.breather) return "Respiro"
  const active = snapshot.activeDeck && snapshot[snapshot.activeDeck]
  if (!active?.trackId || deck?.el?.ended || deck?.el?.error) return "Sem reprodução"
  if (active.playing && !deck?.cueState) return "Tocando agora"
  return snapshot.waitingForNext ? "Sem reprodução" : "Faixa pausada"
}

export function tripTransitionLabel(hint) {
  if (!hint?.track) return ""
  return `${hint.transition?.breather ? "Respiro · " : ""}${hint.transition_label || "SEQ"}`
}
