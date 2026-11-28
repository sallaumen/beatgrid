// Booth shortcuts and the pointer-to-keyboard handoff for its faders.
export function mountBoothKeyboard(booth, rehearsal) {
  const doc = rehearsal.ownerDocument
  const keys = e => {
    if (rehearsal.open || e.metaKey || e.ctrlKey || e.altKey) return
    const t = e.target
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT" || t.isContentEditable)) return
    const k = e.key.toLowerCase()
    if (k === "t") {
      booth.actFire()
    } else if (k === "w") {
      // Holding W postpones one second per key repeat.
      booth.actPostpone(1_000)
    } else if (k === "x") {
      booth.actCancel()
    } else if (k === "a") {
      booth.actAuto()
    } else if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
      const pos = booth.engine.snapshot().xfadePos
      booth.engine.setCrossfader(Math.min(1, Math.max(0, pos + (e.key === "ArrowRight" ? 0.06 : -0.06))))
    } else {
      return
    }
    e.preventDefault()
  }
  const finishSlider = e => {
    const t = e.target
    if (t?.tagName !== "INPUT" || t.type !== "range") return
    if (rehearsal.open) t.focus({preventScroll: true})
    else t.blur()
  }
  const events = new AbortController()
  const options = {signal: events.signal}
  doc.defaultView.addEventListener("keydown", keys, options)
  doc.addEventListener("pointerup", finishSlider, options)
  return () => events.abort()
}
