import assert from "node:assert/strict"
import test from "node:test"
import {scorePassage} from "../../assets/js/dj/passage_score.js"

const dt = 0.01

function passage({kind = "blend", bpm = 120, nextBeat = 0.5, shift = 0, half = false,
                  subdivision = false, silent = false, nextLevel = 1, pause = 0,
                  peak = 0.55, overlapOnly = false, noOnsets = false} = {}) {
  const changeAt = 3, overlap = kind === "cut" ? 0.008 : 2
  function record(t, beat, phase, accents) {
    const p = Math.round((t - phase) / dt) % Math.round(beat / dt)
    const on = p === 0 ? 1 : accents && p === Math.round(beat / dt / 2) ? 0.28 : 0
    return {rms: 0.12 + 0.25 * on, onset: 0.25 * on}
  }
  const frames = Array.from({length: Math.round((changeAt + overlap + 2.2) / dt)}, (_, i) => {
    const t = i * dt, p = Math.min(1, Math.max(0, (t - changeAt) / overlap))
    const a = record(t, 0.5, 0.1)
    const b = record(t, half ? nextBeat * 2 : nextBeat, changeAt + 0.1 + shift, subdivision)
    const inGap = t >= changeAt + 0.12 && t < changeAt + 0.12 + pause
    const rms = inGap || silent ? 0 : (1 - p) * a.rms + p * b.rms * nextLevel
    const frame = {rms, peak: rms ? peak : 0}
    if (!noOnsets) frame.onset = (inGap || silent || (overlapOnly && p > 0 && p < 1)) ? 0 : (1 - p) * a.onset + p * b.onset * nextLevel
    return frame
  })
  return {frames, frameSeconds: dt, changeAt, overlap, kind, bpm}
}

function metric(report, id) {
  return report.metrics.find(metric => metric.id === id)
}

for (const kind of ["cut", "blend"]) {
  test(kind + " finds a steady pulse from audio with a missing or stale catalog BPM", () => {
    for (const bpm of [null, 65, 190]) {
      const result = scorePassage(passage({kind, bpm}))
      assert.equal(metric(result, "pulse").state, "good")
      assert.ok(result.score >= 90)
      assert.deepEqual(result.metrics.map(x => x.id), ["pulse", "level", "headroom"])
    }
  })

  test(kind + " detects a half-beat phase change even when both decks have the same nominal BPM", () => {
    const result = scorePassage(passage({kind, shift: 0.25}))
    assert.equal(metric(result, "pulse").state, "poor")
    assert.ok(result.score <= 65)
  })

  test(kind + " tolerates quieter eighth notes and measured half/double pulse", () => {
    for (const options of [{subdivision: true}, {nextBeat: 0.25}, {half: true}]) {
      assert.equal(metric(scorePassage(passage({kind, ...options})), "pulse").state, "good")
    }
  })

  test(kind + " separates a hole at the change from sustained low incoming level", () => {
    const hole = metric(scorePassage(passage({kind, pause: 0.5})), "level")
    assert.equal(hole.state, "poor")
    assert.match(hole.value, /silêncio|pausa/i)
    const drop = metric(scorePassage(passage({kind, nextLevel: 0.16})), "level")
    assert.equal(drop.state, "poor")
    assert.match(drop.value, /dB/)
  })
}

test("a clean tempo switch can suit a cut while a drifting blend needs attention", () => {
  const cut = metric(scorePassage(passage({kind: "cut", nextBeat: 0.45})), "pulse")
  const blend = metric(scorePassage(passage({nextBeat: 0.45})), "pulse")
  assert.equal(blend.state, "poor")
  assert.equal(cut.state, "watch")
})

test("a disappearing beat during the overlap can be heard even if the exit and entry align", () => {
  assert.equal(metric(scorePassage(passage({overlapOnly: true})), "pulse").state, "poor")
})

test("confidence depends on identifiable attacks, even with catalog BPM and ample signal", () => {
  const data = passage()
  const result = scorePassage({...data, frames: data.frames.map(() => ({rms: 0.12, peak: 0.55, onset: 0}))})
  assert.equal(result.score, null)
  assert.equal(metric(result, "pulse").state, "unknown")
  assert.equal(metric(result, "level").state, "good")
  assert.equal(metric(result, "headroom").state, "good")
  assert.match(result.summary, /pulso|batida/i)
  assert.equal(metric(scorePassage(passage({noOnsets: true})), "pulse").state, "good")
})

test("digital headroom and phase are independent, with no claim of audible distortion", () => {
  for (const [peak, state] of [[0.3, "good"], [0.97, "watch"], [1.14, "poor"]]) {
    const result = scorePassage(passage({peak}))
    assert.equal(metric(result, "headroom").state, state)
    assert.equal(metric(result, "pulse").state, "good")
    assert.doesNotMatch(result.summary, /distorceu|distorção audível|clipou/i)
  }
})

test("silence, missing context, truncation and malformed frames carry no numeric grade", () => {
  const data = passage()
  for (const sample of [passage({silent: true}), {...data, frames: []}, {...data, changeAt: 0.12},
    {...data, frames: data.frames.slice(0, 310)}, {...data, frames: [...data.frames, {peak: 0, rms: NaN}]}]) {
    assert.equal(scorePassage(sample).score, null)
  }
})

test("a few near-regular fluctuations in a sustained tone cannot carry the entry", () => {
  const data = passage({kind: "cut"})
  const first = Math.round((data.changeAt + data.overlap) / dt)
  for (let i = first; i < data.frames.length; i++) {
    const hit = (i - first) % 27 === 0 && i - first < 120
    data.frames[i] = {rms: hit ? 0.0158 : 0.014, peak: 0.03, onset: hit ? 0.0017 : 0.0001}
  }
  const result = scorePassage(data)
  assert.equal(metric(result, "pulse").state, "unknown")
  assert.equal(result.score, null)
})

test("sustained gain dips and surges are local to the overlap", () => {
  for (const gain of [0.16, 3.5]) {
    const data = passage()
    for (const frame of data.frames.slice(350, 420)) frame.rms *= gain
    assert.equal(metric(scorePassage(data), "level").state, "poor")
  }
})


// Keep the subdivision attacks in place and change which ones carry the beat.
function alternatingAccents(kind, shifted, {offset = 0.07, accent = 1.8, bpm = 93.75} = {}) {
  const beat = 0.64, changeAt = 3.13, overlap = kind === "cut" ? 0.008 : 4 * beat
  const frames = Array.from({length: Math.ceil((changeAt + overlap + 2.15) / dt)}, (_, i) => {
    const time = i * dt
    const mix = Math.min(1, Math.max(0, (time - changeAt) / overlap))
    const tick = Math.round((time - offset) / (beat / 2))
    const on = Math.abs(time - (offset + tick * beat / 2)) <= dt * 0.51
    const level = beat => 0.1 * (Math.abs(beat) % 2 === 0 ? accent : 1)
    const onset = on ? (1 - mix) * level(tick) + mix * level(tick + Number(shifted)) : 0
    return {rms: 0.08 + onset, peak: 0.45, onset}
  })
  return {kind, bpm, frames, frameSeconds: dt, changeAt, overlap}
}

for (const kind of ["cut", "blend"]) {
  test(kind + " distinguishes swapped accents on a common subdivision lattice", () => {
    for (const offset of [0.07, 0.23, 0.30]) {
      assert.equal(metric(scorePassage(alternatingAccents(kind, false, {offset})), "pulse").state, "good")
      assert.equal(metric(scorePassage(alternatingAccents(kind, true, {offset})), "pulse").state, "unknown")
    }
  })

  test(kind + " ignores equal subdivisions as evidence that the beat has switched", () => {
    for (const accent of [1, 1.05]) {
      assert.equal(metric(scorePassage(alternatingAccents(kind, true, {accent})), "pulse").state, "good")
    }
    assert.equal(metric(scorePassage(alternatingAccents(kind, false, {bpm: 70})), "pulse").state, "good")
  })
}
