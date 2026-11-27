import {prepareHeadphoneFold} from "./headphone_fold.js"

// Serato-style scrolling waveforms for the Discotecagem console.
//
// The audio file is fetched once, decoded off the playback path and reduced to
// a peak envelope (~50 buckets/second). A moving deck draws from that small
// array every frame: the playhead is FIXED at the canvas center and the wave scrolls
// under it — turn the platter and you see exactly where the needle is going.

// Keep the envelope and scratch PCM together. A cached envelope alone would
// leave a revisited deck permanently unable to scratch until a page reload.
const clips = new Map()
// Stereo rehearsal buffers and scratch PCM share the two platter slots.
const MAX_CLIPS = 2
const platterTracks = new Map()

export function retainScratch(platter, trackId) {
  const previous = platterTracks.get(platter)
  if (trackId == null) platterTracks.delete(platter)
  else platterTracks.set(platter, trackId)
  const pending = clips.get(previous)?.loading
  if (pending && previous !== trackId && ![...platterTracks.values()].includes(previous)) {
    clips.delete(previous)
    pending.abort()
  }
}

export function loadPeaks(trackId, src, ctx) {
  let clip = clips.get(trackId)
  if (clip) {
    clips.delete(trackId)
  } else {
    clip = {pcm: null, loading: new AbortController()}
    clip.ready = decode(clip, src, ctx).catch(error => {
      if (clips.get(trackId) === clip) clips.delete(trackId)
      throw error
    }).finally(() => { clip.loading = null })
  }
  clips.set(trackId, clip)
  if (clips.size > MAX_CLIPS) {
    const mounted = new Set(platterTracks.values())
    for (const id of clips.keys()) {
      if (mounted.has(id)) continue
      clips.delete(id)
      break
    }
  }
  return clip.ready
}

export function getDeckAudio(trackId) {
  return clips.get(trackId)?.audio || null
}

export function getScratchPcm(trackId) {
  return clips.get(trackId)?.pcm || null
}

// The scratch head reads mono. Use the same phase-safe balance heard in one ear.
function scratchSamples(audio, left, right) {
  if (audio.numberOfChannels === 1) return left.slice()
  const points = prepareHeadphoneFold(audio, left, right)
  const pcm = new Float32Array(left.length)
  let start = 0
  for (let p = 0; p < points.length; p++) {
    const next = points[p + 1]
    const end = next ? Math.round(next.time * audio.sampleRate) : pcm.length
    let share = points[p].share
    const step = next && end > start ? (next.share - share) / (end - start) : 0
    for (let i = start; i < end; i++, share += step) {
      pcm[i] = left[i] * (1 - Math.abs(share)) + right[i] * share
    }
    start = end
  }
  return pcm
}

async function decode(clip, src, ctx) {
  const {signal} = clip.loading
  const res = await fetch(src, {signal})
  if (!res.ok) throw new Error(`audio fetch failed: ${res.status}`)
  const buf = await res.arrayBuffer()
  signal.throwIfAborted()
  const audio = await ctx.decodeAudioData(buf)
  // A running decoder cannot be aborted, but an abandoned buffer needs no scratch copy.
  signal.throwIfAborted()
  clip.audio = audio
  const ch0 = audio.getChannelData(0)
  const ch1 = audio.numberOfChannels > 1 ? audio.getChannelData(1) : ch0

  clip.pcm = scratchSamples(audio, ch0, ch1)

  const bps = 50
  const total = Math.ceil(audio.duration * bps)
  const peaks = new Float32Array(total)
  for (let i = 0; i < total; i++) {
    let max = 0
    const start = Math.ceil(i * audio.sampleRate / bps)
    const end = Math.min(Math.ceil((i + 1) * audio.sampleRate / bps), ch0.length)
    for (let j = start; j < end; j++) {
      const a = Math.abs(ch0[j])
      if (a > max) max = a
      const b = Math.abs(ch1[j])
      if (b > max) max = b
    }
    peaks[i] = max
  }

  return {peaks, bps, durationS: audio.duration, sampleRate: audio.sampleRate}
}

const MARKER_COLORS = {cue: "#ffb020", intro: "#5ad1a0", outro: "#ff5d6c"}

// A stopped deck keeps its canvas while the other platter scrolls. Marker edits
// replace the list; loopState returns a new object, so compare its visible bounds.
export function mountDeckWave(canvas) {
  let parked = null
  const invalidate = () => { parked = null }
  canvas.addEventListener("contextrestored", invalidate)

  function resize(pixelRatio) {
    const width = Math.floor(canvas.clientWidth * pixelRatio)
    const height = Math.floor(canvas.clientHeight * pixelRatio)
    if (canvas.width === width && canvas.height === height) return
    canvas.width = width
    canvas.height = height
    invalidate()
  }

  function draw(state) {
    const loop = state.loop?.on ? state.loop : null
    const picture = state.playing ? null : [state.entry, state.posS, state.windowS, state.bpm,
      state.gridPhaseMs, state.markers, loop?.startMs, loop?.endMs, state.fireMs, state.accent, state.label]
    if (picture && parked && picture.every((value, i) => value === parked[i])) return
    drawWave(canvas, state)
    parked = picture
  }

  return {draw, resize, destroy() { canvas.removeEventListener("contextrestored", invalidate); invalidate() }}
}

// Draw one deck's lane. `state`:
//   posS, playing, accent, entry (from loadPeaks) | null,
//   windowS (visible seconds), bpm (beat grid), gridPhaseMs,
//   markers [{ms,type}], loop {on,startMs,endMs}, label
export function drawWave(canvas, state) {
  const g = canvas.getContext("2d")
  const w = canvas.width
  const h = canvas.height
  g.clearRect(0, 0, w, h)

  const {entry} = state
  if (!entry) {
    g.fillStyle = "rgba(255,255,255,.25)"
    g.font = `${10 * (window.devicePixelRatio || 1)}px monospace`
    g.textBaseline = "middle"
    g.fillText(state.label || "", 8, h / 2)
    return
  }

  const {peaks, bps} = entry
  const windowS = state.windowS || 16
  const pxPerS = w / windowS
  const startS = state.posS - windowS / 2
  const mid = h / 2

  // beat grid from the effective tempo — a ruler, not a true beatgrid
  if (state.bpm) {
    const beatS = 60 / state.bpm
    const phaseS = (state.gridPhaseMs || 0) / 1000
    let k = Math.ceil((startS - phaseS) / beatS)
    g.strokeStyle = "rgba(255,255,255,.07)"
    g.lineWidth = 1
    for (; ; k++) {
      const t = phaseS + k * beatS
      if (t > startS + windowS) break
      const x = (t - startS) * pxPerS
      g.beginPath()
      g.moveTo(x, 0)
      g.lineTo(x, h)
      g.stroke()
    }
  }

  // the envelope, past dimmer than future — two passes so fillStyle changes
  // twice per frame, not once per column (canvas rect batching survives)
  const drawColumns = (x0, x1) => {
    for (let x = Math.max(Math.floor(x0), 0); x < Math.min(x1, w); x++) {
      const t = startS + x / pxPerS
      if (t < 0 || t > entry.durationS) continue
      const amp = peaks[Math.floor(t * bps)] || 0
      const y = Math.max(amp * (mid - 2), 1)
      g.fillRect(x, mid - y, 1, y * 2)
    }
  }
  const splitX = (state.posS - startS) * pxPerS
  g.fillStyle = `${state.accent}55`
  drawColumns(0, splitX)
  g.fillStyle = state.accent
  drawColumns(splitX, w)

  // loop region
  if (state.loop && state.loop.on && state.loop.endMs != null) {
    const x1 = (state.loop.startMs / 1000 - startS) * pxPerS
    const x2 = (state.loop.endMs / 1000 - startS) * pxPerS
    if (x2 > 0 && x1 < w) {
      g.fillStyle = "rgba(90,209,160,.18)"
      g.fillRect(Math.max(x1, 0), 0, Math.min(x2, w) - Math.max(x1, 0), h)
      g.strokeStyle = "rgba(90,209,160,.8)"
      for (const x of [x1, x2]) {
        if (x < 0 || x > w) continue
        g.beginPath()
        g.moveTo(x, 0)
        g.lineTo(x, h)
        g.stroke()
      }
    }
  }

  // cue markers
  for (const m of state.markers || []) {
    const x = (m.ms / 1000 - startS) * pxPerS
    if (x < 0 || x > w) continue
    g.fillStyle = MARKER_COLORS[m.type] || MARKER_COLORS.cue
    g.fillRect(x - 1, 0, 2, h)
    g.beginPath()
    g.moveTo(x - 4, 0)
    g.lineTo(x + 4, 0)
    g.lineTo(x, 6)
    g.closePath()
    g.fill()
  }

  // the AUTO fire point — where the next transition takes over (flag at the
  // bottom so it never collides with the cue-marker flags at the top)
  if (state.fireMs != null) {
    const x = (state.fireMs / 1000 - startS) * pxPerS
    if (x >= 0 && x <= w) {
      g.fillStyle = "#ff9f2e"
      g.fillRect(x - 1, 0, 2, h)
      g.beginPath()
      g.moveTo(x - 5, h)
      g.lineTo(x + 5, h)
      g.lineTo(x, h - 7)
      g.closePath()
      g.fill()
    }
  }

  // fixed playhead at center
  g.fillStyle = state.playing ? "#ffffff" : "rgba(255,255,255,.6)"
  g.fillRect(w / 2 - 1, 0, 2, h)
}
