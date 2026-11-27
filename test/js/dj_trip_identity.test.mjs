import assert from "node:assert/strict"
import test from "node:test"
import {tripVersionPath, tripTransportLabel, tripTransitionLabel} from "../../assets/js/dj/trip_identity.js"

const studio = {id: "studio", identity_key: ["sina", "djavan"], rel_path: "MPB/Sina - estúdio.mp3"}
const live = {id: "live", identity_key: ["sina", "djavan"], rel_path: "_Inbox/Sina - ao vivo.mp3"}
const different = {id: "different", identity_key: ["sina", "outro artista"], rel_path: "MPB/Sina.mp3"}

test("distinguishes homonyms across current deck, other deck and next recording", () => {
  const candidates = [studio, different, live]
  assert.equal(tripVersionPath(studio, candidates), studio.rel_path)
  assert.equal(tripVersionPath(live, candidates), live.rel_path)
  assert.equal(tripVersionPath(different, candidates), "")
})

test("does not show paths for the same loaded ID, unrelated titles or empty decks", () => {
  assert.equal(tripVersionPath(studio, [studio, null, {...studio}]), "")
  assert.equal(tripVersionPath(studio, [studio, different]), "")
  assert.equal(tripVersionPath(null, [studio, live]), "")
})


test("trip labels follow actual transport rather than the presence of a loaded deck", () => {
  const active = {activeDeck: "a", a: {trackId: "studio", playing: true}, b: {trackId: "live", playing: false}}
  assert.equal(tripTransportLabel(active), "Tocando agora")
  assert.equal(tripTransportLabel({...active, waitingForNext: true}), "Tocando agora")
  assert.equal(tripTransportLabel({...active, breatherTail: true}), "Tocando agora")
  const paused = {...active, a: {...active.a, playing: false}}
  assert.equal(tripTransportLabel(paused), "Faixa pausada")
  assert.equal(tripTransportLabel({...paused, breather: {remainingMs: 1000}}), "Respiro")
  assert.equal(tripTransportLabel({...paused, activeDeck: null}), "Sem reprodução")
  assert.equal(tripTransportLabel({...paused, a: {trackId: null, playing: false}}), "Sem reprodução")
  assert.equal(tripTransportLabel(paused, {el: {ended: true}}), "Sem reprodução")
  assert.equal(tripTransportLabel(paused, {el: {error: {code: 3}}}), "Sem reprodução")
  assert.equal(tripTransportLabel(active, {cueState: "preview"}), "Faixa pausada")
  assert.equal(tripTransportLabel({...paused, waitingForNext: true}), "Sem reprodução")
})

test("trip transition text uses the server label without exposing engine keys", () => {
  assert.equal(tripTransitionLabel({track: live, transition: {type: "cut"}, transition_label: "CORTE"}), "CORTE")
  assert.equal(tripTransitionLabel({track: live, transition: {type: "echo", breather: true}, transition_label: "ECO"}), "Respiro · ECO")
  assert.equal(tripTransitionLabel({track: live, transition: null, transition_label: "SEQ"}), "SEQ")
  assert.equal(tripTransitionLabel(null), "")
})
