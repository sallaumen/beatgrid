# Beatgrid — Design Spec

> Date: 2026-06-25 · Status: **for review** (pre-implementation)
> Follows the Elixir/Phoenix Architecture & Quality Playbook in `../playbook/`.

## 1. Goal

Build a local-first tool that turns a pile of downloaded MP3s into a clean,
queryable, well-organized DJ library — and acts as an ongoing, AI-assisted
collaborator for curating that library before and between gigs.

Concretely, Beatgrid must:

1. **Map** every audio file under a library root (tags, bitrate, duration, …).
2. **Quarantine bad files** (corrupt, truncated, untagged, low-bitrate, not-audio).
3. **Deduplicate** — the same song appears across many source playlists.
4. **Organize** tracks into genre folders, where moving in the app moves on disk.
5. **Enrich** with music data from Soundcharts (BPM, key, energy, release date, genre).
6. **Classify** each track into a genre folder using Claude + the enriched data.
7. **Map the repertoire** — dashboards of balance, and AI-suggested missing classics.
8. Support the DJ workflow the mockups show: per-track **rating**, **custom tags**,
   **personal notes**, **Camelot key**, and **harmonic "next track" suggestions**.

## 2. Decisions (locked with the user)

| Topic | Decision |
|---|---|
| Source of truth | **The filesystem.** DB is a knowledge layer over the files. |
| Library model | One clean **dedicated library** at `~/Music/DJ/` with genre subfolders. |
| Database | **PostgreSQL** (via Docker Compose locally) + Ecto. |
| Async engine | **Oban** (OSS) — scan, resolve, classify, dedup, gaps as workers. |
| AI power | **The app calls Claude itself**, in background — see §8.2 for auth. |
| AI auth | Default: official **`claude` CLI** (Max plan, no API key). Alt: API key. |
| Organization automation | **Suggest → confirm in batch → apply** (+ undo). Never silent. |
| Import strategy | **Copy** from source playlists into the library; originals preserved. |
| Web UI | **LiveView**, built later from the user's own mockups. Backend first. |
| Project name | **Beatgrid** (record *crate* + `-ex` for Elixir). One rename if disliked. |
| Language | App is **English**; user data (genres/tags/notes) stays as typed. |

### The data we are organizing (measured)

- **393 MP3s, all 320 kbps**, across 7 `SpotiDownloader.com - *` folders.
- ID3 tags present (title/artist/album); **genre empty**; **no ISRC** (0/12 sampled).
- ≥ 37 titles duplicated across folders (real number is higher with spelling variants).
- At least one broken item already found (`Aquelas Coisas` is a folder, not a file).

## 3. The core principle — disk is the source of truth

Beatgrid is a *librarian*, not a vault. The canonical library is:

```
~/Music/DJ/
├── MPB/
├── Forró/
├── Forró In The Light/        # romantic, not necessarily forró
├── Forró Clássico/
├── Forró Roots/               # older, slightly different musicality
├── Forró Psicodélico/         # forró with electronic elements
├── _Inbox/                    # imported-but-unclassified tracks
└── _Quarantine/               # bad files & rejected duplicates (never deleted)
```

You point Serato at `~/Music/DJ/`. The 6 genre folders carry the user's own
descriptions (the *classification rubric*, stored in the `genre_folders` table)
which feed the Claude prompt. The structural folders `_Inbox` / `_Quarantine`
are app-owned. Moving a track between folders in Beatgrid performs a `File.rename`
on disk inside a DB transaction; Serato/Finder see it immediately.

## 4. Architecture

### 4.1 Stack

Elixir 1.19 / OTP 27 · Phoenix 1.8 + LiveView 1.2 · PostgreSQL + Ecto 3.13 ·
Oban 2.23 · Req (HTTP) · `ffprobe`/`ffmpeg` (audio metadata) · Soundcharts API ·
Claude. Quality gate: `mix format` + credo --strict + dialyzer + sobelow.

### 4.2 Layering (per playbook, scaled down)

```
lib/beatgrid/                 DOMAIN — bounded contexts (all business logic + queries)
  library/                    Track, TrackQuery, scanner, file ops, genre_folders
  dedup/                      DuplicateGroup, DuplicateMember, detection
  soundcharts/                cache schemas + the budget-guarded port
  ai/                         Classification, RepertoireSuggestion + the Claude port
  organization/               MoveSuggestion + suggest→confirm→apply + undo
  repertoire/                 analytics queries (dashboard)
  mixing/                     harmonic / "next ideal track" (Camelot + BPM + energy)
  tags/                       Tag, TrackTag (user workflow tags)
  tagging/                    ID3 write-back (ffmpeg)
  settings/                   key/value settings
lib/beatgrid/repo.ex          wrapped Ecto repo (pagination, audited writes, inspect_query)
lib/beatgrid/workers/         Oban workers (args = IDs)
lib/beatgrid/audio/           Beatgrid.Audio port (ffprobe adapter + mock)
soundcharts/                Beatgrid.Soundcharts port  (behaviour + Http adapter + Mock)
lib/beatgrid_web/             WEB — endpoint, router, LiveViews (built later from mockups)
```

Inbound edges (LiveView, workers, mix tasks) authorize + translate, then call a
context. Outbound edges (Postgres via `*Query`, Soundcharts, Claude, ffprobe) are
reached through narrow ports. The web/worker layers stay thin.

### 4.3 Runtime topology

`Beatgrid.Application` supervises (in order): Telemetry → `Beatgrid.Repo` →
`Phoenix.PubSub` → `Task.Supervisor` → `Oban` → `BeatgridWeb.Endpoint`. Feature-gated
so a CLI/one-off task run doesn't need the web endpoint.

## 5. Data model (PostgreSQL, UUID v7 PKs, `:utc_datetime`, `Ecto.Enum`)

| Table | Purpose / key fields |
|---|---|
| **tracks** | One row per physical file. `rel_path` (unique), `filename`, `content_sha256`, `file_size_bytes`, `format`, `bitrate_kbps`, `sample_rate_hz`, `channels`, `duration_ms`, ID3 fields (`tag_title/artist/album/album_artist/year/track_no/isrc/genre/comment`), `raw_tags` (jsonb), normalized `norm_artist`/`norm_title` (matching), `source_playlist`, `genre_folder` (nil = `_Inbox`), `status` (`:present`/`:missing`/`:quarantined`), `quality_issues` (jsonb array), `rating` (0..10, nil), `personal_note` (text), `soundcharts_song_id` (FK, nil), `last_scanned_at`. Indexes: unique `rel_path`; `(norm_artist, norm_title)`; `content_sha256`; `genre_folder`; `status`; `pg_trgm` GIN on title/artist for search. |
| **genre_folders** | The 6 target folders **as data**: `key`, `display_name`, `dir_name`, `description` (the user's rubric, fed to Claude), `sort_order`, `color`. Seeded at setup. |
| **soundcharts_songs** | Cache, 1 row per Soundcharts UUID: `sc_uuid` (unique), `isrc`, `name`, `credit_name`, `release_date`, `label`, `genres` (jsonb), audio features (`tempo_bpm`, `music_key`, `music_mode`, `camelot`, `energy`, `valence`, `danceability`, `acousticness`, …), `popularity`, `raw` (jsonb), `fetched_at`. |
| **soundcharts_artists** | Cache: `sc_uuid` (unique), `name`, `country_code`, `genres`, `career_stage`, `raw`, `fetched_at`. (Optional; resolved sparingly to save quota.) |
| **api_calls** | Budget ledger: `provider`, `endpoint`, `method`, `request_params` (jsonb), `http_status`, `quota_remaining`, `success`, `error` (jsonb), `duration_ms`, `occurred_at`. Current quota = latest `quota_remaining`. |
| **tags** | User workflow tags: `name` (unique), `color`, `sort_order`. |
| **track_tags** | Join: `track_id`, `tag_id` (unique pair). |
| **move_suggestions** | The plan + history + undo: `track_id`, `from_rel_path`, `to_genre_folder`, `reason`, `source` (`:rule`/`:claude`/`:dedup`/`:manual`), `confidence`, `status` (`:pending`/`:approved`/`:rejected`/`:applied`/`:failed`/`:undone`), `batch_id`, `applied_at`, `error`. |
| **classifications** | AI opinion history: `track_id`, `suggested_folder`, `confidence`, `rationale`, `model`, `source`, `prompt_version`. |
| **duplicate_groups** / **duplicate_members** | Group: `match_type` (`:exact_hash`/`:fuzzy_meta`), `signature`, `keeper_track_id`, `status`. Member: `group_id`, `track_id`, `is_keeper`. |
| **repertoire_suggestions** | Gaps ("classics that are missing"): `genre_folder`, `suggested_artist`, `suggested_title`, `reason`, `source`, `status` (`:open`/`:acquired`/`:dismissed`). |
| **settings** | key/value (jsonb): library root, Soundcharts budget floor, AI model, etc. |

Each schema is a triad leg: `Beatgrid.Library.Track` + `Beatgrid.Library.TrackQuery`,
`Beatgrid.Dedup.DuplicateGroup` + query, and so on.

## 6. Contexts & responsibilities

- **`Beatgrid.Library`** — scan disk → upsert `tracks`; compute hash; read tags via
  the `Beatgrid.Audio` port; detect quality issues; mark missing files; `import`
  (copy source folders → `_Inbox`); `move_track/2` and `apply_moves/1` (rename +
  DB, transactional, reversible); folder tree + counts.
- **`Beatgrid.Dedup`** — exact (`content_sha256`) and fuzzy (`norm_artist` +
  `norm_title` + duration tolerance) detection → `duplicate_groups` with a
  suggested keeper (highest bitrate → longest → first).
- **`Beatgrid.Soundcharts`** — the budget-guarded port (§8.1).
- **`Beatgrid.AI`** — the Claude port (§8.2): `classify_track/1`, `suggest_gaps/1`.
- **`Beatgrid.Organization`** — assemble a reviewable batch of `move_suggestions`
  (rules + dedup + AI), apply/undo with file ops.
- **`Beatgrid.Repertoire`** — pure Ecto analytics: counts per folder/decade/artist,
  BPM/energy distributions, unresolved/untagged counts (the dashboard).
- **`Beatgrid.Mixing`** — harmonic compatibility: Camelot-wheel adjacency + BPM
  proximity + energy delta → ranked "next ideal track" (the track-detail view).
- **`Beatgrid.Tags`** — user workflow tags + the join.
- **`Beatgrid.Tagging`** — write `genre` (and standardized tags) back into the MP3
  via `ffmpeg -c copy` (the "enrich ID3" feature).
- **`Beatgrid.Settings`** — tunable preferences.

## 7. Background jobs (Oban OSS)

- `Beatgrid.Workers.ScanWorker` — walk the library, upsert tracks.
- `Beatgrid.Workers.DedupWorker` — recompute duplicate groups.
- `Beatgrid.Workers.ResolveSongWorker` — queue `:soundcharts`, `local_limit: 1`,
  `unique` by `track_id`, **budget-guarded** (checks the floor before calling).
- `Beatgrid.Workers.ClassifyTrackWorker` — queue `:ai`, `unique` by `track_id`.
- `Beatgrid.Workers.SuggestGapsWorker` — per-folder repertoire-gap suggestions.

Args carry IDs only; each worker preloads what it needs.

## 8. Integration ports

### 8.1 Soundcharts (the scarce-quota centerpiece)

- Base URL `https://customer.api.soundcharts.com`; headers `x-app-id` + `x-api-key`.
  **Sandbox credentials in dev/test** (documented by Soundcharts) so development
  never spends real quota.
- **Free tier: 1,000 requests total.** Each successful call returns
  `x-quota-remaining`; we persist it to `api_calls`. The client refuses to call
  when remaining < a safety floor (e.g. 50).
- Our MP3s have **no ISRC**, so resolution is `search-song-by-name` (artist +
  title) → pick the best match → optional `get-song-metadata` for full audio
  features ≈ **1–2 calls/track**. With ~280 unique tracks after dedup that is
  ~300–560 calls — within budget if we **dedup first** and resolve in
  user-triggered, budgeted batches ("resolve next 50", with a live "X/1000" readout).
- **Every response is cached forever** (`soundcharts_songs`/`_artists`) and never
  re-fetched. Tests stub HTTP with `Req.Test`.
- The metadata response carries BPM, key/mode (→ Camelot), energy, valence,
  danceability, acousticness, genre, release date — so the harmonic-mixing and
  "next ideal track" features come from the API, not local audio analysis.

### 8.2 AI / Claude — and the auth resolution

The user wants the app to use their **Claude Max plan via login, not an API key**
(as some third-party apps did). Important correction: since ~April 2026 Anthropic
**blocks reusing Max/Pro OAuth tokens in third-party tools** and the Consumer ToS
forbids it. We will **not** extract or embed OAuth tokens.

The legitimate path that achieves the same goal: the app shells out to the
**official `claude` CLI** in headless mode. That is first-party Claude Code usage
running under the user's existing login — fully ToS-compliant. The CLI (verified,
v2.1.177) supports exactly what we need:

```
claude -p "<prompt>" --output-format json --json-schema <schema.json> --model <model>
```

`--json-schema` gives us validated structured output (`{folder, confidence,
rationale}`) directly. So:

- `Beatgrid.AI.ClaudeCli` (**default**) — `System.cmd("claude", [...])`, no API key,
  uses the Max login.
- `Beatgrid.AI.AnthropicApi` (alternative) — raw HTTP via Req with `x-api-key`
  (Elixir has no official Anthropic SDK; raw HTTP is the supported path), model +
  structured output via `output_config.format`. For headless/cloud runs.
- `Beatgrid.AI.Mock` (test).

Selected by `Application.compile_env!`. Model is configurable; default a cheap,
fast model for bulk classification (switchable). Classification runs **after**
Soundcharts resolution, so Claude decides with genre/BPM/era in hand, using each
folder's stored rubric. Output is always a *pending* `move_suggestion` — nothing
moves without approval.

## 9. The organization workflow (suggest → confirm → apply → undo)

1. **Import** — copy eligible source MP3s into `_Inbox/` (dedup at copy time to
   avoid copying obvious duplicates); originals preserved.
2. **Scan** — `_Inbox/` + genre folders → `tracks` rows.
3. **Quality + Dedup** — flag bad files; group duplicates; suggest a keeper.
   *(Zero API spend so far.)*
4. **Resolve** (budgeted) — Soundcharts enrichment for unique, kept tracks.
5. **Classify** — Claude proposes a genre folder per track → pending `move_suggestions`.
6. **Review** — the user approves/edits a batch in the UI (or via a mix task).
7. **Apply** — `File.rename` `_Inbox/track.mp3` → `<genre>/track.mp3`, transactional,
   recorded for **undo**. Rejected duplicates and bad files go to `_Quarantine/`.

## 10. Feature set — v1 vs later

**v1 (backend-first):** scan + tag read + quality flags; dedup; import (copy);
suggest→confirm→apply + undo; Soundcharts resolution (BPM/key/energy/genre/era);
Claude classification; ID3 genre write-back; repertoire analytics + gap
suggestions; rating; user tags; personal notes; Camelot key + harmonic "next
ideal track" (computable from Soundcharts audio features).

**Phase 2+ (heavier audio analysis):** the waveform + detected sections
(intro/build/break/outro) and suggested cue/entry points shown in the mockups —
these need local audio structural analysis (energy-over-time + onset/segmentation)
and are deliberately deferred. The "REC SET" live-set timer is a future idea.

**UI:** the LiveView screens (library list, dashboard, track detail) are built
later from the user's own mockups, reading the contexts above directly.

## 11. Testing strategy (per playbook)

`Beatgrid.DataCase` (Ecto sandbox, `oban: true` option) + `Beatgrid.ConnCase` for
LiveView. ExMachina factories with the `Map.pop_lazy` assoc idiom. **Mox** for the
Soundcharts, AI, and Audio behaviours — wired in `config/test.exs`. `Req.Test`
for any direct HTTP. Temp dirs for filesystem scan/move/copy tests. **Tests never
touch the real Soundcharts quota or call Claude.** Worker tests via `perform_job/2`
and `assert_enqueued/1`.

## 12. Delivery phases

See [`../plan/IMPLEMENTATION_PLAN.md`](../plan/IMPLEMENTATION_PLAN.md) for the
task-level breakdown. The order is chosen so the highest-value, zero-API-spend
work (inventory, quality report, dedup) lands first, and API/AI spend only begins
*after* dedup — so we never waste quota on duplicates.

| Phase | Delivers | API risk |
|---|---|---|
| 0 | Phoenix+Ecto+Postgres+Oban scaffold, repo wrapper, `genre_folders` seed, `mix lint`, CI | none |
| 1 | Scan + tag read + quality flags + dedup → inventory, dup report, bad-file report | none |
| 2 | Import (copy) + rule-seeded organization + suggest→confirm→apply + undo | none |
| 3 | Soundcharts port + budgeted resolution (BPM/key/energy/genre/era) | controlled |
| 4 | Claude classification + ID3 write-back + repertoire analytics + gaps + mixing | Claude tokens |
| 5 *(later)* | LiveView UI from the user's mockups | none |

## 13. Open decisions / risks

- **Name** — `Beatgrid` chosen over the user's loose `SoundEx` suggestion to avoid
  collision with the *Soundex* phonetic algorithm. Trivial rename at this stage.
- **AI model default** — a cheap/fast model is the engineering default for bulk
  classification; final choice is the user's (exposed as config).
- **Soundcharts match accuracy** — name-only matching (no ISRC) can mismatch
  covers/remixes; we keep the `raw` payload and surface low-confidence matches for
  review rather than trusting silently.
- **Duplicate hashing** — v1 uses full-file `content_sha256` (catches identical
  files) + fuzzy metadata (catches same song, different file). Audio-fingerprint
  hashing (decoded-stream hash) is a later enhancement if needed.
- **Postgres** — not currently running on the machine; v1 brings it up via Docker
  Compose. (SQLite was considered and would also work, but Postgres was chosen.)

## 14. Out of scope for v1

GraphQL, a public REST API, webhooks, Broadway/broker pipelines, Elasticsearch,
Cloak encryption, multi-node clustering, the waveform/cue-point analyzer, and the
live-set timer. All are compatible with this architecture if added later.
