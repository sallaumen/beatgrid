// Serato-style scrolling waveforms for the Discotecagem console.
//
// The audio file is fetched once, decoded off the playback path and reduced to
// a peak envelope (~50 buckets/second). Drawing happens every frame from that
// small array: the playhead is FIXED at the canvas center and the wave scrolls
// under it — turn the platter and you see exactly where the needle is going.

const peaksCache = new Map() // trackId → Promise<{peaks, bps, durationS}>
const MAX_CACHE = 12

// Full mono PCM kept for scratching (AudioWorklet reads it sample-by-sample).
// Heavy (~50 MB/track), so a tight cap: only the decks + a couple recent tracks.
const monoCache = new Map() // trackId → Float32Array (ctx-rate mono samples)
const MAX_MONO = 4

// The cache holds PROMISES: loading the same track on both decks (treino de
// beatmatching) reuses one fetch+decode; failures evict so a retry can work.
export function loadPeaks(trackId, src, ctx) {
  if (peaksCache.has(trackId)) return peaksCache.get(trackId)
  const promise = decode(trackId, src, ctx)
  peaksCache.set(trackId, promise)
  promise.catch(() => peaksCache.delete(trackId))
  if (peaksCache.size > MAX_CACHE) {
    peaksCache.delete(peaksCache.keys().next().value)
  }
  return promise
}

// Mono PCM for the scratch engine, cached by the same decode as the waveform.
// Returns null until the track has been decoded (loadPeaks resolved).
export function getScratchPcm(trackId) {
  return monoCache.get(trackId) || null
}

async function decode(trackId, src, ctx) {
  const res = await fetch(src)
  if (!res.ok) throw new Error(`audio fetch failed: ${res.status}`)
  const buf = await res.arrayBuffer()
  const audio = await ctx.decodeAudioData(buf)
  const ch0 = audio.getChannelData(0)
  const ch1 = audio.numberOfChannels > 1 ? audio.getChannelData(1) : ch0

  // Mono downmix at ctx rate — the scratch worklet reads this back and forth.
  const mono = new Float32Array(ch0.length)
  for (let i = 0; i < ch0.length; i++) mono[i] = (ch0[i] + ch1[i]) * 0.5
  monoCache.set(trackId, mono)
  if (monoCache.size > MAX_MONO) monoCache.delete(monoCache.keys().next().value)

  const bps = 50
  const total = Math.ceil(audio.duration * bps)
  const peaks = new Float32Array(total)
  const samplesPerBucket = Math.floor(audio.sampleRate / bps)
  for (let i = 0; i < total; i++) {
    let max = 0
    const start = i * samplesPerBucket
    const end = Math.min(start + samplesPerBucket, ch0.length)
    for (let j = start; j < end; j += 4) {
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
