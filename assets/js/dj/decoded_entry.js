import {startLiveRecord} from "./live_record.js"

const SEEK_RAMP_S = 0.004 // bridge unrelated waveform phases without delaying the new cue

// A media clock can advance before its decoder delivers the corresponding audio.
// The rehearsed recording owns the sound and playhead across bends and seeks.
export function startDecodedEntry(ctx, media, buffer, offset, input, mediaGain, onRelease, mix = {rate: media.playbackRate, vinyl: !media.preservesPitch}, repeatAtEnd, stage, softenStart = false) {
  const start = ctx.currentTime
  const tails = new Set()
  function play(at, settings, fade = 0, when = ctx.currentTime, saved, recording = buffer, staged = false) {
    return startLiveRecord(ctx, input, recording, at, settings, () => {
      if (!repeatAtEnd?.()) release(false, true)
    }, () => release(true), fade, when, saved, staged)
  }
  const bridge = stage?.outgoing
  // A released scratch can land off zero while the worklet fades out.
  let source = play(offset, mix, bridge || softenStart ? SEEK_RAMP_S : 0, start, stage?.splice, buffer, !!stage)
  function takeMedia(when) {
    mediaGain.gain.cancelScheduledValues(when)
    if (bridge) {
      mediaGain.gain.setValueAtTime(mediaGain.gain.value, when)
      mediaGain.gain.linearRampToValueAtTime(0, when + SEEK_RAMP_S)
    } else mediaGain.gain.setValueAtTime(0, when)
  }
  if (!stage) takeMedia(source.fadeAt)
  let closed = false

  function release(sync = false, ended = false) {
    if (closed) return
    closed = true
    const heard = source.position(), heardRate = source.rate()
    // A paused player already holds the steady tempo chosen for the next PLAY.
    if (!ended && !media.paused && media.playbackRate !== heardRate) media.playbackRate = heardRate
    source.stop()
    for (const tail of tails) tail.stop()
    if (ended && (!media.ended || media.error)) {
      media.currentTime = !media.error && Number.isFinite(media.duration) ? media.duration : buffer.duration
    }
    if (sync && Math.abs(media.currentTime - heard) > 0.02) media.currentTime = heard
    mediaGain.gain.cancelScheduledValues(ctx.currentTime)
    mediaGain.gain.setValueAtTime(1, ctx.currentTime)
    onRelease(ended)
  }

  function adopt(replacement) {
    const prior = source
    source = replacement
    tails.add(prior)
    prior.stop(SEEK_RAMP_S, () => tails.delete(prior), source.fadeAt)
  }

  function prepareRecall(recording, at, settings, saved) {
    const ready = play(at, settings, SEEK_RAMP_S, ctx.currentTime, saved, recording, true)
    let restore
    function commit() {
      restore = null
      adopt(ready)
      buffer = recording
      mix = settings
    }
    return {
      launch(when, head) { ready.launch(when, head); commit() },
      schedule(when, head) {
        ready.launch(when, head)
        // A gain ramp is revocable; a scheduled stop on the live source is not.
        restore = source.fadeOut(when, SEEK_RAMP_S)
      },
      commit,
      discard() { restore?.(); ready.stop() }
    }
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
      adopt(play(target, {...mix, rate}, SEEK_RAMP_S, when))
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
  function setMode(vinyl, rate) {
    if (closed) return false
    if (mix.vinyl === vinyl) return nudge(rate)
    let replacement
    try {
      replacement = prepareRecall(buffer, source.position(), {vinyl, rate})
      const when = ctx.currentTime + 256 / ctx.sampleRate
      replacement.launch(when, source.position(when))
      return true
    } catch {
      replacement?.discard()
      release(true)
      return false
    }
  }

  return {position: time => closed ? media.currentTime : source.position(time), rate: () => source.rate(),
    nudge, setMode, seek, prepareRecall, release,
    launch(when, head) { source.launch(when, head); takeMedia(when) }, discard: () => source.stop()}
}
