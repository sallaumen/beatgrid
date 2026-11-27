// Waveform-similarity overlap-add (WSOLA). Both stereo channels use the same
// splice, so changing tempo preserves pitch and stereo phase.

// A brief burst of high-frequency energy marks a drum attack. Keep that part on
// the musical clock instead of moving it to the most similar neighboring wave.
function nearAttack(channel, target, hop, stride, first, last) {
  const frame = Math.max(4, Math.round(hop / 4))
  const start = Math.max(first, target - 2 * hop)
  const end = Math.min(channel.length, last + 2 * hop, target + 3 * hop)
  let highSum = 0, highPeak = 0, energyPeak = 0, frames = 0
  for (let base = start; base + frame <= end; base += frame) {
    let high = 0, power = 0
    for (let i = base + 2 * stride; i < base + frame; i += stride) {
      const x = channel[i]
      const detail = x - 2 * channel[i - stride] + channel[i - 2 * stride]
      high += detail * detail
      power += x * x
    }
    highSum += high
    highPeak = Math.max(highPeak, high)
    energyPeak = Math.max(energyPeak, power)
    frames++
  }
  // Require both appreciable brightness and a 5 ms frame at four times the
  // local mean so sustained notes and leakage in a silent channel stay locked.
  return highPeak > energyPeak * 0.015 && highPeak * frames > highSum * 4
}

function bestSplice(channel, previous, target, hop, first, last) {
  const nominal = Math.max(first, Math.min(target, last))
  const coarseStep = Math.max(1, Math.round(hop / 80))
  if (nearAttack(channel, target, hop, coarseStep, first, last)) return nominal
  // ±20 ms covers a cycle down to 25 Hz. Use a fixed number of coarse
  // candidates and comparison samples even for high sample-rate recordings.
  const low = Math.max(first, target - hop), high = Math.min(last, target + hop)
  const scoreStep = Math.max(1, Math.round(hop / 64))
  let best = nominal, score = -Infinity
  function compare(start) {
    let dot = 0, energy = 0
    for (let i = 0; i < hop; i += scoreStep) {
      const sample = channel[start + i] || 0
      dot += (channel[previous + i] || 0) * sample
      energy += sample * sample
    }
    const value = dot / Math.sqrt(energy + 1e-12)
    if (value > score) { score = value; best = start }
  }
  compare(best)
  for (let s = low; s <= high; s += coarseStep) compare(s)
  const coarse = best
  for (let s = Math.max(low, coarse - coarseStep + 1); s <= Math.min(high, coarse + coarseStep - 1); s++) compare(s)
  return best
}

// Render a block from a record position. Continuing with its last splice keeps
// both channels phase-continuous when the next block has a different tempo.
export function createRecordRenderer(ctx, buffer, first, end) {
  const channels = Array.from({length: buffer.numberOfChannels}, (_, i) => buffer.getChannelData(i))
  const sr = buffer.sampleRate, hop = Math.max(16, Math.round(sr * 0.02))
  function render(recordFrame, rate, previous, frames, splices) {
    const block = ctx.createBuffer(channels.length, frames, sr)
    for (let i = 0; i < frames; i += hop) {
      const tail = previous == null ? null : previous + hop
      let splice = Math.round(recordFrame + i * rate)
      if (tail != null) {
        let loudest = channels[0], peak = 0
        for (const channel of channels) {
          let energy = 0
          for (let j = 0; j < hop; j += 16) energy += (channel[tail + j] || 0) ** 2
          if (energy > peak) { peak = energy; loudest = channel }
        }
        splice = bestSplice(loudest, tail, splice, hop, first, Math.max(first, end - 2 * hop))
      }
      const count = Math.min(hop, frames - i)
      channels.forEach((channel, index) => {
        const out = block.getChannelData(index)
        for (let j = 0; j < count; j++) {
          const sample = splice + j < end ? channel[splice + j] : 0
          out[i + j] = tail == null ? sample : (tail + j < end ? channel[tail + j] : 0) * (1 - j / hop) + sample * j / hop
        }
      })
      splices?.push(splice)
      previous = splice
    }
    return {block, previous}
  }
  return {render, hop}
}

// Only the grains around an accepted cue can be recalled. The sample data stays
// in its original recording; the tiny list identifies the splice before each grain.
export function recallSplice(saved, buffer, seconds, rate) {
  if (!saved || rate !== saved.rate) return null
  const output = Math.round((seconds * buffer.sampleRate - saved.first) / rate)
  const grain = Math.floor(output / saved.hop)
  const previous = saved.prior[grain - saved.begin]
  if (previous === undefined) return null
  return {first: saved.first, end: saved.end, previous, skip: output % saved.hop,
    frame: saved.first + grain * saved.hop * rate}
}

export function createRecordSource(ctx, buffer, {rate, vinyl}, cue) {
  if (rate === 1 || vinyl) {
    const source = ctx.createBufferSource()
    source.buffer = buffer
    source.playbackRate.value = rate
    return source
  }

  const output = ctx.createGain()
  const sr = buffer.sampleRate
  const voices = new Set()
  let at, first, length, renderer, memory, written = 0, previous, stopped = false, ended = false
  if (Number.isFinite(cue)) {
    output.splices = () => memory?.prior.length ? {...memory, prior: memory.prior.slice()} : null
  }

  function queue() {
    if (written >= length || stopped) return
    const frames = Math.min(renderer.hop * 24, length - written)
    const when = at + written / sr
    const grain = written / renderer.hop
    const collect = memory && grain <= memory.last && grain + frames / renderer.hop > memory.begin
    const points = collect ? [] : null
    const rendered = renderer.render(first + written * rate, rate, previous, frames, points)
    if (points) {
      for (let i = Math.max(0, memory.begin - grain); i < points.length && grain + i <= memory.last; i++) {
        memory.prior[grain + i - memory.begin] = i ? points[i - 1] : previous ?? null
      }
    }
    previous = rendered.previous
    written += frames
    const voice = ctx.createBufferSource()
    voices.add(voice)
    voice.buffer = rendered.block
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
    const end = Math.min(buffer.length, first + Math.round(seconds * sr))
    renderer = createRecordRenderer(ctx, buffer, first, end)
    if (Number.isFinite(cue)) {
      const grainAt = seconds => Math.floor((seconds * sr - first) / (rate * renderer.hop))
      memory = {rate, first, end, hop: renderer.hop, begin: Math.max(0, grainAt(cue - .005)),
        last: grainAt(cue + .105), prior: []}
    }
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
