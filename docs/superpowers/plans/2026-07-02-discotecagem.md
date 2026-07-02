# Discotecagem — implementation plan

Spec: `docs/superpowers/specs/2026-07-02-discotecagem-design.md`.

## Phase 1 — Sets groundwork (echo type + hints + broadcasts)

- [ ] `Sets`: add `"echo"` to `@transition_types`; `normalize_transition`
      unknown → `"cut"`; `suggest_transition` picks `echo` when markers exist
      and BPMs diverge; expose `transition_types/0`.
- [ ] `Sets`: PubSub `"sets:<id>"` — `subscribe_set/1` + `broadcast_set_changed`
      fired by append/remove/reorder/connect/disconnect/set_transition_type.
- [ ] `Sets.entry_after(set_id, track_id)` — fresh next entry WITH transition +
      the track's effective bpm/duration/markers (the console hint).
      Back-half + duration clamp of `from_ms` at hint build.
- [ ] `rec_set_live`: echo in type picker; `transition_abbrev/title` explicit
      clauses ("eco").
- [ ] Tests: suggestion matrix, normalize, entry_after clamps, broadcasts.

## Phase 2 — console page + engine

- [ ] Route `/discotecagem` + nav entry below Sets.
- [ ] `DiscotecagemLive`: set picker (recent sets), deck assigns (A/B),
      pointer + hint protocol events (`transition_started`, `track_ended`,
      `deck_error`, `console_resync`, `load_deck`), auto toggle, event log
      (last ~12 entries), quiet-mode session activation, NowPlaying updates,
      subscribe to `"sets:<id>"`.
- [ ] `assets/js/dj/engine.js`: AudioContext singleton, per-deck graph
      (source→deckGain→dry/echo(Delay+feedback)→channel→xfade pair→master),
      equal-power crossfader, AnalyserNode meters, transition scheduler
      (cut/fade/crossfade/echo), token guards, `canplay` gating, clamps,
      mutual-exclusion events, cleanup.
- [ ] Colocated `.DjConsole` hook: thin adapter — engine wiring, pushEvents,
      `reconnected()` resync, `destroyed()` teardown.
- [ ] UI: two deck panels (cover/vinyl, position strip canvas with markers,
      time, SYNC/CUE/PLAY, hotcue pads 1–4, pitch + level faders reusing the
      Fader visual language), center column (master + echo knob visual,
      crossfader, AUTO, transition timeline + countdown, event log), right
      rail: set entries list with LOAD A/B per row + browse cursor.

## Phase 3 — MIDI

- [ ] `assets/js/dj/midi_map.js`: DJ2GO2 Touch table (spec values) + decoder.
- [ ] Colocated `.DjMidi` hook: requestMIDIAccess, statechange hot-plug,
      dispatch to engine + throttled pushEvent for on-screen reflection.
- [ ] MIDI monitor panel: status chip + last messages ring buffer.

## Phase 4 — verify & polish

- [ ] LiveView tests: page renders decks, hint flow advances pointer on
      `transition_started`, set-edit broadcast refreshes hint, resync adopts
      client state, error skips.
- [ ] Full suite + lint + CI.
- [ ] `preview_start` + screenshots; iterate on visual quality (the console
      must look like an instrument, not a form).
