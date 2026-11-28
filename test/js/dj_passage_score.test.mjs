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

  test(kind + " keeps an audible accent reversal inconclusive even with missing or double-time metadata", () => {
    for (const bpm of [null, 46.875, 187.5, 120]) {
      const take = alternatingAccents(kind, true, {bpm})
      const result = scorePassage(take)
      assert.equal(metric(result, "pulse").state, "unknown")
      assert.equal(result.score, null)
      assert.equal(metric(scorePassage(alternatingAccents(kind, false, {bpm})), "pulse").state, "good")
    }
  })

  test(kind + " ignores equal subdivisions as evidence that the beat has switched", () => {
    for (const accent of [1, 1.05]) {
      assert.equal(metric(scorePassage(alternatingAccents(kind, true, {accent})), "pulse").state, "good")
    }
    assert.equal(metric(scorePassage(alternatingAccents(kind, false, {bpm: 70})), "pulse").state, "good")
  })
}

test("a mixed signal with aligned endpoints only attests to the pulse before and after the overlap", () => {
  const take = alternatingAccents("blend", false)
  const reversed = alternatingAccents("blend", true)
  take.frames = take.frames.map((frame, i) =>
    i * dt >= take.changeAt && i * dt < take.changeAt + take.overlap ? reversed.frames[i] : frame
  )
  for (const data of [take, {...take, kind: "echo", descriptive: true}]) {
    const result = scorePassage(data)
    assert.equal(metric(result, "pulse").state, "good")
    assert.match(metric(result, "pulse").value, /antes e depois/)
    assert.match(result.summary, /antes e depois/)
  }
})

for (const kind of ["fade", "echo", "filter", "lowpass", "bass_swap"]) {
  test(`${kind} reports the two ends and peak without grading its intentional envelope`, () => {
    const make = changes => ({...passage({pause: 1.4, ...changes}), kind, descriptive: true})
    const aligned = scorePassage(make({}))
    assert.equal(aligned.score, null)
    assert.equal(aligned.descriptive, true)
    assert.equal(metric(aligned, "level").state, "good")
    assert.equal(metric(aligned, "pulse").state, "good")
    const degraded = scorePassage(make({nextLevel: .25, peak: 1.1, shift: .18}))
    assert.match(metric(degraded, "level").value, /12.*dB abaixo/)
    assert.equal(metric(degraded, "headroom").state, "poor")
    assert.notEqual(metric(degraded, "pulse").state, "good")
    assert.match(degraded.summary, /dBFS|abaixo|fase|ms/)
  })
}

test("the bass exchange uses the pulse and level evidence of a continuous four-beat overlap", () => {
  const sound = passage({kind: "blend", nextBeat: 0.45})
  const score = scorePassage(sound)
  assert.equal(metric(score, "pulse").state, "poor")
  assert.deepEqual(scorePassage({...sound, kind: "bass_swap"}), score)
})

for (const kind of ["brake", "scratch_cut", "spinback", "chirp", "transform", "scribble"]) {
  test(`${kind} describes the two records and the peak inside the gesture`, () => {
    const take = {...passage({shift: .23, pause: 1.5, nextLevel: .25}), kind, descriptive: true}
    take.frames[295].peak = 1.1 // pre-existing peak just before the gesture
    take.frames[510].peak = 1.1 // new record after the fader opened
    const result = scorePassage(take)
    assert.equal(result.score, null)
    assert.deepEqual(result.metrics.map(m => m.id), ["level", "headroom"])
    assert.match(metric(result, "level").value, /12.*dB abaixo/)
    assert.equal(metric(result, "headroom").state, "good")
    take.frames[410].peak = 1.1
    assert.equal(metric(scorePassage(take), "headroom").state, "poor")
    assert.match(scorePassage(take).summary, /dBFS/)
    const partial = scorePassage({...take, frames: take.frames.slice(0, 490)})
    assert.deepEqual(partial.metrics.map(m => m.state), ["unknown", "unknown"])
  })
}

test("the peak margin grades reconstructed overs and labels sample-only readings in their own unit", () => {
  const data = passage({peak: 0.82})
  const original = metric(scorePassage(data), "headroom")
  assert.equal(original.state, "good")
  assert.match(original.value, /dBFS/)
  const frames = data.frames.map(f => ({...f, truePeak: 1.16}))
  const measured = metric(scorePassage({...data, frames}), "headroom")
  assert.equal(measured.state, "poor")
  assert.match(measured.value, /1,3 dBTP/)
})

test("an entry that goes silent after its first beats cannot earn a steady reading", () => {
  for (const kind of ["cut", "blend", "bass_swap", "brake"]) {
    const data = passage({kind})
    const end = Math.round((data.changeAt + data.overlap) / dt)
    data.frames = [...data.frames.slice(0, end), ...data.frames.slice(0, 200),
      ...Array.from({length: 200}, () => ({rms: 0, peak: 0, onset: 0}))]
    const result = scorePassage({...data, descriptive: kind === "bass_swap" || kind === "brake"})
    assert.equal(result.score, null)
    assert.equal(metric(result, "level").finding, "silent_tail")
    assert.match(result.summary, /2 s.*sem sinal/i)
    if (kind !== "brake") assert.equal(metric(result, "pulse").state, "unknown")
  }
})

test("quiet but measurable music is compared in dB and each side can still carry sound", () => {
  const data = passage({nextLevel: .004})
  const end = Math.round((data.changeAt + data.overlap) / dt)
  for (const f of data.frames.slice(end)) f.peak = .004
  const result = scorePassage(data)
  assert.equal(metric(result, "level").finding, "quieter_entry")
  assert.match(metric(result, "level").value, /dB abaixo/)
})

test("the summary identifies a fully silent recording even when a gesture or pulse has no reference", () => {
  for (const kind of ["cut", "echo", "chirp"]) {
    const result = scorePassage({...passage({kind, silent: true}), descriptive: kind !== "cut"})
    assert.equal(result.score, null)
    assert.match(result.summary, /sem sinal.*(lados|antes e depois)/i)
  }
})

test("a clipped effect still reports a silent entry, with its peak available separately", () => {
  for (const kind of ["echo", "brake", "chirp"]) {
    const data = passage({kind, nextLevel: 0})
    data.frames[350].peak = 1.12
    const result = scorePassage({...data, descriptive: true})
    assert.equal(metric(result, "headroom").state, "poor")
    assert.equal(result.summary, "Entrada em silêncio")
  }
})

test("the silence of an effect and brief rests in an otherwise audible entry keep their context", () => {
  const data = passage({kind: "brake", pause: 1.5})
  const end = Math.round((data.changeAt + data.overlap) / dt)
  const quiet = {rms: 0, peak: 0, onset: 0}
  for (const start of [end, data.frames.length - 99]) {
    const frames = data.frames.map((f, i) => i >= start && i < start + 99 ? quiet : f)
    const result = scorePassage({...data, frames, descriptive: true})
    assert.notEqual(metric(result, "level").finding, "silent_tail")
  }
})
