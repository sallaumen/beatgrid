# Scratch volume + level-knobs FX layer

Date: 2026-07-04 · Branch: `dj/level-knobs-fx`

## Motivation

Two small ergonomics wins on the Discotecagem console, both from live use:

1. **The scratched deck is too quiet.** The DJ keeps channel volume at max and
   mixes on the crossfader, so a scratch sits at exactly the music's level and
   gets buried. It should sit *slightly above* the deck's own audio.

2. **The DJ2GO2 Touch has no dedicated FX knobs.** It has three generic level
   knobs (level A, level B, cue gain) that the DJ no longer needs for volume
   (volume stays maxed, mixing happens on the crossfader). Repurpose them as an
   FX layer so filter/echo/tone are reachable from hardware.

## Part 1 — Scratch volume boost

The per-deck scratch worklet connects straight into `decks[id].hpf`, at unity —
same level as the music. Insert a dedicated `scratchGain` GainNode between each
worklet node and the `hpf`, at a fixed `RAMP.scratchGain = 1.5` (≈ +3.5 dB). The
scratch still flows through the deck's filter → fader → crossfader (respects the
mix); it just enters ~3.5 dB louder than the track. One tunable, no new
behavior.

## Part 2 — Level knobs become an FX layer (in the "Efeitos" focus)

The Browse encoder and Load 1/2 keep their current jobs. The change lives
entirely inside the **Efeitos** focus (Pad 3 of the Sampler pad-mode, already
mapped to `setFocusSection("efeitos")`).

### Focus model

Today the Efeitos focus walks all 7 `FX_RING` knobs one at a time with Browse,
and the cue gain edits the focused item. New model:

- The Efeitos focus carries a **focused deck** (`this.focus.deck`, "a" | "b"),
  defaulting to "a" on entry.
- **Browse** no longer steps through items. Left → focus deck A, right → focus
  deck B. The UI outlines the focused deck's three FX knobs.

### Knob remap (only while in the Efeitos focus)

On the **focused deck**:

| Physical knob | MIDI | Controls |
|---|---|---|
| level A | cc 0x16 ch 0 | **Filtro** |
| level B | cc 0x16 ch 1 | **Eco** |
| cue gain | cc 0x0c ch 15 | **Tom** |

Each MIDI knob drives the corresponding on-screen knob's hidden range input and
re-renders it, so the graphical knobs stay the single source of truth (mouse and
MIDI converge on the same control).

Outside the Efeitos focus:

- **level A / level B** are inert — channel volume stays maxed; the crossfader
  is the only volume control. (The on-screen level faders remain mouse-adjustable
  for anyone who wants them, but MIDI no longer moves them and the resting value
  is 100.)
- **cue gain** keeps its existing roles: headphone volume in the list focus,
  transition length in the transitions focus.

### Tom = grave↔agudo tilt EQ

The third slot ("Tom") is today a vinyl-mode on/off toggle. It becomes a
continuous **tilt EQ** knob per deck: left boosts lows / cuts highs, right the
reverse (`setTone(deck, v ∈ [-1, 1])`). It uses its own low-shelf + high-shelf
pair, distinct from the `bass` shelf the bass-swap transition automates, so the
two never fight. The vinyl-mode toggle survives as a small "Vinil" button beside
the knob (unchanged behavior: keylock on/off).

`resetChain` / the incoming-deck neutralize path zero the tone shelves like the
other FX, so a transition never inherits a tilted deck.

## Files

- **assets/js/dj/engine.js**: `scratchGain` node per deck; `toneBass` +
  `toneTreble` shelves in the deck graph + `setTone`; `resetChain`/neutralize
  zero the tone; `RAMP.scratchGain`, `RAMP.toneMaxDb`.
- **lib/beatgrid_web/live/discotecagem_live.ex**: Efeitos focus gains a focused
  deck; `applyMidi` — `level` → filtro/eco of focus deck, `cue_gain` → tom,
  `browse` → switch deck while in Efeitos; `applyMidi` `level` no longer calls
  `setDeckLevel`; a "Tom" knob per deck + a small "Vinil" toggle; focus outline
  highlights the focused deck's FX knobs.
- **assets/js/dj/midi_map.js**: unchanged (level / browse / cue_gain already
  decoded).

## Validation

- **Now, with mouse**: scratch is audibly louder at master; the Tom knob tilts
  the EQ (verify via `preview_inspect`/audio, and the graphical knob renders).
- **When the DJ2GO2 is plugged in**: the level→FX remap and Browse A/B. No
  keyboard shortcut simulates the encoder (the DJ declined adding one), so the
  MIDI path is validated on hardware.

## Non-goals

- The "central / Punch + 2 future controls" idea is deferred — this ships the
  A/B deck FX layer only.
- No change to Browse/Load, jog, pads, transitions, or the scratch DSP.
