// Numark DJ2GO2 Touch → semantic console actions.
//
// Mapping sourced from the Mixxx community mapping for this controller
// (research notes in docs/superpowers/specs/2026-07-02-discotecagem-design.md):
//   deck buttons/jog on channels 0 (deck A) and 1 (deck B),
//   performance pads on channels 4/5, mixer/browse on channel 15.
//
// decode/1 turns a raw MIDI message into either a semantic action the console
// executes or null (unmapped — still shown raw in the MIDI monitor).

const NOTE_ON = 0x9
const NOTE_OFF = 0x8
const CC = 0xb

const DECK_BY_CHANNEL = {0: "a", 1: "b"}
const PADS_BY_CHANNEL = {4: "a", 5: "b"}

const DECK_NOTES = {
  0x00: "play",
  0x01: "cue",
  0x02: "sync",
  0x06: "jog_touch",
  0x1b: "pfl", // headphone/cue button (capturado ao vivo na DJ2GO2 Touch)
}

const PAD_NOTES = {
  0x01: {type: "hotcue", index: 1},
  0x02: {type: "hotcue", index: 2},
  0x03: {type: "hotcue", index: 3},
  0x04: {type: "hotcue", index: 4},
  0x11: {type: "autoloop", index: 1},
  0x12: {type: "autoloop", index: 2},
  0x13: {type: "autoloop", index: 3},
  0x14: {type: "autoloop", index: 4},
  // Modo MANUAL (0x21-0x24) fica sem mapa de propósito — reservado para loops
  // manuais criativos no futuro; o monitor mostra o cru enquanto isso.
  // Modo SAMPLER repropositado como TECLAS DE SEÇÃO do console: 1 Biblioteca,
  // 2 Fila, 3 Efeitos, 4 Transições — o browse passa a navegar a seção focada
  // e o cue level vira o knob de valor dela. (Notas no padrão 0x01/0x11/0x21/
  // 0x31 dos quatro modos; o monitor mostra o cru se o hardware divergir.)
  0x31: {type: "focus", index: 1},
  0x32: {type: "focus", index: 2},
  0x33: {type: "focus", index: 3},
  0x34: {type: "focus", index: 4},
}

const MASTER_CC = {
  0x08: "crossfader",
  0x0a: "master_gain",
  0x0c: "cue_gain",
  0x00: "browse_turn",
}

const MASTER_NOTES = {
  0x06: "browse_press",
  0x02: "load_a",
  0x03: "load_b",
}

export function decode([status, data1, data2]) {
  const kind = status >> 4
  const channel = status & 0x0f

  if (kind === CC) return decodeCC(channel, data1, data2)
  if (kind === NOTE_ON || kind === NOTE_OFF) {
    return decodeNote(channel, data1, kind === NOTE_ON && data2 > 0)
  }
  return null
}

function decodeCC(channel, cc, value) {
  const deck = DECK_BY_CHANNEL[channel]
  if (deck) {
    if (cc === 0x09) return {type: "pitch", deck, value: value / 127}
    if (cc === 0x16) return {type: "level", deck, value: value / 127}
    if (cc === 0x06) return {type: "jog_turn", deck, delta: value < 64 ? value : value - 128}
    return null
  }

  if (channel === 15 && cc in MASTER_CC) {
    const name = MASTER_CC[cc]
    if (name === "browse_turn") return {type: "browse", delta: value < 64 ? value : value - 128}
    return {type: name, value: value / 127}
  }
  return null
}

function decodeNote(channel, note, pressed) {
  const deck = DECK_BY_CHANNEL[channel]
  if (deck && note in DECK_NOTES) return {type: DECK_NOTES[note], deck, pressed}

  const padDeck = PADS_BY_CHANNEL[channel]
  if (padDeck && note in PAD_NOTES) return {...PAD_NOTES[note], deck: padDeck, pressed}

  if (channel === 15 && note in MASTER_NOTES) return {type: MASTER_NOTES[note], pressed}
  return null
}

export function describe(action) {
  if (!action) return null
  const deck = action.deck ? ` ${action.deck.toUpperCase()}` : ""
  const idx = action.index ? ` ${action.index}` : ""
  const val = action.value != null ? ` ${Math.round(action.value * 100)}%` : ""
  const delta = action.delta != null ? ` ${action.delta > 0 ? "+" : ""}${action.delta}` : ""
  return `${action.type}${deck}${idx}${val}${delta}`
}
