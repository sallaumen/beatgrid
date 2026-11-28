import {measuredCompressorDelay} from "./compressor_delay.js"
import {rehearsalOverlap} from "./rehearsal.js"

// The tap has no outputs. Only stereo energy, peaks and attacks leave the render thread.
export const METER_PROCESSOR = `
// Four phases of the 12-tap interpolator from ITU-R BS.1770-5, Annex 2.
const taps = Float32Array.from([
  14, -239, -155, -68, 90, 240, 271, 122, -161, -424, -477, -218,
  272, 730, 832, 390, -487, -1364, -1641, -838, 1125, 3810, 6388, 7964,
  7964, 6388, 3810, 1125, -838, -1641, -1364, -487, 390, 832, 730, 272,
  -218, -477, -424, -161, 122, 271, 240, 90, -68, -155, -239, 14
], value => value / 8192)

function interpolatedPeak(history, oldest) {
  let a = 0, b = 0, c = 0, d = 0
  for (let i = 0; i < 12; i++) {
    const x = history[oldest + i], at = 4 * i
    a += x * taps[at]
    b += x * taps[at + 1]
    c += x * taps[at + 2]
    d += x * taps[at + 3]
  }
  return Math.max(Math.abs(a), Math.abs(b), Math.abs(c), Math.abs(d))
}

function copyRing(ring, from, length) {
  const result = new Float32Array(length)
  const k = from % ring.length, tail = Math.min(length, ring.length - k)
  result.set(ring.subarray(k, k + tail))
  result.set(ring.subarray(0, length - tail), tail)
  return result
}

class PassageMeter extends AudioWorkletProcessor {
  constructor(options) {
    super()
    const {start, end, historySeconds, monitorPeak} = options.processorOptions
    this.rolling = historySeconds > 0
    this.start = this.rolling ? currentFrame : Math.round(start * sampleRate)
    this.end = this.rolling ? Infinity : Math.round(end * sampleRate)
    this.hop = Math.max(1, Math.round(sampleRate / 100))
    this.peakPeriod = this.rolling && monitorPeak ? Math.max(1, Math.round(sampleRate / this.hop / 2)) : 0
    this.peakSince = 0
    this.lastPeakDbtp = null
    const samples = this.rolling ? historySeconds * sampleRate : this.end - this.start
    this.frames = new Float32Array(3 * Math.ceil(samples / this.hop))
    this.truePeaks = new Float32Array(this.frames.length / 3)
    this.history = [new Float32Array(24), new Float32Array(24)]
    this.cursor = this.warm = this.truePeak = 0
    this.used = this.count = this.power = this.high = this.peak = 0
    this.lastRms = this.lastHigh = 0
    this.previous = [0, 0]
    this.first = null
    this.finished = false
    this.window = null
    this.port.onmessage = ({data}) => {
      if (!this.rolling || data === "stop") this.finished = true
      else if (data === "resetPeak") {
        this.peakSince = this.used / 3
        this.lastPeakDbtp = null
      } else this.window = data
    }
  }

  process([channels]) {
    if (this.finished) return false
    const block = channels[0]?.length || 128
    const start = Math.max(0, this.start - currentFrame)
    const end = Math.min(block, this.end - currentFrame)
    const left = channels[0], right = channels[1] || left
    for (let i = start; i < end; i++) {
      if (this.first === null) this.first = currentFrame + i
      for (let c = 0; c < 2; c++) {
        const x = (c ? right : left)?.[i] || 0
        const difference = x - this.previous[c]
        this.previous[c] = x
        this.power += x * x / 2
        this.high += difference * difference / 2
        this.peak = Math.max(this.peak, Math.abs(x))
        const history = this.history[c]
        history[this.cursor] = history[this.cursor + 12] = x
        if (this.warm === 11) {
          this.truePeak = Math.max(this.truePeak, interpolatedPeak(history, this.cursor + 1))
        }
      }
      if (++this.cursor === 12) this.cursor = 0
      if (this.warm < 11) this.warm++
      if (++this.count === this.hop) {
        const rms = Math.sqrt(this.power / this.hop), high = Math.sqrt(this.high / this.hop)
        const k = this.used % this.frames.length
        this.frames[k] = rms
        this.frames[k + 1] = this.peak
        this.truePeaks[k / 3] = Math.max(this.peak, this.truePeak)
        this.frames[k + 2] = Math.max(0, rms - this.lastRms) + 2 * Math.max(0, high - this.lastHigh)
        this.used += 3
        if (this.peakPeriod && this.used / 3 % this.peakPeriod === 0) this.publishRecentPeak()
        this.lastRms = rms
        this.lastHigh = high
        this.count = this.power = this.high = this.peak = this.truePeak = 0
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
      truePeaks: this.truePeaks.subarray(0, this.used / 3), frameSeconds: this.hop / sampleRate},
      [this.frames.buffer, this.truePeaks.buffer])
    return false
  }

  // Reuse the stereo peaks already in the ring. Update at most twice a second,
  // holding a brief over long enough to read without repeating a steady value.
  publishRecentPeak() {
    const end = this.used / 3
    const from = Math.max(this.peakSince, end - Math.min(8 * this.peakPeriod, this.truePeaks.length))
    let peak = 0
    for (let i = from; i < end; i++) peak = Math.max(peak, this.truePeaks[i % this.truePeaks.length])
    const peakDbtp = peak > 1 ? Math.round(200 * Math.log10(peak)) / 10 : null
    if (peakDbtp === this.lastPeakDbtp) return
    this.lastPeakDbtp = peakDbtp
    this.port.postMessage({peakDbtp})
  }

  publishWindow() {
    const {id, start, end} = this.window
    this.window = null
    const from = Math.max(0, Math.round((start * sampleRate - this.first) / this.hop))
    const to = Math.min(this.used / 3, Math.round((end * sampleRate - this.first) / this.hop))
    const kept = this.used - 3 * from <= this.frames.length
    const count = kept ? Math.max(0, to - from) : 0
    const frames = copyRing(this.frames, 3 * from, 3 * count)
    const truePeaks = copyRing(this.truePeaks, from, count)
    this.port.postMessage({id, frames, truePeaks, first: (this.first + from * this.hop) / sampleRate,
      frameSeconds: this.hop / sampleRate}, [frames.buffer, truePeaks.buffer])
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
    frames.push({rms: data.frames[i], peak: data.frames[i + 1], onset: data.frames[i + 2],
      truePeak: data.truePeaks?.[i / 3]})
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
      meter.port.onmessage = null
      meter.onprocessorerror = null
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
export function createProgramMeter(ctx, input, onPeak) {
  let node, opening, pending, serial = 0, recentPeak = null

  function showPeak(value) {
    if (value === recentPeak) return
    recentPeak = value
    onPeak?.(value)
  }

  function onClockChange() {
    if (ctx.state === "running") node?.port.postMessage("resetPeak")
    else showPeak(null)
  }

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
    showPeak(null)
    opening = null
    if (!node) return
    if (onPeak) ctx.removeEventListener("statechange", onClockChange)
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
        processorOptions: {historySeconds: 32, monitorPeak: Boolean(onPeak)}})
      const active = node
      node.port.onmessage = ({data}) => {
        if (node !== active) return
        if ("peakDbtp" in data) {
          if (ctx.state === "running") showPeak(data.peakDbtp)
        } else if (pending?.id === data.id) finish(data)
      }
      node.onprocessorerror = () => { if (node === active) { finish(null); stop() } }
      if (onPeak) ctx.addEventListener("statechange", onClockChange)
      input.connect(node)
    }).catch(() => { if (opening === scheduled) stop() }).finally(() => {
      if (opening === scheduled) opening = null
    })
    opening = scheduled
    return scheduled
  }

  function read(kind, overlap, bpm, report, change = ctx.currentTime) {
    cancel()
    if (!node || change < 4) return report(null)
    const id = ++serial
    const window = {kind, change, overlap, bpm, start: change - 4, end: change + overlap + 4}
    pending = {id, window, report, timer: setTimeout(() => finish(null), (window.end - ctx.currentTime + 2) * 1000)}
    node.port.postMessage({id, start: window.start, end: window.end})
  }

  return {start, read, cancel, stop}
}

// A stable decoded platter and the compressor are both on the audio clock. Its
// future source position also detects tempo changes already queued in the DSP.
function measuredChange(ctx, deck, choice, now, delay) {
  if (delay == null || !deck.entry || deck.seeking?.()) return null
  const exit = choice.plan.exit ?? choice.exitMs / 1000
  const rate = deck.playbackRate
  const at = now + (exit - deck.entry.position(now)) / rate
  if (!Number.isFinite(at) || at - choice.plan.lead <= now ||
      Math.abs(deck.entry.position(at) - exit) > 1 / ctx.sampleRate) return null
  return at + delay
}

// A reservation follows the playing record; the sound card has its own clock.
// Only the real handoff may anchor a reading of the master output.
export function observeRoomPassage(ctx, input, choice, deck, report, measure = measurePassage, delay = measuredCompressorDelay(ctx)) {
  const {plan, kind} = choice
  const now = ctx.currentTime
  const projected = measuredChange(ctx, deck, choice, now, delay)
  const change = projected ?? now + Math.max(0, choice.exitMs - deck.positionMs()) / (1000 * deck.playbackRate)
  const overlap = rehearsalOverlap(plan, kind)
  const tail = plan.duration - plan.lead
  // Allow startup buffering on the media clock, then keep only what actually played.
  const guard = 1
  const window = {kind, change, overlap, bpm: deck.bpm * (plan.mix?.out.rate ?? deck.playbackRate),
    start: projected === null ? Math.max(now, change - plan.lead - guard) : projected - plan.lead,
    end: change + tail + guard}
  let arrived = null, completed = false, stopped = false, capture

  function publish() {
    if (stopped || !completed || arrived === null) return
    stopped = true
    if (!capture) return report(null)
    const dt = capture.frameSeconds
    const first = change - capture.changeAt
    const wanted = arrived - plan.lead
    // A last-moment confirmation can only hear from the first quantum after it.
    const offset = Math.round((wanted - first) / dt)
    const from = projected !== null ? Math.max(0, offset) : wanted <= now ? 0 : offset
    const sampleAligned = projected !== null && Math.round(wanted * ctx.sampleRate) === Math.round(first * ctx.sampleRate)
    // The headphone meter emits only whole frames of the audition, even for a short file.
    const lead = sampleAligned ? plan.lead : Math.min(plan.lead, arrived - first)
    const to = from + Math.floor((lead + tail) / dt + 1e-9)
    if (from < 0 || to > capture.frames.length || to <= from) return report(null)
    report({...capture, frames: capture.frames.slice(from, to), changeAt: arrived - (first + from * dt)}, projected === null || sampleAligned)
  }

  const cancel = measure(ctx, input, window, data => {
    capture = data
    completed = true
    publish()
  })
  return {
    choice,
    get arrived() { return arrived !== null },
    arrive(time) { arrived = time + (projected === null ? 0 : delay); publish() },
    cancel() { if (!stopped) { stopped = true; cancel() } }
  }
}
