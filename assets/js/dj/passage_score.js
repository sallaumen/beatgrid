// A technical grade of the captured mix. Times are audio-clock seconds and
// amplitudes are linear. A catalog BPM can break a tie, never supply an attack.
const names = {pulse: "Pulso", level: "Nível", headroom: "Margem de pico"}
const steadyEnds = "Pulso e nível semelhantes antes e depois."
const metric = (id, state, value, finding = id) => ({id, label: names[id], state, value, finding})
const unknown = (id, value = "Trecho insuficiente") => metric(id, "unknown", value)
const db = value => 20 * Math.log10(Math.max(value, 1e-8))
const decimal = value => value.toLocaleString("pt-BR", {maximumFractionDigits: 1})
const rms = frames => Math.sqrt(frames.reduce((sum, f) => sum + f.rms ** 2, 0) / frames.length)

function quantile(values, p) {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.floor((sorted.length - 1) * p)]
}

function attacks(frames, offset, dt) {
  const envelope = frames.map((f, i) => f.onset ?? Math.max(0, f.rms - (frames[i - 1]?.rms ?? f.rms)))
  const background = quantile(envelope, 0.5)
  const threshold = Math.max(0.0003, rms(frames) * 0.14, background + 3 * quantile(envelope.map(v => Math.abs(v - background)), 0.5))
  const peaks = []
  for (let i = 0; i < frames.length; i++) {
    const strength = envelope[i]
    if (strength <= threshold || strength <= (envelope[i - 1] ?? 0) || strength < (envelope[i + 1] ?? 0)) continue
    const time = (offset + i) * dt
    const last = peaks.at(-1)
    if (last && time - last.time < 0.11) {
      if (strength > last.strength) peaks[peaks.length - 1] = {time, strength}
    } else peaks.push({time, strength})
  }
  return peaks
}

// Count occupied beats as well as matched attacks. Otherwise a nearly empty
// double-tempo grid, or a few coincident hits in a noisy fill, can win.
function beatGrid(peaks, bpm) {
  if (peaks.length < 3) return null
  const cap = quantile(peaks.map(p => p.strength), 0.8) * 1.5
  const weights = peaks.map(p => Math.min(cap, p.strength))
  const total = weights.reduce((a, b) => a + b, 0)
  const periods = new Set()
  peaks.forEach(({time}, i) => {
    for (let j = Math.max(i - 5, 0); j < i; j++) {
      for (let beats = 1; beats <= 4; beats++) {
        const period = (time - peaks[j].time) / beats
        if (period >= 0.23 && period <= 1.15) periods.add(Math.round(period * 500) / 500)
      }
    }
  })

  let best = null
  for (const period of periods) {
    for (const anchor of peaks) {
      let hits = 0, matched = 0, residual = 0, first, last
      let sumN = 0, sumT = 0, sumNT = 0, sumNN = 0
      for (let i = 0; i < peaks.length; i++) {
        const t = peaks[i].time
        const n = Math.round((t - anchor.time) / period)
        const error = Math.abs(t - anchor.time - n * period) / period
        if (error > 0.12 || n === last) continue
        if (hits === 0) first = n
        hits++
        last = n
        const w = weights[i]
        matched += w
        residual += w * error
        sumN += w * n
        sumT += w * t
        sumNT += w * n * t
        sumNN += w * n * n
      }
      const coverage = hits / (last - first + 1)
      const share = matched / total
      if (hits < 3 || share < 0.56 || coverage < 0.72) continue
      const fit = Math.sqrt(share * coverage) - residual / matched
      if (fit < 0.72) continue
      // Prefer a musically plausible tactus when two measured grids are tied.
      const reference = Number.isFinite(bpm) && bpm > 0 ? bpm : 120
      const rank = fit - 0.015 * Math.abs(Math.log2(60 / period / reference))
      if (!best || rank > best.rank) {
        const step = (matched * sumNT - sumN * sumT) / (matched * sumNN - sumN ** 2)
        best = {period: step, origin: (sumT - step * sumN) / matched, rank}
      }
    }
  }
  return best
}

// A double-tempo lattice can match every subdivision while the strong accents
// alternate on the opposite half of the nominal beat. Treat that as ambiguous.
function strongSubdivision(peaks, grid, reference) {
  const origin = grid.origin + Math.round((reference - grid.origin) / grid.period) * grid.period
  const accents = [[], []]
  for (const {time, strength} of peaks) {
    const subdivision = (time - origin) / grid.period
    const beat = Math.round(subdivision)
    if (Math.abs(subdivision - beat) <= 0.12) accents[Math.abs(beat) % 2].push(strength)
  }
  if (accents.some(group => group.length < 3)) return null
  const strong = quantile(accents[0], 0.5) > quantile(accents[1], 0.5) ? 0 : 1
  const a = accents[strong], b = accents[1 - strong]
  return quantile(a, 0.5) >= 1.5 * quantile(b, 0.5) && quantile(a, 0.25) > quantile(b, 0.75) ? strong : null
}

function pulseMetric(before, after, middle, start, end, dt, kind, bpm, descriptive) {
  const out = attacks(before, start - before.length, dt), into = attacks(after, end, dt)
  const a = beatGrid(out, bpm), b = beatGrid(into, bpm)
  if (!a || !b) return unknown("pulse", "Batidas sem referência firme")
  let ratio = b.period / a.period
  if (ratio > Math.SQRT2) ratio /= 2
  else if (ratio < 1 / Math.SQRT2) ratio *= 2
  const drift = Math.abs(ratio - 1)
  const at = start * dt
  const beatAt = grid => grid.origin + Math.round((at - grid.origin) / grid.period) * grid.period
  const step = Math.min(a.period, b.period)
  const gap = (beatAt(a) - beatAt(b)) / step
  const phase = Math.abs(gap - Math.round(gap))

  if (kind !== "cut" && drift > 0.065) return metric("pulse", "poor", "Andamentos diferentes antes e depois", "tempo")
  if (phase > 0.21) return metric("pulse", "poor", "Diferença de fase entre saída e entrada", "phase")
  if (!descriptive && kind !== "cut" && middle.length * dt >= a.period * 2.8) {
    const cross = attacks(middle, start, dt)
    let count = 0, hits = 0
    for (let t = beatAt(a); t < end * dt - 0.08; t += a.period) {
      if (t < at + 0.08) continue
      count++
      if (cross.some(p => Math.abs(p.time - t) < a.period * 0.15)) hits++
    }
    if (count >= 3 && hits < count / 2) return metric("pulse", "poor", "Pulso sumiu na mistura", "missing_pulse")
  }
  if (phase > 0.10) return metric("pulse", "watch", "Pequena diferença de fase entre saída e entrada", "phase")
  if (drift > 0.035) return metric("pulse", "watch", kind === "cut" ? "O andamento mudou no corte" : "Pequena mudança de andamento entre as faixas", "tempo")
  // Comparing odd/even accents requires the same measured step on both sides.
  if (Math.abs(b.period / a.period - 1) <= 0.035) {
    const reference = beatAt(a)
    const first = strongSubdivision(out, a, reference), last = strongSubdivision(into, b, reference)
    if (first != null && last != null && first !== last) return unknown("pulse", "Acentos alternados sem fase firme")
  }
  return metric("pulse", "good", "Pulso regular antes e depois")
}

function longestQuiet(frames, floor) {
  let longest = 0, run = 0
  for (const {rms} of frames) {
    run = rms < floor ? run + 1 : 0
    longest = Math.max(longest, run)
  }
  return longest
}

// Compare half-second energy windows with the natural dynamics on both sides.
// Overlapping windows catch a short, sustained swell even in a long blend.
function levelWindows(frames, width) {
  let power = 0
  const levels = []
  for (let i = 0; i < frames.length; i++) {
    power += frames[i].rms ** 2
    if (i >= width) power -= frames[i - width].rms ** 2
    if (i + 1 >= width) levels.push(Math.sqrt(Math.max(0, power) / width))
  }
  return levels
}

function levelMetric(before, middle, after, dt, kind, descriptive) {
  const out = rms(before), into = rms(after)
  // A loud pickup can hide a stopped entry in the RMS average. Require both
  // channels to stay below one 16-bit step, preserving measurable quiet music.
  const hasSignal = frame => frame.peak >= 1 / 32768
  const silentExit = out < 0.001 && !before.some(hasSignal)
  const lastSignal = after.findLastIndex(hasSignal)
  if (lastSignal < 0) {
    if (silentExit) return metric("level", "unknown", "Sem sinal antes e depois da troca", "silent_ends")
    return metric("level", "poor", "Entrada em silêncio", "silent_entry")
  }
  const quietTail = (after.length - 1 - lastSignal) * dt
  if (quietTail >= 1) return metric("level", "poor", `Fim da entrada com ${decimal(quietTail)} s sem sinal`, "silent_tail")
  if (silentExit) return metric("level", "poor", "Saída em silêncio", "silent_exit")
  if (out < 0.001 && into < 0.001) return unknown("level", "Sinal muito baixo nos dois lados")
  const jump = db(into / out), change = Math.abs(jump)
  const ends = change > 3.5
    ? metric("level", change >= 8 ? "poor" : "watch", `Entrada ${decimal(change)} dB ${jump > 0 ? "acima" : "abaixo"}`, jump > 0 ? "louder_entry" : "quieter_entry")
    : metric("level", "good", `Variação de ${decimal(change)} dB`)
  if (descriptive) return ends
  const guard = Math.round(0.75 / dt)
  const center = [...before.slice(-guard), ...middle, ...after.slice(0, guard)]
  const floor = Math.max(0.0001, Math.min(out, into) / 16)
  const quiet = longestQuiet(center, floor) * dt
  const rest = Math.max(longestQuiet(before.slice(0, -guard), floor), longestQuiet(after.slice(guard), floor)) * dt
  if (quiet > Math.max(0.18, rest + 0.12)) {
    return metric("level", quiet >= 0.32 ? "poor" : "watch", `Silêncio de ${Math.round(quiet * 1000)} ms`, "gap")
  }
  if (ends.state !== "good") return ends
  const width = Math.max(1, Math.round(0.45 / dt))
  if (kind !== "cut" && [middle, before, after].every(part => part.length >= width)) {
    const context = [...levelWindows(before, width), ...levelWindows(after, width)]
    const levels = levelWindows(middle, width)
    const dip = db(quantile(levels, 0.05) / Math.max(quantile(context, 0.1), floor))
    if (dip < -5) return metric("level", dip < -8 ? "poor" : "watch", `Queda de ${decimal(-dip)} dB na mistura`, "dip")
    const lift = db(quantile(levels, 0.95) / Math.max(quantile(context, 0.9), floor))
    if (lift > 4) return metric("level", lift > 7 ? "poor" : "watch", `Subida de ${decimal(lift)} dB na mistura`, "swell")
  }
  return ends
}

function headroomMetric(frames) {
  let peak = 0, nearRail = 0
  const estimated = frames.every(f => Number.isFinite(f.truePeak) && f.truePeak >= f.peak)
  for (const f of frames) {
    peak = Math.max(peak, estimated ? f.truePeak : f.peak)
    if (f.peak >= 0.99995) nearRail++
  }
  if (peak < 0.001) return unknown("headroom", "Sem sinal na troca")
  const state = peak > 1 || nearRail >= 2 ? "poor" : db(peak) > -1 ? "watch" : "good"
  const reading = decimal(Math.round(db(peak) * 10) / 10 || 0)
  return estimated ? metric("headroom", state, `Pico estimado de ${reading} dBTP`, "true_peak") :
    metric("headroom", state, `Pico de ${reading} dBFS`, "sample_peak")
}

export function scorePassage({frames, frameSeconds: dt, changeAt, overlap, kind, bpm, descriptive = false} = {}) {
  const gesture = descriptive && ["brake", "scratch_cut", "spinback", "chirp", "transform", "scribble"].includes(kind)
  const supported = descriptive ? ["fade", "echo", "filter", "lowpass", "bass_swap"] : ["cut", "blend", "bass_swap"]
  const ids = gesture ? ["level", "headroom"] : Object.keys(names)
  const incomplete = () => ({score: null, descriptive, metrics: ids.map(id => unknown(id)), summary: "É preciso ouvir os dois lados da troca."})
  if (!Array.isArray(frames) || !(Number.isFinite(dt) && dt > 0) || !Number.isFinite(changeAt) ||
      !Number.isFinite(overlap) || overlap < 0 || (!gesture && !supported.includes(kind))) return incomplete()
  const start = Math.round(changeAt / dt), end = Math.round((changeAt + overlap) / dt)
  if (start * dt < 0.35 || (frames.length - end) * dt < 0.35) return incomplete()
  const span = Math.ceil(4 / dt)
  const before = frames.slice(Math.max(0, start - span), start)
  const after = frames.slice(end, end + span)
  const middle = frames.slice(start, end)
  for (const f of frames) {
    if (!f || !Number.isFinite(f.rms) || f.rms < 0 || !Number.isFinite(f.peak) || f.peak < 0 ||
        (f.onset != null && (!Number.isFinite(f.onset) || f.onset < 0))) return incomplete()
  }
  const level = levelMetric(before, middle, after, dt, kind, descriptive)
  const missingEntry = ["silent_entry", "silent_tail", "silent_ends"].includes(level.finding)
  const pulse = gesture ? null : missingEntry ? unknown("pulse", "Sem referência no fim da entrada")
    : pulseMetric(before, after, middle, start, end, dt, kind, bpm, descriptive)
  const headroom = headroomMetric(gesture ? middle : [...before.slice(-Math.ceil(0.25 / dt)), ...middle, ...after.slice(0, Math.ceil(0.75 / dt))])
  if (gesture) headroom.label = "Pico do efeito"
  const metrics = pulse ? [pulse, level, headroom] : [level, headroom]
  if (missingEntry) return {score: null, descriptive, metrics, summary: level.value}
  const issue = metrics.find(m => m.state === "poor") ?? metrics.find(m => m.state === "watch")
  if (descriptive) {
    const reading = gesture ? level.value : pulse.state === "unknown" ? pulse.value : steadyEnds
    const summary = headroom.state === "poor" ? headroom.value : issue?.value ?? reading
    return {score: null, descriptive, metrics, summary}
  }
  if (metrics.some(m => m.state === "unknown")) {
    return {score: null, metrics, summary: issue?.value ?? (level.state === "unknown" ? "Áudio insuficiente para avaliar a troca." : "O pulso não ficou claro neste trecho.")}
  }
  const points = {good: 100, watch: 65, poor: 15}
  let score = 0.5 * points[pulse.state] + 0.35 * points[level.state] + 0.15 * points[headroom.state]
  if (issue?.state === "poor") score = Math.min(score, 65)
  return {score: Math.round(score / 5) * 5, metrics, summary: issue?.value ?? steadyEnds}
}
