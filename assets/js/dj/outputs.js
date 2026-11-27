// Default and communications can be aliases of a named stereo output.
export function separateOutputs(mainId, phonesId, outputs) {
  const main = outputs.find(device => device.deviceId === (mainId || "default"))
  const phones = outputs.find(device => device.deviceId === phonesId)
  if (!main || !phones || main.deviceId === phones.deviceId) return false

  const alias = id => id === "default" || id === "communications"
  if (!alias(main.deviceId) && !alias(phones.deviceId)) return true
  return Boolean(main.groupId && phones.groupId && main.groupId !== phones.groupId)
}
