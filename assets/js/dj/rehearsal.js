import {applyFilter, applyTone, createEq, neutralMix, setMixParam} from "./deck_mix.js"
import {blendGains, scheduleBlend} from "./blend_curve.js"
import {createRecordSource} from "./record_source.js"
import {connectHeadphoneFold} from "./headphone_fold.js"

// Cue points are record seconds. Durations and automation use the audio clock.
export function planRehearsal(outgoing, incoming, exit, entry, bpm, mix = {out: neutralMix, into: neutralMix}) {
  const outRate = mix.out.rate, inRate = mix.into.rate
  const fourBeats = 240 / (bpm > 0 ? bpm : 120)
  const inStart = Math.max(0, entry ?? 0)
  const point = exit != null && exit >= 0 && exit < outgoing.duration
    ? exit : Math.max(0, outgoing.duration - fourBeats)
  const inTime = (incoming.duration - inStart) / inRate
  const fourBeatTime = fourBeats / outRate
  const blend = Math.min(fourBeatTime, (outgoing.duration - point) / outRate, inTime)
  if (!(blend > 0)) return null
  const lead = Math.min(3, point / outRate)
  const duration = lead + Math.min(blend + 2, inTime)
  // Subtracting a fractional fallback cue from the record length can round down.
  const fullBlend = fourBeatTime - blend < 1e-9
  return {outgoing, incoming, exit: point, outStart: point - lead * outRate, inStart, lead, blend, fullBlend, duration, mix}
}

export const CUT_OVERLAP_S = 0.008

export function rehearsalOverlap(plan, kind) {
  return kind === "cut" ? Math.min(CUT_OVERLAP_S, plan.blend) : plan.blend
}

export function rehearsalGains(plan, kind, time) {
  const p = Math.min(1, Math.max(0, (time - plan.lead) / rehearsalOverlap(plan, kind)))
  return blendGains(kind === "blend" && plan.blendCurve, p)
}

// Both 200 Hz shelves are neutral on beat three. Open the new bass over half
// a beat before the handoff and remove the old bass over the following half.
const BASS_OPEN = 3 / 8, BASS_SWAP = 1 / 2, BASS_CLOSE = 5 / 8
const BASS_DEPTH_DB = 8

export function rehearsalBassWindow(plan) {
  const at = position => plan.lead + position * plan.blend
  return {start: at(BASS_OPEN), swap: at(BASS_SWAP), end: at(BASS_CLOSE)}
}

export function rehearsalBassDb(side, progress) {
  const cut = side === "out" ? (progress - BASS_SWAP) / (BASS_CLOSE - BASS_SWAP) :
    (BASS_SWAP - progress) / (BASS_SWAP - BASS_OPEN)
  return cut <= 0 ? 0 : -BASS_DEPTH_DB * Math.min(1, cut)
}

export function scheduleRehearsalBass(param, side, change, fade, at) {
  param.cancelScheduledValues(at)
  param.setValueAtTime(rehearsalBassDb(side, (at - change) / fade), at)
  for (const p of [BASS_OPEN, BASS_SWAP, BASS_CLOSE]) {
    const time = change + p * fade
    if (time > at) param.linearRampToValueAtTime(rehearsalBassDb(side, p), time)
  }
}

export function recordTime(plan, side, time) {
  return side === "out" ? plan.outStart + time * plan.mix.out.rate :
    plan.inStart + (time - plan.lead) * plan.mix.into.rate
}

// This transport has no references to live media elements or the master output.
export function createRehearsal(ctx, phones, pfl) {
  let current = null, cancelMeasurement = null

  function discardMeasurement() {
    cancelMeasurement?.()
    cancelMeasurement = null
  }

  function stop(completed = false, keepPhones = false) {
    if (!completed) discardMeasurement()
    if (!keepPhones) pfl.gain.value = 1
    if (!current) return
    const {sources, nodes, finish} = current
    current = null
    for (const source of sources) {
      source.onended = null
      source.stop()
    }
    for (const node of nodes) node.disconnect()
    finish(completed)
  }

  function applyMix(channels, mix, smooth) {
    for (const [side, channel] of Object.entries(channels)) {
      applyFilter(channel.eq, mix[side].filter, ctx.currentTime, smooth)
      applyTone(channel.eq, mix[side].tone, ctx.currentTime, smooth)
      setMixParam(channel.level.gain, mix[side].level, ctx.currentTime, smooth)
    }
  }

  function play(plan, kind, pan, skip = 0, observe, keepPhones = false) {
    if (skip >= plan.duration || (kind === "bass_swap" && !plan.fullBlend)) { stop(); return Promise.resolve(false) }
    stop(false, true)
    const now = ctx.currentTime
    const start = now - Math.max(0, skip)
    const change = start + plan.lead
    const fade = rehearsalOverlap(plan, kind)
    const finish = start + plan.duration
    const output = ctx.createStereoPanner()
    output.pan.value = pan
    const level = ctx.createGain()
    const oneEar = Math.abs(pan) === 1
    const monitor = oneEar ? ctx.createGain() : level
    if (oneEar) {
      monitor.channelCount = 1
      monitor.channelCountMode = "explicit"
    }
    const edge = Math.min(0.006, (finish - now) / 3)
    const buses = oneEar ? [level, monitor] : [level]
    for (const bus of buses) {
      bus.gain.setValueAtTime(0, now)
      bus.gain.linearRampToValueAtTime(1, now + edge)
      bus.gain.setValueAtTime(1, finish - edge)
      bus.gain.linearRampToValueAtTime(0, finish)
    }
    monitor.connect(output)
    output.connect(phones)
    const ended = new Promise(finish => {
      current = {start, plan, channels: {}, sources: [], nodes: [...buses, output], finish}
    })
    try {
      const add = (side, buffer, at, end) => {
        if (end <= at) return null
        const mix = plan.mix[side]
        const source = createRecordSource(ctx, buffer, mix)
        const eq = createEq(ctx), channel = ctx.createGain(), fader = ctx.createGain()
        if (kind === "bass_swap") scheduleRehearsalBass(eq.bass.gain, side, change, fade, at)
        source.connect(eq.hpf)
        eq.toneTreble.connect(channel)
        channel.connect(fader)
        fader.connect(level)
        current.channels[side] = {eq, level: channel}
        const gain = rehearsalGains(plan, kind, at - start)[side === "out" ? 0 : 1]
        fader.gain.setValueAtTime(gain, at)
        if (change + fade > at) {
          scheduleBlend(fader.gain, kind === "blend" && plan.blendCurve, side === "out" ? 0 : 1, change, fade, at)
        }
        current.nodes.push(source, ...Object.values(eq), channel, fader)
        const offset = Math.max(0, recordTime(plan, side, at - start))
        if (oneEar) {
          const fold = connectHeadphoneFold(ctx, fader, monitor, buffer, at, offset, end - at, mix.rate)
          current.nodes.push(...fold)
        }
        source.start(at, offset, (end - at) * mix.rate)
        current.sources.push(source)
        return source
      }
      pfl.gain.value = 0
      add("out", plan.outgoing, now, change + fade)
      const last = add("into", plan.incoming, Math.max(now, change), finish)
      applyMix(current.channels, plan.mix, false)
      // A missing meter must never interrupt the audio already scheduled.
      if (observe) {
        try { cancelMeasurement = observe(level, {start, change, end: finish, overlap: fade, kind}) }
        catch { cancelMeasurement = null }
      }
      last.onended = () => { if (current?.sources.includes(last)) stop(true, keepPhones) }
      return ended
    } catch (error) {
      stop()
      throw error
    }
  }

  function edit(plan, kind, pan) {
    discardMeasurement()
    if (!current) return
    const before = current.plan
    if ((kind === "blend" && before.blendCurve !== plan.blendCurve) || ["out", "into"].some(s => before.mix[s].rate !== plan.mix[s].rate || before.mix[s].vinyl !== plan.mix[s].vinyl)) {
      const elapsed = ctx.currentTime - current.start
      const skip = elapsed < before.lead
        ? (recordTime(before, "out", elapsed) - plan.outStart) / plan.mix.out.rate
        : plan.lead + (recordTime(before, "into", elapsed) - plan.inStart) / plan.mix.into.rate
      play(plan, kind, pan, Math.max(0, skip))
    } else {
      applyMix(current.channels, plan.mix, true)
      current.plan = plan
    }
  }

  return {play, edit, stop, elapsed: () => current ? ctx.currentTime - current.start : null}
}
