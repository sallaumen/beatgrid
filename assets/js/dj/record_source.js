// Waveform-similarity overlap-add (WSOLA). Both stereo channels use the same
// splice, so changing tempo preserves pitch and stereo phase.
function bestSplice(channel, previous, target, hop, first, last) {
  const radius = Math.floor(hop / 3)
  const low = Math.max(first, target - radius), high = Math.min(last, target + radius)
  let best = Math.max(first, Math.min(target, last)), score = -Infinity
  function compare(start) {
    let dot = 0, energy = 0
    for (let i = 0; i < hop; i += 12) {
      const sample = channel[start + i] || 0
      dot += (channel[previous + i] || 0) * sample
      energy += sample * sample
    }
    const value = dot / Math.sqrt(energy + 1e-12)
    if (value > score) { score = value; best = start }
  }
  compare(best)
  for (let s = low; s <= high; s += 4) compare(s)
  const coarse = best
  for (let s = Math.max(low, coarse - 3); s <= Math.min(high, coarse + 3); s++) compare(s)
  return best
}

export function createRecordSource(ctx, buffer, {rate, vinyl}) {
  if (rate === 1 || vinyl) {
    const source = ctx.createBufferSource()
    source.buffer = buffer
    source.playbackRate.value = rate
    return source
  }

  const output = ctx.createGain()
  const channels = Array.from({length: buffer.numberOfChannels}, (_, i) => buffer.getChannelData(i))
  const sr = buffer.sampleRate, hop = Math.max(16, Math.round(sr * 0.02))
  const voices = new Set()
  let at, first, end, length, written = 0, previous, stopped = false, ended = false

  function queue() {
    if (written >= length || stopped) return
    // Two blocks ahead, bounded memory even when the native deck takes a long time to sync.
    const frames = Math.min(hop * 24, length - written)
    const block = ctx.createBuffer(channels.length, frames, sr)
    const when = at + written / sr
    for (let i = 0; i < frames; i += hop) {
      const tail = previous + hop
      let splice = first
      if (written > 0) {
        let loudest = channels[0], peak = 0
        for (const channel of channels) {
          let energy = 0
          for (let j = 0; j < hop; j += 16) energy += (channel[tail + j] || 0) ** 2
          if (energy > peak) { peak = energy; loudest = channel }
        }
        splice = bestSplice(loudest, tail, first + Math.round(written * rate), hop, first, Math.max(first, end - 2 * hop))
      }
      const count = Math.min(hop, frames - i)
      channels.forEach((channel, index) => {
        const out = block.getChannelData(index)
        for (let j = 0; j < count; j++) {
          const sample = splice + j < end ? channel[splice + j] : 0
          out[i + j] = written === 0 ? sample : (tail + j < end ? channel[tail + j] : 0) * (1 - j / hop) + sample * j / hop
        }
      })
      previous = splice
      written += count
    }
    const voice = ctx.createBufferSource()
    voices.add(voice)
    voice.buffer = block
    voice.connect(output)
    voice.onended = () => {
      voice.disconnect()
      voices.delete(voice)
      queue()
      if (!voices.size && !ended) { ended = true; output.onended?.() }
    }
    voice.start(when)
  }

  output.start = (when, offset, seconds = buffer.duration - offset) => {
    at = when
    first = Math.round(offset * sr)
    end = Math.min(buffer.length, first + Math.round(seconds * sr))
    length = Math.max(1, Math.round((end - first) / rate))
    queue()
    queue()
  }
  output.stop = (when = ctx.currentTime) => {
    stopped = true
    for (const voice of voices) voice.stop(when)
  }
  return output
}
