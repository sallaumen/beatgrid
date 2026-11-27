// Reserve one loaded pair and follow the outgoing record's clock, including during stalls.
const MAX_LATE_MS = 100

export function createPassage(decks, available, start, observer = {}) {
  let choice = null, timer = null, abortStart = null, roomAvailable = true

  let startVersion = 0

  function stopWaiting(saved = choice) {
    startVersion++
    if (saved) observer.abandoned?.(saved)
    clearTimeout(timer)
    const abort = abortStart
    abortStart = null
    abort?.()
  }

  function disarm() {
    const saved = choice
    choice = null
    stopWaiting(saved)
  }

  function fail(phase = "failed") {
    if (!choice) return
    choice.phase = phase
    stopWaiting()
  }

  function arm(pair, plan, kind, reference = null) {
    const from = decks[pair.from], to = decks[pair.to]
    const exitMs = Math.round((plan.exit ?? plan.outStart + plan.lead) * 1000)
    if (from.loadToken !== pair.fromLoad || to.loadToken !== pair.toLoad || !available(from, to, plan, kind) ||
        from.positionMs() > exitMs || !["cut", "blend"].includes(kind)) return {ok: false}
    disarm()
    choice = {pair, plan, kind, exitMs, phase: "armed", reference}
    return {ok: true}
  }

  function check() {
    if (!choice) return
    const {pair, phase, exitMs} = choice
    const from = decks[pair.from], to = decks[pair.to]
    if (from.loadToken !== pair.fromLoad || to.loadToken !== pair.toLoad) return disarm()
    if (!roomAvailable || (phase !== "confirmed" && phase !== "armed")) return
    clearTimeout(timer)
    const remaining = exitMs - from.positionMs()
    if (remaining < (phase === "armed" ? 0 : -MAX_LATE_MS)) return fail("missed")
    if (phase === "armed") return
    if (remaining > 0) {
      timer = setTimeout(check, Math.max(10, remaining / from.playbackRate))
      return
    }
    if (from.seeking() || !available(from, to, choice.plan, choice.kind)) return fail()
    const saved = choice
    saved.phase = "starting"
    // A late decoder must never fade the room after the rehearsed beat has gone by.
    timer = setTimeout(fail, MAX_LATE_MS)
    const version = ++startVersion
    abortStart = start(from, to, saved, (ok, startAudio) => {
      if (version !== startVersion || choice !== saved || saved.phase !== "starting") return false
      if (!ok || !from.audible() || Math.abs(from.positionMs() - exitMs) > MAX_LATE_MS) {
        fail()
        return false
      }
      try {
        startAudio()
      } catch {
        fail()
        return false
      }
      clearTimeout(timer)
      abortStart = null
      choice = null
      return true
    })
  }

  function confirm() {
    check()
    if (!roomAvailable || choice?.phase !== "armed") return {ok: false}
    const {from, to} = choice.pair
    if (!available(decks[from], decks[to], choice.plan, choice.kind)) return {ok: false}
    choice.review = null
    choice.phase = "confirmed"
    observer.confirmed?.(choice)
    check()
    return {ok: true}
  }

  function seek(deck, positionMs) {
    if (choice?.pair.from === deck.id && positionMs >= choice.exitMs) fail("missed")
  }

  function mixChanged(reason = "live") {
    if (!choice || !["armed", "confirmed", "starting"].includes(choice.phase)) return
    if (reason === "draft" && choice.phase === "armed") return
    stopWaiting()
    choice.phase = "armed"
    choice.review = reason
  }

  function setRoomAvailable(next) {
    if (roomAvailable === next) return
    roomAvailable = next
    if (!choice) return
    if (!next) {
      if (choice.phase === "starting") choice.phase = "confirmed"
      stopWaiting()
    } else {
      if (choice.phase === "confirmed") observer.confirmed?.(choice)
      check()
    }
  }

  function sourceEnded() {
    if (roomAvailable) disarm()
    else fail("missed")
  }

  return {arm, confirm, disarm, check, seek, fail, mixChanged, setRoomAvailable, sourceEnded, current: () => choice}
}
