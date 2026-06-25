# Beatgrid

A local-first librarian for a DJ music collection (a forró / MPB record bag),
built in Elixir & Phoenix. Beatgrid scans the audio files on disk,
de-duplicates and organizes them into genre folders, enriches each track with
metadata (BPM, key, audio features) from the Soundcharts API, classifies them
with Claude, and gives you a LiveView UI to review and apply every change —
**moving and renaming the real files on disk** so Serato and Finder always
reflect a clean, curated library.

The **filesystem is the source of truth.** Beatgrid reflects and edits the real
folders under a library root (default `~/Music/DJ`); moving a track in Beatgrid
moves the file on disk. The database is a *knowledge layer* over those files —
never their owner, and the music never lives in this repo.

> All code, docs, comments, and UI text are written so the codebase reads in
> **English**; the product UI is in Portuguese. User-entered data (genre names
> like *Forró*, tags, notes) is stored verbatim in whatever language was typed.

---

## Why

Managing a few hundred DJ tracks by hand is tedious and error-prone: duplicates,
inconsistent file names, no key/BPM metadata, and no good way to decide which
song mixes into which. Beatgrid turns that into a reviewable pipeline where every
file-system change is **proposed first, applied in a batch, and reversible**.

---

## Features

| Area | What it does |
| --- | --- |
| **Scan & import** | Walks the library, hashes files (content de-dup), reads ID3 tags via `ffprobe`, flags quality issues (truncated, silent, low-bitrate…). |
| **Organize** | Moves tracks into genre folders. Moving a track in-app moves it on disk. Nothing is ever deleted — bad files go to `_Quarantine`. |
| **Enrich (Soundcharts)** | Resolves each track to a Soundcharts song and pulls BPM, musical key (Camelot), energy/valence/danceability, genres, ISRC, label, year. Quota-aware budget guard. |
| **Name-sync** | Proposes canonical `Artist - Title.mp3` file names from the matched metadata, with a match-confidence level. |
| **AI classification** | Classifies every track into the right genre folder via the `claude` CLI (structured JSON output), producing reviewable suggestions. |
| **Harmonic mixing** | "Next ideal track" suggestions using the Camelot wheel (compatible keys + nearby BPM). |
| **Review & apply** | A LiveView **Central de Revisão**: approve / edit / reject rename, classification, and audit suggestions, then apply the approved batch to disk — with an ID3 genre write and full **undo**. |
| **Analytics** | A **Painel** dashboard: headline KPIs, genre/decade distribution, top artists, BPM histogram, and AI repertoire-gap suggestions. |
| **Set-builder (REC SET)** | Assemble a harmonic set — seed track → ranked harmonic candidates → append or auto-fill — and export it as an `.m3u` playlist Serato/VLC read directly. |

### The review workflow

The heart of the app is the **Central de Revisão** (`/revisao`):

1. **Three queues** — *Renomeações* (file renames), *Classificação* (AI folder
   moves, with the model's rationale), and *Auditoria* (matches flagged as
   suspicious during an adversarial metadata audit).
2. **Per-card decisions** — approve (green), edit the target, or reject. Clicking
   again toggles back to pending. Plus "approve all high-confidence" per tab.
3. **Apply to disk** — one button applies every approved suggestion: renames
   files, moves them into genre folders, and writes the ID3 genre tag. The work
   runs asynchronously so the UI stays responsive.
4. **Undo** — every disk mutation is logged to an `operations` table
   (`kind / from / to / status / batch_id`). The toast's *Desfazer* reverts the
   whole batch by delegating back to the owning context — one durable source of
   truth for "what changed and how to undo it".

---

## Architecture

Beatgrid follows a small, consistent set of conventions (the Elixir/Phoenix
Architecture & Quality Playbook in `docs/playbook/`):

- **Triad per domain** — a context (`Beatgrid.Organization`), its schema
  (`MoveSuggestion`), and a dedicated query module (`MoveSuggestionQuery`). Reads
  live in the query module; mutations in the context.
- **Ports & adapters** — every external integration is a behaviour with a real
  adapter, a Mox mock, and a compile-time selector:

  | Port | Real adapter | Mock |
  | --- | --- | --- |
  | `Beatgrid.Audio.Behaviour` | `Audio.Ffprobe` (ffprobe) | `Audio.Mock` |
  | `Beatgrid.Soundcharts.Client` | `Soundcharts.Http` (Req) | `Soundcharts.Mock` |
  | `Beatgrid.AI.Client` | `AI.ClaudeCli` (`claude` CLI) | `AI.Mock` |
  | `Beatgrid.Tagging.Writer` | `Tagging.Ffmpeg` (ffmpeg `-c copy`) | `Tagging.Mock` |

- **Errors as data** — functions return `{:ok, _}` / `{:error, reason}`; batch
  operations report `%{applied: n, failed: m}` and never abort on one failure.
- **Reversible disk I/O** — every file move writes-beside-then-renames (atomic,
  never clobbers), recorded in the `operations` log for undo.
- **UUID v7 primary keys** (`Uniq.UUID`), `Ecto.Enum` status fields, Oban jobs.
- **TDD + a strict quality gate** — `mix lint` runs `format --check`, `credo
  --strict`, `sobelow`, and `dialyzer`; it must pass clean. See `AGENTS.md`.

---

## Tech stack

Elixir 1.19 / OTP 27 · Phoenix 1.8 · Phoenix LiveView 1.2 · Ecto · PostgreSQL ·
Oban · Tailwind CSS v4 + daisyUI · heroicons · Req · Mox · ExMachina · Credo ·
Sobelow · Dialyzer. External tools: `ffmpeg`/`ffprobe` (metadata + tagging) and
the `claude` CLI (AI classification).

---

## Getting started

### Prerequisites

- Elixir 1.19 / Erlang OTP 27 (via asdf — see `.tool-versions`)
- Docker (Postgres runs via `docker compose`, dev + test on port `5434`)
- `ffmpeg` / `ffprobe` on your `PATH` (metadata reads + ID3 writes)
- *(optional)* the `claude` CLI, for AI classification
- *(optional)* Soundcharts API credentials, for metadata enrichment

### Setup

```sh
# 1. Start Postgres (dev + test, port 5434)
docker compose up -d

# 2. Configure secrets (optional — only for enrichment / AI-via-API)
cp .env.example .env   # then fill in SOUNDCHARTS_* if you use enrichment

# 3. Install deps, create + migrate the DB, seed the genre folders, build assets
mix setup

# 4. Run it
mix phx.server          # http://localhost:4000
```

Set `LIBRARY_ROOT` in `.env` to point Beatgrid at your music folder (defaults to
`~/Music/DJ`).

### Testing & quality

```sh
mix test                                      # full suite (fast; external tools mocked)
mix test --include ffprobe --include ffmpeg   # also run the real-binary integration tests
mix lint                                       # format + credo --strict + sobelow + dialyzer
```

---

## Project layout

```
lib/
  beatgrid/                 # domain
    library/                # tracks, scanner, genre folders, name-sync, quality
    organization.ex         # genre-folder move suggestions (suggest → apply → undo)
    soundcharts/            # enrichment client (port + HTTP adapter)
    ai/                     # AI classification (port + claude-CLI adapter)
    tagging/                # ID3 genre write-back (port + ffmpeg adapter)
    operations.ex           # unified, reversible disk-mutation log
    review.ex               # Central de Revisão orchestration (decide → apply)
    mixing.ex               # Camelot-wheel harmonic next-track
    sets.ex                 # REC SET set-builder (+ sets/ schemas, M3U export)
    repertoire.ex           # dashboard analytics
    workers/                # Oban background jobs
  beatgrid_web/
    live/                   # LiveViews: Biblioteca, Detalhe, Revisão, Painel, REC SET
    ui.ex                   # design-system components (cards, chips, badges)
priv/repo/migrations/       # schema history
docs/                       # design specs, plan, and the architecture playbook
test/                       # ExUnit + Mox + ExMachina factories
```

---

## Status

The full pipeline is in place: library management, de-dup, organization,
Soundcharts enrichment, AI classification, the **Central de Revisão** review
surface, the **Painel** dashboard, and the **REC SET** harmonic set-builder.

A personal project — built for one DJ's bag.
