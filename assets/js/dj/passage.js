// Reserve one loaded pair and follow the outgoing record's clock, including during stalls.
const MAX_LATE_MS = 100
const PCM_LEAD_MS = 64

export function createPassage(decks, available, start, observer = {}) {
  let choice = null, timer = null, abortStart = null, roomAvailable = true

  let startVersion = 0, arrival = null

  function arrive() {
    if (!arrival || arrival.remaining() > 0) return
    const publish = arrival.publish
    arrival = null
    clearTimeout(timer)
    abortStart = null
    choice = null
    publish()
  }

  function stopWaiting(saved = choice) {
    arrival = null
    startVersion++
    if (saved) observer.abandoned?.(saved)
    clearTimeout(timer)
    const abort = abortStart
    abortStart = null
    abort?.()
  }

  function disarm() {
    arrive()
    const saved = choice
    choice = null
    stopWaiting(saved)
  }

  function fail(phase = "failed") {
    if (!choice) return
    choice.phase = phase
    stopWaiting()
  }

  function arm(pair, plan, kind, reference = null, splices) {
    const from = decks[pair.from], to = decks[pair.to]
    const exitMs = Math.round((plan.exit ?? plan.outStart + plan.lead) * 1000)
    if (from.loadToken !== pair.fromLoad || to.loadToken !== pair.toLoad || !available(from, to, plan, kind) ||
        from.positionMs() > exitMs || !(["cut", "blend"].includes(kind) || (kind === "bass_swap" && plan.fullBlend))) return {ok: false}
    disarm()
    choice = {pair, plan, kind, exitMs, phase: "armed", reference, splices}
    return {ok: true}
  }

  function check() {
    const wait = arrival?.remaining()
    if (wait > 0) {
      clearTimeout(timer)
      timer = setTimeout(check, Math.max(1, wait))
      return
    }
    arrive()
    if (!choice) return
    const {pair, phase, exitMs} = choice
    const from = decks[pair.from], to = decks[pair.to]
    if (from.loadToken !== pair.fromLoad || to.loadToken !== pair.toLoad) return disarm()
    if (!roomAvailable || (phase !== "confirmed" && phase !== "armed")) return
    clearTimeout(timer)
    const remaining = exitMs - from.positionMs()
    if (remaining < (phase === "armed" ? 0 : -MAX_LATE_MS)) return fail("missed")
    if (phase === "armed") return
    const leadMs = observer.canSchedule?.(choice) ? PCM_LEAD_MS : 0
    if (remaining / from.playbackRate > leadMs) {
      timer = setTimeout(check, Math.max(10, remaining / from.playbackRate - leadMs))
      return
    }
    if (from.seeking() || !available(from, to, choice.plan, choice.kind)) return fail()
    const saved = choice
    saved.phase = "starting"
    // A late decoder must never fade the room after the rehearsed beat has gone by.
    timer = setTimeout(fail, MAX_LATE_MS + Math.max(0, remaining / from.playbackRate))
    const version = ++startVersion
    abortStart = start(from, to, saved, (ok, startAudio, scheduled) => {
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
      if (scheduled) {
        arrival = scheduled
        timer = setTimeout(check, Math.max(0, scheduled.remaining()))
      } else {
        abortStart = null
        choice = null
      }
      return true
    }, remaining > 0 && leadMs > 0)
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
    arrive()
    if (choice?.pair.from === deck.id && positionMs >= choice.exitMs) fail("missed")
  }

  function mixChanged(reason = "live") {
    arrive()
    if (!choice || !["armed", "confirmed", "starting"].includes(choice.phase)) return
    if (reason === "draft" && choice.phase === "armed") return
    stopWaiting()
    choice.phase = "armed"
    choice.review = reason
  }

  function setRoomAvailable(next) {
    arrive()
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
    arrive()
    if (roomAvailable) disarm()
    else fail("missed")
  }

  return {arm, confirm, disarm, check, seek, fail, mixChanged, setRoomAvailable, sourceEnded, arrive, current: () => choice}
}
