# AGENTS.md — Beatgrid conventions (ground truth)

This file is the operational contract for anyone (human or AI) writing code in
this repo. It adopts the **Elixir/Phoenix Architecture & Quality Playbook** in
[`docs/playbook/`](docs/playbook/) wholesale, and records the project-specific
decisions on top of it. When this file and the playbook disagree, **this file
wins** (it is the tailored, project-level layer).

Read [`docs/specs/2026-06-25-beatgrid-design.md`](docs/specs/2026-06-25-beatgrid-design.md)
for *what* we are building and *why*. This file is *how* to build it.

## Language rule (hard)

- **Code, comments, module/function names, docs, commit messages, and UI text
  are English. Always. No exceptions** (README, none of it, in Portuguese).
- **User-entered data is not translated.** Genre names (`MPB`, `Forró`, `Forró
  Roots`…), custom tag names (`Pico da Pista`), and personal notes are stored
  verbatim in whatever language the user typed. They are data, not chrome.

## The five principles (from the playbook)

1. **Layer strictly, depend inward.** Edges (LiveView, workers, mix tasks)
   translate + authorize, then delegate. The domain (`lib/beatgrid/`) holds all
   business logic and all queries. Edges never build Ecto queries.
2. **Every aggregate is a triad:** a context module (public API + mutations), an
   Ecto schema (structure + changesets), and a `*Query` module (all reads).
   Reads are `defdelegate`'d to the query module.
3. **Errors are data.** Fallible ops return `{:ok, _}` / `{:error, _}`. Domain
   errors are `defexception` structs with `:code`, `:message`, `:details`.
   Raise only for genuine contract violations (missing preload, impossible state).
4. **Talk to the outside world through ports.** Each external service is a
   behaviour + a real adapter + an `Application.compile_env!` selector + a Mox
   mock. Tests never hit the network. (Soundcharts and the AI client are ports.)
5. **Test first, mock at the boundary.** Failing test → make it pass in the
   domain → refactor. Mox for behaviours; everything else real.

## Project-specific laws

- **Disk is the source of truth.** `lib/beatgrid/library` reflects the real files
  under the library root (`~/Music/DJ`). A move in the app is a `File.rename`
  on disk wrapped in a DB transaction. The DB never hides or owns audio files.
- **Never delete audio.** "Removing" a bad file or a duplicate moves it to
  `_Quarantine/`. Deletion is a separate, explicit, user-confirmed action.
- **Soundcharts budget law.** The free tier is **1,000 requests total**. Every
  response is persisted and never re-fetched. Dedup happens *before* any API
  spend. Each call records `x-quota-remaining` in the `api_calls` ledger and the
  client refuses to call below a safety floor. Dev/test use the **sandbox**
  credentials; tests stub HTTP (`Req.Test`) and never touch the real quota.
- **Suggest → confirm → apply.** AI/rule/dedup decisions create *pending*
  `move_suggestions`. Nothing moves on disk without explicit user approval.
  Applied moves are reversible (undo) via the same table.
- **Import copies, never moves.** Pulling tracks from the original SpotiDownloader
  folders into the library copies them; the originals stay as backup.

## Scope decisions (what we are and aren't building in v1)

We follow the playbook but **scale infrastructure to a single-user, local app**.
The playbook explicitly treats these as optional — we omit them for v1:

| Playbook topic | v1 decision |
|---|---|
| First-party UI | **LiveView reading contexts directly** (no GraphQL). |
| GraphQL (Absinthe), file `04` | **Not used.** Revisit only if a decoupled client appears. |
| REST API for integrators, file `05` | **Not used** (single-user, local). |
| Broadway / broker, file `07` | **Not used.** Oban covers all async work. |
| Elasticsearch (Snap), file `06` | **Not used.** Postgres + `pg_trgm` for search. |
| Cloak encryption, file `06` | **Not used.** Secrets live in env, not the DB. |
| Multiple endpoints / clustering | **Single node, single endpoint.** |
| PaperTrail | **Not used.** Move history lives in `move_suggestions`. |

We **do** adopt, in full: the triad, errors-as-data, ports & adapters + Mox, the
wrapped `Beatgrid.Repo`, `Repo.transact/1`, `Ecto.Enum`, UUID v7 PKs, idempotent +
concurrent-index migrations, Oban worker conventions (args = IDs, `enqueue/1`,
uniqueness), the testing matrix, and the code-style rules in playbook file `09`.

## Integration ports (the two that matter)

- **`Beatgrid.Soundcharts`** — behaviour + `Beatgrid.Soundcharts.Http` (Req) adapter
  + `Beatgrid.Soundcharts.Mock`. Budget-guarded; caches into `soundcharts_songs` /
  `soundcharts_artists`; logs every call to `api_calls`.
- **`Beatgrid.AI`** — behaviour (`classify_track/1`, `suggest_gaps/1`) with three
  adapters selected by config:
  - `Beatgrid.AI.ClaudeCli` (**default**): shells out to the official `claude`
    CLI in headless mode (`claude -p <prompt> --output-format json --json-schema
    <schema> --model <model>`). Uses the user's existing Claude login (Max plan),
    no API key. This is first-party Claude Code usage — ToS-compliant. We do
    **not** extract or reuse OAuth tokens in a third-party client (that is banned).
  - `Beatgrid.AI.AnthropicApi` (alternative): raw HTTP via Req to
    `https://api.anthropic.com/v1/messages` with `x-api-key` (Elixir has no
    official Anthropic SDK; raw HTTP is the supported path). Model + structured
    output via `output_config.format`.
  - `Beatgrid.AI.Mock` (test).
  - Model is config (`:beatgrid, Beatgrid.AI, model: ...`); default a cheap/fast model
    for bulk classification, switchable per the user's preference.
- **`Beatgrid.Audio`** — behaviour + `Beatgrid.Audio.Ffprobe` adapter (reads tags,
  bitrate, duration via `ffprobe`) + mock. ID3 *writes* (genre enrichment) go
  through `ffmpeg -c copy`.

## Commands (once scaffolded)

- `mix lint` — format-check + credo --strict + dialyzer + sobelow (the pre-commit gate).
- `mix test` — full suite (Ecto sandbox; HTTP stubbed; never hits Soundcharts/Anthropic).
- `mix test path/to/file_test.exs:LINE` — the inner-loop scope.
- `docker compose up -d db` — start Postgres for dev/test.
- `mix setup` — deps.get + ecto.setup + assets.

## Boundaries (from the playbook)

- **Always:** write tests for new behavior; `mix format` before commit;
  `{:ok,_}/{:error,_}` for fallible ops; `with` chains; `Ecto.Enum`; idempotent +
  concurrent-index migrations; pass an `origin` on state-changing functions.
- **Ask first:** new deps; new migrations; config changes; new Oban queues;
  changes to the Soundcharts or AI ports.
- **Never:** commit secrets; `String.to_atom/1` on user input; raise for control
  flow; delete a failing test to green CI; delete audio files implicitly;
  re-fetch a cached Soundcharts response; spend API quota in tests.
