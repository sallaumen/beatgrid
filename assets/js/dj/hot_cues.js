// Each pad recalls a position. Keep coincident intro/outro markers in the
// track data for transition timing, but give their beat only one pad.
export function hotCues(markers, durationMs = Infinity) {
  const positions = new Map()
  for (const marker of markers || []) {
    if (!Number.isInteger(marker.ms) || marker.ms < 0 || marker.ms >= durationMs) continue
    const existing = positions.get(marker.ms)
    if (!existing || (existing.source === "auto" && marker.source !== "auto")) {
      positions.set(marker.ms, marker)
    }
  }
  return Array.from(positions.values()).sort((a, b) => a.ms - b.ms).slice(0, 4)
}
