import {applyFilter, applyTone, createEq, neutralMix, setMixParam} from "./deck_mix.js"
import {createRecordSource} from "./record_source.js"

// Cue points are record seconds. Durations and automation use the audio clock.
export function planRehearsal(outgoing, incoming, exit, entry, bpm, mix = {out: neutralMix, into: neutralMix}) {
  const outRate = mix.out.rate, inRate = mix.into.rate
  const fourBeats = 240 / (bpm > 0 ? bpm : 120)
  const inStart = Math.max(0, entry ?? 0)
  const point = exit != null && exit >= 0 && exit < outgoing.duration
    ? exit : Math.max(0, outgoing.duration - fourBeats)
  const inTime = (incoming.duration - inStart) / inRate
  const blend = Math.min(fourBeats / outRate, (outgoing.duration - point) / outRate, inTime)
  if (!(blend > 0)) return null
  const lead = Math.min(3, point / outRate)
  const duration = lead + Math.min(blend + 2, inTime)
  return {outgoing, incoming, exit: point, outStart: point - lead * outRate, inStart, lead, blend, duration, mix}
}

export function rehearsalOverlap(plan, kind) {
  return kind === "cut" ? Math.min(0.008, plan.blend) : plan.blend
}

export function rampRehearsalGain(param, change, fade, start, end) {
  param.setValueAtTime(start, change)
  param.linearRampToValueAtTime(end, change + fade)
}

export function rehearsalGains(plan, kind, time) {
  const p = Math.min(1, Math.max(0, (time - plan.lead) / rehearsalOverlap(plan, kind)))
  return [1 - p, p]
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

  function stop(completed = false) {
    if (!completed) discardMeasurement()
    if (!current) return
    const {sources, nodes} = current
    current = null
    for (const source of sources) {
      source.onended = null
      source.stop()
    }
    for (const node of nodes) node.disconnect()
    pfl.gain.value = 1
  }

  function applyMix(channels, mix, smooth) {
    for (const [side, channel] of Object.entries(channels)) {
      applyFilter(channel.eq, mix[side].filter, ctx.currentTime, smooth)
      applyTone(channel.eq, mix[side].tone, ctx.currentTime, smooth)
      setMixParam(channel.level.gain, mix[side].level, ctx.currentTime, smooth)
    }
  }

  function play(plan, kind, pan, skip = 0, observe) {
    stop()
    if (skip >= plan.duration) return
    const now = ctx.currentTime
    const start = now - Math.max(0, skip)
    const change = start + plan.lead
    const fade = rehearsalOverlap(plan, kind)
    const finish = start + plan.duration
    const output = ctx.createStereoPanner()
    output.pan.value = pan
    const level = ctx.createGain()
    const edge = Math.min(0.006, (finish - now) / 3)
    level.gain.setValueAtTime(0, now)
    level.gain.linearRampToValueAtTime(1, now + edge)
    level.gain.setValueAtTime(1, finish - edge)
    level.gain.linearRampToValueAtTime(0, finish)
    level.connect(output)
    output.connect(phones)
    current = {start, plan, channels: {}, sources: [], nodes: [level, output]}
    try {
      const add = (side, buffer, at, end, a, b) => {
        if (end <= at) return null
        const mix = plan.mix[side]
        const source = createRecordSource(ctx, buffer, mix)
        const eq = createEq(ctx), channel = ctx.createGain(), fader = ctx.createGain()
        source.connect(eq.hpf)
        eq.toneTreble.connect(channel)
        channel.connect(fader)
        fader.connect(level)
        current.channels[side] = {eq, level: channel}
        const gain = rehearsalGains(plan, kind, at - start)[side === "out" ? 0 : 1]
        fader.gain.setValueAtTime(gain, at)
        if (change + fade > at) {
          const ramp = Math.max(at, change)
          rampRehearsalGain(fader.gain, ramp, change + fade - ramp, at < change ? a : gain, b)
        }
        current.nodes.push(source, ...Object.values(eq), channel, fader)
        source.start(at, Math.max(0, recordTime(plan, side, at - start)), (end - at) * mix.rate)
        current.sources.push(source)
        return source
      }
      pfl.gain.value = 0
      add("out", plan.outgoing, now, change + fade, 1, 0)
      const last = add("into", plan.incoming, Math.max(now, change), finish, 0, 1)
      applyMix(current.channels, plan.mix, false)
      // A missing meter must never interrupt the audio already scheduled.
      if (observe) {
        try { cancelMeasurement = observe(level, {start, change, end: finish, overlap: fade, kind}) }
        catch { cancelMeasurement = null }
      }
      last.onended = () => { if (current?.sources.includes(last)) stop(true) }
    } catch (error) {
      stop()
      throw error
    }
  }

  function edit(plan, kind, pan) {
    discardMeasurement()
    if (!current) return
    const before = current.plan
    if (["out", "into"].some(s => before.mix[s].rate !== plan.mix[s].rate || before.mix[s].vinyl !== plan.mix[s].vinyl)) {
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
