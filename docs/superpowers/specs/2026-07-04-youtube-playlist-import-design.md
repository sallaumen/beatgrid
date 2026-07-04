# Imported-playlists screen 2.0 — group by playlist + create a set

Date: 2026-07-04 · Branch: `sets/planning-studio` (shared; a second agent owns the
Planning Studio backend — this work stays in separate files)

## Problem

The `/importados` screen (`BeatgridWeb.ImportsLive`) dumps every YouTube-imported
track in a flat list, with no notion of the playlist it came from. The user wants:
1. A **top button to import a new playlist** (paste a YouTube link → download).
2. Tracks **grouped by playlist, collapsed** — you only see a playlist's tracks
   after expanding it.
3. Each playlist gets **"criar set"** — build a `RecSet` from its tracks, in
   playlist order, with automatic transition mixing (reusing the existing
   `Sets` backend). The transitions are suggestions the player can toggle.

## Key technical gap: playlist order

Playlists are not a DB entity — tracks carry `raw_tags["youtube_playlist_url"]`
(nil for single videos). There is **no position field**, and downloads fan out to
parallel workers, so `inserted_at` order is not the playlist order. To honor "na
mesma ordem", capture the playlist index at ingest going forward; existing imports
fall back to `inserted_at`.

## Isolation (parallel agent)

A second agent is editing `lib/beatgrid/sets.ex`, `mixing.ex`, `track_query.ex`,
`presets.ex` on this shared branch/tree. This work touches ONLY:
`imports_live.ex`, `youtube.ex`, `youtube/yt_dlp.ex`, `workers/download_worker.ex`,
a new `youtube/playlists.ex`, and their tests. It **reuses** `Sets.create/1`,
`Sets.append/3`, `Sets.connect_all/1` (public, already on main) without editing
`sets.ex`. Commits `git add` only these files (never `-A`).

## Backend — capture order + title at ingest

Thread a `playlist` context (`%{url, index, title} | nil`) through the flow:

- **`YouTube.YtDlp.list_entries/1`** — add `%(playlist_title)s` to the
  `--flat-playlist --print` format; `parse_entries/1` returns
  `%{id, title, url, playlist_title}`.
- **`YouTube.enqueue_entries/2`** — `Enum.with_index(1)`; a URL that expands to
  many videos is a playlist (`playlist_url`, `playlist_title` from the entries).
  Enqueue each `DownloadWorker` with `playlist_url`, `playlist_index`,
  `playlist_title`.
- **`DownloadWorker`** — carry `playlist_index` / `playlist_title` args; pass a
  `playlist` map to `download_and_ingest/2`.
- **`YouTube.download_and_ingest/2` → `ingest/2` → `ingest_attrs/4`** — store
  `youtube_playlist_url`, `youtube_playlist_index`, `youtube_playlist_title` in
  `raw_tags` (index/title only when part of a playlist). Single videos unchanged.

## New module — `Beatgrid.YouTube.Playlists` (pure + a thin action)

- `group(tracks) :: %{playlists: [playlist], singles: [Track]}` where a
  `playlist` is `%{key, url, title, tracks (ordered), count}`. Grouping key is
  `youtube_playlist_url`; tracks with none go to `singles`. Ordering: by
  `youtube_playlist_index` when every track in the group has one, else by
  `inserted_at`. Title: `youtube_playlist_title` when present, else a friendly
  fallback ("Playlist do YouTube"). Pure.
- `create_set(playlist) :: {:ok, RecSet.t()}` — `Sets.create(title)` →
  `Sets.append(set, track)` for each track in order → `Sets.connect_all(set)`.
  Returns the set. (Thin composition of existing public `Sets` functions.)

## UI — `ImportsLive`

- **Top bar**: an "Importar playlist" button toggling a small URL input (a
  `<form phx-submit="import_playlist">`); submit → `YouTube.enqueue(url)` + a
  flash ("importando…"); the existing tick/reload shows tracks as they land.
- **Grouped list**: `Playlists.group(@tracks)` → render each playlist as a
  collapsible section (header: title · N faixas · ▸/▾ expand · "Criar set"). The
  expanded body reuses the current per-track row. `singles` render below as
  today. Expansion state kept in an assign `expanded` (MapSet of playlist keys).
- **Events**: `import_playlist` (submit URL), `toggle_playlist` (expand/collapse),
  `create_set` (`phx-value-key`) → `Playlists.create_set/1` → push_navigate to
  `/set/:id` + flash. Existing `toggle_filter`/`sort`/`toggle_gold`/`delete`
  unchanged.

## Testing (TDD, silent)

- `youtube/playlists_test.exs` — `group/1`: groups by url, singles separated,
  order by index when complete else inserted_at, title fallback; `create_set/1`
  (Factory): creates the RecSet, appends in order, connects consecutive pairs
  (assert `Sets.entries` order + transitions present).
- `youtube/yt_dlp_test.exs` (extend) — `parse_entries/1` reads `playlist_title`.
- `youtube_test.exs` (extend) — `ingest_attrs` writes
  `youtube_playlist_index`/`_title` into `raw_tags` for a playlist item, and
  omits them for a single video.
- UI verified in preview WITHOUT audio playback (group, expand, create set →
  redirect); no track is played.

## Non-goals

- A Playlist DB entity — grouping stays derived from `raw_tags`.
- Re-importing existing playlists to backfill exact order — existing imports use
  `inserted_at`. Only new imports get exact order.
