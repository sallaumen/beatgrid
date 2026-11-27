import {recordTime, rehearsalGains, rehearsalOverlap} from "./rehearsal.js"

const sides = ["out", "into"]
const colors = ["#ffb020", "#5ad1a0"]

function peakBetween(wave, from, to) {
  const start = Math.max(0, Math.floor(from * wave.bps))
  const end = Math.min(wave.peaks.length, Math.ceil(to * wave.bps))
  let peak = 0
  for (let i = start; i < end; i++) peak = Math.max(peak, wave.peaks[i])
  return peak
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

function drawWave(view, wave, plan, kind, index, peak) {
  const {width, height, context} = view
  const mid = height / 2, side = sides[index]
  const pixelsPerUnit = (mid - 2) / peak
  context.fillStyle = "#9498a62a"
  context.fillRect(0, Math.floor(mid), width, 1)
  context.fillStyle = colors[index]
  for (let x = 0; x < width; x++) {
    const from = x * plan.duration / width, to = (x + 1) * plan.duration / width
    const gain = rehearsalGains(plan, kind, (from + to) / 2)[index] * plan.mix[side].level
    if (gain === 0) continue
    const amplitude = peakBetween(wave, recordTime(plan, side, from), recordTime(plan, side, to)) * gain * pixelsPerUnit
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
  const peak = Math.max(1 / 16,
    peakBetween(waves[0], plan.outStart, recordTime(plan, "out", plan.lead + plan.blend)),
    peakBetween(waves[1], plan.inStart, recordTime(plan, "into", plan.duration)))
  const overlap = rehearsalOverlap(plan, kind)
  for (const [index, canvas] of [...lanes, gainCanvas].entries()) {
    const view = surface(canvas, pixelRatio)
    const [start, end] = bounds(view, plan, overlap)
    drawRegion(view, start, end)
    if (index < lanes.length) drawWave(view, waves[index], plan, kind, index, peak)
    drawEdges(view, start, end)
    if (index === lanes.length) drawGains(view, plan, kind, overlap)
  }
}
