// Measured peaks include the deck gain and the overlap's timing tolerance.
// Keep 3 dB of digital headroom for interpolation and small source differences.
const CEILING = 10 ** (-3 / 20)
const STEPS = 32

function vertex(curve, p) {
  const out = 1 - p
  const peakBound = out * curve.outPeak + p * curve.inPeak
  const energyGain = 1 / Math.sqrt(out * out + p * p + 2 * curve.correlation * out * p)
  const gain = Math.max(1, Math.min(energyGain, CEILING / peakBound))
  return [out * gain, p * gain]
}

export function blendGains(curve, p) {
  if (!curve) return [1 - p, p]
  const index = p * STEPS, lo = Math.floor(index), high = Math.ceil(index)
  const a = vertex(curve, lo / STEPS)
  if (lo === high) return a
  const b = vertex(curve, high / STEPS), part = index - lo
  return [a[0] + (b[0] - a[0]) * part, a[1] + (b[1] - a[1]) * part]
}

// Drawing, seeking into an audition and both audio paths use the same linear segments.
export function scheduleBlend(param, curve, side, change, fade, at, scale = 1) {
  const start = Math.max(change, at)
  const p = Math.min(1, (start - change) / fade)
  param.setValueAtTime(blendGains(curve, p)[side] * scale, start)
  if (p >= 1) return
  const count = curve ? STEPS : 1
  for (let i = Math.floor(p * count) + 1; i <= count; i++) {
    const position = i / count
    param.linearRampToValueAtTime(blendGains(curve, position)[side] * scale, change + position * fade)
  }
}
