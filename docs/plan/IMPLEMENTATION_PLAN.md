# Beatgrid — Implementation Plan

Task-level, phased plan. Follows the playbook adoption checklist (file `11`) and
the design spec (`../specs/2026-06-25-beatgrid-design.md`). Test-first throughout:
write the failing test, make it pass in the domain, refactor, run `mix lint`.

Legend: `[ ]` todo · each phase ends with a **Done when** verification gate.

---

## Phase 0 — Foundation (no API spend)

**Goal:** a booting Phoenix app with Postgres, Oban, the repo wrapper, the quality
gate, and the genre folders seeded.

- [x] `mix phx.new beatgrid --no-mailer` (LiveView + Ecto/Postgres; `--no-mailer` —
      we add Swoosh only if needed). Move generated tree into the repo root.
- [x] `docker-compose.yml` with a Postgres 16 service; `.env.example`; wire
      `config/dev.exs` + `config/test.exs` to it.
- [x] Wrap the repo: `Beatgrid.Repo` with `migration_lock: :pg_advisory_lock`,
      `migration_timestamps: [type: :utc_datetime]`, and stubs for `paginate/2`,
      `inspect_query/1` (fill in as needed).
- [x] Add deps: `oban`, `req`, `uniq` (UUID v7), `ex_machina` (test), `mox` (test),
      `mimic` (test), `credo`, `dialyxir`, `sobelow`, `excoveralls`. (Ask before each
      per AGENTS.md "ask first", then add as a batch.)
- [x] Configure Oban (queues: `default`, `scan`, `soundcharts` [`local_limit: 1`],
      `ai`) in `config/config.exs`; add to the supervision tree.
- [x] `Beatgrid.Application` supervision tree in playbook order (Telemetry → Repo →
      PubSub → Task.Supervisor → Oban → Endpoint), feature-gated with the `add/2` helper.
- [x] `.formatter.exs`, `.credo.exs` (strict), dialyzer PLT config; `mix lint` alias
      (`format --check-formatted` + `credo --all --strict` + `dialyzer` + `sobelow`).
- [x] Test scaffolding: `Beatgrid.DataCase` (sandbox, `oban:`/`properties:` opts),
      `Beatgrid.ConnCase`, `Beatgrid.Factory`, `test/support/mocks.ex`, `test_helper.exs`
      (`Mimic.copy` for `Date`/`DateTime`/`Req`).
- [x] Migration + schema + seed for `genre_folders` (the 6 folders + the user's
      rubric descriptions). `Beatgrid.Library.GenreFolder` + `GenreFolderQuery`.
- [x] `mix beatgrid.init_library` task: create `~/Music/DJ/` with the 6 folders +
      `_Inbox` + `_Quarantine` (idempotent), reading the library root from settings.
- [x] GitHub Actions CI: `mix lint` + `mix test` against a Postgres service.

**Done when:** `docker compose up -d db && mix setup && mix phx.server` boots; `mix
lint` and `mix test` are green; `genre_folders` is seeded; `~/Music/DJ` exists.

---

## Phase 1 — Inventory, quality & dedup (no API spend)

**Goal:** know exactly what we have, what's broken, and what's duplicated — the
highest-value, zero-cost foundation.

- [ ] `Beatgrid.Audio` port: behaviour + `Beatgrid.Audio.Ffprobe` adapter (`System.cmd
      "ffprobe" ... -print_format json`) returning a typed `Beatgrid.Audio.Metadata`
      struct; `Beatgrid.Audio.Mock` wired in `config/test.exs`.
- [ ] `tracks` migration + `Beatgrid.Library.Track` schema (all §5 fields, `Ecto.Enum`
      for `format`/`status`, jsonb for `raw_tags`/`quality_issues`) + constraint helpers.
- [ ] `Beatgrid.Library.TrackQuery` — `list_tracks_by/1`, `get_track_by/1`,
      `fetch_track_by/1` (reducer pattern), plus `pg_trgm` search migration.
- [ ] Normalization: `Beatgrid.Library.Normalize` (downcase, strip accents/punctuation,
      collapse spaces, drop `feat.`/`remaster`/`remix` suffixes) → `norm_artist`/`norm_title`.
      **Property-test it.**
- [ ] `Beatgrid.Library.scan/1` — walk the library root, hash files, read tags, detect
      `quality_issues` (`:missing_tags`, `:low_bitrate`, `:truncated`, `:corrupt`,
      `:not_audio`, `:too_short`, `:silent`), upsert by `rel_path`, mark missing.
- [ ] `Beatgrid.Workers.ScanWorker` (`enqueue/1`, unique). Worker test.
- [ ] `Beatgrid.Dedup`: `duplicate_groups`/`duplicate_members` migrations + schemas +
      `Beatgrid.Dedup.detect/0` (exact hash + fuzzy meta) + keeper heuristic. Tests.
- [ ] `Beatgrid.Workers.DedupWorker`. Worker test.
- [ ] `mix beatgrid.report` task: prints inventory counts, the bad-file list, and the
      duplicate groups (run against the real SpotiDownloader folders as a smoke test —
      read-only; no copying yet).

**Done when:** scanning a temp library populates `tracks` with correct metadata and
quality flags; dedup groups the known duplicates; `mix beatgrid.report` shows a sane
picture of the real 393-file collection. All under `mix test` with no network.

---

## Phase 2 — Import & organization (no API spend)

**Goal:** get tracks into the clean library and into the right folders, by rule +
manual, with full review and undo — before any AI is involved.

- [ ] `Beatgrid.Library.import_from/1` — copy MP3s from a source folder into `_Inbox/`,
      skipping files that duplicate something already in the library (uses Dedup).
      Originals untouched. Records provenance in `source_playlist`.
- [ ] `move_suggestions` migration + `Beatgrid.Organization.MoveSuggestion` schema + query.
- [ ] `Beatgrid.Organization.suggest_by_rule/0` — seed suggestions from the
      source-playlist → genre-folder mapping (e.g. `Baile Forrodélico` → `Forró Psicodélico`).
- [ ] `Beatgrid.Organization.apply_batch/1` — for each approved suggestion, `File.rename`
      within the library inside `Repo.transact`, update `tracks.genre_folder` + the
      suggestion status; collect failures without aborting the batch.
- [ ] `Beatgrid.Organization.undo/1` — reverse an applied move (rename back, flip status).
- [ ] `Beatgrid.Library.quarantine/1` — move a track to `_Quarantine/` (bad files,
      rejected duplicates); never `File.rm`.
- [ ] mix tasks: `beatgrid.import <source>`, `beatgrid.suggest`, `beatgrid.apply <batch>`,
      `beatgrid.undo <batch>` (interim CLI driver until the LiveView UI exists).

**Done when:** importing a source folder copies non-dup MP3s into `_Inbox`; rule
suggestions land as pending; applying a batch moves files on disk and records undo;
undo restores them; rejected dups land in `_Quarantine`. Filesystem-level tests in temp dirs.

---

## Phase 3 — Soundcharts enrichment (controlled API spend)

**Goal:** enrich kept tracks with BPM, key→Camelot, energy, genre, release date —
under a hard budget, cached forever, dev on sandbox.

- [ ] `Beatgrid.Soundcharts` port: behaviour + `Beatgrid.Soundcharts.Http` (Req) adapter
      + `Beatgrid.Soundcharts.Mock`. `config/runtime.exs` reads `SOUNDCHARTS_APP_ID` /
      `SOUNDCHARTS_API_KEY` (sandbox defaults in dev/test).
- [ ] `soundcharts_songs` (+ `soundcharts_artists`) + `api_calls` migrations + schemas.
- [ ] Budget guard: read/record `x-quota-remaining` into `api_calls`; refuse below floor;
      a `Beatgrid.Soundcharts.budget/0` readout ("X/1000 remaining").
- [ ] `Beatgrid.Soundcharts.resolve_track/1` — ISRC lookup if present, else
      `search-song-by-name` → best match → optional metadata; cache; link
      `tracks.soundcharts_song_id`. Idempotent (no re-fetch).
- [ ] Camelot derivation (`music_key` + `music_mode` → e.g. `8A`).
- [ ] `Beatgrid.Workers.ResolveSongWorker` (queue `:soundcharts`, `local_limit: 1`,
      unique by `track_id`, budget-guarded). `mix beatgrid.resolve --limit N` (batched).
- [ ] Tests: `Req.Test` stubs with captured sandbox fixtures; assert quota accounting,
      caching (no second call), and budget-floor refusal. **No live calls in tests.**

**Done when:** resolving a batch enriches tracks, writes `api_calls` rows, never
double-fetches, and stops at the floor — all verified against stubbed HTTP.

---

## Phase 4 — Claude classification, enrichment & analytics (Claude tokens)

**Goal:** AI-assisted genre placement, ID3 enrichment, the repertoire dashboard,
gap suggestions, and harmonic "next track".

- [ ] `Beatgrid.AI` port: behaviour (`classify_track/1`, `suggest_gaps/1`) +
      `Beatgrid.AI.ClaudeCli` (default, `System.cmd "claude" ... --json-schema`) +
      `Beatgrid.AI.AnthropicApi` (Req + `x-api-key`) + `Beatgrid.AI.Mock`. Config selector + model setting.
- [ ] `classifications` + `repertoire_suggestions` migrations + schemas + queries.
- [ ] `Beatgrid.AI.classify_track/1` — build the prompt from tags + Soundcharts data +
      the `genre_folders` rubric; parse `{folder, confidence, rationale}`; store a
      classification; create a pending `move_suggestion` (source `:claude`).
- [ ] `Beatgrid.Workers.ClassifyTrackWorker` (queue `:ai`, unique by `track_id`).
- [ ] `Beatgrid.Tagging.write_genre/1` — `ffmpeg -c copy` to set the `genre` tag on the
      MP3 from the resolved folder; verify with a re-probe.
- [ ] `Beatgrid.Repertoire` — analytics queries: counts per folder/decade/artist,
      BPM/energy histograms, unresolved/untagged counts (dashboard data).
- [ ] `Beatgrid.AI.suggest_gaps/1` + `SuggestGapsWorker` — per-folder missing-classics.
- [ ] `Beatgrid.Mixing.suggest_next/1` — Camelot-wheel adjacency + BPM proximity +
      energy delta → ranked compatible tracks. Pure, property-tested.
- [ ] Tests: Mox-stub the AI behaviour (`expect/3`); never call Claude in tests.

**Done when:** classification produces reviewable suggestions from real metadata;
approved genres write back to the MP3; the dashboard queries return correct numbers;
`Mixing.suggest_next/1` ranks sensibly — all under stubbed AI/HTTP.

---

## Phase 5 — LiveView UI (later, from the user's mockups)

**Goal:** the three screens the mockups show — library list, dashboard, track
detail — reading the contexts directly.

- [ ] Library list (search, filters by genre/BPM/key/rating/tags, sortable).
- [ ] Dashboard (totals, BPM distribution, rating histogram, tags breakdown,
      recently added, "to review").
- [ ] Track detail (metadata, Camelot/BPM/energy, rating, tags, personal note,
      similar/"next ideal", and — Phase 2+ — waveform/sections/cue points).
- [ ] Review screen for `move_suggestions` (approve/edit/reject a batch, then apply).

**Done when:** the user can browse, rate, tag, annotate, and drive the
suggest→confirm→apply loop from the browser. Built against the real mockups when provided.

---

## Cross-cutting (every phase)

- Test-first; `mix format` + `mix lint` before each commit; conventional commits.
- New deps / migrations / Oban queues / config / port changes are "ask first".
- Multi-agent **workflows** are a good fit for parallelizable phases (e.g. building
  several independent contexts at once, or an adversarial review pass) — opt in per phase.
