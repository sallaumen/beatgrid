# Beatgrid

[![CI](https://github.com/sallaumen/beatgrid/actions/workflows/ci.yml/badge.svg)](https://github.com/sallaumen/beatgrid/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19-4e2a8e.svg)](https://elixir-lang.org)

**[Versão em português](README.md)** *(the canonical README — this project
celebrates Brazilian forró, so Portuguese comes first)*

A DJ library manager built with Elixir + Phoenix LiveView. Born to organize a
forró/MPB record bag: it scans the audio files on disk, de-duplicates,
organizes into genre folders, enriches with metadata (BPM, key, energy),
builds sets with an energy arc and transitions, and plays everything through a
crossfading player.

The **filesystem is the source of truth**: moving a track in the app moves the
file on disk (with undo). The database is a knowledge layer over the files —
the music never lives in this repository.

## Screens

**Library** — filters by genre, key (Camelot), BPM, energy and rating; batch
actions with undo:

![Library](docs/screenshots/biblioteca.png)

**REC SET** — scored set builder (style + harmony + energy arc), automatic
planner, per-pair transitions and M3U export:

![REC SET](docs/screenshots/rec-set.png)

**Dashboard** — collection overview and operations hub (audio analysis,
loudness, cue markers, YouTube import, AI repertoire gaps):

![Dashboard](docs/screenshots/painel.png)

## What it does

- **Real organization**: content-hash dedup, genre folders, reversible
  quarantine — files are never deleted.
- **Metadata from every angle**: ID3 tags (ffprobe), the Soundcharts API
  (BPM/key/energy), local librosa analysis (API-independent) and AI genre
  classification — everything becomes a reviewable suggestion before touching
  disk.
- **DJ-worthy sets**: a planner with an energy arc (opener → peaks and rests →
  fade-out), rare gems on the peaks, automatic transitions
  (cut/fade/crossfade) driven by intro/outro markers detected via audio
  analysis, and a dual-deck crossfading player.
- **Consistent volume**: measures loudness (LUFS) and applies gain to the
  files (lossless mp3gain for MP3; ffmpeg for the rest), with undo.
- **YouTube import**: paste a URL or playlist and tracks flow into the normal
  review pipeline.
- Every disk change follows **propose → review → apply → undo**, recorded in
  an operations log.

## Getting started

### Requirements

Only the first three are required; the rest unlock individual features (the
app runs without them, and the test suite needs none — everything is mocked).

| Tool | Used for |
| --- | --- |
| Elixir 1.19 / OTP 27 | the app |
| Docker | dev + test PostgreSQL (port 5434) |
| ffmpeg | metadata, tags, gain |
| mp3gain *(optional)* | lossless MP3 gain |
| yt-dlp *(optional)* | YouTube import |
| Python 3 + librosa *(optional)* | offline BPM/key/markers |
| claude CLI *(optional)* | AI genre classification and suggestions |
| Soundcharts API key *(optional)* | metadata enrichment (`.env`) |

### macOS

```sh
brew install elixir ffmpeg           # + optional: mp3gain yt-dlp
pip install librosa                  # optional: offline analysis
```

### Linux (Debian/Ubuntu)

```sh
# Elixir/OTP: asdf recommended (https://asdf-vm.com) or distro packages
sudo apt install ffmpeg              # + optional: mp3gain yt-dlp
pip install librosa                  # optional: offline analysis
```

### Run it

```sh
docker compose up -d                 # Postgres (port 5434)
cp .env.example .env                 # optional: SOUNDCHARTS_* and LIBRARY_ROOT
mix setup                            # deps + db + seeds + assets
mix phx.server                       # http://localhost:4000
```

Point `LIBRARY_ROOT` in `.env` at your music folder (default: `~/Music/DJ`).

### Tests and quality

```sh
mix test     # full suite, fast (external tools mocked)
mix lint     # format + credo --strict + sobelow + dialyzer
```

## Architecture in one note

Domain contexts with dedicated query modules; every external integration is a
behaviour with a real adapter + a Mox mock; heavy jobs run in the background
(Oban) with live PubSub progress; errors are data (`{:ok, _}` /
`{:error, _}`); TDD with a strict quality gate. Details in `docs/playbook/`
and `AGENTS.md`.

## License

[MIT](LICENSE) — free software: use, study, modify and share.

---

A personal project, built for one forró DJ's bag.
