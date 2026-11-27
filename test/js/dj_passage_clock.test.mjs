import assert from "node:assert/strict"
import test from "node:test"
import {passageClock} from "../../assets/js/dj/passage_clock.js"

test("the exit clock uses the playing record's rate and keeps the last fraction visible", () => {
  const choice = {phase: "confirmed", exitMs: 66000, pair: {from: "b"}}
  const deck = {positionMs: () => 5500, el: {playbackRate: 1.25}, audible: () => true, ready: () => true}
  const fast = passageClock(choice, deck, "running")
  assert.deepEqual(fast, {label: "Na pista em", time: "0:49", text: "Na pista em 0:49"})
  deck.el.playbackRate = 0.8
  assert.equal(passageClock(choice, deck, "running").time, "1:16")
  deck.positionMs = () => 65999
  assert.equal(passageClock(choice, deck, "running").time, "0:01")
})

test("an armed take marks a cue point without promising to launch", () => {
  const choice = {phase: "armed", exitMs: 11000, pair: {from: "a"}}
  const deck = {positionMs: () => 9000, el: {playbackRate: 1}, audible: () => true, ready: () => true}
  const armed = passageClock(choice, deck, "running")
  assert.deepEqual(armed, {label: "Ponto ensaiado em", time: "0:02", text: "Ponto em 0:02 · aguarda confirmação"})
  assert.equal(passageClock(choice, deck, "interrupted").time, undefined)
  deck.ready = () => false
  assert.match(passageClock(choice, deck, "running").text, /Aguardando o áudio do deck A/)
  deck.entry = {}
  assert.equal(passageClock(choice, deck, "running").time, "0:02")
  deck.audible = () => false
  assert.equal(passageClock(choice, deck, "running").time, undefined)
})

test("the clock never announces an entry before the handoff has actually succeeded", () => {
  const choice = {phase: "confirmed", exitMs: 4100, pair: {from: "b"}}
  const deck = {positionMs: () => 4101, el: {playbackRate: 1}, audible: () => true, ready: () => true}
  for (const phase of ["confirmed", "starting", "missed", "failed"]) {
    const state = passageClock({...choice, phase}, deck, "running")
    assert.equal(state.time, undefined)
    assert.doesNotMatch(state.text, /Na pista|Entrou/)
  }
})
