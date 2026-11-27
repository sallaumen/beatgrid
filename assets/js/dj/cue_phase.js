// This pure function is also shipped to a dedicated Worker as a self-contained program.
export function analyzeCuePair({out, into}) {
  if (!out || !into) return null
  // Analyse bounded regions of decoded audio at 12 kHz. No transport or audio graph is involved.
  const RATE = 12000,
    HOP = 60,
    NFFT = 512,
    BINS = 64
  const WINDOW = 6,
    MARGIN = 0.25
  const floor = Math.floor
  const wrap = (x) => x - Math.floor(x + 0.5)
  const bands = [
    [35, 110],
    [70, 250],
    [250, 1200],
    [1200, 3500],
    [3500, 5700]
  ]
  const bandWeight = [1.1, 1.2, 1, 0.8, 0.65]
  const hann = Float64Array.from({length: NFFT}, (_, i) => (1 - Math.cos((2 * Math.PI * i) / (NFFT - 1))) / 2)
  const freqRanges = bands.map(([low, high]) => [
    Math.ceil((low * NFFT) / RATE),
    Math.ceil((high * NFFT) / RATE)
  ])
  const reverse = Uint16Array.from({length: NFFT}, (_, n) => {
    let bits = 0
    for (let k = NFFT; k > 1; k >>= 1) {
      bits = bits * 2 + (n & 1)
      n >>= 1
    }
    return bits
  })
  const cos = Float64Array.from({length: NFFT / 2}, (_, i) => Math.cos((-2 * Math.PI * i) / NFFT))
  const sin = Float64Array.from({length: NFFT / 2}, (_, i) => Math.sin((-2 * Math.PI * i) / NFFT))
  const smooth = Float64Array.from({length: 15}, (_, i) => Math.exp(-0.5 * ((i - 7) / 1.7) ** 2))
  const kernelSum = smooth.reduce((a, b) => a + b)
  function quantile(values, q) {
    values.sort()
    const i = (values.length - 1) * q,
      lo = floor(i)
    return values[lo] + (values[Math.ceil(i)] - values[lo]) * (i - lo)
  }

  // A finite polyphase low-pass resampler keeps high-frequency energy out of the pulse estimate.
  function kernels(ratio) {
    const radius = Math.min(64, Math.ceil(6 * ratio)),
      count = 64
    const taps = 2 * radius + 1
    const coefficients = new Float64Array(count * taps)
    for (let phase = 0; phase < count; phase++) {
      let sum = 0
      for (let j = -radius; j <= radius; j++) {
        const t = j - phase / count,
          z = (Math.PI * t) / ratio
        const sinc = Math.abs(z) < 1e-8 ? 1 : Math.sin(z) / z
        const window = Math.abs(t) > radius ? 0 : (1 + Math.cos((Math.PI * t) / radius)) / 2
        sum += coefficients[phase * taps + j + radius] = sinc * window
      }
      for (let j = 0; j < taps; j++) coefficients[phase * taps + j] /= sum
    }
    return {coefficients, taps, radius, count}
  }
  function sampleRegion(buffer, start, size) {
    const ratio = buffer.sampleRate / RATE
    const left = buffer.getChannelData(0),
      right = buffer.numberOfChannels > 1 ? buffer.getChannelData(1) : left
    const offset = Math.round(start * RATE)
    const mono = new Float32Array(size)
    let mid = 0,
      powerL = 0,
      powerR = 0
    for (let i = 0; i < size; i += 17) {
      const at = Math.round((offset + i) * ratio) - buffer.firstSample
      const l = left[at],
        r = right[at]
      mid += ((l + r) / 2) ** 2
      powerL += l * l
      powerR += r * r
    }
    const reference = mid < 0.0225 * Math.max(powerL, powerR) ? (powerL >= powerR ? left : right) : null
    if (Math.abs(ratio - 1) < 1e-8) {
      for (let i = 0; i < size; i++)
        mono[i] = reference
          ? reference[offset + i - buffer.firstSample]
          : (left[offset + i - buffer.firstSample] + right[offset + i - buffer.firstSample]) * 0.5
      return mono
    }
    const {coefficients, taps, radius, count} = kernels(ratio)
    for (let i = 0; i < size; i++) {
      const input = (offset + i) * ratio,
        at = floor(input),
        phase = Math.min(count - 1, floor((input - at) * count))
      let s = 0,
        pos = at - radius - buffer.firstSample
      for (let j = 0; j < taps; j++, pos++) {
        const x = reference ? reference[pos] : (left[pos] + right[pos]) * 0.5
        s += coefficients[phase * taps + j] * x
      }
      mono[i] = s
    }
    return mono
  }
  function spectrum(data, start, re, im, target) {
    for (let i = 0; i < NFFT; i++) {
      re[reverse[i]] = data[start + i] * hann[i]
      im[reverse[i]] = 0
    }
    for (let size = 2; size <= NFFT; size *= 2) {
      const half = size / 2,
        step = NFFT / size
      for (let group = 0; group < NFFT; group += size) {
        for (let i = group, k = 0; i < group + half; i++, k += step) {
          const j = i + half
          const x = re[j] * cos[k] - im[j] * sin[k],
            y = re[j] * sin[k] + im[j] * cos[k]
          re[j] = re[i] - x
          im[j] = im[i] - y
          re[i] += x
          im[i] += y
        }
      }
    }
    for (let i = 0; i < target.length; i++)
      target[i] = Math.log1p(4 * Math.sqrt(re[i] * re[i] + im[i] * im[i]))
  }
  function novelty(data) {
    const frameCount = floor((data.length - NFFT) / HOP) + 1
    const out = bands.map(() => new Float32Array(frameCount - 2))
    const half = NFFT / 2 + 1,
      mag = Array.from({length: 3}, () => new Float64Array(half))
    const re = new Float64Array(NFFT),
      im = new Float64Array(NFFT),
      diff = new Float64Array(half)
    for (let frame = 0; frame < frameCount; frame++) {
      const current = mag[frame % 3]
      spectrum(data, frame * HOP, re, im, current)
      if (frame < 2) continue
      const previous = mag[(frame - 2) % 3]
      for (let i = 0; i < half; i++) diff[i] = Math.max(0, current[i] - previous[i])
      for (let b = 0; b < bands.length; b++) {
        const [lo, hi] = freqRanges[b]
        let sum = 0
        for (let i = lo; i < hi; i++) sum += diff[i]
        out[b][frame - 2] = sum / (hi - lo)
      }
    }
    // A sliding median suppresses sustained energy. The analysis windows exclude the edges.
    const tmp = new Float32Array(31)
    return out.map((row) => {
      const cleaned = new Float32Array(row.length)
      for (let i = 15; i < row.length - 15; i++) {
        tmp.set(row.subarray(i - 15, i + 16))
        tmp.sort()
        cleaned[i] = Math.max(0, row[i] - tmp[15])
      }
      return cleaned
    })
  }
  function profile(region, period, from, to) {
    const first = Math.max(0, Math.ceil((from - region.firstTime) / (HOP / RATE)))
    const last = Math.min(region.bands[0].length, Math.ceil((to - region.firstTime) / (HOP / RATE)))
    const counts = new Uint16Array(BINS),
      position = new Uint8Array(last - first)
    for (let i = first; i < last; i++) {
      const cycles = (region.firstTime + (i * HOP) / RATE) / period
      const b = Math.min(BINS - 1, floor((cycles - floor(cycles)) * BINS))
      position[i - first] = b
      counts[b]++
    }
    const weights = [],
      rows = region.bands.map((band) => {
        const raw = new Float64Array(BINS),
          result = new Float64Array(BINS)
        const scale = Math.max(1e-6, quantile(band.slice(first, last), 0.95))
        for (let i = first; i < last; i++) raw[position[i - first]] += Math.min(band[i] / scale, 1.3)
        for (let k = 0; k < BINS; k++) raw[k] /= Math.max(1, counts[k])
        let sum = 0
        for (let k = 0; k < BINS; k++) {
          for (let j = 0; j < smooth.length; j++) result[k] += raw[(k + j - 7 + BINS) % BINS] * smooth[j]
          result[k] /= kernelSum
          sum += result[k]
        }
        const mean = sum / BINS
        let ssq = 0
        for (let k = 0; k < BINS; k++) {
          result[k] -= mean
          ssq += result[k] ** 2
        }
        const norm = Math.sqrt(ssq)
        weights.push(norm / Math.sqrt(BINS) / Math.max(1e-7, mean))
        for (let k = 0; k < BINS; k++) result[k] /= Math.max(1e-7, norm)
        return result
      })
    return {rows, weights}
  }
  function argmax(values) {
    let idx = 0
    for (let i = 1; i < values.length; i++) if (values[i] > values[idx]) idx = i
    return idx
  }
  function compare(a, b) {
    const scores = new Float64Array(BINS),
      votes = [],
      weights = []
    let total = 0
    for (let band = 0; band < bands.length; band++) {
      const correlations = new Float64Array(BINS),
        x = a.rows[band],
        y = b.rows[band]
      const weight = Math.max(1e-7, Math.min(a.weights[band], b.weights[band]) * bandWeight[band])
      total += weight
      weights.push(weight)
      for (let lag = 0; lag < BINS; lag++) {
        let c = 0
        for (let i = 0; i < BINS; i++) c += x[i] * y[(i + lag) % BINS]
        scores[lag] += c * weight
        correlations[lag] = c
      }
      votes.push(argmax(correlations))
    }
    const best = argmax(scores),
      phase = wrap(best / BINS)
    let runner = -Infinity,
      agreement = 0
    for (let k = 0; k < BINS; k++)
      if (Math.abs(wrap(k / BINS - phase)) > 0.17) runner = Math.max(runner, scores[k])
    for (let b = 0; b < votes.length; b++)
      if (Math.abs(wrap(votes[b] / BINS - phase)) < 0.12) agreement += weights[b]
    return {
      phase,
      peak: scores[best] / total,
      margin: (scores[best] - runner) / total,
      agree: agreement / total,
      support: [...weights].sort((x, y) => x - y)[2]
    }
  }
  // Prepare only 12.5 record-seconds per deck. The caller may pass a bounded PCM slice and a relative cue.
  function prepareCuePhase({buffer, cue, bpm, rate = 1} = {}) {
    if (
      !buffer ||
      typeof buffer.getChannelData !== "function" ||
      !Number.isFinite(buffer.sampleRate) ||
      buffer.sampleRate < RATE ||
      buffer.sampleRate > 192000 ||
      buffer.numberOfChannels < 1 ||
      buffer.numberOfChannels > 2 ||
      !Number.isFinite(cue) ||
      !Number.isFinite(bpm) ||
      bpm < 45 ||
      bpm > 240 ||
      !Number.isFinite(rate) ||
      rate < 0.5 ||
      rate > 2
    )
      return null
    const size = Math.ceil((2 * WINDOW + 2 * MARGIN + HOP / RATE) * RATE)
    if (!Number.isFinite(buffer.duration) || cue < 0 || cue >= buffer.duration) return null
    const hopSeconds = HOP / RATE,
      minimum = 0.01
    const latest = Math.floor((buffer.duration - size / RATE - minimum) / hopSeconds) * hopSeconds
    if (latest < minimum) return null
    const ideal = Math.floor((cue - WINDOW - MARGIN) / hopSeconds) * hopSeconds
    const start = Math.max(minimum, Math.min(latest, ideal))
    // Near the head or tail, measure the available audio on one side of the cue.
    const from = start + MARGIN - cue
    const into = from + 2 * WINDOW
    const region = {
      firstTime: start - cue + (2 * HOP + NFFT / 2) / RATE,
      bands: novelty(sampleRegion(buffer, start, size))
    }
    return {
      cue,
      period: 60 / bpm,
      rate,
      duration: buffer.duration,
      profiles: [
        [from, into],
        [from, from + WINDOW],
        [from + WINDOW, into]
      ].map(([from, to]) => profile(region, 60 / bpm, from, to)),
      octave: profile(region, 120 / bpm, from, into)
    }
  }
  function compareCuePhase(out, into) {
    if (!out || !into || Math.abs(out.period / out.rate / (into.period / into.rate) - 1) > 0.015) return null
    const [whole, first, last] = out.profiles.map((p, i) => compare(p, into.profiles[i]))
    const drift = Math.max(
      Math.abs(wrap(first.phase - whole.phase)),
      Math.abs(wrap(last.phase - whole.phase))
    )
    if (
      whole.peak < 0.48 ||
      whole.margin < 0.16 ||
      whole.agree < 0.57 ||
      whole.support < 0.16 ||
      drift > 0.12
    )
      return null
    return whole
  }
  // Positive recordDelta means advancing in the incoming file so the next attack is heard earlier.
  function suggestCueShift(out, into) {
    const result = compareCuePhase(out, into)
    if (!result || Math.abs(result.phase) < 0.08 || Math.abs(result.phase) > 0.37) return null
    // A tempo tag can be an octave too fast on both decks. A strong competing two-beat
    // reference vetoes the opposite move. Equal accents on successive beats do not vote.
    const longer = compare(out.octave, into.octave)
    if (
      longer.peak >= 0.48 &&
      longer.margin >= 0.12 &&
      Math.abs(wrap(longer.phase - result.phase / 2)) * 2 > 0.18
    )
      return null
    const recordDelta = result.phase * into.period,
      entry = into.cue + recordDelta
    if (entry < 0 || entry >= into.duration) return null
    return {recordDelta, entry, wallDelta: recordDelta / into.rate}
  }
  function readWindow({channels, sampleRate, cue, bpm, rate, firstSample, duration}) {
    const buffer = {
      numberOfChannels: channels.length,
      sampleRate,
      duration,
      firstSample,
      getChannelData: (index) => channels[index]
    }
    return prepareCuePhase({buffer, cue, bpm, rate})
  }
  return suggestCueShift(readWindow(out), readWindow(into))
}

// Keep enough guard samples for the resampler at either edge, including disk CUE 0.
const WINDOW_SECONDS = 12.55
export function copyCueWindow(buffer, cue, bpm, rate) {
  if (
    !buffer ||
    !Number.isFinite(cue) ||
    cue < 0 ||
    cue >= buffer.duration ||
    !Number.isFinite(bpm) ||
    bpm < 45 ||
    bpm > 240 ||
    !Number.isFinite(rate) ||
    rate < 0.5 ||
    rate > 2 ||
    !Number.isFinite(buffer.sampleRate) ||
    buffer.sampleRate < 12000 ||
    buffer.sampleRate > 192000 ||
    buffer.numberOfChannels < 1 ||
    buffer.numberOfChannels > 2 ||
    buffer.duration < 12.53
  )
    return null
  const length = Math.min(buffer.length, Math.ceil(WINDOW_SECONDS * buffer.sampleRate))
  const firstSample = Math.min(
    buffer.length - length,
    Math.max(0, Math.floor((cue - WINDOW_SECONDS / 2) * buffer.sampleRate))
  )
  const channels = Array.from({length: buffer.numberOfChannels}, (_, index) => {
    const window = new Float32Array(length)
    buffer.copyFromChannel(window, index, firstSample)
    return window
  })
  return {channels, cue, bpm, rate, sampleRate: buffer.sampleRate, firstSample, duration: buffer.duration}
}
