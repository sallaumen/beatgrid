// Real turntable scratch via an AudioWorklet. The deck's mono PCM is read back
// and forth at the platter's velocity (negative = reverse) — so it SOUNDS like
// a record, not a seek. The node feeds the deck's own chain (filter → fader →
// crossfader), so scratches respect the mix.
//
// The commanded position/velocity arrive in coarse, jittery steps (mouse moves,
// ~16 ms ticks). Reading the buffer at that stepped velocity directly sounds
// ROBOTIC — a stair-cased rate is basically a square-wave FM of the audio. So
// the worklet models a platter with inertia: it SMOOTHS the commanded velocity
// (one-pole) and integrates it, while gently tracking the commanded position so
// it never drifts — the rate becomes continuous. Reads use CUBIC (Catmull-Rom)
// interpolation, which is far cleaner than linear at the odd rates a scratch
// sweeps through (this is the standard turntable-emulation approach, not a
// home-grown one). Shipped as a string + Blob URL, so no extra esbuild entry.

export const SCRATCH_WORKLET = `
class ScratchProcessor extends AudioWorkletProcessor {
  constructor() {
    super()
    this.pcm = null
    this.len = 0
    this.readPos = 0    // the actual read head, in samples (glides smoothly)
    this.vel = 0        // current samples/output-sample (can be negative)
    this.targetVel = 0  // velocity that reaches the last command over its interval
    this.sinceCmd = 1e9 // output samples since the last position command
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
        // Derive velocity from the position delta over the ACTUAL elapsed output
        // samples (our own audio clock) — the main thread's dt can be ~0 between
        // two fast mouse moves and would spike the velocity into a click. Floor
        // the interval so a burst of commands can't spike it either.
        if (!this.active) {
          this.readPos = d.position
          this.vel = 0
          this.active = true
        } else {
          const interval = Math.max(this.sinceCmd, 64)
          this.targetVel = (d.position - this.readPos) / interval
        }
        this.sinceCmd = 0
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
    const on = this.active && pcm && len > 4
    const gTarget = on ? 1 : 0
    // Platter inertia: one-pole smooth the target velocity (~2 ms) so the rate is
    // continuous, integrate it; wind down if the commands stop (hand lifted).
    const VEL_SLEW = 0.012
    for (let i = 0; i < n; i++) {
      this.g += (gTarget - this.g) * 0.008
      if (on) {
        if (this.sinceCmd > 1400) this.targetVel *= 0.99 // ~30 ms silent → coast to a stop
        this.vel += (this.targetVel - this.vel) * VEL_SLEW
        this.readPos += this.vel
        this.sinceCmd++
      }
      let raw = 0
      const p = this.readPos
      if (pcm && len > 4 && p >= 1 && p < len - 2) {
        const i0 = p | 0
        const f = p - i0
        const a = pcm[i0 - 1]
        const b = pcm[i0]
        const c = pcm[i0 + 1]
        const dd = pcm[i0 + 2]
        // Catmull-Rom cubic
        raw = b + 0.5 * f * (c - a + f * (2 * a - 5 * b + 4 * c - dd + f * (3 * (b - c) + dd - a)))
      }
      // DC blocker: a platter held still reads a constant sample — high-pass it
      // so "stopped" is silence, not a DC thump.
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
