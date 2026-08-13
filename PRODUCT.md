# Product

<!-- impeccable:product-schema 1 -->

<!-- Derived from repository evidence (README.md, AGENTS.md,
     docs/specs/2026-06-25-beatgrid-design.md) rather than a fresh interview:
     the owner is the sole user and had already written this product truth down.
     Lines marked [inferido] are my reading, not his words — correct them freely. -->

## Platform

web

## Users

One working DJ — the repository owner — running the app locally on his own Mac
against his own music library (`~/Music/DJ`). He uses it in two distinct
situations, and they have opposite tolerances:

- **At the desk, curating:** importing, de-duplicating, filing by genre,
  correcting metadata, rating, planning sets. Long sessions, dense screens,
  batch actions, undo expected.
- **In the booth, playing:** the Discotecagem console driving two decks live,
  with a Numark DJ2GO2 Touch mapped. Here a wrong click costs a real gig — the
  app has already played live sets (2026-08-05).

There is no second audience, no multi-tenancy, no onboarding funnel. [inferido]

## Product Purpose

Turn a pile of downloaded audio files into a library a DJ can actually play
from, and then play from it. It scans the files on disk, removes duplicates,
files them into genre folders, enriches them with BPM, key (Camelot), energy
and loudness, builds sets with a real energy arc and planned transitions, and
plays the result through a crossfading player and a two-deck console.

Success is a set that survives contact with a dance floor: no missing files, no
volume jumps, no dead transitions, and the tracks the DJ actually meant to play.

## Positioning

Commercial DJ software owns the booth; library managers own the shelf. Beatgrid
is built around the seam between them, and its mechanism is that **the file
system is the source of truth**: moving a track in the app is a `File.rename` on
disk wrapped in a transaction, so the library stays correct for every other tool
the DJ opens. The database is a knowledge layer over the files, never their
owner — and the audio never lives in this repository.

The second differentiator is that it knows one music culture deeply rather than
all of them shallowly: forró's rules (the breather, the sacred endings) are
first-class product logic, not tags.

## Operating Context

- Local single-user Phoenix app; Postgres in Docker; Oban for background work.
- The library root is a real folder of real audio the owner has curated for
  years. Destructive-looking actions are reversible by design: "removing" a bad
  file or duplicate moves it to `_Quarantine/`; gain writes back up the original
  to `_Backups/Gain/` first.
- Paid and metered external services are part of the operating reality:
  Soundcharts has a hard 1,000-request free tier, AudD charges per recognition.
  Both are spent deliberately, never speculatively.
- Live playback pauses background jobs (QuietMode) so analysis never stutters a
  set in progress.

## Capabilities and Constraints

- **Confirmed capabilities:** disk scan and integrity census; de-duplication;
  genre filing with undo; metadata enrichment (BPM, Camelot, energy, loudness,
  YouTube views/age); ratings and the Selo Ouro rarity mark; cue markers;
  set building with scoring and automatic planning; transitions; M3U export;
  YouTube playlist import; recording a set excerpt as a new track; a global
  crossfading player; a two-deck live console with scratch, FX and MIDI.
- **Suggest → confirm → apply:** AI, rule and dedup decisions create *pending*
  suggestions. Nothing moves on disk without an explicit human approval, and
  applied moves are undoable.
- **Never delete audio.** Deletion is a separate, explicitly confirmed action.
- **Language:** user-facing text is pt-BR — the product speaks the DJ's
  language. User-entered data (genre names, tag names, notes) is never
  translated. Code and identifiers are English.
- **Curation is sparse by nature.** Ratings and Selo Ouro exist on a fraction of
  the library, so quality controls must influence selection (quotas, weights,
  nil-tolerant floors) and must never hard-filter on a curated field.

## Brand Commitments

- Name: **Beatgrid** (a record crate plus Elixir's `-ex`).
- Voice: adult, precise, unsentimental pt-BR. It is a tool for a working
  professional, not a consumer toy — no cutesy microcopy, no decorative emoji.
- The visual world is committed and documented in `DESIGN.md` ("A Cabine").

## Evidence on Hand

- Real screenshots of live screens in `docs/screenshots/` (Biblioteca, REC SET,
  Painel).
- A real library of ~560 tracks with partial curation (Selo Ouro on ~148).
- Product spec: `docs/specs/2026-06-25-beatgrid-design.md`; engineering contract:
  `AGENTS.md`.
- **No** customers, testimonials, pricing, benchmarks or press exist. This is a
  personal tool under the MIT license; future work must not fabricate any of
  them, and there is no marketing surface to design for.

## Product Principles

1. **Disk is the source of truth.** The app reflects the files; it never hides
   or owns them.
2. **Nothing irreversible without a human.** Suggest → confirm → apply, and
   everything applied can be undone.
3. **Spend metered calls once.** Every external response is persisted and never
   re-fetched; dedup happens before any spend.
4. **The dance floor is the acceptance test.** A feature is done when it holds
   up in a real set, not when the suite is green.
5. **Know one culture deeply.** Forró's rules are product logic, and they
   outrank generic "DJ app" convention when the two disagree.

## Accessibility & Inclusion

No external requirement applies (single user, local app), but the booth context
sets a real floor: the app is used in a dark room, in a hurry, sometimes on a
laptop screen. Hit targets on the live console must stay comfortable, state must
be readable at a glance, and color must never be the only carrier of meaning —
every chip pairs its color with a label. [inferido]
