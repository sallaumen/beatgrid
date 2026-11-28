import assert from "node:assert/strict"
import test from "node:test"
import {createRehearsal, planRehearsal, recordTime, rehearsalBassDb, rehearsalBassWindow, rehearsalGains, scheduleRehearsalBass} from "../../assets/js/dj/rehearsal.js"

test("the two choices compare the same entry and fit both real audio files", () => {
  const plan = planRehearsal({duration: 14}, {duration: 8}, 12, 5, 120)
  assert.equal(plan.outStart, 9)
  assert.equal(plan.inStart, 5)
  assert.equal(plan.lead, 3)
  assert.equal(plan.blend, 2)
  assert.equal(plan.duration, 6)
  assert.deepEqual(rehearsalGains(plan, "cut", 3.5), [0, 1])
  assert.deepEqual(rehearsalGains(plan, "blend", 3.5), [0.75, 0.25])
})

test("short files, an opening cue at zero and unknown BPM produce a bounded preview", () => {
  const plan = planRehearsal({duration: 1}, {duration: 0.5}, 0, 0, null)
  assert.equal(plan.lead, 0)
  assert.equal(plan.blend, 0.5)
  assert.equal(plan.duration, 0.5)
  assert.equal(planRehearsal({duration: 1}, {duration: 1}, 0, 1, 120), null)
})

test("a fractional BPM fits a full four-beat fallback, but a missing audio frame does not", () => {
  const duration = 36, bpm = 105.73, fourBeats = 240 / bpm
  const track = {duration}, frame = 1 / 96000
  const mix = {out: {rate: 1.08}, into: {rate: .92}}
  for (const speeds of [undefined, mix]) {
    assert.equal(planRehearsal(track, track, null, 0, bpm, speeds).fullBlend, true)
    assert.equal(planRehearsal(track, track, duration - fourBeats + frame, 0, bpm, speeds).fullBlend, false)
    const requiredIncoming = fourBeats * (speeds?.into.rate ?? 1) / (speeds?.out.rate ?? 1)
    assert.equal(planRehearsal(track, track, null, duration - requiredIncoming + frame, bpm, speeds).fullBlend, false)
  }
})

function rehearsalFixture() {
  const sources = [], splitters = [], routed = []
  const preparationDelays = [], targets = [], clocks = []
  const param = () => ({value: 1, points: [], setValueAtTime(v, t) { this.value = v; this.points.push([v, t]) }, linearRampToValueAtTime() {},
    cancelScheduledValues() {}, setTargetAtTime(value) { targets.push({param: this, value}) }})
  const node = () => ({
    connections: [],
    connect(next, output = 0) { this.connections.push({next, output}) },
    disconnect(target) { this.connections = target ? this.connections.filter(edge => edge.next !== target) : [] },
    frequency: param(), gain: param()
  })
  const ctx = {
    createBuffer(channels, frames, sampleRate) {
      const samples = Array.from({length: channels}, () => new Float32Array(frames))
      return {length: frames, sampleRate, numberOfChannels: channels, getChannelData: i => samples[i]}
    },
    currentTime: 10, sampleRate: 48000,
    createStereoPanner: () => ({...node(), pan: {value: 0}, connect(dest) {
      this.connections.push({next: dest})
      routed.push(ctx.currentTime)
    }}),
    createGain: node, createBiquadFilter: node,
    createConstantSource() {
      const clock = {...node(), offset: param(), start() {}, stop(when) { this.stopAt = when }}
      clocks.push(clock)
      return clock
    },
    createChannelSplitter() {
      const splitter = node()
      splitters.push(splitter)
      return splitter
    },
    createBufferSource() {
      const source = {...node(), playbackRate: param(), start(...args) {
        this.args = args
        if (args[1] === 9) ctx.currentTime += preparationDelays.shift() ?? 0
      }, stop(when) { this.stopped = true; this.stopAt = when }}
      sources.push(source)
      return source
    }
  }
  const phones = node(), pfl = node()
  pfl.gain.linearRampToValueAtTime = function(value) { this.value = value }
  const preview = createRehearsal(ctx, phones, pfl)
  function track(duration, polarity) {
    const left = new Float32Array(duration * 1000).fill(0.5)
    const right = new Float32Array(duration * 1000).fill(polarity * 0.5)
    return {duration, length: left.length, sampleRate: 1000, numberOfChannels: 2, getChannelData: ch => [left, right][ch]}
  }
  const plan = planRehearsal(track(14, 1), track(8, -1), 12, 5, 120)
  return {preview, plan, ctx, phones, pfl, sources, splitters, routed, preparationDelays, targets, clocks}
}

test("the live cue fades before an audition and returns smoothly when the DJ stops listening", async () => {
  const {preview, plan, ctx, pfl, sources, clocks} = rehearsalFixture()
  const ramps = []
  pfl.gain.linearRampToValueAtTime = function(value, time) { this.value = value; ramps.push({value, time}) }
  let start, envelope
  const ended = preview.play(plan, "cut", 0, 0, (tap, times) => { envelope = tap.gain; start = times.start })
  const privateEdge = []
  envelope.cancelAndHoldAtTime = () => {}
  envelope.linearRampToValueAtTime = (value, time) => privateEdge.push({value, time})
  assert.equal(ramps.at(-1)?.value, 0)
  assert.ok(ramps.at(-1).time > ctx.currentTime && ramps.at(-1).time <= start)
  ctx.currentTime = start + .2
  preview.stopListening()
  assert.equal(preview.elapsed(), null)
  assert.equal(ramps.at(-1).value, 1)
  assert.deepEqual(privateEdge, [{value: 1, time: ctx.currentTime}, {value: 0, time: ramps.at(-1).time}])
  assert.equal(ramps.at(-1).time, sources.at(-1).stopAt)
  assert.ok(sources.at(-1).stopAt > ctx.currentTime)
  assert.equal(clocks.at(-1).stopAt, sources.at(-1).stopAt)
  clocks.at(-1).onended()
  assert.equal(await ended, false)
  assert.ok(sources.every(s => !s.connections.length))
})

test("losing the output during a headphone fade releases every private source immediately", async () => {
  const {preview, plan, ctx, sources} = rehearsalFixture()
  const take = preview.play(plan, "blend", 0)
  ctx.currentTime += .4
  preview.stopListening()
  assert.ok(sources.at(-1).stopAt > ctx.currentTime)
  preview.stop()
  assert.equal(await take, false)
  assert.ok(sources.every(source => source.stopped && source.stopAt === undefined && !source.connections.length))
})

test("auditions schedule independent sources only into phones and restore PFL on stop or completion", async () => {
  const {preview, plan, ctx, phones, pfl, sources, splitters} = rehearsalFixture()
  let canceled = 0, stereoTap, clock
  const observe = (tap, times) => {
    stereoTap = tap
    clock = times
    return () => { canceled++ }
  }
  const interrupted = preview.play(plan, "blend", -1, 0, observe)
  assert.ok(clock.start > ctx.currentTime)
  assert.equal(clock.change, clock.start + 3)
  assert.equal(clock.end, clock.start + 6)
  assert.equal(stereoTap.connections.length, 0)
  const [a, b] = sources
  assert.equal(a.buffer, plan.outgoing)
  assert.equal(b.buffer, plan.incoming)
  assert.deepEqual(a.args, [clock.start, 9, 5])
  assert.deepEqual(b.args.slice(0, 2), [clock.change, 5])
  assert.ok(Math.abs(b.args[2] - 3) < 1 / ctx.sampleRate)
  for (const [index, source] of [a, b].entries()) {
    let fader = source
    while (fader.connections.length === 1) fader = fader.connections[0].next
    assert.deepEqual(fader.connections.map(edge => edge.next), [stereoTap, splitters[index]])
    const [left, right] = splitters[index].connections
    assert.deepEqual([left.output, right.output], [0, 1])
    assert.deepEqual([left.next.gain.value, right.next.gain.value], [0.5, index === 0 ? 0.5 : -0.5])
    const monitor = left.next.connections[0].next
    assert.equal(right.next.connections[0].next, monitor)
    assert.equal(monitor.channelCount, 1)
    const panner = monitor.connections[0].next
    assert.equal(panner.pan.value, -1)
    assert.equal(panner.connections[0].next, phones)
  }
  assert.equal(pfl.gain.value, 0)
  const staleEnd = b.onended
  const completed = preview.play(plan, "cut", 1, 0, observe)
  assert.equal(await interrupted, false)
  assert.equal(canceled, 1)
  assert.ok(a.stopped && b.stopped)
  staleEnd()
  assert.equal(preview.elapsed(), 0)
  sources.at(-1).onended()
  assert.equal(await completed, true)
  assert.equal(pfl.gain.value, 1)
  assert.equal(preview.elapsed(), null)
  assert.ok(sources.every(s => s.stopped && !s.connections.length))
  assert.equal(canceled, 1, "natural completion lets the last meter window arrive")
  preview.stop()
  assert.equal(canceled, 2)
  const compared = preview.play(plan, "cut", 1, 0, observe, true)
  sources.at(-1).onended()
  assert.equal(await compared, true)
  assert.equal(pfl.gain.value, 0, "keep PFL private while the first reading arrives")
  preview.stop()
  assert.equal(pfl.gain.value, 1, "stopping between the auditions restores the live cue")

  const splittersBeforeStereo = splitters.length
  preview.play(plan, "cut", 0, 0, () => { throw new Error("observer unavailable") })
  assert.equal(splitters.length, splittersBeforeStereo)
  assert.equal(preview.elapsed(), 0)
  preview.stop()

  const shifted = planRehearsal(plan.outgoing, plan.incoming, plan.exit, plan.inStart, 120,
    {...plan.mix, out: {...plan.mix.out, rate: 1.055}})
  void preview.play(shifted, "blend", 0, shifted.lead - .2)
  ctx.currentTime += .1
  preview.stop()
  assert.equal(preview.splices(shifted, "blend"), undefined, "a canceled cue has not been heard")
  void preview.play(shifted, "blend", 0, shifted.lead - .2)
  ctx.currentTime += .25
  const heard = preview.splices(shifted, "blend")
  assert.ok(heard.prior.length > 0 && heard.prior.length <= 8)
  assert.equal(preview.splices(shifted, "bass_swap"), undefined)
  preview.stop()
  assert.deepEqual(preview.splices(shifted, "blend"), heard)
  const revised = {...shifted, mix: {...shifted.mix, out: {...shifted.mix.out, rate: .96}}}
  void preview.play(revised, "blend", 0, revised.lead - .2)
  assert.equal(preview.splices(revised, "blend"), undefined)
  ctx.currentTime += .25
  assert.equal(preview.splices(revised, "blend").rate, .96)
  assert.deepEqual(preview.splices(shifted, "blend"), heard, "a second take cannot rewrite the first")
  preview.stop()
})

test("a slow setup retimes both sources before routing or measuring the take", async () => {
  const {preview, plan, pfl, sources, routed, preparationDelays} = rehearsalFixture()
  const measurements = []
  preparationDelays.push(.04, .04)
  const take = preview.play(plan, "blend", 0, 0, (_tap, times) => { measurements.push(times) })
  assert.equal(measurements.length, 1)
  assert.equal(routed.length, 1)
  const [clock] = measurements
  assert.ok(clock.start > routed[0])
  assert.equal(preview.elapsed(), 0)
  const [staleOut, staleIn, freshOut, freshIn] = sources
  assert.ok(staleOut.stopped && staleIn.stopped)
  assert.equal(freshOut.args[0], clock.start)
  assert.equal(freshIn.args[0], clock.change)
  assert.equal(freshOut.args[1], 9)
  assert.equal(freshIn.args[1], 5)
  preview.stop()
  assert.equal(await take, false)
  assert.equal(pfl.gain.value, 1)
})

test("two missed starts leave no audition or measurement and return private cue control", () => {
  const {preview, plan, pfl, sources, routed, preparationDelays} = rehearsalFixture()
  preparationDelays.push(.04, .2)
  let measured = false
  assert.throws(() => preview.play(plan, "blend", 0, 0, () => { measured = true }), /scheduled start/)
  assert.equal(measured, false)
  assert.equal(routed.length, 0)
  assert.ok(sources.every(source => source.stopped))
  assert.equal(preview.elapsed(), null)
  assert.equal(pfl.gain.value, 1)
})

test("resuming a private take keeps its record position while the start is queued", () => {
  const {preview, plan, ctx} = rehearsalFixture()
  let origin
  void preview.play(plan, "cut", 0, 2.5, (_tap, times) => { origin = times.start })
  assert.equal(preview.elapsed(), 2.5)
  ctx.currentTime = origin + 2.75
  assert.equal(preview.elapsed(), 2.75)
  preview.stop()
})

test("moving the opposite deck's filter leaves a running channel gain ramp alone", () => {
  const {preview, plan, ctx, targets} = rehearsalFixture()
  void preview.play(plan, "blend", 0)
  ctx.currentTime += plan.lead + .25
  const lower = {...plan, mix: {...plan.mix, out: {...plan.mix.out, level: .4}}}
  preview.edit(lower, "blend", 0)
  const gain = targets.find(change => change.value === .4).param
  targets.length = 0
  ctx.currentTime += .01
  preview.edit({...lower, mix: {...lower.mix, into: {...lower.mix.into, filter: .5}}}, "blend", 0)
  assert.ok(targets.some(change => change.value > 10), "the incoming filter moved")
  assert.ok(!targets.some(change => change.param === gain), "the outgoing gain continued its first ramp")
  preview.stop()
})

test("an edit too late for the outgoing fade leaves the incoming record in flight", () => {
  for (const [kind, afterFade] of [["cut", -.004], ["blend", .08], ["bass_swap", -.004]]) {
    const {preview, plan, ctx, sources} = rehearsalFixture()
    const settings = (out, into) => planRehearsal(plan.outgoing, plan.incoming, plan.exit, plan.inStart, 120,
      {out: {...plan.mix.out, ...out}, into: {...plan.mix.into, ...into}})
    const original = settings({rate: 1.055})
    let clock
    void preview.play(original, kind, 0, original.lead - .1, (_tap, times) => { clock = times })
    ctx.currentTime = clock.change + clock.overlap + afterFade
    const before = sources.length, slower = {rate: .80, vinyl: true}
    const revised = settings(slower)
    preview.edit(revised, kind, 0)
    assert.equal(sources.length, before, "the incoming audio kept its current voice")
    if (kind !== "cut") {
      assert.ok(preview.splices(original, kind), "the previous audition kept its pitch memory")
      assert.equal(preview.splices(revised, kind), undefined, "the new outgoing pitch was not heard")
    }
    preview.edit(settings(slower, {rate: .99, vinyl: true}), kind, 0)
    assert.deepEqual(sources.slice(before).flatMap(source => source.buffer ? [source.buffer] : []), [plan.incoming],
      "editing the audible record did not bring the faded record back")
    preview.stop()
  }
})

test("editing a single transport keeps the opposite record and its filter running", async () => {
  for (const [kind, time, side] of [["cut", -.55, "into"], ["blend", .6, "into"], ["bass_swap", .45, "out"]]) {
    const {preview, plan, ctx, sources} = rehearsalFixture()
    let clock
    const take = preview.play(plan, kind, 0, 0, (_tap, timing) => { clock = timing })
    const [out, into] = sources, kept = side === "out" ? into : out
    const initialFilter = kept.connections[0].next
    ctx.currentTime = clock.change + time
    // Changing the incoming pitch (or the outgoing vinyl switch) preserves the other record's clock.
    const mix = {...plan.mix, [side]: {...plan.mix[side], rate: side === "into" ? 1.04 : 1, vinyl: true}}
    const revision = planRehearsal(plan.outgoing, plan.incoming, plan.exit, plan.inStart, 120, mix)
    preview.edit(revision, kind, 0)
    assert.equal(kept.stopped, undefined, "the opposite record was never stopped")
    assert.equal(kept.connections[0].next, initialFilter)
    let level = initialFilter
    while (level.connections.length === 1) level = level.connections[0].next
    const replacementBus = level.connections.at(-1).next.connections[0].next
    assert.deepEqual(replacementBus.gain.points[0], [0, ctx.currentTime], "a live voice was muted until its new edge")
    assert.equal(sources.filter(source => source.buffer).length, 3, "only the edited transport was prepared")
    preview.stop()
    assert.equal(await take, false)
    assert.ok(sources.every(source => source.stopped && !source.connections.length))
  }
})

test("a retained voice keeps its heard grains and stale clocks cannot finish a different cue", async () => {
  const {preview, plan, ctx, clocks, pfl, sources} = rehearsalFixture()
  const mix = {...plan.mix, out: {...plan.mix.out, rate: .92}}
  const pair = (entry, settings) => planRehearsal(plan.outgoing, plan.incoming, plan.exit, entry, 120, settings)
  const first = pair(.4, mix)
  let timing
  const ended = preview.play(first, "blend", 0, first.lead - .2, (_tap, value) => { timing = value })
  const stale = clocks.at(-1).onended
  ctx.currentTime = timing.change + .07
  const grains = preview.splices(first, "blend")
  assert.ok(grains?.prior.length)
  const changed = pair(.4, {...mix, into: {...mix.into, rate: 1.02, vinyl: true}})
  preview.edit(changed, "blend", 0)
  assert.deepEqual(preview.splices(changed, "blend"), grains)
  preview.stopListening(true)
  const next = pair(1.2, mix)
  const done = preview.play(next, "cut", -1, next.lead - .1)
  stale()
  assert.notEqual(preview.elapsed(), null)
  assert.equal(preview.splices(next, "cut"), undefined)
  assert.deepEqual(preview.splices(first, "blend"), grains)
  const scheduled = clocks.at(-1)
  assert.ok(scheduled.stopAt < ctx.currentTime + plan.incoming.duration, "the take ends before physical EOF")
  ctx.currentTime = scheduled.stopAt
  scheduled.onended()
  assert.equal(await done, true)
  assert.equal(await ended, false)
  assert.equal(preview.elapsed(), null)
  assert.equal(pfl.gain.value, 1)
  assert.ok(clocks.every(clock => !clock.connections.length))
  assert.ok(sources.every(source => source.stopped))
  for (const grain of sources) grain.onended?.()
  assert.ok(sources.every(source => !source.connections.length))
})

test("rapid pitch edits keep the playing source until each replacement reaches the same record position", () => {
  const {preview, plan, ctx, pfl, sources} = rehearsalFixture()
  let originalStart
  void preview.play(plan, "blend", 0, 0, (_tap, times) => { originalStart = times.start })
  ctx.currentTime += .7
  const revised = rate => ({...plan, mix: {...plan.mix, out: {...plan.mix.out, rate, vinyl: true}}})
  preview.edit(revised(1.004), "blend", 0)
  const first = sources[2]
  assert.ok(first.args[0] > ctx.currentTime)
  assert.ok(sources[0].stopAt >= first.args[0] + .0059)
  assert.ok(Math.abs(first.args[1] - recordTime(plan, "out", first.args[0] - originalStart)) < 1e-8)
  ctx.currentTime += .008
  preview.edit(revised(.996), "blend", 0)
  const second = sources[4]
  assert.ok(second.args[0] > first.args[0])
  assert.ok(first.stopAt >= second.args[0] + .0059)
  assert.ok(Math.abs(second.args[1] - first.args[1] - (second.args[0] - first.args[0]) * 1.004) < 1e-8)
  assert.equal(pfl.gain.value, 0)
  preview.stop()
  assert.ok(sources.every(source => source.stopped && source.stopAt === undefined && !source.connections.length))
  assert.equal(pfl.gain.value, 1)
})

test("failed replacement preparation restores private cue and frees the take that was still playing", async () => {
  const {preview, plan, ctx, pfl, sources} = rehearsalFixture()
  const take = preview.play(plan, "blend", 0)
  ctx.currentTime += .2
  ctx.createStereoPanner = () => { throw new Error("cannot allocate a panner") }
  assert.throws(() => preview.edit({...plan, mix: {...plan.mix, out: {...plan.mix.out, rate: 1.01}}}, "blend", 0), /panner/)
  assert.equal(pfl.gain.value, 1)
  assert.equal(preview.elapsed(), null)
  assert.ok(sources.every(source => source.stopped && !source.connections.length))
  assert.equal(await take, false)
})

test("source cues, wave positions and the four-beat blend account for both effective tempos", () => {
  const plan = planRehearsal({duration: 60}, {duration: 10}, 45, 8.75, 100,
    {out: {rate: 1.2}, into: {rate: 0.8}})
  assert.equal(plan.exit, 45)
  assert.equal(recordTime(plan, "out", 3), 45)
  assert.equal(recordTime(plan, "into", 3), 8.75)
  assert.equal(plan.blend, 1.25 / 0.8)
  assert.equal(recordTime(plan, "into", plan.duration), 10)
})

test("the waveform preserves energy through a measured blend, while a cut stays linear", () => {
  const plan = {...planRehearsal({duration: 14}, {duration: 8}, 12, 5, 120),
    blendCurve: {correlation: 0, outPeak: 0.25, inPeak: 0.35}}
  const [out, into] = rehearsalGains(plan, "blend", plan.lead + plan.blend/2)
  assert.ok(Math.abs(out ** 2 + into ** 2 - 1) < 0.001)
  assert.deepEqual(rehearsalGains(plan, "cut", plan.lead + 0.5), [0, 1])
})

test("a resumed blend schedules the same amplitude drawn at every sample point", async () => {
  const {scheduleBlend} = await import("../../assets/js/dj/blend_curve.js")
  const plan = {...planRehearsal({duration: 14}, {duration: 8}, 12, 5, 120),
    blendCurve: {correlation: .13, outPeak: .4, inPeak: .24}}
  for (const side of [0, 1]) {
    const points = [], param = {setValueAtTime: (v,t) => points.push([v,t]), linearRampToValueAtTime: (v,t) => points.push([v,t])}
    const at = plan.lead + .373
    scheduleBlend(param, plan.blendCurve, side, plan.lead, plan.blend, at)
    assert.equal(points[0][1], at)
    for (let i = 1; i < points.length; i++) {
      const [v1,t1] = points[i-1], [v2,t2] = points[i]
      assert.ok(Math.abs((v1+v2)/2 - rehearsalGains(plan, "blend", (t1+t2)/2)[side]) < 1e-12)
    }
    assert.equal(points.at(-1)[0], side)
  }
})

test("the four-beat bass exchange opens the incoming shelf on beat three before removing the old bass", () => {
  const plan = planRehearsal({duration: 20}, {duration: 20}, 5, 0, 120)
  assert.deepEqual(rehearsalBassWindow(plan), {start: 3.75, swap: 4, end: 4.25})
  assert.deepEqual(rehearsalGains({...plan, blendCurve: {outPeak: 0.1, inPeak: 0.1, correlation: 0}}, "bass_swap", 4), [.5, .5])
  for (const [side, expected] of [["out", [0, 0, 0, -4, -8]], ["into", [-8, -4, 0, 0, 0]]]) {
    const points = [.375, .4375, .5, .5625, .625]
    for (const [i, p] of points.entries()) assert.ok(Math.abs(rehearsalBassDb(side, p) - expected[i]) < 1e-9)
    // Seeking partway through the preview must pick up the same automated curve.
    const events = []
    const param = {cancelScheduledValues() {}, setValueAtTime(v, t) { events.push([v,t]) },
      linearRampToValueAtTime(v,t) { events.push([v,t]) }}
    scheduleRehearsalBass(param, side, 10, 2, 10.875)
    assert.equal(events[0][1], 10.875)
    for (const [v,t] of events) assert.ok(Math.abs(v - rehearsalBassDb(side, (t-10)/2)) < 1e-9)
    assert.ok(events.slice(1).every((x,i) => x[1] > events[i][1]))
  }
})

test("changing either pitch during the overlap keeps both records and the faders at their heard positions", () => {
  for (const progress of [.35, .71]) {
    const {preview, plan, ctx, sources, pfl} = rehearsalFixture()
    let clock
    preview.play(plan, "blend", 0, 0, (_tap, timing) => { clock = timing })
    let before = plan, pair = sources.slice(), fadeAt = clock.change
    ctx.currentTime = fadeAt + progress * plan.blend
    for (const [side, rate, wait] of [["out", 1.03, .004], ["into", .92, .008], ["out", .97, .013], ["into", 1.08, .007]]) {
      const mix = {...before.mix, [side]: {...before.mix[side], rate, vinyl: true}}
      const next = planRehearsal(plan.outgoing, plan.incoming, plan.exit, plan.inStart, 120, mix)
      preview.edit(next, "blend", 0)
      const replacements = [plan.outgoing, plan.incoming].map(track => sources.findLast(s => s.buffer === track))
      const at = Math.max(...replacements.map(source => source.args[0]))
      const phase = (at - fadeAt) / before.blend
      for (const [i, deck] of ["out", "into"].entries()) {
        const [started, record] = pair[i].args
        const [start, offset] = replacements[i].args
        assert.ok(Math.abs(offset + (at - start) * mix[deck].rate - (record + (at - started) * before.mix[deck].rate)) < 1e-8, deck)
      }
      assert.ok(Math.abs((preview.elapsed() - next.lead) / next.blend - phase) < 1e-8, "gain envelope")
      fadeAt = at - phase * next.blend
      before = next
      pair = replacements
      ctx.currentTime += wait
    }
    assert.equal(pfl.gain.value, 0)
    preview.stop()
  }
})

test("a slower edit retains audio before the new preview window and never revives a finished deck", () => {
  for (const elapsed of [.1, 5.1]) {
    const {preview, plan, ctx, sources} = rehearsalFixture()
    let start
    preview.play(plan, "blend", 0, 0, (_tap, timing) => { start = timing.start })
    ctx.currentTime = start + elapsed
    const next = planRehearsal(plan.outgoing, plan.incoming, plan.exit, plan.inStart, 120,
      {...plan.mix, out: {...plan.mix.out, rate: .8, vinyl: true}})
    preview.edit(next, "blend", 0)
    if (elapsed < 1) {
      const [at, offset] = sources[2].args
      assert.ok(Math.abs(offset - (plan.outStart + at - start)) < 1e-8)
      assert.equal(preview.elapsed(), 0)
      assert.ok(Math.abs(sources[3].args[0] - at - (plan.exit - offset) / .8) < 1e-8)
    } else {
      assert.equal(sources.length, 2, "the outgoing record stayed finished")
      assert.equal(sources[1].stopped, undefined, "the incoming record kept playing")
    }
    preview.stop()
  }
})

test("restarting the final audition releases the first take softly and keeps the live cue closed", async () => {
  const {preview, plan, ctx, pfl, sources, clocks} = rehearsalFixture()
  const cue = [], edge = []
  pfl.gain.linearRampToValueAtTime = value => cue.push(value)
  let envelope
  const first = preview.play(plan, "cut", 0, 0, tap => { envelope = tap.gain })
  const oldSource = sources.at(-1)
  ctx.currentTime += .6
  envelope.linearRampToValueAtTime = (level, time) => edge.push([level, time])
  const second = preview.play(plan, "cut", 0)
  assert.deepEqual(edge, [[1, ctx.currentTime], [0, ctx.currentTime + .006]])
  assert.deepEqual(cue, [0])
  assert.equal(oldSource.stopAt, ctx.currentTime + .006)
  assert.equal(sources.at(-2).args[1], plan.outStart)
  clocks.at(-1).onended()
  assert.equal(await first, false)
  sources.at(-1).onended()
  assert.equal(await second, true)
  assert.deepEqual(cue, [0, 1])
})
