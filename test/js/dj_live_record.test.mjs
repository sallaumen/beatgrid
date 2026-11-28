import assert from "node:assert/strict"
import test from "node:test"
import {startLiveRecord} from "../../assets/js/dj/live_record.js"
import {createRecordSource, recallSplice} from "../../assets/js/dj/record_source.js"

function recording(seconds = 3) {
  const sr = 16_000
  const voices = new Set()
  const ctx = {sampleRate: sr, currentTime: 0,
    createGain: () => ({connect() {}, disconnect() {}}),
    createBuffer(n, length) {
      const data = Array.from({length: n}, () => new Float32Array(length))
      return {sampleRate: sr, length, numberOfChannels: n, duration: length / sr, getChannelData: i => data[i]}
    },
    createBufferSource() {
      return {playbackRate: {value: 1, setValueAtTime(rate) { this.value = rate }},
        connect() {}, disconnect() {}, stop(at = ctx.currentTime) { this.end = at },
        start(when, offset = 0) { this.when = when; this.end = Infinity; this.frame = offset * sr; voices.add(this) }}
    }}
  const input = ctx.createBuffer(2, seconds * sr)
  for (let i = 0; i < input.length; i++) {
    input.getChannelData(0)[i] = .4 * Math.sin(2 * Math.PI * 55 * i / sr)
    input.getChannelData(1)[i] = -.7 * input.getChannelData(0)[i]
  }
  let frame = 0
  function run(duration, control = () => {}) {
    const left = [], right = []
    const finish = frame + Math.round(duration * sr)
    for (; frame < finish; frame++) {
      ctx.currentTime = frame / sr
      for (const voice of voices) {
        if (ctx.currentTime + 1e-10 >= voice.end || voice.frame >= voice.buffer.length) {
          voices.delete(voice)
          voice.onended?.()
        }
      }
      control(frame, ctx.currentTime)
      let l = 0, r = 0
      for (const voice of voices) {
        if (ctx.currentTime + 1e-10 < voice.when || ctx.currentTime >= voice.end) continue
        const i = Math.floor(voice.frame), fraction = voice.frame - i
        const sample = row => row[i] * (1 - fraction) + (row[i+1] || 0) * fraction
        l += sample(voice.buffer.getChannelData(0))
        r += sample(voice.buffer.getChannelData(1))
        voice.frame += voice.playbackRate.value
      }
      left.push(l)
      right.push(r)
    }
    return {left, right}
  }
  return {ctx, input, run, voices}
}

function hz(samples, sr, start, end) {
  const at = []
  for (let i = Math.ceil(sr * start); i < sr * end; i++) {
    if (samples[i-1] < 0 && samples[i] >= 0) at.push(i)
  }
  return (at.length - 1) * sr / (at.at(-1) - at[0])
}

test("the room uses the same samples as the unedited rehearsal and keeps its scheduling runway", () => {
  const mix = {rate: 1.08, vinyl: false}
  const rehearsal = recording(), live = recording()
  const preview = createRecordSource(rehearsal.ctx, rehearsal.input, mix)
  preview.start(0, .1)
  startLiveRecord(live.ctx, live.ctx.createGain(), live.input, .1, mix, () => {})
  const runway = Math.max(...Array.from(live.voices, v => v.when + v.buffer.duration))
  assert.ok(runway >= .95)
  assert.ok(live.voices.size <= 3, "a steady passage only needs two long scheduled blocks")
  const r = rehearsal.run(1.3), p = live.run(1.3)
  for (const channel of ["left", "right"]) {
    for (let i = 0; i < r[channel].length; i++) assert.ok(Math.abs(r[channel][i] - p[channel][i]) < .0001)
  }
})

test("a pitch-locked cut hears the last attack of the running record and stops at the chosen frame", () => {
  for (const rate of [.92, 1.08]) {
    const phones = recording(), room = recording(), recalled = recording()
    const sr = phones.ctx.sampleRate, lead = .46, offset = .12
    const frames = Math.round((lead + .008) * sr)
    const cue = offset + lead * rate
    const mix = {rate, vinyl: false}
    for (const {input} of [phones, room, recalled]) {
      for (let c = 0; c < 2; c++) {
        const channel = input.getChannelData(c)
        channel.fill(0)
        const at = Math.round(cue * sr)
        for (let i = 0; i < 32; i++) {
          channel[at + i] = (c ? -.7 : 1) * Math.sin(2 * Math.PI * i / 10) * Math.sin(Math.PI * i / 32) ** 2
        }
      }
    }
    const take = createRecordSource(phones.ctx, phones.input, mix, cue)
    take.start(0, offset, frames * rate / sr)
    startLiveRecord(room.ctx, room.ctx.createGain(), room.input, offset, mix, () => {})
    const heard = phones.run(.55), onAir = room.run(.55)
    const splice = recallSplice(take.splices(), recalled.input, cue, rate)
    assert.ok(splice)
    startLiveRecord(recalled.ctx, recalled.ctx.createGain(), recalled.input, cue, mix,
      () => {}, () => {}, 0, 0, splice)
    const ending = recalled.run(.008)
    for (const channel of ["left", "right"]) {
      assert.ok(onAir[channel].slice(0, frames).some(v => Math.abs(v) > .2))
      assert.ok(heard[channel].slice(0, frames).every((v, i) => v === onAir[channel][i]),
        "the private excerpt must keep the live attack at " + rate + "×")
      assert.deepEqual(ending[channel], heard[channel].slice(Math.round(lead * sr), frames))
      assert.ok(heard[channel].slice(frames).every(v => v === 0))
    }
  }
})

test("recalling a pitch-locked excerpt near the end of the recording preserves its remaining audio and silence", () => {
  const phones = recording(.6), room = recording(.6), rate = 1.08
  const sr = phones.ctx.sampleRate, offset = .06, cue = offset + .46 * rate
  const mix = {rate, vinyl: false}
  const source = createRecordSource(phones.ctx, phones.input, mix, cue)
  source.start(0, offset, 2)
  const heard = phones.run(.75)
  const saved = recallSplice(source.splices(), room.input, cue, rate)
  assert.ok(saved)
  let ended = 0
  startLiveRecord(room.ctx, room.ctx.createGain(), room.input, cue, mix, () => ended++, () => {},
    0, 0, saved)
  const recalled = room.run(.2)
  const remaining = Math.round((phones.input.duration - cue) / rate * sr)
  for (const channel of ["left", "right"]) {
    const original = heard[channel].slice(Math.round(.46 * sr))
    assert.ok(original.slice(0, remaining).some(v => Math.abs(v) > .2))
    assert.ok(recalled[channel].every((v, i) => Math.abs(v - original[i]) < .0001))
    assert.ok(recalled[channel].slice(remaining).every(v => v === 0))
  }
  assert.equal(ended, 1)
})

for (const vinyl of [false, true]) {
  test("repeated live bends retain the record, " + (vinyl ? "transpose the note" : "lock its note") + " and end exactly once", () => {
    const {ctx, input, run, voices} = recording()
    let ended = 0
    const live = startLiveRecord(ctx, ctx.createGain(), input, .2, {rate: 1, vinyl}, () => ended++)
    const samples = run(2, (frame, t) => {
      if (t > .1 && frame % 400 === 0) {
        const direction = t < 1 ? 1 : -1
        live.setRate(1 + direction * (frame % 800 === 0 ? .12 : .119))
      }
    })
    const early = hz(samples.left, ctx.sampleRate, .23, .9), late = hz(samples.left, ctx.sampleRate, 1.22, 1.9)
    assert.ok(Math.abs(early - (vinyl ? 55 * 1.12 : 55)) < .2)
    assert.ok(Math.abs(late - (vinyl ? 55 * .88 : 55)) < .2)
    for (let i = 0; i < samples.left.length; i++) assert.ok(Math.abs(samples.right[i] + .7 * samples.left[i]) < .0001)
    assert.ok(Math.abs(live.position() - 2.19) < .03)
    live.setRate(1)
    run(2)
    assert.equal(ended, 1)
    assert.equal(voices.size, 0)
    live.stop()
    assert.equal(ended, 1)
  })
}

test("an outgoing pitch-locked record restarts on the exact samples heard in the middle of a rehearsal grain", () => {
  const rate = 1.065, mix = {rate, vinyl: false}
  const rehearsal = recording(4)
  const first = .117, cue = 1.841
  const src = createRecordSource(rehearsal.ctx, rehearsal.input, mix, cue)
  src.start(0, first, 3.68)
  const reference = rehearsal.run(2.8)
  for (const late of [0, .0013, .045, .097]) {
    const live = recording(4), saved = src.splices()
    const at = cue + late
    const head = startLiveRecord(live.ctx, live.ctx.createGain(), live.input, at, mix,
      () => {}, () => {}, 0, live.ctx.currentTime, recallSplice(saved, live.input, at, rate))
    const samples = live.run(.55)
    const offset = Math.round((at - first) * rehearsal.ctx.sampleRate / rate)
    for (const side of ["left", "right"]) {
      for (let i = 0; i < samples[side].length; i++) {
        assert.ok(Math.abs(samples[side][i] - reference[side][offset + i]) < .00001, side + " sample " + i)
      }
    }
    head.stop()
  }
})

test("the jog owns the recalled tempo and a rescued track plays beyond the headphone excerpt", () => {
  const take = recording(4), room = recording(4), rate = 1.06, cue = .95
  const source = createRecordSource(take.ctx, take.input, {rate, vinyl: false}, cue)
  source.start(0, .06, 1.57)
  take.run(1.7)
  let ends = 0
  const live = startLiveRecord(room.ctx, room.ctx.createGain(), room.input, cue,
    {rate, vinyl: false}, () => ends++, () => {}, 0, 0, recallSplice(source.splices(), room.input, cue, rate))
  const samples = room.run(1.8, (frame, time) => {
    if (frame === 960) {
      const at = live.position()
      live.setRate(.94)
      assert.equal(live.position(), at)
    }
    if (time > .16) assert.equal(live.rate(), .94)
  })
  assert.ok(Math.abs(hz(samples.left, room.ctx.sampleRate, .9, 1.7) - 55) < .2)
  assert.ok(live.position() > 2.6)
  assert.equal(ends, 0)
  room.run(2)
  assert.equal(ends, 1)
})

for (const mix of [{rate: 1, vinyl: false}, {rate: .95, vinyl: true}, {rate: 1.052, vinyl: false}]) {
  test(`a prepared ${mix.rate}× entry keeps its first stereo samples while another record takes time`, () => {
    const room = recording(4), reference = recording(4), cue = .177
    const prepared = startLiveRecord(room.ctx, room.ctx.createGain(), room.input, cue, mix,
      () => {}, () => {}, 0, 0, null, true)
    assert.equal(room.voices.size, 0)
    const wait = room.run(.035)
    assert.ok(wait.left.every(x => x === 0) && wait.right.every(x => x === 0))
    room.ctx.currentTime = .035
    prepared.launch(.035, cue)
    const preview = createRecordSource(reference.ctx, reference.input, mix)
    preview.start(0, cue)
    const a = room.run(.56), b = reference.run(.56)
    for (const channel of ["left", "right"]) {
      for (let i = 0; i < a[channel].length; i++) assert.ok(Math.abs(a[channel][i] - b[channel][i]) < 1e-5)
    }
    prepared.stop()
  })
}
