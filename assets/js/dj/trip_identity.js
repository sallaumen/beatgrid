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
