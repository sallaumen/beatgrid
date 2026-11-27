import {recordTime, rehearsalBassDb, rehearsalBassWindow, rehearsalGains, rehearsalOverlap} from "./rehearsal.js"

const sides = ["out", "into"]
const colors = ["#ffb020", "#5ad1a0"]

function maximum(samples, start, end) {
  let peak = 0
  const stop = Math.min(samples.length, end)
  for (let i = Math.max(0, start); i < stop; i++) {
    const value = Math.abs(samples[i])
    if (value > peak) peak = value
  }
  return peak
}

function peakReader({bps, peaks}, buffer) {
  if (!buffer) return (from, to) => maximum(peaks, Math.floor(from * bps), Math.ceil(to * bps))
  const channels = Array.from({length: Math.min(2, buffer.numberOfChannels)}, (_, i) => buffer.getChannelData(i))
  const samples = (from, to) => {
    const start = Math.ceil(from * buffer.sampleRate), end = Math.ceil(to * buffer.sampleRate)
    return Math.max(maximum(channels[0], start, end), channels[1] ? maximum(channels[1], start, end) : 0)
  }
  return (from, to) => {
    // Full 20 ms buckets are exact. A partial one may contain an attack outside this pixel or cue.
    const first = Math.ceil(from * bps), end = Math.floor(to * bps)
    if (first >= end) return samples(from, to)
    return Math.max(samples(from, first / bps), maximum(peaks, first, end), samples(end / bps, to))
  }
}

function surface(canvas, pixelRatio) {
  const width = Math.max(1, canvas.clientWidth), height = canvas.clientHeight
  canvas.width = Math.round(width * pixelRatio)
  canvas.height = Math.round(height * pixelRatio)
  const context = canvas.getContext("2d")
  context.scale(pixelRatio, pixelRatio)
  return {context, width, height}
}

function bounds(view, plan, overlap) {
  const pixel = time => Math.min(view.width - 1, Math.floor(view.width * time / plan.duration))
  const start = pixel(plan.lead)
  return [start, view.width * overlap < plan.duration ? start : pixel(plan.lead + overlap)]
}

function drawRegion(view, start, end) {
  if (end <= start) return
  view.context.fillStyle = "#c4c7d014"
  view.context.fillRect(start, 0, end - start, view.height)
}

function drawEdges(view, start, end) {
  view.context.fillStyle = "#9498a6"
  view.context.fillRect(start, 0, 1, view.height)
  if (end !== start) view.context.fillRect(end, 0, 1, view.height)
}

function drawWave(view, readPeak, plan, kind, index, peak, overlap) {
  const {width, height, context} = view
  const mid = height / 2, side = sides[index]
  const pixelsPerUnit = (mid - 2) / peak
  context.fillStyle = "#9498a62a"
  context.fillRect(0, Math.floor(mid), width, 1)
  context.fillStyle = colors[index]
  const begin = index === 0 ? 0 : plan.lead
  const end = index === 0 ? plan.lead + overlap : plan.duration
  for (let x = 0; x < width; x++) {
    const from = Math.max(begin, x * plan.duration / width), to = Math.min(end, (x + 1) * plan.duration / width)
    if (from >= to) continue
    const gain = rehearsalGains(plan, kind, (from + to) / 2)[index] * plan.mix[side].level
    if (gain === 0) continue
    const amplitude = readPeak(recordTime(plan, side, from), recordTime(plan, side, to)) * gain * pixelsPerUnit
    if (amplitude > 0) context.fillRect(x, mid - amplitude, 1, 2 * amplitude)
  }
}

function drawGains(view, plan, kind, overlap) {
  const {width, height, context} = view
  const x = time => time * width / plan.duration
  const start = plan.lead, end = start + overlap
  for (const [index, side] of sides.entries()) {
    const y = t => 2 + (1 - rehearsalGains(plan, kind, t)[index] * plan.mix[side].level) * (height - 4)
    context.strokeStyle = colors[index]
    context.lineWidth = 2
    context.setLineDash(index === 0 ? [] : [5, 3])
    context.beginPath()
    context.moveTo(0, y(0))
    context.lineTo(x(start), y(start))
    for (let column = Math.ceil(x(start)); column < x(end); column++) {
      context.lineTo(column, y(column * plan.duration / width))
    }
    context.lineTo(x(end), y(end))
    context.lineTo(width, y(plan.duration))
    context.stroke()
  }
}

export function drawRehearsalWaves(lanes, gainCanvas, waves, plan, kind, pixelRatio) {
  // Keep one scale across decks and across transition choices. Limit visual amplification to 16x.
  const readers = [peakReader(waves[0], plan.outgoing), peakReader(waves[1], plan.incoming)]
  const peak = Math.max(1 / 16,
    readers[0](plan.outStart, recordTime(plan, "out", plan.lead + plan.blend)),
    readers[1](plan.inStart, recordTime(plan, "into", plan.duration)))
  const overlap = rehearsalOverlap(plan, kind)
  for (const [index, canvas] of [...lanes, gainCanvas].entries()) {
    const view = surface(canvas, pixelRatio)
    const [start, end] = bounds(view, plan, overlap)
    drawRegion(view, start, end)
    if (index < lanes.length) drawWave(view, readers[index], plan, kind, index, peak, overlap)
    drawEdges(view, start, end)
    if (kind === "bass_swap" && plan.fullBlend) drawBassMarker(view, plan)
    if (index === lanes.length) drawGains(view, plan, kind, overlap)
  }
}

function drawBassMarker(view, plan) {
  const x = Math.floor(view.width * rehearsalBassWindow(plan).swap / plan.duration)
  view.context.fillStyle = "#e6e9f2"
  view.context.fillRect(x, 0, 1, view.height)
}

export function drawRehearsalBass(canvas, plan, pixelRatio) {
  const view = surface(canvas, pixelRatio)
  const {width, height, context} = view
  const {start, swap, end} = rehearsalBassWindow(plan)
  const [left, right] = bounds(view, plan, plan.blend)
  drawRegion(view, left, right)
  drawBassMarker(view, plan)
  const depth = -rehearsalBassDb("into", 0)
  for (const [index, side] of sides.entries()) {
    context.strokeStyle = colors[index]
    context.lineWidth = 2
    context.setLineDash(index === 0 ? [] : [5, 3])
    context.beginPath()
    // The shelf ramps linearly in dB between its scheduled breakpoints.
    for (const [i, time] of [plan.lead, start, swap, end, plan.lead + plan.blend].entries()) {
      const x = width * time / plan.duration
      const db = rehearsalBassDb(side, (time - plan.lead) / plan.blend)
      const y = 2 - db / depth * (height - 4)
      if (i === 0) context.moveTo(x, y)
      else context.lineTo(x, y)
    }
    context.stroke()
  }
}
