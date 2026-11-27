// Keep the horizontal throw at about 2.7 ms of music per pixel on either platter.
export function wireJogDrag(el, engine, deck) {
  const listeners = new AbortController()
  const options = {signal: listeners.signal}
  let contact = null, lastX = 0

  function release() {
    if (contact === null) return
    const id = contact
    contact = null
    if (el.hasPointerCapture(id)) el.releasePointerCapture(id)
    el.classList.remove("dj-scratching")
    engine.jogTouch(deck, false)
  }

  el.addEventListener("pointerdown", e => {
    if (e.button !== 0 || contact !== null || engine.decks[deck].trackId == null) return
    el.setPointerCapture(e.pointerId)
    contact = e.pointerId
    lastX = e.clientX
    engine.resume()
    engine.jogTouch(deck, true, e.timeStamp)
    el.classList.add("dj-scratching")
    e.preventDefault()
  }, options)
  el.addEventListener("pointermove", e => {
    if (e.pointerId !== contact) return
    engine.jogTurn(deck, (e.clientX - lastX) * 0.36, e.timeStamp)
    lastX = e.clientX
  }, options)
  for (const type of ["pointerup", "pointercancel", "lostpointercapture"]) {
    el.addEventListener(type, e => { if (e.pointerId === contact) release() }, options)
  }
  el.ownerDocument.defaultView.addEventListener("blur", release, options)
  return () => { release(); listeners.abort() }
}
