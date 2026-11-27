// Source positions are in record seconds. Both choices use the same two excerpts.
export function planRehearsal(outgoing, incoming, exit, entry, bpm) {
  const fourBeats = 240 / (bpm > 0 ? bpm : 120)
  const inStart = Math.max(0, entry ?? 0)
  const outPoint = exit != null && exit >= 0 && exit < outgoing.duration
    ? exit : Math.max(0, outgoing.duration - fourBeats)
  const blend = Math.min(fourBeats, outgoing.duration - outPoint, incoming.duration - inStart)
  if (!(blend > 0)) return null
  const lead = Math.min(3, outPoint)
  const duration = lead + Math.min(blend + 2, incoming.duration - inStart)
  return {outgoing, incoming, outStart: outPoint - lead, inStart, lead, blend, duration}
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

// This transport has no references to live media elements or the master output.
export function createRehearsal(ctx, phones, pfl) {
  let current = null

  function stop() {
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

  function play(plan, kind, pan) {
    stop()
    const now = ctx.currentTime
    const change = now + plan.lead
    const fade = rehearsalOverlap(plan, kind)
    const output = ctx.createStereoPanner()
    output.pan.value = pan
    const level = ctx.createGain()
    const finish = now + plan.duration
    const edge = Math.min(0.006, plan.duration / 3)
    level.gain.setValueAtTime(0, now)
    level.gain.linearRampToValueAtTime(1, now + edge)
    level.gain.setValueAtTime(1, finish - edge)
    level.gain.linearRampToValueAtTime(0, finish)
    level.connect(output)
    output.connect(phones)
    current = {start: now, sources: [], nodes: [level, output]}
    try {
      const add = (buffer, at, offset, seconds, a, b) => {
        const source = ctx.createBufferSource()
        const fader = ctx.createGain()
        source.buffer = buffer
        source.connect(fader)
        fader.connect(level)
        fader.gain.setValueAtTime(a, at)
        rampRehearsalGain(fader.gain, change, fade, a, b)
        current.nodes.push(source, fader)
        source.start(at, offset, seconds)
        current.sources.push(source)
        return source
      }
      pfl.gain.value = 0
      add(plan.outgoing, now, plan.outStart, plan.lead + fade, 1, 0)
      const last = add(plan.incoming, change, plan.inStart, plan.duration - plan.lead, 0, 1)
      last.onended = () => { if (current?.sources.includes(last)) stop() }
    } catch (error) {
      stop()
      throw error
    }
  }

  return {play, stop, elapsed: () => current ? ctx.currentTime - current.start : null}
}
