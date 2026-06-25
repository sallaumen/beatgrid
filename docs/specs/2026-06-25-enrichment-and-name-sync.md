# Beatgrid — Soundcharts enrichment fields + name sync (Phase 3.5)

Date: 2026-06-25 · Status: approved (decisions below)

## Context

After validating the Soundcharts client, a 10-track sample showed two things:

1. **Every imported file name diverges from the cloud canonical.** SpotiDownloader
   names files with the **title only** (no artist), some with a leading space.
   So syncing to `"Artist - Title"` adds real value.
2. **Title-only search yields weak matches for short/ambiguous titles.** E.g.
   `"Baiao"` matched a Wesley Safadão medley. Renaming blindly to an imperfect
   match would write the wrong name — so renaming must be confidence-gated.

The full Soundcharts `object` carries far more than we persist (it's all kept in
`raw`); the question is which fields earn a first-class **column**.

## Decisions

### Fields to add as columns ("Lean+")

On `soundcharts_songs` (rest stays in `raw`):

| Column | Source | Why |
|---|---|---|
| `duration_seconds` | `object.duration` | cross-check vs physical `duration_ms` → truncated-download detector |
| `time_signature` | `audio.timeSignature` | mixing |
| `subgenres` (array) | `genres[].sub` flattened | `"forró"`/`"brasilian music"` (the `root` `"latin"` is too coarse) |
| `sc_artist_uuid` | `mainArtists[0].uuid` | links to canonical artist for future artist-level enrichment |
| `sc_artist_name` | `mainArtists[0].name` | canonical artist name |
| `language_code` | `object.languageCode` | filtering (`pt-BR`) |
| `image_url` | `object.imageUrl` | artwork for the UI |

### Truncated-download detector

On resolution, if both the cloud `duration_seconds` and the physical
`duration_ms` are known and the physical length is materially shorter
(< 80% of cloud), add `:truncated` to the track's `quality_issues`.
"Great data, bad file" becomes a visible flag.

### Match confidence (`tracks.sc_match_confidence`: high | medium | low)

Computed when picking the best search result:

- **high** — normalized credit_name == track.norm_artist **and** normalized
  song name == track.norm_title.
- **medium** — artist confirmed but title differs (medley/variant), **or** title
  exact but artist unknown.
- **low** — fell back to the top hit; neither confirmed.

### Name sync — "precision + auto only high confidence"

- The pick prefers an item matching **both** artist and title; bare top-hit is
  the last resort and marks **low** confidence.
- Canonical filename = `"<credit_name> - <name><ext>"`, filesystem-sanitized
  (`/` `\` `:` → `-`, whitespace collapsed). `/` matters: medley names contain it.
- **high** confidence → file is auto-renamed on resolution (via the existing
  `do_move` primitive, which now also updates `filename`).
- **medium/low** → a **pending `RenameSuggestion`** is created; the user reviews
  and applies in batch (suggest → confirm → apply), with **undo**. Mirrors the
  existing `MoveSuggestion` workflow. Nothing touches disk until approved.

### Operational notes (first run, 2026-06-25)

- The first preview created **11 pending suggestions** but **nothing was applied
  to disk** — renames are deferred for review (e.g. in the future UI).
- Two findings from the real preview: (1) confidence measures *string match*, not
  *correctness* — several `low` proposals were actually correct (multi-artist
  credit order); (2) a medley/compilation `name` (contains `/`) leaked into
  `high` (Soundcharts returns the whole medley title). **TODO before auto-applying:**
  add a medley guard so a `to_filename` containing `/` (pre-sanitization) never
  auto-renames, regardless of confidence.

### Serato caveat

Renames change the file path; Serato references files by path. Renaming is safe
**now** (the library copies are not yet indexed by Serato). Workflow rule:
organize + name-sync fully **before** adding the library to Serato.
