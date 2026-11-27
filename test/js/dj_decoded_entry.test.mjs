import assert from "node:assert/strict"
import test from "node:test"
import {recallSplice} from "../../assets/js/dj/record_source.js"
import {startDecodedEntry} from "../../assets/js/dj/decoded_entry.js"

function entry(t, offset = 1.25) {
  t.mock.timers.enable({apis: ["setInterval"]})
  const param = () => ({value: 1, cancelScheduledValues() {}, setValueAtTime(v) { this.value = v },
    linearRampToValueAtTime(v) { this.value = v }})
  const node = () => ({connect() {}, disconnect() {}, gain: param()})
  const source = {...node(), playbackRate: param(), start(...args) { this.started = args }, stop(at) { this.stopAt = at }}
  const ctx = {currentTime: 5, sampleRate: 8000, createGain: node, createBufferSource: () => source,
    createBuffer() { throw Error("buffer unavailable") }}
  const buffer = {duration: 10, length: 80_000, sampleRate: 8000, numberOfChannels: 1,
    getChannelData: () => new Float32Array(80_000)}
  const media = {currentTime: offset, duration: 10, playbackRate: 1, preservesPitch: true, readyState: 4}
  const gain = node(), released = []
  const bridge = startDecodedEntry(ctx, media, buffer, offset, node(), gain, end => released.push(end))
  return {ctx, media, source, gain: gain.gain, bridge, released, tick() { t.mock.timers.tick(25) }}
}

test("aligned media clocks cannot replace the rehearsed sound when a decoder starts late", t => {
  const {ctx, media, source, gain, bridge, released, tick} = entry(t)
  assert.deepEqual(source.started, [5, 1.25])
  for (let i = 0; i < 8; i++) {
    ctx.currentTime += 0.025
    // A reported position can advance through silence, then stall or run behind.
    if (i < 4) media.currentTime = bridge.position()
    tick()
    assert.equal(gain.value, 0)
    assert.equal(source.stopAt, undefined)
  }
  const atGesture = bridge.position()
  bridge.release(true)
  assert.equal(media.currentTime, atGesture)
  assert.equal(gain.value, 1)
  bridge.release(true)
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

test("a failed bend allocation returns the audible position to the loaded player", t => {
  const {ctx, bridge, media, gain, released} = entry(t)
  ctx.currentTime += .4
  const heard = bridge.position()
  assert.equal(bridge.nudge(1.08), false)
  assert.equal(media.currentTime, heard)
  assert.equal(gain.value, 1)
  assert.deepEqual(released, [false])
})

test("a failed pitch-locked recall leaves the previous recording playing at its original speed", t => {
  const {bridge, source, released, ctx, gain} = entry(t)
  ctx.currentTime += .375
  const heard = bridge.position()
  const file = {numberOfChannels: 1, sampleRate: 8000, length: 80_000, duration: 10,
    getChannelData: () => new Float32Array(80_000)}
  const saved = {rate: 1.05, first: 0, end: 32000, begin: 76, hop: 160, prior: [12160, 12320]}
  assert.throws(() => bridge.recall(file, heard, {rate: 1.05, vinyl: false}, recallSplice(saved, file, heard, 1.05)), /buffer unavailable/)
  assert.equal(source.stopAt, undefined)
  assert.equal(gain.value, 0)
  assert.equal(bridge.rate(), 1)
  ctx.currentTime += .25
  assert.equal(bridge.position(), heard + .25)
  assert.deepEqual(released, [])
})

test("a playing hot cue bridges both heads briefly and a stop can silence the retiring head", t => {
  const {ctx, media, gain, bridge, source} = entry(t)
  let newVoice
  const newGain = {gain: {value: 1, setValueAtTime() {}, linearRampToValueAtTime(value, at) { this.rampEnds = at }},
    connect() {}, disconnect() {}}
  ctx.createGain = () => newGain
  ctx.createBufferSource = () => (newVoice = {...source, start(...args) { this.started = args }})
  ctx.currentTime += .1
  assert.ok(bridge.seek(5.25))
  assert.equal(bridge.position(), 5.25)
  assert.equal(gain.value, 0)
  assert.equal(newVoice.started[1], 5.25)
  assert.ok(newVoice.started[0] >= ctx.currentTime + 256 / ctx.sampleRate)
  assert.ok(source.stopAt > newVoice.started[0] && source.stopAt <= newVoice.started[0] + .01)
  assert.equal(newGain.gain.rampEnds, source.stopAt)
  assert.equal(newGain.gain.value, 0, "even a sample before the scheduled ramp starts silently")
  bridge.release(true)
  assert.equal(media.currentTime, 5.25)
  assert.equal(source.onended, null)
  assert.equal(source.stopAt, undefined)
})

test("recalling a heard phase crossfades both heads and a stop silences both at once", t => {
  const {ctx, bridge, source, gain, released} = entry(t)
  const nodes = [], voices = []
  const output = ctx.createGain
  ctx.createGain = () => {
    const node = output()
    node.gain.linearRampToValueAtTime = (value, when) => { node.ramp = {value, when} }
    nodes.push(node)
    return node
  }
  ctx.createBuffer = (channels, length, sampleRate) => {
    ctx.currentTime += .006 // private splice reconstruction crosses an audio quantum
    const rows = Array.from({length: channels}, () => new Float32Array(length))
    return {length, sampleRate, numberOfChannels: channels, getChannelData: i => rows[i]}
  }
  ctx.createBufferSource = () => {
    const voice = {...source}
    voices.push(voice)
    return voice
  }
  const file = ctx.createBuffer(2, 80_000, 8000)
  file.duration = 10
  const out = {rate: 1.05, vinyl: false}
  const saved = {rate: 1.05, first: 0, end: 32000, begin: 76, hop: 160, prior: [12160, 12320]}
  ctx.currentTime += .375
  const at = ctx.currentTime
  const heard = bridge.position()
  bridge.recall(file, heard, out, recallSplice(saved, file, heard, out.rate))
  assert.ok(Math.abs(bridge.position() - heard - (ctx.currentTime - at) * out.rate) < 1 / 8000)
  assert.equal(bridge.rate(), out.rate)
  assert.equal(source.stopAt, ctx.currentTime + .004)
  assert.deepEqual(nodes[0].ramp, {value: 1, when: source.stopAt})
  assert.equal(gain.value, 0)
  bridge.release(true)
  assert.ok(voices.every(voice => voice.stopAt === undefined && voice.onended === null))
  assert.equal(source.stopAt, undefined)
  assert.deepEqual(released, [false])
})
