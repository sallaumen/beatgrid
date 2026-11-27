import test from "node:test"
import assert from "node:assert/strict"
import {wireJogDrag} from "../../assets/js/dj/jog_drag.js"

function platter(view, engine, deck) {
  const el = new EventTarget()
  let capture = null
  Object.assign(el, {
    ownerDocument: {defaultView: view},
    classList: {add() {}, remove() {}},
    setPointerCapture(id) { capture = id },
    hasPointerCapture(id) { return capture === id },
    releasePointerCapture() { capture = null },
  })
  const destroy = wireJogDrag(el, engine, deck)
  function send(type, pointerId, clientX = 0, button = 0) {
    const event = Object.assign(new Event(type, {cancelable: true}), {pointerId, clientX, button})
    el.dispatchEvent(event)
    return event
  }
  return {send, destroy}
}

test("the touching finger owns each platter until release, cancellation, focus loss or removal", () => {
  const view = new EventTarget(), touches = [], turns = []
  const engine = {
    decks: {a: {trackId: "out"}, b: {trackId: "in"}}, resume() {},
    jogTouch(deck, held) { touches.push([deck, held]) },
    jogTurn(deck, ticks, time) { turns.push([deck, ticks, time]) },
  }
  const a = platter(view, engine, "a"), b = platter(view, engine, "b")
  a.send("pointerdown", 1, 5, 2)
  assert.deepEqual(touches, [])
  a.send("pointerdown", 1, 5)
  b.send("pointerdown", 2, 10)
  a.send("pointerdown", 3, 50)
  a.send("pointerup", 3)
  a.send("pointermove", 3, 80)
  const moved = a.send("pointermove", 1, 30)
  assert.deepEqual(turns, [["a", 9, moved.timeStamp]])
  a.send("pointercancel", 1)
  a.send("lostpointercapture", 1)
  view.dispatchEvent(new Event("blur"))
  assert.deepEqual(touches, [["a", true], ["b", true], ["a", false], ["b", false]])
  a.send("pointerdown", 4)
  a.destroy()
  a.send("pointerdown", 5)
  assert.deepEqual(touches.slice(4), [["a", true], ["a", false]])
  b.send("pointerdown", 6)
  b.send("lostpointercapture", 6)
  b.send("pointerdown", 7)
  b.send("pointerup", 7)
  b.destroy()
  assert.deepEqual(touches.slice(6), [["b", true], ["b", false], ["b", true], ["b", false]])
})
