import test from "node:test"
import assert from "node:assert/strict"
import {drawRehearsalWaves, drawRehearsalBass} from "../../assets/js/dj/rehearsal_waves.js"
import {neutralMix, syncedRate} from "../../assets/js/dj/deck_mix.js"
import {planRehearsal} from "../../assets/js/dj/rehearsal.js"

function canvas(width = 100, height = 48) {
  const rectangles = [], paths = []
  let points = []
  const context = {
    scale() {}, setLineDash() {},
    fillRect(x, y, w, h) { rectangles.push({x, y, w, h, color: this.fillStyle}) },
    beginPath() { points = [] },
    moveTo(x, y) { points.push([x, y]) },
    lineTo(x, y) { points.push([x, y]) },
    stroke() { paths.push({points, color: this.strokeStyle}) }
  }
  return {clientWidth: width, clientHeight: height, getContext: () => context, rectangles, paths}
}

const waveform = amplitude => ({bps: 50, peaks: new Float32Array(600).fill(amplitude)})
function drawing(kind, outVolume = 1, outPeak = 0.08, intoPeak = 0.04, width = 100) {
  const out = canvas(width), into = canvas(width), gain = canvas(width, 32)
  const plan = {duration: 8, lead: 3, blend: 2, outStart: 0, inStart: 0,
    mix: {out: {...neutralMix, level: outVolume}, into: neutralMix}}
  drawRehearsalWaves([out, into], gain, [waveform(outPeak), waveform(intoPeak)], plan, kind, 2)
  return {out, into, gain}
}

test("quiet recordings share a single linear scale while deck level still controls their height", () => {
  const maxBar = lane => Math.max(0, ...lane.rectangles.filter(r => r.w === 1 && r.h < 48).map(r => r.h))
  const normal = drawing("cut"), quieter = drawing("cut", 0.5), silent = drawing("cut", 1, 0, 0)
  assert.ok(maxBar(normal.out) >= 30)
  assert.ok(Math.abs(maxBar(normal.out) - 2 * maxBar(normal.into)) < 0.01)
  assert.ok(Math.abs(maxBar(quieter.out) - maxBar(normal.into)) < 0.01)
  assert.equal(maxBar(silent.out), 0)
  assert.equal(normal.out.width, 200)
})

test("a cut shorter than one pixel uses one boundary even when it crosses an integer column", () => {
  const {out} = drawing("cut", 1, 0.08, 0.04, 173)
  assert.equal(out.rectangles.filter(r => r.w === 1 && r.h === out.clientHeight).length, 1)
})

test("a narrow screen still draws a percussion peak between two sampled pixel positions", () => {
  const out = canvas(40), into = canvas(40), gain = canvas(40, 32)
  const wave = waveform(0)
  wave.peaks[4] = 0.1
  const plan = {duration: 8, lead: 3, blend: 2, outStart: 0, inStart: 0,
    mix: {out: neutralMix, into: neutralMix}}
  drawRehearsalWaves([out, into], gain, [wave, waveform(0)], plan, "blend", 1)
  assert.ok(out.rectangles.some(r => r.x === 0 && r.w === 1 && r.h > 30))
})

test("both boundaries align with the fader panel and a subpixel cut keeps a single time mark", () => {
  for (const [kind, expected] of [["blend", [37, 62]], ["cut", [37]]]) {
    const {out, into, gain} = drawing(kind)
    for (const lane of [out, into, gain]) {
      const marks = lane.rectangles.filter(r => r.w === 1 && r.h === lane.clientHeight)
      assert.deepEqual(marks.map(r => Math.floor(r.x)), expected)
    }
    const ramps = gain.paths.filter(p => p.points.length > 2)
    assert.equal(ramps.length, 2)
    const [outgoing, incoming] = ramps
    assert.ok(outgoing.points[0][1] < outgoing.points.at(-1)[1])
    assert.ok(incoming.points[0][1] > incoming.points.at(-1)[1])
  }
})

test("the bass handoff follows the actual third beat and changes one shelf at a time", () => {
  for (const blend of [2, 3.2]) {
    const graph = canvas(320, 32)
    const plan = {duration: 8, lead: 2, blend}
    drawRehearsalBass(graph, plan, 2)
    const edge = portion => 40 * (plan.lead + portion * blend)
    const pivot = edge(0.5)
    const marks = graph.rectangles.filter(rect => rect.w === 1 && rect.h === graph.clientHeight)
    assert.ok(marks.some(rect => rect.x === Math.floor(pivot)))
    const [out, into] = graph.paths.map(path => path.points)
    const value = (points, x) => points.find(point => Math.abs(point[0] - x) < 0.00001)[1]
    assert.equal(value(out, pivot), value(into, pivot))
    assert.ok(value(into, edge(0.375)) > value(into, pivot))
    assert.equal(value(out, edge(0.375)), value(out, pivot))
    assert.ok(value(out, edge(0.625)) > value(out, pivot))
    assert.equal(value(into, edge(0.625)), value(into, pivot))
    assert.equal(graph.width, 640)
  }
})

function impulseAt(attack) {
  const sampleRate = 10000, duration = 8
  const channels = [new Float32Array(duration * sampleRate), new Float32Array(duration * sampleRate)]
  channels[1][Math.round(attack * sampleRate)] = 1
  const wave = waveform(0)
  wave.peaks[Math.floor(attack * wave.bps)] = 1
  return {wave, buffer: {sampleRate, duration, numberOfChannels: 2, getChannelData: index => channels[index]}}
}

function attackColumns(width, out, into, plan) {
  const lanes = [canvas(width), canvas(width)]
  drawRehearsalWaves(lanes, canvas(width), [out.wave, into.wave], plan, "cut", 2)
  return lanes.map((lane, side) => lane.rectangles.filter(r => r.color === ["#ffb020", "#5ad1a0"][side]).map(r => r.x))
}

test("attacks outside the CUE and cut are silent on both waveforms, including fractional cue buckets", () => {
  const out = impulseAt(5.012), into = impulseAt(7.4005)
  const plan = planRehearsal(out.buffer, into.buffer, 5.001, 7.401, 120,
    {out: {...neutralMix, rate: 1.08}, into: {...neutralMix, rate: .82}})
  for (const width of [292, 616]) assert.deepEqual(attackColumns(width, out, into, plan), [[], []])
})

test("pitch and SYNC put each right-channel attack in its actual playback column", () => {
  const outAt = 4.889, intoAt = 7.453
  const out = impulseAt(outAt), into = impulseAt(intoAt)
  for (const inRate of [.82, syncedRate(1, 112, 120)]) {
    const plan = planRehearsal(out.buffer, into.buffer, 5.001, 7.401, 120,
      {out: {...neutralMix, rate: 1.08}, into: {...neutralMix, rate: inRate}})
    const times = [(outAt - plan.outStart) / 1.08, plan.lead + (intoAt - plan.inStart) / inRate]
    for (const width of [292, 616]) {
      assert.deepEqual(attackColumns(width, out, into, plan),
        times.map(t => [Math.floor(t * width / plan.duration)]))
    }
  }
})
