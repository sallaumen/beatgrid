// The room passes through a DynamicsCompressor. Measure its lookahead in this
// audio implementation without connecting a test signal to the live context.
const probes = new WeakMap()

export function measuredCompressorDelay(ctx) {
  return probes.get(ctx)?.delay ?? null
}

export function prepareCompressorDelay(ctx) {
  if (probes.has(ctx)) return probes.get(ctx).ready
  const probe = {delay: null}
  probes.set(ctx, probe)
  probe.ready = Promise.resolve().then(async () => {
    const Offline = globalThis.OfflineAudioContext ?? globalThis.webkitOfflineAudioContext
    if (!Offline || !ctx.sampleRate) return
    const length = Math.ceil(ctx.sampleRate * .04) + 64
    const offline = new Offline(1, length, ctx.sampleRate)
    const source = offline.createBufferSource()
    const impulse = offline.createBuffer(1, 64, ctx.sampleRate)
    const input = impulse.getChannelData(0)
    input[1] = .25
    input[33] = -.25
    source.buffer = impulse
    const compressor = offline.createDynamicsCompressor()
    source.connect(compressor)
    compressor.connect(offline.destination)
    source.start()
    const audio = await offline.startRendering()
    const output = audio.getChannelData(0)
    const start = output.findIndex(value => value > .01)
    if (start >= 1 && output[start + 32] < -.01) probe.delay = (start - 1) / ctx.sampleRate
  }).catch(() => {})
  return probe.ready
}
