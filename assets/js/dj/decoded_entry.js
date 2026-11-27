import {startLiveRecord} from "./live_record.js"

const SEEK_RAMP_S = 0.004 // bridge unrelated waveform phases without delaying the new cue

// A media clock can advance before its decoder delivers the corresponding audio.
// The rehearsed recording owns the sound and playhead across bends and seeks.
export function startDecodedEntry(ctx, media, buffer, offset, input, mediaGain, onRelease, mix = {rate: media.playbackRate, vinyl: !media.preservesPitch}, repeatAtEnd) {
  const start = ctx.currentTime
  const tails = new Set()
  function play(at, rate, fade = 0, when = ctx.currentTime) {
    return startLiveRecord(ctx, input, buffer, at, {...mix, rate}, () => {
      if (!repeatAtEnd?.()) release(false, true)
    }, () => release(true), fade, when)
  }
  let source = play(offset, mix.rate)
  mediaGain.gain.cancelScheduledValues(start)
  mediaGain.gain.setValueAtTime(0, start)
  let closed = false

  function release(sync = false, ended = false) {
    if (closed) return
    closed = true
    const heard = source.position(), heardRate = source.rate()
    if (!ended && media.playbackRate !== heardRate) media.playbackRate = heardRate
    source.stop()
    for (const tail of tails) tail.stop()
    if (ended && !media.ended) media.currentTime = media.duration
    if (sync && Math.abs(media.currentTime - heard) > 0.02) media.currentTime = heard
    mediaGain.gain.cancelScheduledValues(ctx.currentTime)
    mediaGain.gain.setValueAtTime(1, ctx.currentTime)
    onRelease(ended)
  }

  function seek(seconds, positionAfter) {
    if (closed) return false
    if (seconds >= buffer.duration) { release(); return false }
    const prior = source, rate = prior.rate()
    // Both heads receive the same future audio timestamp. A loop carries the
    // setup time into its next lap; a hot cue plays its very first sample.
    const lead = prior.position() < buffer.duration ? 256 / ctx.sampleRate : 0
    const when = ctx.currentTime + lead
    const target = positionAfter?.(lead * rate) ?? seconds
    try {
      source = play(target, rate, SEEK_RAMP_S, when)
    } catch {
      release()
      return false
    }
    tails.add(prior)
    prior.stop(SEEK_RAMP_S, () => tails.delete(prior), when)
    return true
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
  return {position: () => closed ? media.currentTime : source.position(), rate: () => source.rate(), nudge, seek, release}
}
