import test from "node:test"
import assert from "node:assert/strict"
import {drawRehearsalWaves} from "../../assets/js/dj/rehearsal_waves.js"
import {neutralMix} from "../../assets/js/dj/deck_mix.js"

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
