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

## Finding a task

Navigation labels are in Brazilian Portuguese.

| Menu group | Page | Tasks |
| --- | --- | --- |
| Coleção | Biblioteca | Find and audition music, filter by tempo or key, and organize multiple tracks. Open a track to edit its metadata, notes, cues and gold status. |
| Coleção | Importações | Review versions, select videos and follow the batch under **YouTube e Spotify**. Review and copy local files under **Pasta ou arquivo**. |
| Coleção | Repertório | View collection statistics and get suggestions for a folder. A selected recommendation opens in Imports for review. |
| Curadoria | Revisão de sugestões | Approve, edit or reject proposed names and classifications. Inspect and undo applied batches. |
| Curadoria | Duplicatas · Gêneros · Recuperação de arquivos | Compare duplicate files, manage genre folders and recover damaged or quarantined audio in their respective pages. |
| Sets e palco | Montagem de sets | Build, reorder and audition sets, adjust planning and export M3U. **Abrir na discotecagem** opens the selected set in the booth. |
| Sets e palco | Sets gravados | Study long recordings, identify segments and open extracted tracks. Paid AudD recognition requires confirmation. |
| Sets e palco | Discotecagem | Play live with two decks, vinyl, scratch, effects, transitions, headphones and MIDI. |
| Sistema | Fila de tarefas | Filter downloads, imports and analyses by type and state. Inspect errors and retry jobs. |
| Sistema | Manutenção | Run library-wide analysis, measure loudness, apply or undo gain batches, prepare markers, enrich metadata and back up curation data. |
| Sistema | Ajustes | Change set, booth, audio, backup and curation preferences. |

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
- **Importações** lets you review titles and select tracks before downloading.
  A video link with a radio opens only that video. Paste an explicit playlist link
  to select tracks from it. The queue shows the state of each download and supports retries.
- **Public Spotify playlists** serve as a repertoire reference. Review tracks exposed
  by the public preview, check artist/title matches in your library, and search YouTube
  for versions. The DJ chooses the video. Audio availability depends on YouTube.
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

On macOS, Beatgrid prefers yt-dlp installed at
`~/Library/Application Support/beatgrid/yt-dlp/bin/yt-dlp`. It also accepts the system executable.

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

### Elixir Agent Kit

[Elixir Agent Kit](https://hexdocs.pm/elixir_agent_kit/installation.html) is a Hex dependency for development and tests. After `mix deps.get`, run `mix agent_kit.check` to verify the local references. To update within `~> 1.2`, run `mix deps.update elixir_agent_kit`, review `mix agent_kit.sync --dry-run`, apply with `mix agent_kit.sync` and run the check again.

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
