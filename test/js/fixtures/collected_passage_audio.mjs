import assert from "node:assert/strict"
import {setImmediate} from "node:timers/promises"
import {neutralMix} from "../../../assets/js/dj/deck_mix.js"
import {mountPassageComparison} from "../../../assets/js/dj/passage_comparison.js"

const view = mountPassageComparison({clear() {}, show() {}, listening() {}}, [], () => "cut", () => "Corte")
const pair = {from: "a", to: "b", fromLoad: 2, toLoad: 5}
const points = {exit: 32, inStart: 4, lead: 3, duration: 7, blend: 2, mix: {out: neutralMix, into: neutralMix}}
const reading = {score: 65, metrics: [], summary: ""}

function closeDraft() {
  const plan = {...points, outgoing: new Float32Array(48000), incoming: new Float32Array(48000)}
  view.bind(pair, plan, 120)
  view.begin("cut").finish(reading)
  view.select()
  return [new WeakRef(plan.outgoing), new WeakRef(plan.incoming)]
}

const tracks = closeDraft()
// Weak references stay valid until the task that created them has finished.
await setImmediate()
global.gc()
assert.ok(tracks.every(track => track.deref() === undefined), "the score still owns a decoded track")
view.bind({...pair}, {...points}, 120)
assert.equal(view.reading(), reading)
view.bind({...pair, fromLoad: 6, toLoad: 7}, {...points}, 120)
assert.equal(view.reading(), null)
