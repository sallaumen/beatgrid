// System aliases can move to another speaker before devicechange is delivered.
const isAlias = id => id === "default" || id === "communications"

export function separateOutputs(mainId, phonesId, outputs) {
  const main = outputs.find(device => device.deviceId === (mainId || "default"))
  const phones = outputs.find(device => device.deviceId === phonesId)
  if (!main || !phones || isAlias(phonesId) || main.deviceId === phonesId) return false
  return !isAlias(main.deviceId) || Boolean(main.groupId && phones.groupId && main.groupId !== phones.groupId)
}

export function headphoneOutput(mainId, choice, outputs) {
  let id = choice
  if (isAlias(choice)) {
    const group = outputs.find(device => device.deviceId === choice)?.groupId
    if (!group) return null
    const matches = outputs.filter(device => !isAlias(device.deviceId) && device.groupId === group)
    if (matches.length !== 1) return null
    id = matches[0].deviceId
  }
  return separateOutputs(mainId, id, outputs) ? id : null
}

// The caller serializes sink changes and revalidates the route after each
// browser promise. A rejected switch may still leave the previous sink active.
export async function activateHeadphones(audio, stream, device, previous, allowed) {
  const choices = previous && previous !== device ? [device, previous] : [device]
  for (const id of choices) {
    if (!allowed(id)) continue
    try {
      if (audio.sinkId !== id) await audio.setSinkId(id)
      if (!allowed(id)) continue
      audio.srcObject = stream
      await audio.play()
      if (allowed(id)) return id
    } catch {
      // A device, permission or play failure can still leave a safe fallback.
    }
    audio.pause()
    audio.srcObject = null
  }
  return null
}

export async function unlockOutputNames(devices) {
  let timeout
  try {
    // Permission can arrive after enumeration has already continued.
    const probe = devices.getUserMedia({audio: true}).then(stream => {
      for (const track of stream.getTracks()) track.stop()
    })
    await Promise.race([probe, new Promise(resolve => { timeout = setTimeout(resolve, 3000) })])
  } catch {
    // Device enumeration can continue without permission.
  } finally {
    clearTimeout(timeout)
  }
}

// A named room can disappear while AudioContext keeps its sinkId. An inventory
// or a returning device cannot grant permission to resume a different room.
export function watchRoomOutput(ctx, available) {
  let devices = [], known = null, missing = null, version = 0
  const current = () => ctx.sinkId === "default" ? "" : ctx.sinkId || ""
  const named = id => id && !isAlias(id) ? devices.find(d => d.deviceId === id) ?? null : null

  function interrupt() {
    if (!known) return
    version++
    if (missing) return
    missing = known
    available(false)
  }

  return {
    get missing() { return missing },
    choice() { return ++version },
    interrupt,
    observe(next) {
      if (typeof ctx.setSinkId !== "function") return
      devices = next
      if (!missing && known && (known.deviceId !== current() || !named(known.deviceId))) interrupt()
      if (!missing) known = named(current())
    },
    async selected(id, request) {
      if (request !== version || id !== current()) return false
      if (missing) {
        if (id && !devices.some(d => d.deviceId === id)) return false
        try {
          if (ctx.state !== "running") await ctx.resume()
        } catch {
          return false
        }
        if (request !== version || id !== current() || ctx.state !== "running" ||
            (id && !devices.some(d => d.deviceId === id))) return false
        missing = null
        available(true)
      }
      known = named(id)
      return true
    }
  }
}
