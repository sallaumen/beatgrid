# Set Builder Studio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the basic set-count planner with a backend-configurable Planning Studio for long DJ sets.

**Architecture:** Keep business rules in `Beatgrid.Sets`; keep LiveView as parameter translation and rendering. Presets are domain data, duration estimation is a context read, and the existing energy arc plus transition connector remain the composition engine.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, ExUnit, Phoenix LiveViewTest.

---

### Task 1: Preset Configuration

**Files:**
- Modify: `lib/beatgrid/sets.ex`
- Test: `test/beatgrid/sets_test.exs`

- [x] Add failing tests for `plan_presets/0`, Roots Marathon MPB exclusion, and Roots-to-Forro-MPB phased planning.
- [x] Add backend preset maps with keys, names, target styles, exclusions, max tracks, descriptions, and style phases.
- [x] Update `plan_set/3` to read `:preset`, apply phased target style per slot, and pass preset exclusions into ranking.
- [x] Run focused domain tests and verify they pass.

### Task 2: Duration and Long Counts

**Files:**
- Modify: `lib/beatgrid/sets.ex`
- Test: `test/beatgrid_web/live/rec_set_live_test.exs`

- [x] Add failing LiveView tests for planning 70 tracks and estimating a five-hour set.
- [x] Add `max_plan_tracks/0` and `estimate_count_for_duration/2` in `Beatgrid.Sets`.
- [x] Estimate duration from present tracks that fit the preset, with a 3.5 minute fallback and a 240-track cap.
- [x] Run focused LiveView tests and verify they pass.

### Task 3: Planning Studio UI

**Files:**
- Modify: `lib/beatgrid_web/live/rec_set_live.ex`
- Test: `test/beatgrid_web/live/rec_set_live_test.exs`

- [x] Assign `plan_presets` and `max_plan_tracks` in LiveView mount.
- [x] Replace the old 60-capped input with preset, mode, duration, track-count, and summary controls.
- [x] Keep old event parsing resilient while using the new `mode` and `track_count` contract in tests.
- [x] Run the full set-focused test suite and verify it passes.
