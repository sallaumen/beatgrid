import {createRecordRenderer} from "./record_source.js"

// The audible recording owns both the clock and the samples. A new bend can
// replace queued blocks, never the block coming out of the speakers.
export function startLiveRecord(ctx, input, buffer, offset, mix, onEnd, onFailure) {
  const output = ctx.createGain()
  output.connect(input)
  const sr = buffer.sampleRate
  const start = ctx.currentTime
  const blocks = []
  let direct = null, renderer = null, closed = false, lastBend = -Infinity
  let next = {when: start, frame: Math.round(offset * sr), rate: mix.rate, previous: null}

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
    const horizon = ctx.currentTime + 2 * grains * renderer.hop / sr
    while (!closed && next.when < horizon - 1e-8 && next.frame < buffer.length) {
      const {when, frame, rate, previous} = next
      const frames = Math.max(1, Math.min(grains * renderer.hop, Math.round((buffer.length - frame) / rate)))
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
      try { voice.start(when) } catch (error) { dispose(voice); throw error }
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
      const finished = direct.until === Infinity
      dispose(voice)
      direct = null
      if (finished) onEnd()
    }
    voice.start(start, offset)
  } else {
    try { queue() } catch (error) { stop(); throw error }
  }

  function stop() {
    if (closed) return
    closed = true
    if (direct) dispose(direct.voice, true)
    for (const block of blocks.splice(0)) dispose(block.voice, true)
    output.disconnect()
  }
  return {position, rate: () => audibleSegment(ctx.currentTime)?.rate ?? next.rate, setRate, stop}
}
