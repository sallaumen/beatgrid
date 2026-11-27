export const neutralMix = Object.freeze({rate: 1, vinyl: false, filter: 0, tone: 0, level: 1})

const MIN_SYNC_RATE = 0.92, MAX_SYNC_RATE = 1.08

export function syncedRate(current, bpm, targetBpm) {
  if (!(bpm > 0 && targetBpm > 0) || current * bpm === targetBpm) return current
  const target = targetBpm / bpm
  const limited = Math.min(MAX_SYNC_RATE, Math.max(MIN_SYNC_RATE, target))
  return Math.abs(limited - target) < Math.abs(current - target) ? limited : current
}

// Two counts can share a pulse without sharing their displayed BPM. This
// alternative is an explicit headphone choice; the live SYNC stays literal.
export function pulseSync(current, bpm, referenceBpm) {
  if (!(bpm > 0 && referenceBpm > 0)) return null
  const factor = bpm > referenceBpm ? 2 : 0.5
  const target = referenceBpm * factor
  const rate = target / bpm
  if (!(rate >= MIN_SYNC_RATE && rate <= MAX_SYNC_RATE)) return null
  return {factor, bpm: target, rate: syncedRate(current, bpm, target)}
}

export function createEq(ctx) {
  const filter = (type, frequency) => {
    const node = ctx.createBiquadFilter()
    node.type = type
    node.frequency.value = frequency
    return node
  }
  const hpf = filter("highpass", 10), lpf = filter("lowpass", 20_000)
  const bass = filter("lowshelf", 200), toneBass = filter("lowshelf", 250), toneTreble = filter("highshelf", 3000)
  for (const node of [bass, toneBass, toneTreble]) node.gain.value = 0
  hpf.connect(lpf)
  lpf.connect(bass)
  bass.connect(toneBass)
  toneBass.connect(toneTreble)
  return {hpf, lpf, bass, toneBass, toneTreble}
}

export function setMixParam(param, value, time, smooth = true, tau = 0.01) {
  const previous = param.value
  param.cancelScheduledValues(time)
  param.setValueAtTime(smooth ? previous : value, time)
  if (smooth) param.setTargetAtTime(value, time, tau)
}

export function applyFilter(eq, value, time, smooth) {
  setMixParam(eq.hpf.frequency, value > 0 ? 10 * Math.pow(400, value) : 10, time, smooth, 0.03)
  setMixParam(eq.lpf.frequency, value < 0 ? 20_000 * Math.pow(150 / 20_000, -value) : 20_000, time, smooth, 0.03)
}

export function applyTone(eq, value, time, smooth) {
  setMixParam(eq.toneBass.gain, -value * 9, time, smooth, 0.03)
  setMixParam(eq.toneTreble.gain, value * 9, time, smooth, 0.03)
}
