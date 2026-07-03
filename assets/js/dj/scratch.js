// Real turntable scratch via an AudioWorklet. The deck's mono PCM is read back
// and forth at the platter's velocity (negative = reverse), with linear
// interpolation — so it SOUNDS like a record, not a seek. The node feeds the
// deck's own chain (filter → fader → crossfader), so scratches respect the mix.
//
// The processor is shipped as a string and loaded from a Blob URL, so there's
// no extra esbuild entry to wire up.

export const SCRATCH_WORKLET = `
class ScratchProcessor extends AudioWorkletProcessor {
  constructor() {
    super()
    this.pcm = null
    this.len = 0
    this.pos = 0        // read head, in samples (fractional)
    this.vel = 0        // samples advanced per output sample (can be negative)
    this.active = false
    this.g = 0          // smoothed gain — kills the click on start/stop
    this.xp = 0         // DC-blocker state (silences a platter held still)
    this.yp = 0
    this.port.onmessage = (e) => {
      const d = e.data
      if (d.type === "load") {
        this.pcm = d.pcm || null
        this.len = this.pcm ? this.pcm.length : 0
      } else if (d.type === "scrub") {
        this.pos = d.position
        this.vel = d.velocity
        this.active = true
      } else if (d.type === "stop") {
        this.active = false
      }
    }
  }
  process(inputs, outputs) {
    const out = outputs[0]
    const ch = out[0]
    const n = ch.length
    const pcm = this.pcm
    const len = this.len
    const target = this.active && pcm && len > 1 ? 1 : 0
    for (let i = 0; i < n; i++) {
      this.g += (target - this.g) * 0.008
      let raw = 0
      if (pcm && len > 1) {
        const p = this.pos
        if (p >= 0 && p < len - 1) {
          const i0 = p | 0
          const frac = p - i0
          raw = pcm[i0] * (1 - frac) + pcm[i0 + 1] * frac
        }
        if (this.active) this.pos += this.vel
      }
      // DC blocker: a platter held still (velocity 0) reads a constant sample —
      // high-pass it so "stopped" is silence, not a DC thump.
      const dc = raw - this.xp + 0.995 * this.yp
      this.xp = raw
      this.yp = dc
      ch[i] = dc * this.g
    }
    for (let c = 1; c < out.length; c++) out[c].set(ch)
    return true
  }
}
registerProcessor("scratch-processor", ScratchProcessor)
`

let modulePromise = null

// Load the worklet module once per context (idempotent).
export function ensureScratchModule(ctx) {
  if (!modulePromise) {
    const url = URL.createObjectURL(new Blob([SCRATCH_WORKLET], {type: "application/javascript"}))
    modulePromise = ctx.audioWorklet
      .addModule(url)
      .finally(() => URL.revokeObjectURL(url))
      .catch((err) => {
        modulePromise = null // let a later attempt retry
        throw err
      })
  }
  return modulePromise
}

// Auto-scratch shapes. phase advances 0→1 each cycle. Returns:
//   pos  — normalized platter offset in [-1, 1] (caller scales by a depth)
//   gate — crossfader position: 1 = full toward the scratched deck, 0 = full
//          toward the OTHER (live) deck, 0.5 = center (both heard).
// baby: continuous forward/back — sits at CENTER so the scratch layers OVER the
//   live track instead of cutting it (gate 1 would fully mute the on-air deck).
// transform: gentle motion chopped into staccato bursts by the crossfader.
// chop: forward/back but only the forward stroke is heard (the "chirp").
export function scratchPattern(name, phase) {
  const tau = Math.PI * 2
  if (name === "transform") {
    return {pos: 0.5 * Math.sin(tau * phase), gate: Math.floor(phase * 8) % 2 === 0 ? 1 : 0}
  }
  if (name === "chop") {
    return {pos: Math.sin(tau * phase), gate: Math.cos(tau * phase) > 0 ? 1 : 0}
  }
  return {pos: Math.sin(tau * phase), gate: 0.5} // baby — layer, don't cut
}
