import {rehearsalOverlap} from "./rehearsal.js"

// The tap has no outputs. Only stereo energy, peaks and attacks leave the render thread.
export const METER_PROCESSOR = `
class PassageMeter extends AudioWorkletProcessor {
  constructor(options) {
    super()
    const {start, end, historySeconds} = options.processorOptions
    this.rolling = historySeconds > 0
    this.start = this.rolling ? currentFrame : Math.round(start * sampleRate)
    this.end = this.rolling ? Infinity : Math.round(end * sampleRate)
    this.hop = Math.max(1, Math.round(sampleRate / 100))
    const samples = this.rolling ? historySeconds * sampleRate : this.end - this.start
    this.frames = new Float32Array(3 * Math.ceil(samples / this.hop))
    this.used = this.count = this.power = this.high = this.peak = 0
    this.lastRms = this.lastHigh = 0
    this.previous = [0, 0]
    this.first = null
    this.finished = false
    this.window = null
    this.port.onmessage = ({data}) => {
      if (!this.rolling || data === "stop") this.finished = true
      else this.window = data
    }
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
        const k = this.used % this.frames.length
        this.frames[k] = rms
        this.frames[k + 1] = this.peak
        this.frames[k + 2] = Math.max(0, rms - this.lastRms) + 2 * Math.max(0, high - this.lastHigh)
        this.used += 3
        this.lastRms = rms
        this.lastHigh = high
        this.count = this.power = this.high = this.peak = 0
      }
    }
    if (this.rolling) {
      if (this.window && currentFrame + block >= this.window.end * sampleRate) this.publishWindow()
      return true
    }
    if (currentFrame + block < this.end) return true
    // WebKit can request another quantum after false. The transfer detaches frames.
    this.finished = true
    this.port.postMessage({frames: this.frames.subarray(0, this.used), first: this.first / sampleRate,
      frameSeconds: this.hop / sampleRate}, [this.frames.buffer])
    return false
  }

  publishWindow() {
    const {id, start, end} = this.window
    this.window = null
    const from = Math.max(0, Math.round((start * sampleRate - this.first) / this.hop))
    const to = Math.min(this.used / 3, Math.round((end * sampleRate - this.first) / this.hop))
    const kept = this.used - 3 * from <= this.frames.length
    const frames = new Float32Array(kept ? 3 * Math.max(0, to - from) : 0)
    const k = 3 * from % this.frames.length
    const tail = Math.min(frames.length, this.frames.length - k)
    frames.set(this.frames.subarray(k, k + tail))
    frames.set(this.frames.subarray(0, frames.length - tail), tail)
    this.port.postMessage({id, frames, first: (this.first + from * this.hop) / sampleRate,
      frameSeconds: this.hop / sampleRate}, [frames.buffer])
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

function measuredWindow(window, data) {
  if (!data || data.first - window.start > 0.1 || data.frames.length < 3) return null
  const frames = []
  for (let i = 0; i < data.frames.length; i += 3) {
    frames.push({rms: data.frames[i], peak: data.frames[i + 1], onset: data.frames[i + 2]})
  }
  return {...window, frames, frameSeconds: data.frameSeconds, changeAt: window.change - data.first}
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
      meter.port.onmessage = ({data}) => finish(measuredWindow(window, data))
      meter.onprocessorerror = () => finish(null)
      input.connect(meter)
    } catch { finish(null) }
  })
  return stop
}

// Keep 10 ms summaries in the render thread so a manual cut can look back at
// the music already heard. The longest crossfade is 20 s, with 4 s on each side.
export function createProgramMeter(ctx, input) {
  let node, opening, pending, serial = 0

  function cancel() {
    if (!pending) return
    clearTimeout(pending.timer)
    pending = null
    node?.port.postMessage(null)
  }

  function finish(data) {
    if (!pending) return
    const {window, report, timer} = pending
    clearTimeout(timer)
    pending = null
    const end = data && data.first + data.frames.length / 3 * data.frameSeconds
    report(end >= window.end - 0.02 ? measuredWindow(window, data) : null)
  }

  function stop() {
    cancel()
    opening = null
    if (!node) return
    try { input.disconnect(node) } catch { /* The device may have detached the input. */ }
    node.port.postMessage("stop")
    node.port.close()
    node.disconnect()
    node = null
  }

  function start() {
    if (node || opening) return opening
    const scheduled = preparePassageMeter(ctx).then(available => {
      if (!available || opening !== scheduled) return
      node = new AudioWorkletNode(ctx, "beatgrid-passage-meter", {numberOfInputs: 1, numberOfOutputs: 0,
        processorOptions: {historySeconds: 32}})
      node.port.onmessage = ({data}) => { if (pending?.id === data.id) finish(data) }
      const active = node
      node.onprocessorerror = () => { if (node === active) { finish(null); stop() } }
      input.connect(node)
    }).catch(() => { if (opening === scheduled) stop() }).finally(() => {
      if (opening === scheduled) opening = null
    })
    opening = scheduled
    return scheduled
  }

  function read(kind, overlap, bpm, report) {
    cancel()
    const change = ctx.currentTime
    if (!node || change < 4) return report(null)
    const id = ++serial
    const window = {kind, change, overlap, bpm, start: change - 4, end: change + overlap + 4}
    pending = {id, window, report, timer: setTimeout(() => finish(null), (overlap + 6) * 1000)}
    node.port.postMessage({id, start: window.start, end: window.end})
  }

  return {start, read, cancel, stop}
}

// A reservation follows the playing record; the sound card has its own clock.
// Only the real handoff may anchor a reading of the master output.
export function observeRoomPassage(ctx, input, choice, deck, report, measure = measurePassage) {
  const {plan, kind} = choice
  const now = ctx.currentTime
  const change = now + Math.max(0, choice.exitMs - deck.positionMs()) / (1000 * deck.playbackRate)
  const overlap = rehearsalOverlap(plan, kind)
  // Allow startup buffering on the media clock, then keep only what actually played.
  const guard = 1
  const window = {kind, change, overlap, bpm: deck.bpm * (plan.mix?.out.rate ?? deck.playbackRate),
    start: Math.max(now, change - plan.lead - guard), end: change + overlap + 2 + guard}
  let arrived = null, completed = false, stopped = false, capture

  function publish() {
    if (stopped || !completed || arrived === null) return
    stopped = true
    if (!capture) return report(null)
    const dt = capture.frameSeconds
    const first = change - capture.changeAt
    const wanted = arrived - plan.lead
    // A last-moment confirmation can only hear from the first quantum after it.
    const from = wanted <= now ? 0 : Math.round((wanted - first) / dt)
    const to = Math.round((arrived + overlap + 2 - first) / dt)
    if (from < 0 || to > capture.frames.length || to <= from) return report(null)
    report({...capture, frames: capture.frames.slice(from, to), changeAt: arrived - (first + from * dt)})
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
