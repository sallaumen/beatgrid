import assert from "node:assert/strict"
import test from "node:test"
import {mountBoothKeyboard} from "../../assets/js/dj/booth_keyboard.js"

function fixture() {
  const doc = new EventTarget()
  doc.defaultView = new EventTarget()
  const rehearsal = {ownerDocument: doc, open: true}
  const calls = []
  const booth = {
    actFire: () => calls.push("fire"), actPostpone: ms => calls.push(ms),
    actCancel: () => calls.push("cancel"), actAuto: () => calls.push("auto"),
    engine: {snapshot: () => ({xfadePos: .5}), setCrossfader: pos => calls.push(pos)}
  }
  const release = mountBoothKeyboard(booth, rehearsal)
  function dispatch(hub, type, target, key) {
    const event = new Event(type, {cancelable: true})
    Object.defineProperty(event, "target", {get: () => target})
    event.key = key
    hub.dispatchEvent(event)
    return event.defaultPrevented
  }
  const body = {tagName: "BODY"}
  const slider = {tagName: "INPUT", type: "range", focus: () => { doc.activeElement = slider }, blur: () => { doc.activeElement = body }}
  const pointerUp = () => dispatch(doc, "pointerup", slider)
  const key = k => dispatch(doc.defaultView, "keydown", doc.activeElement, k)
  return {doc, rehearsal, slider, body, pointerUp, key, calls, release}
}

test("a rehearsal slider stays focused after a pointer adjustment so arrows still go to that control", () => {
  const {doc, slider, body, pointerUp, key, calls} = fixture()
  doc.activeElement = body
  pointerUp()
  assert.equal(doc.activeElement, slider)
  assert.equal(key("ArrowRight"), false)
  assert.deepEqual(calls, [])
})

test("the booth leaves every rehearsal shortcut alone and resumes its controls after the dialog closes", () => {
  const {doc, rehearsal, slider, body, pointerUp, key, calls, release} = fixture()
  for (const target of [slider, {tagName: "BUTTON"}, body]) {
    doc.activeElement = target
    for (const k of ["T", "w", "x", "a", "ArrowLeft", "ArrowRight"]) assert.equal(key(k), false)
  }
  assert.deepEqual(calls, [])
  rehearsal.open = false
  doc.activeElement = slider
  assert.equal(key("ArrowRight"), false)
  pointerUp()
  assert.equal(doc.activeElement, body)
  for (const k of ["T", "w", "w", "x", "a", "ArrowLeft", "ArrowRight"]) assert.equal(key(k), true)
  assert.deepEqual(calls, ["fire", 1000, 1000, "cancel", "auto", .44, .56])
  release()
  doc.activeElement = slider
  pointerUp()
  assert.equal(doc.activeElement, slider)
  doc.activeElement = body
  assert.equal(key("T"), false)
})
