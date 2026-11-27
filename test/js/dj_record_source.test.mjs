import test from "node:test"
import assert from "node:assert/strict"
import {createRecordSource} from "../../assets/js/dj/record_source.js"

function renderLocked({sr = 48_000, rate, seconds, offset = 0, fill}) {
  const chunks = []
  const ctx = {currentTime: 0, createGain: () => ({connect() {}, disconnect() {}}),
    createBuffer(n, length) {
      const channels = Array.from({length: n}, () => new Float32Array(length))
      return {sampleRate: sr, duration: length / sr, length, numberOfChannels: n, getChannelData: i => channels[i]}
    }, createBufferSource() {
      return {playbackRate: {}, connect() {}, disconnect() {}, stop() {}, start(at) { chunks.push([at, this]) }}
    }}
  const input = ctx.createBuffer(2, Math.ceil((offset + seconds) * sr))
  fill(input.getChannelData(0), input.getChannelData(1))
  const source = createRecordSource(ctx, input, {rate, vinyl: false})
  const length = Math.round(sr * seconds / rate)
  const left = new Float32Array(length), right = new Float32Array(length)
  let ends = 0, written = 0
  source.onended = () => ends++
  source.start(0, offset, seconds)
  for (const [at, voice] of chunks) {
    assert.ok(Math.abs(at - written / sr) < .001)
    left.set(voice.buffer.getChannelData(0), written)
    right.set(voice.buffer.getChannelData(1), written)
    written += voice.buffer.length
    voice.onended()
  }
  assert.equal(written, length)
  assert.equal(ends, 1)
  return {left, right}
}

function frequency(samples, sr) {
  const crossings = []
  for (let i = Math.round(.1 * sr); i < samples.length - .1 * sr; i++) {
    if (samples[i - 1] < 0 && samples[i] >= 0) crossings.push(i)
  }
  return (crossings.length - 1) * sr / (crossings.at(-1) - crossings[0])
}

test("locked tempo keeps the pitch, stereo polarity and intended duration at both pitch extremes", () => {
  const sr = 24_000, hz = 330
  for (const rate of [.8, 1.2]) {
    const {left, right} = renderLocked({sr, rate, seconds: 3, offset: .25, fill(l, r) {
      for (let i = 0; i < l.length; i++) {
        l[i] = Math.sin(2 * Math.PI * i * hz / sr)
        r[i] = -l[i]
      }
    }})
    assert.ok(Math.abs(frequency(left, sr) - hz) < 2)
    for (let i = 0; i < left.length; i++) assert.ok(Math.abs(left[i] + right[i]) < .0001)
  }
})

test("tempo lock also keeps low bass notes during SYNC, including bass present only on the right", () => {
  const sr = 48_000
  for (const hz of [27.5, 41.203, 55]) {
    for (const rate of [.92, 1.08]) {
      const {left, right} = renderLocked({sr, rate, seconds: 3, offset: .25, fill(_l, r) {
        for (let i = 0; i < r.length; i++) r[i] = .4 * Math.sin(2 * Math.PI * hz * i / sr)
      }})
      const cents = 1200 * Math.log2(frequency(right, sr) / hz)
      assert.ok(Math.abs(cents) < 10, hz + " Hz at " + rate + "× differed by " + cents + " cents")
      assert.ok(left.every(sample => sample === 0))
    }
  }
})

test("short drum attacks stay on tempo while stretching or compressing the beat", () => {
  const sr = 48_000, period = .432, offset = .21
  for (const rate of [.8, .92, 1.08, 1.2]) {
    const {left} = renderLocked({sr, rate, seconds: 6, offset, fill(l, r) {
      let seed = 7309
      for (let i = 0; i < l.length; i++) {
        const t = i / sr, beat = (t + .037) % period
        seed = (1664525 * seed + 1013904223) >>> 0
        const click = beat < .008 ? Math.exp(-beat * 440) * ((seed / 2147483648 - 1) * .2 + .1 * Math.sin(2 * Math.PI * 1980 * beat)) : 0
        l[i] = click + .7 * Math.exp(-beat * 21) * Math.sin(2 * Math.PI * (48 * beat + .85 * (1 - Math.exp(-90 * beat))))
        r[i] = .8 * l[i]
      }
    }})
    const errors = []
    for (let beat = period - .037; beat < 6; beat += period) {
      const nominal = (beat - offset) / rate
      let strongest = 0, heard = 0
      for (let i = Math.round((nominal - .055) * sr); i < (nominal + .055) * sr; i++) {
        const attack = Math.abs(left[i] - 2 * left[i - 1] + left[i - 2])
        if (attack > strongest) { strongest = attack; heard = i / sr }
      }
      assert.ok(strongest > .02, "missing drum attack at " + beat)
      errors.push(Math.abs(heard - nominal))
    }
    errors.sort((a, b) => a - b)
    assert.ok(errors[Math.floor(errors.length * .9)] < .015, "late drum attacks at " + rate + "×")
  }
})
