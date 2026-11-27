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
