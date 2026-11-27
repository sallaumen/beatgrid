import {createRecordSource} from "./record_source.js"

// A media clock can advance before its decoder delivers the corresponding audio.
// The rehearsed recording owns the sound and playhead until a transport gesture or EOF.
export function startDecodedEntry(ctx, media, buffer, offset, input, mediaGain, onRelease, mix = {rate: media.playbackRate, vinyl: !media.preservesPitch}) {
  const source = createRecordSource(ctx, buffer, mix)
  const start = ctx.currentTime
  const position = () => Math.min(buffer.duration, offset + (ctx.currentTime - start) * mix.rate)
  source.connect(input)
  source.start(start, offset)
  mediaGain.gain.cancelScheduledValues(start)
  mediaGain.gain.setValueAtTime(0, start)
  let closed = false

  function release(sync = false, ended = false) {
    if (closed) return
    closed = true
    source.onended = null
    source.stop()
    source.disconnect()
    if (ended && !media.ended) media.currentTime = media.duration
    if (sync && Math.abs(media.currentTime - position()) > 0.02) media.currentTime = position()
    mediaGain.gain.cancelScheduledValues(ctx.currentTime)
    mediaGain.gain.setValueAtTime(1, ctx.currentTime)
    onRelease(ended)
  }

  source.onended = () => release(false, true)
  return {position: () => closed ? media.currentTime : position(), release}
}
