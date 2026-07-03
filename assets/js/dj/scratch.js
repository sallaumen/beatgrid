// Real turntable scratch via an AudioWorklet. The deck's mono PCM is read back
// and forth at the platter's velocity (negative = reverse) — so it SOUNDS like
// a record, not a seek. The node feeds the deck's own chain (filter → fader →
// crossfader), so scratches respect the mix.
//
// The hand arrives as sparse position commands (~60 Hz pointermoves, with
// jitter and coalesced bursts). Playing those raw is a staircase: velocity
// steps at the command rate square-wave-FM the audio — the robotic buzz — and
// burst-spiked velocity estimates fire like a machine gun. The fix, chosen by
// offline simulation of both artifacts: reconstruct the velocity the way DVS
// software filters timecode — take the MEAN velocity of each command interval
// (from sender timestamps, so delivery jitter can't spike it) and smooth it
// with a two-pole cascade. The head integrates that smooth velocity — position
// is never JUMPED mid-stroke (jumps click) — but a gentle ~1 Hz error bleed
// keeps steering it back to the commanded position, so hold-overshoot, clamped
// flicks and even a protocol hiccup (a lost "stop") stay transient instead of
// accumulating. Costs ~35 ms of hand-to-ear lag — less than a Bluetooth
// controller. Reads use Catmull-Rom cubic interpolation, plus a velocity-
// scaled one-pole that tames the aliasing hiss of fast passes. Shipped as a
// string + Blob URL, so no extra esbuild entry.

export const SCRATCH_WORKLET = `
class ScratchProcessor extends AudioWorkletProcessor {
  constructor() {
    super()
    this.pcm = null
    this.len = 0
    this.x = 0        // read head, fractional samples (glides; never jumps mid-stroke)
    this.v = 0        // heard velocity, samples/output-sample (negative = reverse)
    this.v1 = 0       // first pole of the velocity smoother
    this.targetV = 0  // mean hand velocity over the last command interval
    this.lastPos = 0
    this.lastT = 0    // sender clock (ms) of the last scrub
    this.sinceCmd = 1e9
    this.active = false
    this.g = 0        // smoothed gain — kills the click on start/stop
    this.lp = 0       // anti-alias pole
    this.xp = 0       // DC-blocker state (a platter held still is silence)
    this.yp = 0
    this.ref = 0      // smoothed hand position the bleed measures against
    this.K = 1 - Math.exp((-2 * Math.PI * 22) / sampleRate) // smoother corner, per pole
    this.K2 = 1 - Math.exp((-2 * Math.PI * 11) / sampleRate) // bleed-reference smoother
    this.HOLD = Math.round(0.06 * sampleRate) // command silence -> the hand is holding still
    this.MINDT = 0.004 * sampleRate // floor the interval: coalesced bursts can't spike
    this.VMAX = 32 // a hard backspin flick; the anti-alias pole covers the sound up there
    this.KP = 1.5e-4 // position-error bleed per sample (~150 ms) — closes the loop softly
    this.port.onmessage = (e) => {
      const d = e.data
      if (d.type === "load") {
        this.pcm = d.pcm || null
        this.len = this.pcm ? this.pcm.length : 0
      } else if (d.type === "scrub") {
        if (this.active) {
          // Cap the interval at the HOLD window: after a long still-hand pause
          // the elapsed time says nothing about how fast the NEW stroke is.
          const dtMs = Math.min(d.t - this.lastT, 60)
          const dt = Math.max((dtMs / 1000) * sampleRate, this.MINDT)
          const v = (d.position - this.lastPos) / dt
          this.targetV = Math.max(-this.VMAX, Math.min(this.VMAX, v))
        } else {
          this.x = d.position
          this.ref = d.position
          this.v = 0
          this.v1 = 0
          this.targetV = 0
          this.active = true
        }
        this.lastPos = d.position
        this.lastT = d.t
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
    for (let i = 0; i < n; i++) {
      this.g += (gTarget - this.g) * 0.008
      if (on) {
        if (this.sinceCmd > this.HOLD) this.targetV = 0
        // Error bleed: whatever the smoothing/clamps cost in position (hold
        // overshoot, a clamped flick's deficit), pay it back over ~150 ms so
        // the head always converges to the hand. The reference is lastPos run
        // through its own pole — raw lastPos steps at the command rate, and on
        // sustained fast passes that sawtooth survived the main smoother as an
        // audible ripple riding the velocity.
        this.ref += (this.lastPos - this.ref) * this.K2
        let errV = (this.ref - this.x) * this.KP
        if (errV > 3) errV = 3
        else if (errV < -3) errV = -3
        this.v1 += (this.targetV + errV - this.v1) * this.K
        this.v += (this.v1 - this.v) * this.K
        this.x += this.v
        this.sinceCmd++
      }
      let raw = 0
      const p = this.x
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
      // Faster than 1x skips samples and aliases into a harsh hiss; narrow a
      // one-pole with speed, like the blur of a real needle whipping past.
      const speed = this.v < 0 ? -this.v : this.v
      this.lp += (raw - this.lp) * (speed > 1 ? 1 / speed : 1)
      const dc = this.lp - this.xp + 0.995 * this.yp
      this.xp = this.lp
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
