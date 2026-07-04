# Planning Studio 2.0 — real customization + cross-playlist dedup

Date: 2026-07-04 · Branch: `sets/planning-studio`

## Problem

The "Planejar set" panel exposes only a preset dropdown, a mode toggle, and two
number fields. The underlying engine is actually capable (BPM window, harmony,
energy arc, rating, style affinity, exclusions) but almost none of it reaches the
UI, and "Custom" degrades to "use the set's target_style, default arc, no
constraints" — so it feels useless. Re-planning *appends* (silently doubling the
set). The planning code lives in a 793-line `Sets` god-context written early in
the project; the user wants it rebuilt cleanly so he can keep extending it.

Two goals:
1. **Real customization** — expose and extend the engine as a proper studio.
2. **Cross-playlist dedup** — when planning playlist N, exclude the tracks that
   already live in chosen other playlists (chainable, chosen at plan time).

## Architecture — decompose the planner out of the `Sets` god-context

New focused modules under `lib/beatgrid/sets/` (house pattern: thin context +
submodules + Query modules; calculations separated from actions; short funcs):

- **`Sets.PlanConfig`** — an embedded schema (NOT persisted) + changeset that
  validates/normalizes the form params into a typed struct. One place that knows
  the knobs and their defaults/clamps. Pure data. Fields:
  `preset`, `mode` (:tracks|:duration), `track_count`, `duration_minutes`,
  `allow_styles` (whitelist; empty = all), `exclude_styles`, `bpm_min`,
  `bpm_max`, `min_rating`, `arc_shape` (:wave|:rise|:fall|:peak|:steady),
  `avoid_artist_repeat` (bool), `exclude_set_ids` (list of RecSet ids),
  `fill_mode` (:replace|:append).
- **`Sets.Presets`** — extracts `@plan_presets` + lookup/`phase_target_style`.
  A preset is a *starting point*: `Presets.to_config_fields/1` returns the field
  values the UI pre-fills (allow_styles, exclude_styles, arc_shape). The preset's
  multi-phase *style journey* still drives per-slot scoring; `allow_styles` is an
  independent HARD pool filter the user layers on top.
- **`Sets.EnergyArc`** — `plan(count, shape) :: [%{role, target_intensity}]` for
  all five shapes. Owns the arc vocabulary. **Moves `block_plan` out of
  `Mixing`** (arc = planning domain, not the scorer; also avoids a future
  `Mixing`→`Sets` cycle). `Mixing` loses `block_plan/@arc_intensity/middle_waves`;
  callers (`Planner`, `remix`) and the tests move to `EnergyArc`. Pure.
- **`Sets.TransitionChooser`** — extracts `choose_transition` + `choose_by_signal`
  + `choose_close` + `bpm_delta` + `energy_delta` + `pct`. `choose(a, b, out,
  intro) :: {type, reason}`. Pure calculation. `Sets.suggest_transition` (which
  reads markers + builds the map) delegates to it.
- **`Sets.Planner`** — the orchestration action: `run(set, %PlanConfig{}) ::
  {:ok, RecSet.t()}`. Builds the arc (EnergyArc), computes the initial exclude
  set (existing members ∪ cross-set track ids), then walks slots ranking with
  `Mixing.rank` (config → rank opts), applies `avoid_artist_repeat`, appends,
  and **accumulates the exclude in memory** (fixes the current O(n)-query
  re-fetch of members per slot). On `:replace` it clears the set first. Ends by
  connecting all consecutive pairs.
- **`Sets`** (context) — gets thinner: `plan(set, params) :: {:ok, set}` builds a
  `PlanConfig` and calls `Planner.run`; adds `clear/1` and
  `cross_set_track_ids/1`. Keeps append/connect/move/etc.
- **`Library.TrackQuery.mixing_candidates`** — gains an `allow_styles` whitelist
  filter (`genre_folder in ^keys`) alongside the existing `min_rating` /
  `exclude_styles`.
- **`Mixing.rank`** — already supports `bpm_min`/`bpm_max`/`min_rating`/
  `exclude_styles`/`weights`/`harmonic_only`; add `allow_styles` passthrough.
  Otherwise unchanged (the scorer is good).

## Energy-arc shapes (`EnergyArc.plan/2`)

Each returns `count` slots `%{role, target_intensity}`:
- `:wave` — current behavior: opener → peak↔respiro waves → fade.
- `:rise` — intensity climbs monotonically opener→peak.
- `:fall` — climbs to an early peak then descends to a low close.
- `:peak` — mountain: rises to a mid-set peak, descends (symmetric).
- `:steady` — flat plateau at a mid-high intensity, gentle opener/close.

Roles stay in the existing vocabulary (`abertura`/`pico`/`respiro`/`queda`) so
the arc chart + remix keep working; each shape maps its slots to sensible roles.

## Data flow

Form submit (`plan_set` / `add_more`) → params →
`Sets.plan(set, params)` → `PlanConfig.from_params/2` (validate) →
`Planner.run(set, config)`:
  1. `fill_mode == :replace` → `Sets.clear(set)`.
  2. `exclude0 = member_ids(set) ∪ cross_set_track_ids(config.exclude_set_ids)`.
  3. `slots = EnergyArc.plan(count, config.arc_shape)`.
  4. reduce over slots, threading `{exclude, used_artists, prev}`:
     `Mixing.rank(rank_opts(config, target_style, target_intensity, exclude,
     prev))` → drop candidates whose artist ∈ used_artists **if any remain** →
     `Enum.random(top_k)` → `append` → update accumulators.
  5. `connect_all(set)`.
→ `{:ok, set}`.

`count` = `track_count` (tracks mode) or `estimate_count_for_duration` (duration
mode), clamped to `[2, max_plan_tracks]`.

## UI (`rec_set_live.ex`)

Rebuild the Planning Studio form, controls always visible:
- **Preset** select → on change, pre-fills the controls (`Presets.to_config_fields`).
- **Tamanho**: mode (Duração min / Nº faixas) + the number field.
- **Estilos**: checkboxes of genre folders (`Library.genre_folders` /
  `@folders`); checked = allowed (empty = all).
- **BPM**: min / max number inputs.
- **Arco de energia**: select of the five shapes.
- **Qualidade**: min rating (0–10) + ☑ "não repetir artista".
- **Não repetir com**: checkboxes of the *other* sets (`@sets` minus current);
  their tracks are excluded this run.
- **Buttons**: "Refazer" (`plan_set`, replace) + "Adicionar" (`add_more`, append).

Both events carry the full form; the handler builds params incl. `fill_mode`.

## Testing (TDD — write tests first, per module)

- `plan_config_test` — defaults, clamps (count/bpm/rating), mode parsing,
  styles/exclude_set_ids list parsing, invalid → safe fallback.
- `energy_arc_test` — for each shape: length == count, role vocabulary, and the
  intensity monotonicity/shape invariant (rise non-decreasing, fall single peak
  then non-increasing, peak symmetric, steady near-constant, wave alternates).
  Move the existing `block_plan` cases here.
- `transition_chooser_test` — the full decision tree (brake/lowpass/echo/filter/
  fade/crossfade/bass_swap/cut). Reuse the asserts from `sets_connections_test`.
- `track_query` — `allow_styles` whitelist filter.
- `planner_test` — integration with `Beatgrid.Factory`: plans N tracks; replace
  clears first; append keeps + adds; cross-set exclusion removes shared tracks;
  avoid_artist_repeat spreads artists when alternatives exist (and still fills
  when they don't); allow_styles + bpm bounds are respected.
- Keep `sets_test` / `mixing_test` green (update the moved `block_plan` refs).

All silent (ExUnit + Postgres; no audio). UI verification: plan a set and read
the entries list — no track playback.

## Non-goals (to fit today)

- A manual multi-phase **style-journey editor** — journeys come from presets;
  Custom uses a fixed allowed-styles whitelist. (Noted as the natural next step.)
- Persisting the plan config on the set — config is per-plan (ephemeral), as the
  user chose ("só na hora de gerar"). No migration.
