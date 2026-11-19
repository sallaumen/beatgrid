import assert from "node:assert/strict"
import test from "node:test"
import Player from "../../assets/js/player.js"

const origin = "https://beatgrid.test"

class Media extends EventTarget {
  dataset = {previewOffsetMs: "20000", previewMinMs: "25000"}
  paused = true
  ended = false
  readyState = 0
  duration = NaN
  currentTime = 0
  currentSrc = ""
  src = ""

  load() {
    this.pause()
    this.readyState = 0
    this.duration = NaN
    this.ended = false
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
      this.ended = false
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

function fixture(t, lane = null) {
  const media = new Media()
  const browser = Object.assign(new EventTarget(), {location: {href: origin}})
  const body = {dataset: {}}
  const document = {
    body,
    getElementById: id => id === "player-marker-lane" ? lane : null,
    createElement: () => Object.assign(new EventTarget(), {style: {}}),
  }
  const globals = {window: browser, document}
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

test("a media error during loading releases the set and lets the DJ retry at the preview point", t => {
  const {select, signal, media, pushes} = fixture(t)
  t.mock.method(console, "warn", () => {})
  select("one", {set_id: "baile"})
  media.error = {code: 2}
  media.dispatchEvent(new Event("error"))
  assert.equal(pushes.at(-1)[0], "playback_paused")

  // A failed media resource requires a fresh load for a real retry.
  media.metadata()
  assert.equal(media.paused, true)
  signal("toggle")
  assert.equal(media.readyState, 0)
  media.error = null
  media.metadata()
  assert.equal(media.currentTime, 20)
  assert.equal(media.paused, false)
})

test("a rejected play releases quiet mode only for the still-current track", async t => {
  const {select, media, pushes} = fixture(t)
  t.mock.method(console, "warn", () => {})
  const blocked = []
  media.play = () => new Promise((_, reject) => blocked.push(reject))
  select("one", {set_id: "baile"})
  media.metadata()
  select("two", {set_id: "baile"})
  media.metadata()

  blocked[0](new Error("old attempt"))
  await Promise.resolve()
  assert.equal(pushes.some(([name]) => name === "playback_paused"), false)
  blocked[1](new Error("play was blocked"))
  await Promise.resolve()
  assert.equal(pushes.at(-1)[0], "playback_paused")
})

test("teardown cancels pending audio and a remounted player handles each action once", t => {
  const {hook, select, media, pushes, browser} = fixture(t)
  select("old", {set_id: "baile"})
  hook.destroyed?.()
  media.metadata()
  assert.equal(media.paused, true)

  const oldEvents = pushes.length
  const newEvents = []
  const newHook = Object.assign(Object.create(Player), {
    el: media, pushEvent: (...msg) => newEvents.push(msg), handleEvent() {},
  })
  newHook.mounted()
  select("new")
  media.metadata()
  assert.deepEqual(newEvents.map(([name]) => name), ["now_playing", "playback_playing"])
  assert.equal(pushes.length, oldEvents)
  newHook.destroyed()
  const pause = t.mock.method(media, "pause")
  browser.dispatchEvent(new CustomEvent("beatgrid:playing", {detail: {source: "dj-console"}}))
  assert.equal(pause.mock.callCount(), 0)
})

function end(media) {
  media.paused = media.ended = true
  media.currentTime = media.duration
  media.dispatchEvent(new Event("ended"))
}

function advanceRequest(pushes) {
  return pushes.findLast(([name]) => name === "track_ended")?.[1]
}

test("a delayed advance cannot replace a fresh preview, a stopped player or the booth", t => {
  const {select, signal, media, browser, listeners, pushes} = fixture(t)
  for (const action of ["preview", "stop", "booth"]) {
    select("one", {set_id: "baile"})
    media.metadata()
    end(media)
    const request = advanceRequest(pushes)
    assert.equal(request.track_id, "one")
    assert.equal(request.set_id, "baile")
    assert.equal(typeof request.play_token, "number")
    if (action === "preview") select("one")
    if (action === "stop") signal("stop")
    if (action === "booth") {
      browser.dispatchEvent(new CustomEvent("beatgrid:playing", {detail: {source: "dj-console"}}))
    }
    listeners.play_track({id: "two", src: "/audio/two", set_id: "baile", after_token: request.play_token})
    assert.notEqual(media.src, "/audio/two")
  }
})

test("playing the last track again stays outside the finished set", t => {
  const {select, signal, media, listeners, pushes} = fixture(t)
  select("one", {set_id: "baile"})
  media.metadata()
  end(media)
  const first = advanceRequest(pushes)
  listeners.play_track({id: "two", src: "/audio/two", set_id: "baile", after_token: first.play_token})
  media.metadata()
  assert.deepEqual(pushes.at(-1), ["playback_playing", {track_id: "two", set_id: "baile"}])
  end(media)
  const second = advanceRequest(pushes)
  assert.equal(second.track_id, "two")
  assert.notEqual(first.play_token, second.play_token)
  listeners.player_set_finished({after_token: second.play_token})
  signal("toggle")
  assert.deepEqual(pushes.at(-1), ["playback_playing", {track_id: "two", set_id: null}])
  end(media)
  assert.equal(pushes.filter(([name]) => name === "track_ended").length, 2)
})

test("a pending request still accepts a legacy play_track reply without a token", t => {
  const {select, media, listeners} = fixture(t)
  select("one", {set_id: "baile"})
  media.metadata()
  end(media)
  listeners.play_track({id: "two", src: "/audio/two"})
  media.metadata()
  assert.equal(media.currentSrc, origin + "/audio/two")
  assert.equal(media.paused, false)
})

test("the seek lane keeps only the selected song's markers during rapid track changes", t => {
  const lane = {
    ticks: [],
    set innerHTML(_value) { this.ticks = [] },
    appendChild(button) { this.ticks.push(button) },
  }
  const labels = () => lane.ticks.map(tick => tick.title)
  const {select, media, listeners, pushes} = fixture(t, lane)
  const markers = (id, label) =>
    listeners.player_markers({track_id: id, markers: [{ms: 1000, label}]})
  select("one")
  media.metadata()
  markers("one", "Rabeca")
  assert.deepEqual(labels(), ["Rabeca"])
  select("two", {set_id: "baile"})
  media.metadata()
  assert.deepEqual(labels(), [])
  markers("two", "Refrão")
  markers("one", "Rabeca")
  assert.deepEqual(labels(), ["Refrão"])

  // A set advance may deliver the new markers before the new audio's metadata.
  end(media)
  const request = advanceRequest(pushes)
  listeners.play_track({id: "one", src: "/audio/one", after_token: request.play_token, set_id: "baile"})
  markers("one", "Solo")
  assert.deepEqual(labels(), [])
  media.metadata()
  assert.deepEqual(labels(), ["Solo"])

  // A pre-token server sent the incoming cues first, without a track_id.
  end(media)
  listeners.player_markers({markers: [{ms: 2000, label: "Ponte"}]})
  listeners.play_track({id: "two", src: "/audio/two"})
  media.metadata()
  assert.deepEqual(labels(), ["Ponte"])
})
