import {analyzeCuePair, copyCueWindow} from "./cue_phase.js"

// Only this local worker sees PCM. Transfer private slices so the two decks
// and their waveform cache keep ownership of the full stereo recordings.
export function startCueAnalysis({out, into}, report) {
  let worker, url, closed = false
  function cancel() {
    closed = true
    worker?.terminate()
    if (url) URL.revokeObjectURL(url)
    url = null
  }
  function finish(result, failed = false) {
    if (closed) return
    cancel()
    report(result, failed)
  }
  try {
    if (Math.abs(into.bpm * into.rate / (out.bpm * out.rate) - 1) > .015) {
      queueMicrotask(() => finish(null))
      return cancel
    }
    const copy = deck => copyCueWindow(deck.buffer, deck.cue, deck.bpm, deck.rate)
    const clips = {out: copy(out), into: copy(into)}
    if (!clips.out || !clips.into) {
      queueMicrotask(() => finish(null))
      return cancel
    }
    const program = "self.onmessage = event => self.postMessage((" + analyzeCuePair.toString() + ")(event.data))"
    url = URL.createObjectURL(new Blob([program], {type: "text/javascript"}))
    worker = new Worker(url)
    worker.onmessage = ({data}) => finish(data)
    worker.onerror = () => finish(null, true)
    worker.onmessageerror = () => finish(null, true)
    worker.postMessage(clips, [...clips.out.channels, ...clips.into.channels].map(channel => channel.buffer))
  } catch {
    queueMicrotask(() => finish(null, true))
  }
  return cancel
}
