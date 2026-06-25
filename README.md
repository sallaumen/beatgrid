# Beatgrid

A local-first librarian for a DJ music collection. Beatgrid maps, deduplicates,
quality-checks, and organizes audio files on disk into genre folders, enriches
them with music metadata (BPM, key, energy, release date) from the Soundcharts
API, and uses Claude to suggest genre placement and spot gaps in the repertoire.

The **filesystem is the source of truth.** Beatgrid reflects and edits the real
folders under a library root (default `~/Music/DJ`); moving a track in Beatgrid
moves the file on disk, so Serato and Finder see it immediately. The database is
a *knowledge layer* over those files — never their owner.

> All code, docs, comments, and UI text in this project are written in **English**.
> User-entered data (genre names like *Forró*, custom tags, personal notes) is
> stored verbatim in whatever language the user typed.

## Status

Pre-implementation. This repository currently holds the design and plan:

- **[docs/specs/2026-06-25-beatgrid-design.md](docs/specs/2026-06-25-beatgrid-design.md)** — the design spec (read this first).
- **[docs/plan/IMPLEMENTATION_PLAN.md](docs/plan/IMPLEMENTATION_PLAN.md)** — the phased implementation plan.
- **[AGENTS.md](AGENTS.md)** — coding conventions (the ground truth for humans and AI assistants).
- **[docs/playbook/](docs/playbook/)** — the Elixir/Phoenix Architecture & Quality Playbook this project follows.

## Stack (target)

Elixir 1.19 / OTP 27 · Phoenix 1.8 + LiveView 1.2 · PostgreSQL + Ecto · Oban ·
Req · ffprobe/ffmpeg (audio metadata) · Soundcharts API · Claude (via the
`claude` CLI or the Anthropic API).

## Prerequisites

- Elixir 1.19 / Erlang OTP 27 (via asdf)
- Docker (Postgres runs via `docker compose`)
- `ffmpeg` / `ffprobe` on `PATH` (already present on the dev machine via Homebrew)
- The `claude` CLI (for AI features in CLI mode) **or** an `ANTHROPIC_API_KEY`
- A Soundcharts account (sandbox credentials for dev; 1,000 free requests)

## Quick start

See [docs/plan/IMPLEMENTATION_PLAN.md](docs/plan/IMPLEMENTATION_PLAN.md). Once
scaffolded, the loop is `docker compose up -d db` → `mix setup` → `mix phx.server`.
