import {createEq} from "./deck_mix.js"

const PREROLL = 0.5
const GUARD = 0.15

function eligible(plan) {
  if (!plan.fullBlend || !(plan.blend >= 0.5 && plan.blend <= 6)) return false
  const {outgoing, incoming, mix} = plan
  const sr = outgoing.sampleRate
  return sr === incoming.sampleRate && sr >= 32_000 && sr <= 96_000 &&
    [outgoing, incoming].every(buffer => [1, 2].includes(buffer.numberOfChannels)) &&
    [mix.out, mix.into].every(m => m.rate === 1 && m.filter === 0 && m.tone === 0 && m.level > 0 && m.level <= 1)
}

// Keep stems separate so a quiet acoustic sum or opposite polarity can never hide a hot deck.
function renderStems(plan, Offline) {
  const sr = plan.outgoing.sampleRate
  const ctx = new Offline(4, Math.ceil((PREROLL + plan.blend + GUARD) * sr), sr)
  const bus = ctx.createChannelMerger(4)
  bus.connect(ctx.destination)
  for (const [i, buffer] of [plan.outgoing, plan.incoming].entries()) {
    const src = ctx.createBufferSource(), eq = createEq(ctx), split = ctx.createChannelSplitter(2)
    src.buffer = buffer
    src.connect(eq.hpf)
    eq.toneTreble.connect(split)
    split.connect(bus, 0, 2 * i)
    split.connect(bus, buffer.numberOfChannels === 1 ? 0 : 1, 2 * i + 1)
    const before = i === 0 ? Math.min(PREROLL, plan.exit) : 0
    src.start(PREROLL - before, i === 0 ? plan.exit - before : plan.inStart)
  }
  return ctx.startRendering()
}

export async function measureBlendCurve(plan, active = () => true) {
  const Offline = globalThis.OfflineAudioContext ?? globalThis.webkitOfflineAudioContext
  if (!Offline || !eligible(plan)) return null
  return measuredBlend(plan, await renderStems(plan, Offline), active)
}

export async function measuredBlend(plan, rendered, active = () => true) {
  const sr = rendered.sampleRate, start = Math.round(PREROLL * sr), end = Math.round((PREROLL + plan.blend) * sr)
  let outPeak = 0, inPeak = 0, correlation = 0, audible = false
  for (let ch = 0; ch < 2; ch++) {
    const out = rendered.getChannelData(ch), into = rendered.getChannelData(2 + ch)
    let dot = 0, powerA = 0, powerB = 0
    for (let offset = start - Math.round(GUARD * sr); offset < out.length; offset += 16384) {
      if (!active()) return null
      const last = Math.min(offset + 16384, out.length)
      for (let n = offset; n < last; n++) {
        const a = out[n], b = into[n]
        outPeak = Math.max(outPeak, Math.abs(a))
        inPeak = Math.max(inPeak, Math.abs(b))
        if (n >= start && n < end) { powerA += a * a; powerB += b * b; dot += a * b }
      }
      // Yield between bounded scans even on machines without a Worker or an idle callback.
      if (last < out.length) await new Promise(resolve => setTimeout(resolve, 0))
    }
    if (Math.min(powerA, powerB) > (end - start) * 1e-6) {
      audible = true
      correlation = Math.max(correlation, Math.abs(dot) / Math.sqrt(powerA * powerB))
    }
  }
  outPeak *= plan.mix.out.level
  inPeak *= plan.mix.into.level
  if (!audible || correlation >= 0.90 || Math.min(outPeak, inPeak) < 0.003 ||
      !Number.isFinite(outPeak + inPeak + correlation) || Math.max(outPeak, inPeak) >= 1 ||
      Math.min(outPeak, inPeak) >= 10 ** (-3 / 20)) return null
  return Object.freeze({correlation, outPeak, inPeak})
}

// Only an untouched draft may acquire a curve. A late render has no path to a heard or armed plan.
export function createBlendReview(inspect = measureBlendCurve, debounce = 80) {
  let version = 0, timer, pending = Promise.resolve()
  function lock() {
    version++
    clearTimeout(timer)
  }
  function prepare(plan, accept) {
    lock()
    const id = version, active = () => id === version
    timer = setTimeout(() => {
      pending = pending.then(async () => {
        if (!active()) return
        try {
          const curve = await inspect(plan, active)
          if (curve && active()) accept(curve)
        } catch { /* The same linear plan remains available to headphones and the room. */ }
      })
    }, debounce)
  }
  return {prepare, lock}
}
