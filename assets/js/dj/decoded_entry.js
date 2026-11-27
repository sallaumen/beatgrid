import {startLiveRecord} from "./live_record.js"

const SEEK_RAMP_S = 0.004 // bridge unrelated waveform phases without delaying the new cue

// A media clock can advance before its decoder delivers the corresponding audio.
// The rehearsed recording owns the sound and playhead across bends and seeks.
export function startDecodedEntry(ctx, media, buffer, offset, input, mediaGain, onRelease, mix = {rate: media.playbackRate, vinyl: !media.preservesPitch}, repeatAtEnd, splice) {
  const start = ctx.currentTime
  const tails = new Set()
  function play(at, settings, fade = 0, when = ctx.currentTime, saved, recording = buffer) {
    return startLiveRecord(ctx, input, recording, at, settings, () => {
      if (!repeatAtEnd?.()) release(false, true)
    }, () => release(true), fade, when, saved)
  }
  let source = play(offset, mix, splice ? SEEK_RAMP_S : 0, start, splice)
  mediaGain.gain.cancelScheduledValues(start)
  if (splice) {
    mediaGain.gain.setValueAtTime(mediaGain.gain.value, source.fadeAt)
    mediaGain.gain.linearRampToValueAtTime(0, source.fadeAt + SEEK_RAMP_S)
  } else mediaGain.gain.setValueAtTime(0, start)
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

  function replace(at, settings, when, saved, recording) {
    const prior = source
    source = play(at, settings, SEEK_RAMP_S, when, saved, recording)
    tails.add(prior)
    prior.stop(SEEK_RAMP_S, () => tails.delete(prior), source.fadeAt)
  }

  function recall(recording, seconds, settings, saved) {
    // Allocate and schedule before retiring the audible head. Failure leaves
    // that head and both buses intact for the passage's rollback.
    replace(seconds, settings, ctx.currentTime, saved, recording)
    buffer = recording
    mix = settings
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
      replace(target, {...mix, rate}, when)
    } catch {
      release()
      return false
    }
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
  return {position: () => closed ? media.currentTime : source.position(), rate: () => source.rate(), nudge, seek, recall, release}
}
