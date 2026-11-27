import {createRecordSource} from "./record_source.js"

// The media element can report "playing" before it delivers any samples. Start
// with the already decoded record, then give the same passage back to the deck.
export function startDecodedEntry(ctx, media, buffer, offset, input, mediaGain, onRelease, mix = {rate: media.playbackRate, vinyl: !media.preservesPitch}) {
  const source = createRecordSource(ctx, buffer, mix)
  const level = ctx.createGain()
  const start = ctx.currentTime
  const rate = mix.rate
  const position = () => Math.min(buffer.duration, offset + (ctx.currentTime - start) * rate)
  source.connect(level)
  level.connect(input)
  source.start(start, offset)
  mediaGain.gain.cancelScheduledValues(start)
  mediaGain.gain.setValueAtTime(0, start)
  let last = media.currentTime, stable = 0, attempts = 0, adjustment = 0
  let nextSeek = start + 0.4, closed = false, aligned = false

  function release(sync = false, ended = false) {
    if (closed) return
    closed = true
    clearInterval(timer)
    source.onended = null
    source.stop()
    source.disconnect()
    level.disconnect()
    mediaGain.gain.cancelScheduledValues(ctx.currentTime)
    mediaGain.gain.setValueAtTime(1, ctx.currentTime)
    if (ended && !media.ended) media.currentTime = media.duration
    if (sync && Math.abs(media.currentTime - position()) > 0.02) media.currentTime = position()
    onRelease(ended)
  }

  const timer = setInterval(() => {
    const now = ctx.currentTime
    const pos = media.currentTime
    const drift = position() - pos
    const advancing = pos > last && !media.seeking && media.readyState >= 3
    last = pos
    stable = advancing && Math.abs(drift) < 0.012 ? stable + 1 : 0
    if (stable >= 3) {
      aligned = true
      clearInterval(timer)
      level.gain.setValueAtTime(1, now)
      level.gain.linearRampToValueAtTime(0, now + 0.012)
      mediaGain.gain.setValueAtTime(0, now)
      mediaGain.gain.linearRampToValueAtTime(1, now + 0.012)
      source.stop(now + 0.014)
    } else if (advancing && now >= nextSeek && Math.abs(drift) >= 0.012 && attempts < 4) {
      // Seek only the muted transport. Its decoder's measured lag is device-specific.
      adjustment += drift
      const target = position() + adjustment
      if (target >= buffer.duration - 0.25) return
      media.currentTime = Math.max(0, target)
      attempts++
      nextSeek = now + 0.5
    }
  }, 25)
  source.onended = () => release(false, !aligned)
  return {position: () => closed ? media.currentTime : position(), release}
}
