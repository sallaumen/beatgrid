import assert from "node:assert/strict"
import test from "node:test"
import Player from "../../assets/js/player.js"

const origin = "https://beatgrid.test"

class Media extends EventTarget {
  dataset = {previewOffsetMs: "20000", previewMinMs: "25000"}
  paused = true
  readyState = 0
  duration = NaN
  currentTime = 0
  currentSrc = ""
  src = ""

  load() {
    this.pause()
    this.readyState = 0
    this.duration = NaN
    this.currentTime = 0
  }

  metadata(seconds = 90) {
    this.readyState = 1
    this.duration = seconds
    this.currentSrc = new URL(this.src, origin).href
    this.dispatchEvent(new Event("loadedmetadata"))
  }

  play() {
    if (this.paused) {
      this.paused = false
      this.dispatchEvent(new Event("play"))
    }
    return Promise.resolve()
  }

  pause() {
    if (!this.paused) {
      this.paused = true
      this.dispatchEvent(new Event("pause"))
    }
  }

  removeAttribute(name) { delete this[name] }
}

function fixture(t) {
  const media = new Media()
  const browser = Object.assign(new EventTarget(), {location: {href: origin}})
  const body = {dataset: {}}
  const globals = {window: browser, document: {body, getElementById: () => null}}
  for (const [key, value] of Object.entries(globals)) {
    const old = Object.getOwnPropertyDescriptor(globalThis, key)
    Object.defineProperty(globalThis, key, {configurable: true, value})
    t.after(() => old ? Object.defineProperty(globalThis, key, old) : delete globalThis[key])
  }
  const pushes = []
  const listeners = {}
  const hook = Object.assign(Object.create(Player), {
    el: media,
    pushEvent(name, params) { pushes.push([name, params]) },
    handleEvent(name, fn) { listeners[name] = fn },
  })
  hook.mounted()
  const select = (id, params = {}) => {
    media.dispatchEvent(new CustomEvent("beatgrid:play", {
      detail: {id, src: "/audio/" + id, preview: true, ...params},
    }))
  }
  const signal = name => media.dispatchEvent(new Event("beatgrid:" + name))
  return {hook, select, signal, media, browser, body, pushes, listeners}
}

test("closing a preview before metadata arrives never starts the hidden player", t => {
  const {select, signal, media, pushes} = fixture(t)
  select("one", {set_id: "baile"})
  signal("stop")
  media.metadata()
  assert.equal(media.paused, true)
  assert.equal(pushes.some(([name]) => name === "playback_playing"), false)
})

test("the booth can take over while the sticky preview is still loading", t => {
  const {select, browser, media, signal} = fixture(t)
  select("one")
  browser.dispatchEvent(new CustomEvent("beatgrid:playing", {detail: {source: "dj-console"}}))
  media.metadata()
  assert.equal(media.paused, true)
  // The DJ can explicitly resume the preview from its configured offset.
  signal("toggle")
  assert.equal(media.paused, false)
  assert.equal(media.currentTime, 20)
})
