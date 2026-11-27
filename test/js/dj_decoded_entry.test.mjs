import assert from "node:assert/strict"
import test from "node:test"
import {startDecodedEntry} from "../../assets/js/dj/decoded_entry.js"

function entry(t, offset = 1.25) {
  t.mock.timers.enable({apis: ["setInterval"]})
  const param = () => ({value: 1, cancelScheduledValues() {}, setValueAtTime(v) { this.value = v },
    linearRampToValueAtTime(v) { this.value = v }})
  const node = () => ({connect() {}, disconnect() {}, gain: param()})
  const source = {...node(), playbackRate: param(), start(...args) { this.started = args }, stop(at) { this.stopAt = at }}
  const ctx = {currentTime: 5, createGain: node, createBufferSource: () => source}
  const media = {currentTime: offset, duration: 10, playbackRate: 1, readyState: 4}
  const gain = node(), released = []
  const bridge = startDecodedEntry(ctx, media, {duration: 10}, offset, node(), gain, end => released.push(end))
  return {ctx, media, source, gain: gain.gain, bridge, released, tick() { t.mock.timers.tick(25) }}
}

test("the exact cue supplies the missing media frames, then matched clocks return audio to the native deck", t => {
  const {ctx, media, source, gain, bridge, released, tick} = entry(t)
  assert.deepEqual(source.started, [5, 1.25])
  ctx.currentTime += 0.18
  tick()
  assert.equal(gain.value, 0)
  assert.ok(Math.abs(bridge.position() - 1.43) < 1e-7)
  for (let i = 0; i < 3; i++) {
    ctx.currentTime += 0.025
    media.currentTime = bridge.position()
    tick()
  }
  assert.equal(gain.value, 1)
  assert.ok(source.stopAt > ctx.currentTime)
  source.onended()
  assert.deepEqual(released, [false])
})

test("a very short cue ends once even if the native player never delivers its first frame", t => {
  const {media, ctx, source, released, bridge} = entry(t, 9.99)
  ctx.currentTime += 0.012
  source.onended()
  assert.equal(media.currentTime, 10)
  bridge.release(true)
  assert.deepEqual(released, [true])
})
