# Beatgrid — Phase 4: AI classification, analytics & mixing

Date: 2026-06-25 · Status: approved (decisions below) · extends `docs/plan/IMPLEMENTATION_PLAN.md`

## Decisions

- **Scope of AI classification:** re-classify **all** resolved tracks to refine the 6
  genre folders (the rule-based import is coarse — e.g. 0 in *Forró Clássico*). The AI
  proposes a change only where it **disagrees** with the current folder, as a pending
  `MoveSuggestion` (source `:claude`) — reusing the existing approve → apply → undo flow.
  **Nothing moves on disk until approved.**
- **Batch classification:** classify ~15 tracks per `claude` call (337 single calls would
  be far too slow). One structured response per batch.
- **AI transport:** `Beatgrid.AI.ClaudeCli` via `System.cmd("claude", ["-p", prompt,
  "--output-format", "json", "--json-schema", schema, "--model", model])` — the Max-plan
  CLI (ToS-compliant), confirmed to support `-p` / `--output-format json` / `--json-schema`.
  Tests always stub the `Beatgrid.AI` behaviour (Mox); never call `claude`.
- **ID3 write-back:** **in scope.** `Beatgrid.Tagging.write_genre/1` writes the genre tag
  to the MP3 (ffmpeg `-c copy`, verify by re-probe) — applied when a placement is approved.
- **Build order:** **pure features first** (no AI, no waiting, no quota):
  1. `Beatgrid.Mixing.suggest_next/2` — Camelot adjacency + BPM proximity + energy delta.
  2. `Beatgrid.Repertoire` — dashboard analytics queries.
  3. `Beatgrid.AI` port + batch classification + `ClassifyTrackWorker`.
  4. `Beatgrid.Tagging.write_genre/1` (ID3 write-back on approval).
  5. `Beatgrid.AI.suggest_gaps/1` — per-folder missing classics.

## Harmonic compatibility (Camelot)

Two tracks mix harmonically when their Camelot codes are: identical, ±1 on the wheel
(same letter, wrapping 12↔1), or relative major/minor (same number, A↔B). `suggest_next`
ranks compatible candidates by Camelot tier, then BPM closeness (within a tolerance), then
energy delta.
