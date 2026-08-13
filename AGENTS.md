# AGENTS.md — Beatgrid conventions (ground truth)

This file is the operational contract for anyone (human or AI) writing code in
this repo. It adopts the **Elixir/Phoenix Architecture & Quality Playbook** in
[`docs/playbook/`](docs/playbook/) wholesale, and records the project-specific
decisions on top of it. When this file and the playbook disagree, **this file
wins** (it is the tailored, project-level layer).

Read [`docs/specs/2026-06-25-beatgrid-design.md`](docs/specs/2026-06-25-beatgrid-design.md)
for *what* we are building and *why*. This file is *how* to build it.

## Language rule (hard)

- **Code is English: identifiers, module/function names, commit messages,
  @doc/@moduledoc. Comments: English preferred (pt-BR tolerated where the
  DJ-domain nuance reads better).**
- **User-facing text (UI chrome, flashes, transition reasons) is pt-BR** — the
  product speaks the DJ's language. `README.md` (pt-BR) is canonical;
  `README.en.md` mirrors it.
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
   errors are `defexception` structs with `:code`, `:message`, `:details` —
   that struct is `Beatgrid.Error` (Recognition is the first adopter; new ports
   and reworked boundaries return it instead of ad-hoc reason tuples).
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
- **AudD is paid per call.** Recognition (`Beatgrid.Recognition`) runs only from an
  explicit button click, serially and throttled; a no-match stamps
  `audd_attempted_at` so it is never re-paid for the same segment.
- **Gain writes are backed up.** Applying loudness gain copies the original file to
  `_Backups/Gain/<track>/<batch>/` first and records a reversible `:gain` operation —
  the batch is undoable from the Painel.
- **Quiet mode.** Active playback pauses Oban's background work
  (`Beatgrid.Playback.QuietMode`) so ffmpeg/librosa never stutter a live set.
- **Worker error semantics.** `{:cancel, reason}` for permanent failures (missing
  entity, missing audio, no credentials); `{:error, reason}` for transient ones;
  snooze on budget exhaustion. Every worker exposes its own `enqueue/…` wrapper —
  callers never hand-build `Worker.new` args.
- **PubSub contract.** Every topic + message shape is documented and typed in
  `Beatgrid.Events`; contexts own their `subscribe`/`broadcast_*` helpers and
  their specs reference those types. Changing a payload starts there.

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

## Integration ports

Every external tool/service is a behaviour + a config-selected adapter + a Mox
mock (see `config/config.exs` for the wiring and `test/support/mocks.ex` for the
mocks — those two files are the ground truth). The current ports:

| Port | Real adapter | Talks to |
| --- | --- | --- |
| `Beatgrid.Audio` | `Audio.Ffprobe` | `ffprobe` (tags, bitrate, duration) |
| `Beatgrid.Soundcharts.Client` | `Soundcharts.Http` (Req) | Soundcharts API (budget-guarded, cached, logged to `api_calls`) |
| `Beatgrid.AI.Client` | `AI.ClaudeCli` | `claude` CLI headless (Max plan, ToS-compliant — never reuse OAuth tokens in a third-party client) |
| `Beatgrid.Tagging.Writer` | `Tagging.Ffmpeg` | `ffmpeg -c copy` (ID3 genre write-back) |
| `Beatgrid.Audio.Analyzer` | `Audio.LibrosaCli` | Python + librosa (offline BPM/key) |
| `Beatgrid.Audio.MarkerDetector` | `Audio.MarkerDetectorCli` | Python + librosa (cue markers) |
| `Beatgrid.Audio.Loudness` | `Audio.FfmpegLoudness` | `ffmpeg loudnorm` (LUFS/true peak) |
| `Beatgrid.Audio.GainApplier` | `Audio.GainApplierCli` | `mp3gain` / `ffmpeg` (gain apply) |
| `Beatgrid.Audio.SetSegmenter` | `Audio.SetSegmenter.LibrosaCli` | Python + librosa (mix segmentation + DJ candidates) |
| `Beatgrid.YouTube.Downloader` | `YouTube.YtDlp` | `yt-dlp` (download + listing) |
| `Beatgrid.Mixes.Source` | `Mixes.Source.YtDlp` | `yt-dlp` (online-set audio fetch) |
| `Beatgrid.Video.FrameSampler` | `Video.FrameSampler.FfmpegCli` | `ffmpeg` (frames for DJ-name OCR) |
| `Beatgrid.Recognition` | `Recognition.Audd` | AudD API (**paid per call** — see law below) |

- AI model is config (`:beatgrid, Beatgrid.AI, model: ...`), default a cheap/fast
  model for bulk classification.
- **CLI hardening law:** every adapter that shells out wraps `System.cmd` in
  `Beatgrid.Cli.run/2` (Task + timeout + brutal kill) with stdin from `/dev/null`
  where the tool might block — a CLI can never hang an Oban slot or a LiveView.

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

## Skills routing (Claude Code)

Skills live in `~/.claude/skills` (machine-global). Invoke BEFORE starting the
work, not after it is already done the old way:

- **impeccable**: any task touching UI (.heex, `~H` components, CSS, screens).
  A new surface goes through `shape` before code; reviews use `audit`/`critique`.
- **ui-ux-pro-max**: UX pattern decisions (which component, which flow, which
  layout) and usability review.
- **huashu-design**: throwaway HTML prototypes to discuss direction before
  touching the app. Prototypes are not committed.
- **tdd**: every feature and every bugfix.
- **elixir-antipatterns** (+ elixir, elixir-ecto-patterns): Elixir review and
  refactors.

Design posture: generator-default UI is a defect even when the detector stays
quiet. Side-tab accent borders, glow, gradient text, flat hierarchy, timid
spacing, emoji as decoration, toy-like rounded corners, cutesy microcopy: none
of it ships. This is a tool for working DJs; keep it adult and precise. The
impeccable hook (`.impeccable/config.json`, committed on purpose) is the
mechanical floor, not the ceiling.

[`DESIGN.md`](DESIGN.md) is the visual contract ("A Cabine") and
[`PRODUCT.md`](PRODUCT.md) the product one. DESIGN.md's frontmatter arms the
`design-system-*` drift rules, so a colour, radius or type size outside the
system trips the hook. Read it before touching UI — it carries the named rules
(Booth-Light, Mono-Data, Cockpit-Type, Hairline, One-Spine, No-Near-Miss,
Keyboard-Leaves-a-Mark, Title-Never-Yields) that no detector can check.

Two traps it exists to prevent, both of which shipped for months:

- **A Tailwind class whose token is missing from `@theme` compiles to nothing** —
  no error, no warning, the element just inherits. That is how `text-body*` and
  `text-caption` rendered 16px across ~313 elements in a UI whose core band is
  8-13px. `test/beatgrid_web/design_tokens_test.exs` fails on any `text-*` class
  that resolves to nothing; keep it that way.
- **The detector reads source, the browser reads computed.** `text-[11px]` is
  greppable; a stock `text-sm`, an inherited size, or a theme coming from the
  OS is not. When the dev server is up, measure with `getComputedStyle` before
  concluding a screen is clean.

## Local ports

Beatgrid owns **4003** — the default in `config/runtime.exs`, so plain
`mix phx.server` lands there and never fights the other local apps. Postgres is
on **5434**. Never start a second Beatgrid on another port to dodge a
collision: attach to the running one (`.claude/launch.json` has a
`beatgrid-attach` entry) — two servers on one dev database means two Oban
schedulers working the real library.
