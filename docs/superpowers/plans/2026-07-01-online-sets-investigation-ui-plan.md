# Online Sets Investigation UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Sets online useful for investigating imported DJ sets by showing source metadata clearly and adding segment-to-segment player navigation.

**Architecture:** Keep the current `Beatgrid.Mixes` domain model intact for this pass. Improve `MixesLive` and `MixLive` rendering with existing persisted metadata, and extend the colocated `.MixPlayer` hook to seek to previous/next segment timestamps from the cached mix audio.

**Tech Stack:** Phoenix LiveView, HEEx, colocated LiveView hooks, ExUnit/LiveViewTest, Tailwind utility classes already used by Beatgrid.

---

### Task 1: Online Sets Index Metadata

**Files:**
- Modify: `test/beatgrid_web/live/mixes_live_test.exs`
- Modify: `lib/beatgrid_web/live/mixes_live.ex`

- [ ] **Step 1: Write the failing test**

Add a LiveView test that inserts a ready mix with title, DJ, URL, duration, description, and segments, then asserts the index renders the title, original URL, duration, track count, and library coverage.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/beatgrid_web/live/mixes_live_test.exs`
Expected: the new assertions for metadata fail before the UI is expanded.

- [ ] **Step 3: Implement the index rendering**

Render each mix as an operational row/card with source badge, title, DJ/source, original URL, duration, detected track count, library coverage, imported date, and status/error.

- [ ] **Step 4: Run the focused test**

Run: `mix test test/beatgrid_web/live/mixes_live_test.exs`
Expected: all index tests pass.

### Task 2: Mix Detail Header and Player Navigation

**Files:**
- Modify: `test/beatgrid_web/live/mix_live_test.exs`
- Modify: `lib/beatgrid_web/live/mix_live.ex`

- [ ] **Step 1: Write the failing tests**

Add tests that assert the detail view exposes the original URL and stable player controls with `data-mix-prev`, `data-mix-next`, and segment timestamp data.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/beatgrid_web/live/mix_live_test.exs`
Expected: the new control/metadata assertions fail before implementation.

- [ ] **Step 3: Implement the detail rendering and hook**

Add a richer metadata header, a compact investigation player toolbar, and JavaScript actions that seek the audio element to the previous or next segment based on the current playback position.

- [ ] **Step 4: Run the focused test**

Run: `mix test test/beatgrid_web/live/mix_live_test.exs`
Expected: all detail tests pass.

### Task 3: Verification and Commit

**Files:**
- Verify changed files only, then full project.

- [ ] **Step 1: Build assets**

Run: `mix assets.build`
Expected: Tailwind and esbuild complete successfully.

- [ ] **Step 2: Run full checks**

Run: `mix format --check-formatted && mix test && mix lint`
Expected: format, tests, Credo, Sobelow, and Dialyzer complete successfully.

- [ ] **Step 3: Commit and push**

Run: `git add ... && git commit -m "refine online sets investigation ui" && git push origin main`
Expected: `main` is pushed to origin.
