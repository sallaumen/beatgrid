import {rehearsalOverlap} from "./rehearsal.js"

// The tap has no outputs. Only stereo energy, peaks and attacks leave the render thread.
export const METER_PROCESSOR = `
class PassageMeter extends AudioWorkletProcessor {
  constructor(options) {
    super()
    const {start, end} = options.processorOptions
    this.start = Math.round(start * sampleRate)
    this.end = Math.round(end * sampleRate)
    this.hop = Math.max(1, Math.round(sampleRate / 100))
    this.frames = new Float32Array(3 * Math.ceil((this.end - this.start) / this.hop))
    this.used = this.count = this.power = this.high = this.peak = 0
    this.lastRms = this.lastHigh = 0
    this.previous = [0, 0]
    this.first = null
    this.finished = false
    this.port.onmessage = () => { this.finished = true }
  }

  process([channels]) {
    if (this.finished) return false
    const block = channels[0]?.length || 128
    const start = Math.max(0, this.start - currentFrame)
    const end = Math.min(block, this.end - currentFrame)
    for (let i = start; i < end; i++) {
      if (this.first === null) this.first = currentFrame + i
      const n = Math.max(1, Math.min(2, channels.length))
      for (let c = 0; c < n; c++) {
        const x = channels[c]?.[i] || 0
        const difference = x - this.previous[c]
        this.previous[c] = x
        this.power += x * x / n
        this.high += difference * difference / n
        this.peak = Math.max(this.peak, Math.abs(x))
      }
      if (++this.count === this.hop) {
        const rms = Math.sqrt(this.power / this.hop), high = Math.sqrt(this.high / this.hop)
        this.frames[this.used++] = rms
        this.frames[this.used++] = this.peak
        this.frames[this.used++] = Math.max(0, rms - this.lastRms) + 2 * Math.max(0, high - this.lastHigh)
        this.lastRms = rms
        this.lastHigh = high
        this.count = this.power = this.high = this.peak = 0
      }
    }
    if (currentFrame + block < this.end) return true
    // WebKit can request another quantum after false. The transfer detaches frames.
    this.finished = true
    this.port.postMessage({frames: this.frames.subarray(0, this.used), first: this.first / sampleRate,
      frameSeconds: this.hop / sampleRate}, [this.frames.buffer])
    return false
  }
}
registerProcessor("beatgrid-passage-meter", PassageMeter)
`

const modules = new WeakMap()
export function preparePassageMeter(ctx) {
  if (!modules.has(ctx)) {
    if (!ctx.audioWorklet || typeof AudioWorkletNode === "undefined") return Promise.resolve(false)
    modules.set(ctx, Promise.resolve().then(async () => {
      const url = URL.createObjectURL(new Blob([METER_PROCESSOR], {type: "text/javascript"}))
      try { await ctx.audioWorklet.addModule(url); return true }
      finally { URL.revokeObjectURL(url) }
    }).catch(() => false))
  }
  return modules.get(ctx)
}

// The observer never gates audio playback. Late/incomplete measurements have no score.
export function measurePassage(ctx, input, window, report) {
  let active = true, meter
  const stop = () => {
    if (!active) return
    active = false
    clearTimeout(timeout)
    if (meter) {
      try { input.disconnect(meter) } catch { /* The transport already disconnected its graph. */ }
      meter.port.postMessage("stop")
      meter.port.close()
      meter.disconnect()
    }
  }
  const finish = data => {
    if (!active) return
    stop()
    report(data)
  }
  const timeout = setTimeout(() => finish(null), Math.max(0, window.end - ctx.currentTime + 2) * 1000)
  preparePassageMeter(ctx).then(ready => {
    if (!active) return
    if (!ready || ctx.currentTime > window.start + 0.1) return finish(null)
    try {
      meter = new AudioWorkletNode(ctx, "beatgrid-passage-meter", {numberOfInputs: 1, numberOfOutputs: 0,
        processorOptions: {start: window.start, end: window.end}})
      meter.port.onmessage = ({data}) => {
        if (data.first - window.start > 0.1 || data.frames.length < 3) return finish(null)
        const frames = []
        for (let i = 0; i < data.frames.length; i += 3) {
          frames.push({rms: data.frames[i], peak: data.frames[i + 1], onset: data.frames[i + 2]})
        }
        finish({...window, frames, frameSeconds: data.frameSeconds, changeAt: window.change - data.first})
      }
      meter.onprocessorerror = () => finish(null)
      input.connect(meter)
    } catch { finish(null) }
  })
  return stop
}

// A reservation follows the playing record; the sound card has its own clock.
// Only the real handoff may anchor a reading of the master output.
export function observeRoomPassage(ctx, input, choice, deck, report, measure = measurePassage) {
  const {plan, kind} = choice
  const now = ctx.currentTime
  const change = now + Math.max(0, choice.exitMs - deck.positionMs()) / (1000 * deck.el.playbackRate)
  const overlap = rehearsalOverlap(plan, kind)
  const tolerance = 0.25
  const window = {kind, change, overlap, bpm: deck.bpm * (plan.mix?.out.rate ?? deck.el.playbackRate),
    start: Math.max(now, change - plan.lead), end: change + overlap + 2 + tolerance}
  let arrived = null, completed = false, stopped = false, capture

  function publish() {
    if (stopped || !completed || arrived === null) return
    stopped = true
    const drift = arrived - change
    report(capture && Math.abs(drift) <= tolerance ? {...capture, changeAt: capture.changeAt + drift} : null)
  }

  const cancel = measure(ctx, input, window, data => {
    capture = data
    completed = true
    publish()
  })
  return {
    choice,
    get arrived() { return arrived !== null },
    arrive(time) { arrived = time; publish() },
    cancel() { if (!stopped) { stopped = true; cancel() } }
  }
}
