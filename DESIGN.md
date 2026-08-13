---
name: Beatgrid
description: The working DJ's booth for library curation and set-craft — always dark, cockpit-dense, warm-accented
colors:
  base: "#0b0c10"
  rail: "#0e0f15"
  surface: "#11131a"
  surface-2: "#131520"
  input: "#15171f"
  deep: "#0d0e14"
  pill: "#1b1d26"
  ink: "#eef0f5"
  ink-secondary: "#c4c7d0"
  ink-muted: "#9498a6"
  ink-faint: "#5f636f"
  ink-disabled: "#3a3d48"
  border-subtle: "rgba(255,255,255,.06)"
  border-soft: "rgba(255,255,255,.08)"
  border-strong: "rgba(255,255,255,.10)"
  focus-ring: "rgba(139,123,240,.50)"
  primary: "#8b7bf0"
  primary-deep: "#6c5ce7"
  primary-soft: "#a594f5"
  amber: "#ffb020"
  amber-deep: "#e08e00"
  green: "#5ad1a0"
  green-deep: "#2f9e76"
  blue: "#2d9cff"
  coral: "#ff5d6c"
  coral-soft: "#ff8d97"
  violet-pink: "#c08bf0"
  gold: "#f5c518"
  neutral-none: "#7d818c"
  white: "#ffffff"
  black: "#000000"
typography:
  hero:
    fontFamily: "Space Grotesk, system-ui, sans-serif"
    fontSize: "28px"
    fontWeight: 600
    lineHeight: 1.25
  title:
    fontFamily: "Space Grotesk, system-ui, sans-serif"
    fontSize: "22px"
    fontWeight: 600
  heading:
    fontFamily: "Space Grotesk, system-ui, sans-serif"
    fontSize: "18px"
    fontWeight: 600
  body:
    fontFamily: "Space Grotesk, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.5
  caption:
    fontFamily: "Space Grotesk, system-ui, sans-serif"
    fontSize: "10px"
    fontWeight: 400
  label:
    fontFamily: "Space Grotesk, system-ui, sans-serif"
    fontSize: "10px"
    fontWeight: 600
  numeral:
    fontFamily: "IBM Plex Mono, monospace"
    fontSize: "25px"
    fontWeight: 600
    lineHeight: 1
  scale:
    micro-2: "8px"
    micro: "9px"
    chip: "9.5px"
    caption: "10px"
    caption-plus: "10.5px"
    body-sm: "11px"
    body: "12px"
    body-lg: "13px"
    wordmark: "15px"
    heading: "18px"
    title: "22px"
    hero-sm: "24px"
    numeral: "25px"
    hero: "28px"
rounded:
  xs: "5px"
  sm: "7px"
  md: "9px"
  lg: "11px"
  xl: "12px"
  2xl: "14px"
  full: "9999px"
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.white}"
    rounded: "{rounded.md}"
    padding: "6px 12px"
  button-quiet:
    backgroundColor: "{colors.input}"
    textColor: "{colors.ink-muted}"
    rounded: "{rounded.md}"
    padding: "6px 10px"
  input:
    backgroundColor: "{colors.input}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "8px 12px"
  kpi-card:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.xl}"
    padding: "13px 15px"
  nav-item-active:
    backgroundColor: "rgba(139,123,240,.12)"
    textColor: "{colors.primary}"
    rounded: "{rounded.lg}"
    padding: "8px 10px"
---

# Design System: Beatgrid

## Overview

**Creative North Star: "A Cabine"**

Beatgrid is the DJ's booth in the middle of a set: a dark room, an instrument
panel, meters glowing. Every screen is lit the same way — near-black surfaces
(`base` → `rail` → `surface`), hairline separations, and small pools of colored
light where information lives. The library is the record crate in that half-dark;
the Discotecagem console is the mixing desk itself. There is no daytime mode and
no neutral corporate skin: the app is always the booth.

The voice is technical with warmth. Precision comes from cockpit density —
micro-typography from 8 to 13px, monospaced numerals, chips that read at a
glance — and the warmth comes from the palette itself: the amber, coral, and
gold of the forró world glowing against ultraviolet. This is a professional tool
for a working DJ, adult and exact, but it is not cold; the colors carry the
music's temperature.

Controls are instrumental and recessed: they serve the data, never compete with
it. Confirmed visual rejections (posture, not taste): no light theme, no
gradient text, no decorative emoji, no cutesy microcopy, no toy-rounded corners.
Generator-default UI is a defect here even when no rule names it.

**Key Characteristics:**
- Always dark; depth by surface tone and hairline, almost never by shadow
- Cockpit-dense micro-typography (8–13px core) with mono for every measurement
- Accents are semantic booth lights, tinted low (9–15%) until the moment of commitment
- One committed world across screens; the console (Discotecagem) is its most physical expression

## Colors

Booth light on dark metal: a violet brand glow, with the warm stage colors of
forró — amber, coral, gold — doing the semantic work.

### Primary
- **Ultravioleta da Cabine** (`primary` #8b7bf0, deep #6c5ce7, soft #a594f5):
  the brand light. Active nav, selected/playing states, the one loud button per
  view, the logo tile gradient (145deg, deep → primary), 9–10 ratings, the MPB
  folder, the "style" fader channel.

### Secondary
- **Âmbar de Palco** (`amber` #ffb020) and **Âmbar Profundo** (`amber-deep`
  #e08e00): attention and harmony. Medium confidence, 5–6 ratings, audit flags,
  Camelot keys (major = amber, minor = amber-deep), the Forró and Forró Clássico
  folders, the "bpm" fader channel.

### Tertiary
- **Verde VU** (`green` #5ad1a0, deep #2f9e76): confirmation and health — high
  confidence, 7–8 ratings, selection ("Marcar"), the → in before/after rows, the
  "respiro" arc, the "intensity" channel.
- **Coral de Clip** (`coral` #ff5d6c, soft #ff8d97): danger and absence —
  destructive actions, no-match/low confidence, 0–4 ratings, loudness spikes,
  the "rating" channel.
- **Azul de Monitor** (`blue` #2d9cff): informational cool — the "harmony"
  channel, the Forró In The Light folder.
- **Ouro de Crate** (`gold` #f5c518): the rare-gem star (Selo Ouro). Lives only
  in code today, not in `tokens.css` — promote it when touching the tokens file.
- **Violeta-rosa** (`violet-pink` #c08bf0): the Forró MPB folder blend.

### Neutral
- **Ink ramp** (#eef0f5 → #c4c7d0 → #9498a6 → #5f636f → #3a3d48): text
  hierarchy, from primary copy down to disabled.
- **Surface ramp** (#0b0c10 base → #0e0f15 rail → #11131a surface → #131520
  surface-2 → #15171f input → #1b1d26 pill; #0d0e14 deep for recesses): layering
  is tonal, one step per level.
- **Hairlines** (white at 6% / 8% / 10%): all separation. **Sem Match**
  (`neutral-none` #7d818c): the "no data" chip tone. Scrims are black at 40–55%.

### Named Rules
**The Booth-Light Rule.** An accent is a lamp on a dark desk: fills at 9–15%
alpha (`color-mix` or `/10`–`/15`), borders at 23–50%, full color only for
text/glyphs and moments of commitment. The `.bg-token-chip` / `.bg-folder-badge`
helpers (`--c` + `color-mix`) are the canonical recipe — new chips reuse them
instead of inventing bg/border pairs.

**The One-Meaning Rule.** Every accent already carries semantics (green =
confirm/high, amber = attention/harmonic, coral = danger/low, primary =
brand/active/excellent, gold = rare). Never decorate with a semantic color; the
Format helpers (`folder_color/1`, `rating_color/1`, `confidence_color/1`,
`dimension_color/1`) are the palette's meaning in code — reach for them first.

**The Always-Dark Rule.** There is no light theme. The daisyUI light/dark theme
scaffolding in `app.css` is vestigial; `html, body` force the Beatgrid palette.
Do not build against daisyUI theme tokens.

**The No-Near-Miss Rule.** A color that is *almost* a token is drift, not a
shade. `#7a7a85` shadowed `neutral-none` and `#8b5cf6` (Tailwind's violet)
posed as `primary` in a `var()` fallback — both are gone. When a value needs to
be near an existing token, use the token.

## Typography

**Display/Body Font:** Space Grotesk (with system-ui, sans-serif)
**Mono Font:** IBM Plex Mono (with monospace)

**Character:** a geometric grotesk with just enough quirk to stay human — the
"technical with warmth" voice in letterform. The mono grounds every measurement;
together they read like a well-labeled instrument panel.

### Hierarchy
- **Hero** (600, 24px → 28px at `sm`, tight leading): the track page title only —
  the one place a name gets stage lighting.
- **Title** (600, 22px): every page header ("Biblioteca", "Painel").
- **Heading** (600, 18px): modal and section titles ("Critérios de montagem").
- **Body** (400–500, 11–13px): the workhorse band, and the one band with named
  utilities — `text-caption` (10px), `text-body-sm` (11px), `text-body` (12px),
  `text-body-lg` (13px), defined in `@theme`. 12px is the default row text;
  13px for emphasized rows and nav items; 11px for secondary row text.
- **Caption** (400, 10–10.5px): metadata under titles, KPI sublines.
- **Label** (600–700, 9–10px, uppercase, tracked 0.025–0.18em): section labels,
  chip text (9.5px), table headers, console micro-labels. Wider tracking as the
  size shrinks.
- **Micro** (600–700, 8–9px): the console's smallest annotations.
- **Numeral** (600 mono, 25px, leading 1): KPI values. All data — BPM, key,
  LUFS, dB, m:ss, counts — is IBM Plex Mono at its context's size, with
  `tabular-nums` wherever values align in columns.

### Named Rules
**The Mono-Data Rule.** If it is a measurement, it is mono. No exceptions: a
BPM in Space Grotesk is a defect.

**The Cockpit-Type Rule.** Interface text lives in the 8–13px band. Sizes ≥15px
are identity moments only: the wordmark (15px), headings (18px), page titles
(22px), KPI numerals (25px), the track hero (24/28px). Nothing else earns them.

**The Named-Step Rule.** A semantic type class only exists if `@theme` defines
it. Tailwind compiles an undefined token to *nothing* — no error, the element
just inherits — which is how `text-body*`/`text-caption` shipped dead for ~313
uses and `text-h2` for one. `test/beatgrid_web/design_tokens_test.exs` now
fails on any `text-*` class that resolves to nothing.

Every page title is the Title step (22px) — Resgate and Discotecagem were 17px
until they were normalized. 18px covers both section/panel headers and compact
stat numerals (the Painel's status pills).

## Layout

A fixed left rail (216px, `rail` background, right hairline) carries grouped
navigation — Coleção / Curadoria / Sistema — and collapses to 68px
(`data-nav=collapsed`, applied before paint, 200ms ease-out width transition;
collapsed items show 3-letter codes). Main content clears the sticky global
player with `pb-20`.

Pages are single-column operational surfaces: `mx-auto max-w-[1600px] px-6
py-5/6` for dense screens (library, console), `max-w-[1100px]` for focused ones.
Spacing rides the stock Tailwind 4px grid at booth density: `gap-1.5`–`gap-3`
between row elements, 13–15px card padding, `px-2 py-1` – `px-3 py-2` control
padding. Desktop-first: the app is built for the DJ's laptop; `sm:`/`lg:`
adjustments are refinements, not a mobile redesign.

## Elevation & Depth

Flat plus hairline. Depth is conveyed by the surface ramp (one tonal step per
layer) and 1px white hairlines at 6–10% — not by shadows. The app's few shadows
are reserved and named:

### Shadow Vocabulary
- **Elevated** (`box-shadow: 0 12px 32px rgba(0,0,0,.5)`): modals and popovers —
  the only "floating" surfaces.
- **Primary glow** (`box-shadow: 0 4px 14px rgba(139,123,240,.35)`): the single
  amplified CTA (e.g. the track page's play pill).
- **Logo glow** (`box-shadow: 0 6px 18px rgba(108,92,231,.45)`): the brand tile
  in the rail. Not a general-purpose glow.
- **Console recess** (`box-shadow: inset 0 1px 3px rgba(0,0,0,.6)`): the inside
  of physical controls (fader channels). Inset only; reserved for the console's
  instrument feel.

### Named Rules
**The Hairline Rule.** Separation is a hairline or a surface-tone step, never a
drop shadow. A shadow appears only as elevation (modal), amplification (primary
glow), or recess (console) — if it isn't one of those three, remove it.

## Shapes

Tight, instrumental corners: a compact 5–14px radius scale where `md` (9px) is
the workhorse for buttons, inputs, and row containers; `xl` (12px) for cards;
`2xl` (14px) for large covers. Anything rounder is either a pill (9999px —
seals, badges, toggle chips) or a true circle (play button, vinyl disc). Tiny
inline elements (checkbox, marker-type switch) sit at 4–5px.

A recurring silhouette: the **left color spine** — a 2–3px colored left edge
that codes a row's meaning (marker rows in their marker color, the AI rationale
quote in primary, the active nav item's 3px `rounded-r-full` bar).

**The Pill-or-Tight Rule.** Rectangles stay ≤14px radius. If a shape wants to
be rounder, it becomes a full pill or a circle — there is nothing in between.

## Components

### Buttons
- **Character:** instrumental and recessed — quiet until the moment of commitment.
- **Shape:** gently rounded (`md`, 9px); the amplified CTA is a pill.
- **Primary:** solid `primary` bg, white text, 12px semibold, `px-3 py-1.5`.
  One per view ("Importar", "Salvar", "Aplicar").
- **Quiet:** `input` bg + hairline border (white/8–10), `ink-muted`/`ink-secondary`
  text; hover brightens the text to `ink`, background stays.
- **Confirm tint ("Marcar"):** green at 12% bg + 30% border + green text; when
  selected, flips to solid green with near-black (#0b0c10) text.
- **Danger tint:** coral at 10% bg + coral text, hover 20%; a rejected state is
  solid coral with white text.
- **Disabled:** `opacity-40`, no color change.

**The Commitment Rule.** A control fills with its full accent only at the
moment of commitment (selected, confirmed, destructive-armed) — and its text
flips to near-black or white. Tint is the resting state; solid is the act.

### Chips
- **Style:** the `--c` recipe — text in the semantic color, bg `color-mix` 9–11%,
  border `color-mix` 23–30% (`.bg-token-chip`, `.bg-folder-badge`).
- **Confidence chip:** `xs` radius, 9.5px bold uppercase tracked; folder badge:
  `sm` radius, 10px semibold; Ouro badge: pill, gold at 20% with star glyph.
- **Camelot seal:** mono pill, 11px semibold, min-width 30px — amber (major) or
  amber-deep (minor).

### Cards / Containers
- **Corner Style:** `xl` (12px).
- **Background:** `surface` on `base`; nested panels step to `surface-2`.
- **Shadow Strategy:** none at rest (Hairline Rule); `elevated` only when floating.
- **Border:** 1px white/8; state overrides: green/40 + green/5 bg (selected),
  coral/35 + coral/5 bg + 60% opacity (rejected), `ring-1 ring-primary/50` (playing).
- **Internal Padding:** 13–15px.

### Inputs / Fields
- **Style:** `input` bg, 1px white/8 border, `md` radius, 11–12px text (mono when
  numeric), `ink-faint` placeholder; dense variants `px-2 py-1`.
- **Focus:** border shifts to primary/50, outline removed; some controls use
  `ring-2 ring-primary/40` instead. (Buttons often remove outline without a
  replacement — an accessibility debt to settle, not a pattern to copy.)
- **Select / Checkbox:** same recipe; checkbox is 4px radius, `input` bg.

### Navigation
- Rail items: 13px medium, `lg` radius, `ink-muted`; hover white/5 bg + `ink`
  text; active `primary/12` bg + primary text + the 3px left spine. Section
  labels are the canonical Label (10px/600, uppercase, 0.14em, `ink-faint`).

### A Mesa (Discotecagem console) — signature
The most physical surface in the app; its materials stay inside it:
- **Fader:** recessed channel (`deep` bg + console recess + hairline), fill as a
  vertical `color-mix` gradient (70% → 22%) in the dimension color, mono value
  above, Label below. Dimension colors: style = primary, harmony = blue,
  intensity = green, bpm = amber, rating = coral.
- **Deck materials:** key caps on #101218; deck faces
  `linear-gradient(135deg, #1a1c24, #0e0f15)`; disc grooves in #14161d.
- **Scratch pattern set:** the console's one sanctioned categorical palette —
  #e6e9f2, #ff8c42, #e84dc4, #ff6b9d, #48dbfb, #feca57.
- **Vinyl:** radial groove rings (#0c0c0f / #3a3a44) with a primary label dot;
  spins via `animate-spin` gated by `body[data-playing]` — motion means audio.

### Covers
Album art at `sm` (7px) radius (≤60px) or `2xl` (14px) above; fallback is a
stable two-color gradient seeded by artist (from the 8-color brand palette) with
1–2 initials. Hover reveals a ▶ scrim (black/55).

### KPI Card
Label (10px/600 uppercase, `ink-faint`) over a 25px mono semibold numeral in a
semantic color, optional 10.5px subline; `alert` swaps the hairline for coral/25.

## Do's and Don'ts

### Do:
- **Do** build new chips and badges with the `--c` + `color-mix` recipe
  (`.bg-token-chip` / `.bg-folder-badge`) — 9–15% fills, 23–50% borders.
- **Do** set every measurement in IBM Plex Mono (`tabular-nums` in columns).
- **Do** reach for the Format helpers (`folder_color/1`, `rating_color/1`,
  `confidence_color/1`, `camelot_color/1`, `dimension_color/1`) — the palette's
  semantics live there, not in per-screen hexes.
- **Do** keep controls tinted ≤15% at rest and spend full accent only on the
  Commitment moment or the single primary action per view.
- **Do** separate with hairlines (white/6–10) or one surface-ramp step.
- **Do** write microcopy in adult pt-BR — direct and calm, like
  "Nenhum marcador ainda — toque a faixa e use ＋ para marcar."

### Don't:
- **Don't** introduce a light theme or build on the vestigial daisyUI theme
  tokens — the booth is always dark.
- **Don't** use drop shadows for separation; the only shadows are Elevated,
  Primary glow, Logo glow, and Console recess.
- **Don't** invent a semantic type class without adding its step to `@theme` —
  an undefined token compiles to nothing and the element silently inherits.
- **Don't** add font families beyond Space Grotesk and IBM Plex Mono.
- **Don't** use gradient text, decorative emoji, or cutesy microcopy — glyphs
  (★ ▶ ✕ ♪) are instruments, not decoration.
- **Don't** round a rectangle past 14px — pill or circle, nothing in between.
- **Don't** invent new accent colors inside features; anchor meaning to the
  existing semantic set first (the console's scratch set is the one categorical
  exception, and it stays in the console).
