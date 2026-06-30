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
| **Local audio analysis** | Offline BPM + musical key (Camelot) per track via a `librosa` script — independent of Soundcharts, so unmatched tracks still get key/BPM and you can sanity-check suspicious API values. Auto-runs on first open of a track. |
| **YouTube import** | Paste video URLs or a playlist in the Painel to download audio (`yt-dlp`) into `_Inbox`, with a heuristic artist/title parsed from the video title — then enrich + organize through the normal review flow. Downloading is offline (no API quota). |
| **Harmonic mixing** | "Next ideal track" suggestions using the Camelot wheel (compatible keys + nearby BPM). |
| **Review & apply** | A LiveView **Central de Revisão**: select rename / classification / audit suggestions with checkboxes, then apply the batch to disk — with an ID3 genre write and full **undo**. |
| **Analytics** | A **Painel** dashboard: headline KPIs, genre/decade distribution, top artists, BPM histogram, AI repertoire-gap suggestions, bulk audio-analysis, and YouTube import. |
| **Set-builder (REC SET)** | Assemble a **scored** set (style affinity + Camelot harmony + an energy arc of manual sections — abertura → pico → queda), audition tracks inline, and export to an `.m3u` playlist Serato/VLC read directly. A backend-driven "Critérios" modal shows the exact scoring weights and the style-affinity matrix. |

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
  | `Beatgrid.Audio.Analyzer` | `Audio.LibrosaCli` (Python + librosa) | `Audio.AnalyzerMock` |
  | `Beatgrid.YouTube.Downloader` | `YouTube.YtDlp` (`yt-dlp`) | `YouTube.DownloaderMock` |

  CLI adapters (`claude`, `yt-dlp`) run with stdin from `/dev/null` and a timeout,
  so a CLI can never hang the caller.

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
Sobelow · Dialyzer. External tools: `ffmpeg`/`ffprobe` (metadata + tagging and
loudness gain), optional `mp3gain` (lossless MP3 gain), the `claude` CLI (AI),
`yt-dlp` (YouTube import), and Python + `librosa` (offline BPM/key analysis).
See **Requirements** below.

---

## Getting started

### Requirements

Beatgrid shells out to a few external tools. Only the first three are needed to
run the app; the rest unlock individual features and the app degrades gracefully
without them. **Every external tool is mocked in the test suite, so `mix test`
needs none of them.**

| Tool | Required? | Used for | Install (macOS) |
| --- | --- | --- | --- |
| Elixir 1.19 / Erlang OTP 27 | **Required** | the app itself (via asdf — see `.tool-versions`) | `asdf install` |
| Docker | **Required** | PostgreSQL for dev + test, via `docker compose` (port `5434`) | [docker.com](https://docs.docker.com/get-docker/) |
| `ffmpeg` / `ffprobe` | **Required** | reading metadata, ID3 genre write-back, audio extraction | `brew install ffmpeg` |
| `mp3gain` | Feature | lossless loudness gain application for MP3 files; MP3 falls back to `ffmpeg` without it | `brew install mp3gain` |
| `yt-dlp` | Feature | importing tracks from YouTube (download + audio extraction) | `brew install yt-dlp` |
| Python 3 + `librosa` | Feature | offline BPM + musical-key (Camelot) analysis | `pip install librosa` |
| `claude` CLI | Feature | AI genre classification, repertoire-gap ideas, YouTube title parsing | [Claude Code](https://claude.com/claude-code) (a Max plan or API key) |
| Soundcharts API key | Feature | metadata enrichment (BPM, key, energy, genres, year…) | set `SOUNDCHARTS_*` in `.env` |

"Feature" = optional: the app boots and the rest works, but that one feature is
unavailable until the tool is installed/configured. The `yt-dlp` and Python
executables are configurable if they aren't on `PATH` (see `config/config.exs`).

### Setup

```sh
# 1. Start Postgres (dev + test, port 5434)
docker compose up -d

# 2. Configure secrets (optional — only for enrichment)
cp .env.example .env   # then fill in SOUNDCHARTS_* if you use enrichment

# 3. Install deps, create + migrate the DB, seed the genre folders, build assets
mix setup

# 4. (optional) feature tools
brew install ffmpeg yt-dlp   # ffmpeg required; yt-dlp for YouTube import
pip install librosa          # offline BPM/key analysis

# 5. Run it
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
    audio/                  # offline analysis (port + librosa adapter) + ffprobe
    analysis.ex             # local BPM/key detection orchestration
    youtube.ex              # YouTube import (+ youtube/: yt-dlp adapter, title parser)
    operations.ex           # unified, reversible disk-mutation log
    review.ex               # Central de Revisão orchestration (decide → apply)
    mixing.ex               # scored set engine (style + harmony + intensity) + style matrix
    sets.ex                 # REC SET set-builder (+ sets/ schemas, M3U export)
    repertoire.ex           # dashboard analytics
    workers/                # Oban background jobs (scan, soundcharts, ai, analysis, youtube)
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
Soundcharts enrichment, AI classification, offline BPM/key analysis, the
**Central de Revisão** review surface, the **Painel** dashboard, the **REC SET**
scored set-builder, and YouTube import (download today; one-click metadata
enrichment is in progress).

A personal project — built for one DJ's bag.
