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

test("auditions schedule independent sources only into phones and restore PFL on stop or completion", async () => {
  const sources = [], splitters = []
  const param = () => ({value: 1, setValueAtTime(v) { this.value = v }, linearRampToValueAtTime() {}, cancelScheduledValues() {}})
  const node = () => ({
    connections: [],
    connect(next, output = 0) { this.connections.push({next, output}) },
    disconnect() { this.connections.length = 0 },
    frequency: param(), gain: param()
  })
  const ctx = {
    currentTime: 10,
    createBuffer(channels, frames, sampleRate) {
      const samples = Array.from({length: channels}, () => new Float32Array(frames))
      return {length: frames, sampleRate, numberOfChannels: channels, getChannelData: i => samples[i]}
    },
    createStereoPanner: () => ({...node(), pan: {value: 0}}),
    createGain: node, createBiquadFilter: node,
    createChannelSplitter() {
      const splitter = node()
      splitters.push(splitter)
      return splitter
    },
    createBufferSource() {
      const source = {...node(), playbackRate: param(), start(...args) { this.args = args }, stop() { this.stopped = true }}
      sources.push(source)
      return source
    }
  }
  const phones = node(), pfl = node()
  const preview = createRehearsal(ctx, phones, pfl)
  function track(duration, polarity) {
    const left = new Float32Array(duration * 1000).fill(0.5)
    const right = new Float32Array(duration * 1000).fill(polarity * 0.5)
    return {duration, length: left.length, sampleRate: 1000, numberOfChannels: 2, getChannelData: ch => [left, right][ch]}
  }
  const plan = planRehearsal(track(14, 1), track(8, -1), 12, 5, 120)
  let canceled = 0, stereoTap, clock
  const observe = (tap, times) => {
    stereoTap = tap
    clock = times
    return () => { canceled++ }
  }
  const interrupted = preview.play(plan, "blend", -1, 0, observe)
  assert.equal(clock.change, 13)
  assert.equal(clock.end, 16)
  assert.equal(stereoTap.connections.length, 0)
  const [a, b] = sources
  assert.equal(a.buffer, plan.outgoing)
  assert.equal(b.buffer, plan.incoming)
  assert.deepEqual(a.args, [10, 9, 5])
  assert.deepEqual(b.args, [13, 5, 3])
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
