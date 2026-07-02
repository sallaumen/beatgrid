# Discotecagem — dual-deck DJ console (design)

## Context & problem

Beatgrid's set playback is a single hidden `<audio>` with hard cuts between
tracks. A dual-deck crossfade engine was built ("Parte 4a/4b") and **removed**
(`574f0d0`) after it broke a live gig: the client held a `set_plan` snapshot and
became a second authority over set order, and volume ramps via
`requestAnimationFrame` writing `element.volume` stranded the gain near zero
whenever interrupted. Transition types (`cut/fade/crossfade`) exist as data but
execute nowhere.

The user wants a **Discotecagem** page: a visible DJ console (two decks,
crossfader, echo) inspired by his Numark DJ2GO2 Touch, controllable both from
the UI and from the physical controller over Web MIDI, with an **auto mode**
that plays the chosen set executing real transitions VISIBLY — so he can watch
the algorithm mix and learn from it — including the classic **echo-out**
transition (outgoing track gets a strong feedback delay whose tail rings while
the next track enters).

## Never-again requirements (from the bug post-mortem)

1. The client is NEVER an authority over set order. Server pointer + fresh
   `next_after`-style reads at every boundary; lookahead is a **revocable hint**.
2. Engine code NEVER writes `HTMLMediaElement.volume`. All gain/crossfade/echo
   through WebAudio `GainNode` automation (`linearRampToValueAtTime` etc.) —
   sample-accurate, immune to rAF throttling, cancelable without stranding gain.
3. NEVER swap `src` on an audible element. Two dedicated deck elements; the
   incoming track always loads on the idle deck.
4. NEVER trust `from_ms` blindly: clamp to the back half and to the media
   duration at both hint-build (server) and fire time (client).
5. Single advance authority, one trigger per boundary; `ended` is a deduped
   fallback only.
6. Errors skip (through the same single advance path), never stall.
7. No audible playback before `canplay` on the target deck.
8. The console joins the `beatgrid:playing` mutual-exclusion contract
   (source `"dj-console"`) and `beatgrid:stop`s the global player on takeover.
9. Token-guard every async continuation; every latch releasable by
   error/seek/manual action.
10. Socket loss must not kill the party: the engine finishes what it armed and
    reconciles on reconnect (client truth for audio, server truth for order).

## Decisions (approved)

- **Page**: `/discotecagem`, nav entry "Discotecagem" (short `DJC`,
  `hero-adjustments-vertical`) right below Sets. The page owns its own audio
  surface — the sticky global player is stopped on takeover and untouched
  otherwise.
- **Audio graph** (one lazy `AudioContext`, resumed on first gesture):

  ```
  deck.<audio> → MediaElementSource → deckGain ─┬─ dry ──────────────┐
                                                └─ echoSend → Delay ─┤→ channelOut → xfadeGain → master → destination
                                                      ↺ feedback     │
                                                      (wet loops back into Delay)
  ```

  Crossfader = equal-power pair of `xfadeGain`s driven by one position value.
  Meters via `AnalyserNode` per deck + master (no precomputed waveform in v1;
  a position strip canvas shows progress + intro/outro/cue markers).
- **Advance protocol** ("pointer + revocable hint"):
  - Server (DiscotecagemLive) owns `set_id` + current pointer. It pushes a
    `deck_hint` = next entry (track, src, bpm, duration, markers, transition)
    computed fresh via the Sets context.
  - `Beatgrid.Sets` gains a PubSub topic (`"sets:<id>"`) broadcast on every
    membership/transition mutation; the console re-pulls the hint on any edit,
    swapping the preloaded idle deck if it hasn't fired yet.
  - The client arms the transition at clamped `from_ms`; at fire time it runs
    the transition locally and pushes `transition_started`; the server verifies
    against a fresh `next_after` and answers with the following hint. Edits that
    land DURING an active transition (a window of seconds) take effect on the
    NEXT boundary — bounded, documented staleness.
  - `ended` still advances (deduped by token) — covers cut transitions and
    failure of the scheduler. Deck `error` skips through the same path.
  - On `reconnected()`, the hook pushes `console_resync {track_id, set_id}` and
    the server adopts the client's actual audio state as the pointer.
- **Echo-out transition** (new type `"echo"`):
  - Persisted data stays minimal: `%{"type" => "echo", "from_ms", "to_ms"}`.
  - Engine params (v1 constants in the engine, beat-synced): delay =
    `(60_000 / bpm) * 0.75` ms (dotted eighth; fallback 375ms), feedback 0.55,
    wet ramp 0 → 0.85 over 1.2s while dry ramps to 0; incoming deck starts at
    `to_ms` immediately with a 0.5s fade-in; tail rings ~4 beats, then wet → 0
    and the outgoing media pauses.
  - `suggest_transition/2`: markers present + BPMs close → `crossfade` (as
    today); markers present + BPMs diverging → **`echo`** (echo masks the tempo
    jump — replaces the old `fade` suggestion); `fade` stays selectable
    manually. Unknown types in `normalize_transition` now fall back to `"cut"`
    (safest) instead of silently becoming crossfade.
- **Tempo/SYNC**: SYNC sets the deck's `playbackRate` to match the other deck's
  effective BPM (clamp ±8%, `preservesPitch`). The rate KEEPS for the rest of
  the track (no audible snap-back); resets on next load.
- **Auto vs manual**: AUTO toggle drives scheduled transitions and ANIMATES the
  on-screen console (crossfader glides, echo knob lights, timeline shows the
  armed transition + countdown). Any manual gesture on an automated control
  during a transition cancels that automation (`cancelScheduledValues`) and the
  user finishes the transition by hand; AUTO stays on and the pointer still
  advances. An event log ("Deck B entrou 0:32 · echo 8s") narrates every action
  for learning.
- **MIDI (Web MIDI, Chrome/Edge)**: mapping module for the DJ2GO2 Touch (from
  the Mixxx community mapping): decks ch0/ch1 — play `0x00`, cue `0x01`, sync
  `0x02`, jog touch/turn `0x06` (nudge in v1, not scratch), pitch `CC 0x09`,
  level `CC 0x16`; pads ch4/ch5 — hotcues notes `0x01–0x04` (map to the
  track's first 4 markers), autoloop `0x11–0x14`/sampler `0x31–0x34` reserved;
  master ch15 — crossfader `CC 0x08`, master gain `CC 0x0A`, cue gain `CC 0x0C`
  (reserved, no headphone routing in v1), browse `CC 0x00` + press `0x06`,
  LOAD 1/2 `0x02/0x03` (browse the set list and load onto a deck). Faders are
  last-writer-wins and reflect on screen. Hot-plug via `statechange`. A **MIDI
  monitor** panel shows connection status + the last messages so the mapping
  can be verified live when the device is plugged (it is not connected today).
  Safari/no-MIDI degrades gracefully (UI-only console).
- **Quiet mode**: session-scoped — activate on the console's first play,
  deactivate on stop/leave. No per-boundary churn.
- **NowPlaying**: the console updates the global pointer (screens keep
  highlighting the playing track); `source: "dj-console"` in the
  mutual-exclusion window events.
- **Single-tab assumption** documented for v1 (NowPlaying is global; decks are
  per-tab).

## Out of scope (v1)

Headphone cueing/split output, jog scratching, precomputed waveforms, LED
feedback to the controller, recording the mix, keyboard shortcuts.

## Files

- `lib/beatgrid_web/live/discotecagem_live.ex` (+ colocated `.DjConsole` and
  `.DjMidi` hooks) — page, deck panels, hints protocol.
- `assets/js/dj/engine.js`, `assets/js/dj/deck.js`, `assets/js/dj/midi_map.js`
  — plain ES modules imported via the `@` alias.
- `lib/beatgrid/sets.ex` — `"echo"` type, suggestion rule, set-edit broadcasts,
  console hint API (`entry_after/2`).
- `lib/beatgrid_web/ui.ex` — nav entry.
- `lib/beatgrid_web/live/rec_set_live.ex` — echo in the type picker/badges.
