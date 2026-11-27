import assert from "node:assert/strict"
import test from "node:test"
import {createRehearsal, planRehearsal, rehearsalGains} from "../../assets/js/dj/rehearsal.js"

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
  const node = () => ({
    connect(next) { this.next = next },
    disconnect() { this.next = null },
    gain: {value: 1, setValueAtTime() {}, linearRampToValueAtTime() {}}
  })
  const ctx = {
    currentTime: 10,
    createStereoPanner: () => ({...node(), pan: {value: 0}}),
    createGain: node,
    createBufferSource() {
      const source = {...node(), start(...args) { this.args = args }, stop() { this.stopped = true }}
      sources.push(source)
      return source
    }
  }
  const phones = node(), pfl = node()
  const preview = createRehearsal(ctx, phones, pfl)
  const plan = planRehearsal({duration: 14}, {duration: 8}, 12, 5, 120)
  preview.play(plan, "blend", -1)
  const [a, b] = sources
  assert.equal(a.buffer, plan.outgoing)
  assert.equal(b.buffer, plan.incoming)
  assert.deepEqual(a.args, [10, 9, 5])
  assert.deepEqual(b.args, [13, 5, 3])
  assert.equal(a.next.next.next.next, phones)
  assert.equal(b.next.next.next.next, phones)
  assert.equal(a.next.next.next.pan.value, -1)
  assert.equal(pfl.gain.value, 0)
  const staleEnd = b.onended
  preview.play(plan, "cut", 1)
  assert.ok(a.stopped && b.stopped)
  staleEnd()
  assert.equal(preview.elapsed(), 0)
  sources.at(-1).onended()
  assert.equal(pfl.gain.value, 1)
  assert.equal(preview.elapsed(), null)
  assert.ok(sources.every(s => s.stopped && !s.next))
})
