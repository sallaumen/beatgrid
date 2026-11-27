import assert from "node:assert/strict"
import test from "node:test"
import {tripVersionPath} from "../../assets/js/dj/trip_identity.js"

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
