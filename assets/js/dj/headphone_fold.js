// One-ear monitoring uses L * (1 - |r|) + R * r. Keeping absolute gains at
// unity prevents summing two identical channels 6 dB above the stereo mix.
const WINDOW = 0.04
const RAMP = 0.008
const profiles = new WeakMap()

function rightShare(left, right, start, end, previous) {
  let leftPower = 0, rightPower = 0, cross = 0
  // Sample just the record interval that will play. Paired adjacent samples
  // keep a periodic tone at the sampling stride from landing entirely on zeros.
  const step = Math.max(2, Math.floor((end - start) / 64))
  for (let i = start; i < end; i += step) {
    for (let j = i; j < Math.min(i + 2, end); j++) {
      const l = left[j], r = right[j]
      leftPower += l * l
      rightPower += r * r
      cross += l * r
    }
  }
  if (leftPower + rightPower < 1e-12) return previous
  const relativePower = Math.min(leftPower, rightPower) / Math.max(leftPower, rightPower)
  if (relativePower < 0.0001) {
    // Give a one-sided recording its original level; ease in the second
    // channel continuously as it emerges from more than 40 dB below the first.
    const quietShare = 0.5 * Math.sqrt(relativePower / 0.0001)
    const share = rightPower > leftPower ? 1 - quietShare : quietShare
    return previous < 0 ? -share : share
  }
  // Flip only for a strongly opposed pair. Hysteresis keeps weakly correlated
  // instruments on a stable fold as their relative levels change.
  const threshold = previous < 0 ? -0.4 : -0.8
  return cross < threshold * Math.sqrt(leftPower * rightPower) ? -0.5 : 0.5
}

// The bin identifies a reversal; locate the switch inside it. A quantized
// 40 ms flip can briefly cancel a note or create a click at the boundary.
function polarityBoundary(left, right, from, to, previous) {
  let covariance = 0, best = 0, boundary = from
  const step = Math.max(1, Math.floor((to - from) / 512))
  const direction = Math.sign(previous)
  for (let i = from; i < to; i += step) {
    covariance += left[i] * right[i] * direction
    if (covariance > best) {
      best = covariance
      boundary = Math.min(to, i + step)
    }
  }
  return boundary
}

// While the PCM already belongs to the waveform decoder, keep only the few
// record-time coefficient changes. Playback and pitch edits never reopen a
// multi-minute AudioBuffer to inspect a several-second excerpt.
export function prepareHeadphoneFold(buffer, left, right) {
  const knots = []
  const sr = buffer.sampleRate, windowFrames = Math.max(1, Math.round(WINDOW * sr))
  const add = (frame, share) => {
    const last = knots.at(-1)
    const time = Math.max(last?.time ?? 0, Math.min(left.length, frame) / sr)
    if (last?.time === time) last.share = share
    else knots.push({time, share})
  }
  let previous = 0.5
  for (let start = 0; start < left.length; start += windowFrames) {
    const end = Math.min(left.length, start + windowFrames)
    const next = rightShare(left, right, start, end, previous)
    if (start === 0) add(0, next)
    else if (next !== previous) {
      const reversed = previous * next < 0
      const change = reversed ? polarityBoundary(left, right, start - windowFrames, end, previous) : start
      add(change - RAMP * sr, previous)
      // Cross opposite polarities through the unchanged left channel.
      if (reversed) add(change, 0)
      add(change + RAMP * sr, next)
    }
    previous = next
  }
  profiles.set(buffer, knots)
  return knots
}

function shareAt(before, after, time) {
  if (!after) return before.share
  return before.share + (after.share - before.share) * (time - before.time) / (after.time - before.time)
}

export function scheduleHeadphoneFold(leftGain, rightGain, buffer, at, offset, duration, rate) {
  const knots = profiles.get(buffer) ?? prepareHeadphoneFold(buffer, buffer.getChannelData(0), buffer.getChannelData(1))
  let low = 0, high = knots.length
  while (high - low > 1) {
    const mid = (low + high) >>> 1
    if (knots[mid].time <= offset) low = mid
    else high = mid
  }
  const end = offset + duration * rate
  const initial = shareAt(knots[low], knots[low + 1], offset)
  leftGain.setValueAtTime(1 - Math.abs(initial), at)
  rightGain.setValueAtTime(initial, at)
  for (let i = low + 1; i < knots.length && knots[i - 1].time < end; i++) {
    const time = Math.min(knots[i].time, end)
    const share = shareAt(knots[i - 1], knots[i], time)
    const when = at + (time - offset) / rate
    leftGain.linearRampToValueAtTime(1 - Math.abs(share), when)
    rightGain.linearRampToValueAtTime(share, when)
  }
}

export function connectHeadphoneFold(ctx, input, monitor, buffer, at, offset, duration, rate) {
  if (buffer.numberOfChannels !== 2) {
    input.connect(monitor)
    return []
  }
  const split = ctx.createChannelSplitter(2), left = ctx.createGain(), right = ctx.createGain()
  scheduleHeadphoneFold(left.gain, right.gain, buffer, at, offset, duration, rate)
  input.connect(split)
  split.connect(left, 0)
  split.connect(right, 1)
  left.connect(monitor)
  right.connect(monitor)
  return [split, left, right]
}
