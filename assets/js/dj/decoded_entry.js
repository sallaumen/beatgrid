import {startLiveRecord} from "./live_record.js"

// A media clock can advance before its decoder delivers the corresponding audio.
// The rehearsed recording owns the sound and playhead until a transport gesture or EOF.
export function startDecodedEntry(ctx, media, buffer, offset, input, mediaGain, onRelease, mix = {rate: media.playbackRate, vinyl: !media.preservesPitch}) {
  const start = ctx.currentTime
  const source = startLiveRecord(ctx, input, buffer, offset, mix, () => release(false, true), () => release(true))
  mediaGain.gain.cancelScheduledValues(start)
  mediaGain.gain.setValueAtTime(0, start)
  let closed = false

  function release(sync = false, ended = false) {
    if (closed) return
    closed = true
    const heard = source.position(), heardRate = source.rate()
    if (!ended && media.playbackRate !== heardRate) media.playbackRate = heardRate
    source.stop()
    if (ended && !media.ended) media.currentTime = media.duration
    if (sync && Math.abs(media.currentTime - heard) > 0.02) media.currentTime = heard
    mediaGain.gain.cancelScheduledValues(ctx.currentTime)
    mediaGain.gain.setValueAtTime(1, ctx.currentTime)
    onRelease(ended)
  }

  function nudge(rate) {
    try {
      source.setRate(rate)
      return true
    } catch {
      // If the device cannot allocate the next PCM block, the loaded media
      // remains available at the audible position for the normal jog fallback.
      release(true)
      return false
    }
  }
  return {position: () => closed ? media.currentTime : source.position(), rate: source.rate, nudge, release}
}
