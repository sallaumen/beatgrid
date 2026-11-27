import {createRecordRenderer} from "./record_source.js"

// The audible recording owns both the clock and the samples. A new bend can
// replace queued blocks, never the block coming out of the speakers.
export function startLiveRecord(ctx, input, buffer, offset, mix, onEnd, onFailure, fadeIn = 0, start = ctx.currentTime, saved) {
  const output = ctx.createGain()
  output.connect(input)
  const sr = buffer.sampleRate
  let fadeAt = start
  if (fadeIn) {
    // A fractional buffer offset can start one sample before the timed ramp.
    output.gain.value = 0
  }
  const blocks = []
  let silenceTail = null
  let direct = null, renderer = null, closed = false, lastBend = -Infinity
  let next = {when: start, frame: Math.round(offset * sr), rate: mix.rate, previous: null}
  let renderEnd = buffer.length, skip = 0
  if (saved) {
    skip = saved.skip
    renderEnd = saved.end
    renderer = createRecordRenderer(ctx, buffer, saved.first, renderEnd)
    next = {when: start - skip / sr, frame: saved.frame, rate: mix.rate, previous: saved.previous}
  }

  function dispose(voice, stop = false) {
    voice.onended = null
    if (stop) voice.stop()
    voice.disconnect()
  }

  function audibleSegment(time) {
    if (direct && time < direct.until) return direct
    return blocks.findLast(b => b.when <= time) ?? blocks[0]
  }

  function position(time = ctx.currentTime) {
    const part = audibleSegment(time)
    if (!part) return next.frame / sr
    return Math.min(buffer.duration, part.offset + Math.max(0, time - part.when) * part.rate)
  }

  function queue() {
    if (!renderer) renderer = createRecordRenderer(ctx, buffer, Math.round(offset * sr), buffer.length)
    // Keep the full 960 ms runway of the rehearsal when steady. While the
    // wheel moves, precompute 240 ms and replace only its unplayed blocks.
    const grains = ctx.currentTime - lastBend < 0.24 ? 6 : 24
    const horizon = ctx.currentTime + (2 * grains * renderer.hop - skip) / sr
    while (!closed && next.when < horizon - 1e-8 && next.frame < buffer.length) {
      const {when, frame, rate, previous} = next
      if (frame >= renderEnd - rate / 2 && renderEnd < buffer.length) {
        // A rescue may let the deck run beyond the outgoing audio heard privately.
        renderEnd = buffer.length
        renderer = createRecordRenderer(ctx, buffer, saved.first, renderEnd)
      }
      const frames = Math.max(1, Math.min(grains * renderer.hop, Math.round((renderEnd - frame) / rate)))
      const splices = []
      const rendered = renderer.render(frame, rate, previous, frames, splices)
      const voice = ctx.createBufferSource()
      const block = {...next, offset: frame / sr, frames, splices, voice}
      voice.buffer = rendered.block
      voice.connect(output)
      next = {when: when + frames / sr, frame: Math.min(buffer.length, frame + frames * rate),
        previous: rendered.previous, rate}
      voice.onended = () => {
        dispose(voice)
        const index = blocks.indexOf(block)
        if (index < 0) return
        blocks.splice(index, 1)
        try { queue() } catch { onFailure(); return }
        if (!closed && !blocks.length) onEnd()
      }
      const audibleAt = saved ? Math.max(when + skip / sr, ctx.currentTime) : when
      try { voice.start(audibleAt, Math.max(0, audibleAt - when)) } catch (error) { dispose(voice); throw error }
      skip = 0
      blocks.push(block)
    }
  }

  function setRate(rate) {
    if (closed) return
    const now = ctx.currentTime
    if (direct && mix.vinyl) {
      if (direct.rate === rate) return
      direct.offset = position(now)
      direct.when = now
      direct.rate = rate
      direct.voice.playbackRate.setValueAtTime(rate, now)
      return
    }
    // Leave two render quanta for Web Audio to accept a new scheduling command.
    const earliest = now + 256 / ctx.sampleRate
    if (direct?.until === Infinity) {
      if (rate === direct.rate || position(earliest) >= buffer.duration) return
      const frame = position(earliest) * sr
      renderer = createRecordRenderer(ctx, buffer, Math.round(offset * sr), buffer.length)
      next = {when: earliest, frame, rate, previous: Math.round(frame) - renderer.hop}
      direct.until = earliest
      direct.voice.stop(earliest)
    } else {
      // Cut on a grain boundary inside the long scheduled buffer. Its prior
      // splice belongs to the actual outgoing sound, including after reversal.
      const hop = renderer.hop
      let index = blocks.findIndex(b => b.when + b.frames / sr > earliest)
      if (index < 0) return
      let block = blocks[index]
      let samples = Math.max(0, Math.ceil((earliest - block.when) * sr / hop)) * hop
      if (samples >= block.frames) {
        block = blocks[++index]
        if (!block) return
        samples = 0
      }
      if (block.rate === rate && next.rate === rate) return
      const when = block.when + samples / sr
      const previous = samples ? block.splices[samples / hop - 1] : block.previous
      next = {when, frame: block.frame + samples * block.rate, previous, rate}
      if (samples) {
        block.frames = samples
        block.voice.stop(when)
        index++
      }
      for (const future of blocks.splice(index)) dispose(future.voice, true)
    }
    lastBend = now
    queue()
  }

  if (mix.vinyl || mix.rate === 1) {
    const voice = ctx.createBufferSource()
    direct = {voice, when: start, offset, rate: mix.rate, until: Infinity}
    voice.buffer = buffer
    voice.playbackRate.value = mix.rate
    voice.connect(output)
    voice.onended = () => {
      if (closed || direct?.voice !== voice) return
      const finished = direct.until === Infinity
      if (finished) { next.frame = buffer.length; next.rate = direct.rate }
      dispose(voice)
      direct = null
      if (finished) onEnd()
    }
    voice.start(start, offset)
  } else {
    try { queue() } catch (error) { stop(); throw error }
  }
  if (fadeIn) {
    // Keep the existing head audible if preparing the new one took a render quantum.
    fadeAt = Math.max(start, ctx.currentTime)
    output.gain.setValueAtTime(0, fadeAt)
    output.gain.linearRampToValueAtTime(1, fadeAt + fadeIn)
  }

  function stop(fade = 0, finished, when = ctx.currentTime) {
    if (closed) {
      if (!fade) silenceTail?.()
      return
    }
    closed = true
    const voices = new Set(blocks.splice(0).map(block => block.voice))
    if (direct) voices.add(direct.voice)
    function finish() {
      silenceTail = null
      output.disconnect()
      finished?.()
    }
    function detach(voice, immediate) {
      dispose(voice, immediate)
      voices.delete(voice)
      if (!voices.size) finish()
    }
    if (!voices.size) return finish()
    const silence = () => { for (const voice of voices) detach(voice, true) }
    if (!fade) return silence()

    const until = when + fade
    const level = fadeIn ? Math.max(0, Math.min(1, (when - fadeAt) / fadeIn)) : 1
    output.gain.cancelScheduledValues(when)
    output.gain.setValueAtTime(level, when)
    output.gain.linearRampToValueAtTime(0, until)
    silenceTail = silence
    for (const voice of voices) {
      voice.onended = () => detach(voice, false)
      voice.stop(until)
    }
  }
  return {position, rate: () => audibleSegment(ctx.currentTime)?.rate ?? next.rate, setRate, stop, fadeAt}
}
