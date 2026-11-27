import assert from "node:assert/strict"
import test from "node:test"
import {createRehearsal, planRehearsal, recordTime, rehearsalGains} from "../../assets/js/dj/rehearsal.js"

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

test("auditions schedule independent sources only into phones and restore PFL on stop or completion", () => {
  const sources = []
  const param = () => ({value: 1, setValueAtTime(v) { this.value = v }, linearRampToValueAtTime() {}, cancelScheduledValues() {}})
  const node = () => ({
    connect(next) { this.next = next },
    disconnect() { this.next = null },
    frequency: param(), gain: param()
  })
  const ctx = {
    currentTime: 10,
    createStereoPanner: () => ({...node(), pan: {value: 0}}),
    createGain: node, createBiquadFilter: node,
    createBufferSource() {
      const source = {...node(), playbackRate: param(), start(...args) { this.args = args }, stop() { this.stopped = true }}
      sources.push(source)
      return source
    }
  }
  const phones = node(), pfl = node()
  const preview = createRehearsal(ctx, phones, pfl)
  const plan = planRehearsal({duration: 14}, {duration: 8}, 12, 5, 120)
  let canceled = 0
  const observe = (level, times) => {
    assert.equal(level.next.next, phones)
    assert.equal(times.change, 13)
    assert.equal(times.end, 16)
    return () => { canceled++ }
  }
  preview.play(plan, "blend", -1, 0, observe)
  const [a, b] = sources
  assert.equal(a.buffer, plan.outgoing)
  assert.equal(b.buffer, plan.incoming)
  assert.deepEqual(a.args, [10, 9, 5])
  assert.deepEqual(b.args, [13, 5, 3])
  for (const source of [a, b]) {
    let bus = source
    while (bus.next && !bus.pan) bus = bus.next
    assert.equal(bus.next, phones)
    assert.equal(bus.pan.value, -1)
  }
  assert.equal(pfl.gain.value, 0)
  const staleEnd = b.onended
  preview.play(plan, "cut", 1, 0, observe)
  assert.equal(canceled, 1)
  assert.ok(a.stopped && b.stopped)
  staleEnd()
  assert.equal(preview.elapsed(), 0)
  sources.at(-1).onended()
  assert.equal(pfl.gain.value, 1)
  assert.equal(preview.elapsed(), null)
  assert.ok(sources.every(s => s.stopped && !s.next))
  assert.equal(canceled, 1, "natural completion lets the last meter window arrive")
  preview.stop()
  assert.equal(canceled, 2)
  preview.play(plan, "cut", 0, 0, () => { throw new Error("observer unavailable") })
  assert.equal(preview.elapsed(), 0)
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
