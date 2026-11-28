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

export function scheduleRehearsalBass(param, side, change, fade, at, previousProgress) {
  param.cancelScheduledValues(at)
  if (previousProgress !== undefined) param.linearRampToValueAtTime(rehearsalBassDb(side, previousProgress), at)
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
  const edgeSeconds = 0.006
  const guard = 256 / ctx.sampleRate // Two render quanta for the audio thread.
  const startLead = 3 * guard
  let current = null, cancelMeasurement = null, pflTarget = 1
  const heardSplices = new WeakMap()
  const fading = new Set()

  function saveSplices() {
    if (!current?.outSource?.splices || ctx.currentTime < current.change) return
    const saved = current.outSource.splices()
    if (saved) {
      const takes = heardSplices.get(current.plan) ?? {}
      takes[current.kind] = saved
      heardSplices.set(current.plan, takes)
    }
  }

  function splices(plan, kind) {
    if (current?.plan === plan && current.kind === kind) saveSplices()
    return heardSplices.get(plan)?.[kind]
  }

  function discardMeasurement() {
    cancelMeasurement?.()
    cancelMeasurement = null
  }

  function release(take, completed = false) {
    if (!take || take.released) return
    take.released = true
    fading.delete(take)
    if (take.clock) {
      take.clock.onended = null
      take.clock.stop()
      take.clock.disconnect()
    }
    for (const {record, fader} of Object.values(take.channels)) {
      record.level.disconnect(fader)
      if (--record.users === 0) {
        record.source.onended = null
        record.source.stop()
        for (const node of [record.source, ...Object.values(record.eq), record.level]) node.disconnect()
      }
    }
    for (const node of take.nodes) node.disconnect()
    take.finish(completed)
  }

  function fadePfl(value, end) {
    if (pflTarget === value) return
    pflTarget = value
    const now = ctx.currentTime, gain = pfl.gain
    if (gain.cancelAndHoldAtTime) gain.cancelAndHoldAtTime(now)
    else {
      const held = gain.value
      gain.cancelScheduledValues(now)
      gain.setValueAtTime(held, now)
    }
    gain.linearRampToValueAtTime(value, end)
  }

  function stop(completed = false, keepPhones = false) {
    if (!completed) discardMeasurement()
    if (!keepPhones) {
      if (completed) fadePfl(1, ctx.currentTime + edgeSeconds)
      else {
        pflTarget = 1
        pfl.gain.cancelScheduledValues(ctx.currentTime)
        pfl.gain.setValueAtTime(1, ctx.currentTime)
      }
    }
    saveSplices()
    release(current, completed)
    current = null
    for (const take of fading) release(take)
  }

  function finishAt(take, when, callback) {
    if (!take.clock) {
      const clock = ctx.createConstantSource() // A silent marker on the same audio clock as the faders.
      clock.offset.value = 0
      clock.connect(take.buses[0])
      clock.start()
      take.clock = clock
    }
    take.clock.onended = callback
    take.clock.stop(when)
  }

  function fadeUntil(take, when, edge) {
    const end = when + edge
    if (take.released || take.stopAt <= end) return
    // Mirror the incoming six-millisecond edge while the current pitch keeps playing.
    const level = take.fadeAt != null && when >= take.fadeAt
      ? take.fadeLevel * Math.max(0, (take.stopAt - when) / (take.stopAt - take.fadeAt))
      : Math.max(0, Math.min(1, (when - take.playAt) / take.edge, (take.end - when) / take.edge))
    for (const {gain} of take.buses) {
      gain.cancelScheduledValues(when)
      // Anchor the edge here; a ramp from the last attack would cut the sustain immediately.
      gain.linearRampToValueAtTime(level, when)
      gain.linearRampToValueAtTime(0, end)
    }
    take.fadeAt = when
    take.fadeLevel = level
    take.stopAt = end
    fading.add(take)
    finishAt(take, end, () => release(take))
    for (const {record} of Object.values(take.channels)) {
      if (record.users === 1) record.source.stop(end)
    }
  }

  // A deliberate stop can finish its headphone edge. A lost route still disconnects at once.
  function stopListening(keepPhones = false) {
    const now = ctx.currentTime
    discardMeasurement()
    saveSplices()
    if (current) {
      if (now < current.playAt || now >= current.end) release(current)
      else fadeUntil(current, now, edgeSeconds)
      current = null
    }
    for (const take of fading) fadeUntil(take, now, edgeSeconds)
    if (!keepPhones) fadePfl(1, now + edgeSeconds)
  }

  function applyMix({eq, level}, next, previous) {
    const now = ctx.currentTime
    if (next.filter !== previous?.filter) applyFilter(eq, next.filter, now, !!previous)
    if (next.tone !== previous?.tone) applyTone(eq, next.tone, now, !!previous)
    if (next.level !== previous?.level) setMixParam(level.gain, next.level, now, !!previous)
  }

  function speedChanged(before, next) {
    return before.rate !== next.rate || before.vinyl !== next.vinyl
  }

  function play(plan, kind, pan, skip = 0, observe, keepPhones = false) {
    if (current) stopListening(true)
    else if (!fading.size) stop(false, true)
    return schedule(plan, kind, pan, skip, observe, keepPhones, null)
  }

  function heardPosition(take, side, time) {
    const channel = take?.channels[side]
    if (!channel || time < channel.at) return null
    return channel.offset + (time - channel.at) * take.plan.mix[side].rate
  }

  function editedTime(previous, plan, kind, at) {
    if (at < previous.change) {
      return (heardPosition(previous, "out", at) - plan.outStart) / plan.mix.out.rate
    }
    // Keep the faders at the fraction already heard. After the overlap, only
    // the incoming deck remains, even if the new pitch made the blend longer.
    const elapsed = at - previous.change
    const before = previous.overlap
    const after = rehearsalOverlap(plan, kind)
    if (elapsed >= before) return plan.lead + after + (elapsed - before)
    return plan.lead + after * elapsed / before
  }

  function schedule(plan, kind, pan, skip, observe, keepPhones, previous, retryLead = null) {
    try {
      // Both sources and their automation must reach the render thread before their shared start.
      const setupStart = ctx.currentTime
      const playAt = setupStart + (retryLead ?? startLead)
      const handoff = previous ? Math.max(playAt, previous.playAt) : playAt
      const from = previous ? editedTime(previous, plan, kind, handoff) : Math.max(0, skip)
      if (from >= plan.duration || (kind === "bass_swap" && !plan.fullBlend)) {
        release(previous)
        stop()
        return Promise.resolve(false)
      }
      const start = playAt - from
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
      const edge = Math.min(edgeSeconds, (finish - playAt) / 3)
      const buses = oneEar ? [level, monitor] : [level]
      for (const bus of buses) {
        bus.gain.setValueAtTime(0, setupStart) // A retained record already carries signal during preparation.
        bus.gain.setValueAtTime(0, playAt)
        bus.gain.linearRampToValueAtTime(1, playAt + edge)
        bus.gain.setValueAtTime(1, finish - edge)
        bus.gain.linearRampToValueAtTime(0, finish)
      }
      monitor.connect(output)
      const ended = new Promise(resolve => {
        current = {start, change, overlap: fade, from, playAt, end: finish, edge, buses, plan, kind, channels: {}, nodes: [...buses, output], finish: resolve}
      })
      const sample = 1 / ctx.sampleRate
      const add = (side, buffer, at, end) => {
        if (end <= at) return null
        const mix = plan.mix[side]
        const old = previous?.channels[side]?.record
        const offset = heardPosition(previous, side, handoff) ?? Math.max(0, recordTime(plan, side, at - start))
        // Reuse the original filter history and grains only while their audio covers the new clock.
        const audioEnd = side === "into" ? at + Math.max(0, buffer.duration - offset) / mix.rate : end
        const keep = old && old.buffer === buffer && !speedChanged(previous.plan.mix[side], mix) && old.at <= at + sample &&
          Math.abs(old.offset + (at - old.at) * mix.rate - offset) <= sample * mix.rate &&
          Math.min(end, audioEnd) <= old.end + sample
        let record = old
        if (!keep) {
          const remember = side === "out" && kind !== "cut" && from <= plan.lead
          const source = createRecordSource(ctx, buffer, mix, remember ? plan.exit : undefined)
          const eq = createEq(ctx), level = ctx.createGain()
          source.connect(eq.hpf)
          eq.toneTreble.connect(level)
          if (kind === "bass_swap") scheduleRehearsalBass(eq.bass.gain, side, change, fade, at)
          record = {source, eq, level, buffer, at, offset, end: audioEnd, users: 0}
          applyMix(record, mix)
        }
        const fader = ctx.createGain()
        record.level.connect(fader)
        record.users++
        current.channels[side] = {record, fader, at, offset}
        fader.connect(level)
        const gain = rehearsalGains(plan, kind, at - start)[side === "out" ? 0 : 1]
        fader.gain.setValueAtTime(gain, at)
        if (change + fade > at) {
          scheduleBlend(fader.gain, kind === "blend" && plan.blendCurve, side === "out" ? 0 : 1, change, fade, at)
        }
        current.nodes.push(fader)
        if (oneEar) {
          const fold = connectHeadphoneFold(ctx, fader, monitor, buffer, at, offset, end - at, mix.rate)
          current.nodes.push(...fold)
        }
        if (!keep) record.source.start(at, offset, (audioEnd - at) * mix.rate)
        return record.source
      }
      const outgoing = add("out", plan.outgoing, playAt, change + fade)
      const last = add("into", plan.incoming, Math.max(playAt, change), finish)
      if (ctx.currentTime + guard > playAt) {
        // Nothing was routed. Retry a slow setup once with its measured cost in reserve.
        if (retryLead !== null) throw new Error("Headphone playback missed its scheduled start")
        release(current)
        current = null
        return schedule(plan, kind, pan, skip, observe, keepPhones, previous, 2 * (ctx.currentTime - setupStart) + 3 * guard)
      }
      if (previous) {
        const bassMoved = kind === "bass_swap" && (Math.abs(previous.change - change) > sample || Math.abs(previous.overlap - fade) > sample)
        for (const [side, {record, at}] of Object.entries(current.channels)) {
          if (record.users < 2) continue
          applyMix(record, plan.mix[side], previous.plan.mix[side])
          if (bassMoved) scheduleRehearsalBass(record.eq.bass.gain, side, change, fade, at, (at - previous.change) / previous.overlap)
        }
        for (const take of fading) fadeUntil(take, playAt, edge)
        fadeUntil(previous, playAt, edge)
      }
      output.connect(phones)
      fadePfl(0, Math.min(playAt, ctx.currentTime + edgeSeconds))
      // A missing meter must never interrupt the audio already scheduled.
      if (observe) {
        try { cancelMeasurement = observe(level, {start, change, end: finish, overlap: fade, kind}) }
        catch { cancelMeasurement = null }
      }
      const take = current
      last.onended = () => { if (current === take) stop(true, keepPhones) }
      if (take.channels.into.record.end > finish + sample) finishAt(take, finish, last.onended)
      current.outSource = outgoing
      return ended
    } catch (error) {
      release(previous)
      stop()
      throw error
    }
  }

  function elapsed() {
    return current ? Math.max(0, current.from, ctx.currentTime - current.start) : null
  }

  function edit(plan, kind, pan) {
    discardMeasurement()
    if (!current) return
    const before = current.plan
    const outChanged = speedChanged(before.mix.out, plan.mix.out)
    const handoff = Math.max(ctx.currentTime + startLead, current.playAt)
    const stillMixing = handoff < current.change + current.overlap
    const curveChanged = kind === "blend" && before.blendCurve !== plan.blendCurve
    if (speedChanged(before.mix.into, plan.mix.into) || (stillMixing && (outChanged || curveChanged))) {
      const previous = current
      saveSplices()
      current = null
      schedule(plan, kind, pan, 0, null, false, previous)
    } else {
      if (outChanged) {
        saveSplices()
        current.outSource = null // The revised outgoing grains were never heard.
      }
      for (const [side, {record}] of Object.entries(current.channels)) applyMix(record, plan.mix[side], before.mix[side])
      current.plan = plan
    }
  }

  return {play, edit, stop, stopListening, splices, elapsed}
}
