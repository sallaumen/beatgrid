# UI technical audit (impeccable) — 2026-08-13

_Five-dimension technical pass over the running app (`localhost:4003`, main at `71fcd33`), measured in the live DOM rather than read off the source. Nothing was fixed here; findings are for follow-up passes._

Scope: Biblioteca, REC SET and Discotecagem at 1280px, plus the shared shell.
Product context that shapes the scoring: this is a **single-user desktop tool**
(`PRODUCT.md`), used at a desk for curation and in a dark booth during a set.
Mobile is not a target; keyboard use and legibility in the dark are.

## Audit Health Score

| # | Dimension | Score | Key finding |
|---|-----------|-------|-------------|
| 1 | Accessibility | 2/4 | `ink-faint` text sits at **3.09:1** — below WCAG AA — in ~140 places per screen |
| 2 | Performance | 3/4 | Nothing expensive found: every image lazy-loads, `will-change` unused, the vinyl spin is gated by playback |
| 3 | Theming | 4/4 | One token system, one theme, zero colour drift in the detector |
| 4 | Responsive | 3/4 | No overflow anywhere at 1280 after the library fix; touch targets stay small |
| 5 | Implementation integrity | 4/4 | Coherent, product-specific system with a written contract and a test guard |
| **Total** | | **16/20** | **Good — one weak dimension to address** |

## Implementation integrity verdict — PASS

The implementation expresses a coherent, product-specific system rather than a
generic template. Evidence: a single documented palette and type ramp
(`DESIGN.md`), a test that fails on any `text-*` class resolving to nothing
(`design_tokens_test.exs`), and a detector run over every `.heex`/`.ex` file
returning **2 findings**, both known and deliberate:

- `player_live.ex:406` — a 2px radius on the ~3px seekbar tick. Rounding it to
  the 5px token would turn a tick into a dot.
- `root.html.heex:11` — "Space Grotesk is saturated". It is the incumbent brand
  font; the brief wins.

## Executive summary

- **16/20 (Good).** Accessibility is the only dimension pulling weight down.
- P0: none. P1: 4. P2: 4. P3: 2.
- The three highest-value fixes are all **token-level**, so each one lands
  everywhere at once instead of file by file.

## Findings

### [P1] `ink-faint` text fails WCAG AA contrast

- **Location**: `--text-faint: #5f636f` (`tokens.css`), `text-ink-faint` — ~140
  elements on Biblioteca alone (section labels, placeholders, the `–` empty marks).
- **Category**: Accessibility · **Standard**: WCAG 2.1 SC 1.4.3 (AA, 4.5:1)
- **Measured**: 3.09:1 on `surface`, 3.26:1 on `base`. Its neighbours pass
  comfortably — `ink-muted` 6.45:1, `ink-secondary` 10.98:1.
- **Impact**: the faintest tier is used for labels that orient the eye
  ("COLEÇÃO", "FILTROS", column headers). In a dark booth, at 10px, it is the
  first thing to disappear.
- **Recommendation**: lift the token until it clears 4.5:1 (around `#7d818c`,
  which the palette already owns as `neutral-none`) rather than patching call
  sites. Verify the ramp still reads as five distinct steps afterwards.

### [P1] White on `primary` fails contrast on the main button

- **Location**: `.ds-btn-primary` pattern — `bg-primary text-white`, e.g. the
  "Importar" button (`library_live.ex`), "Salvar" (`ui.ex`).
- **Category**: Accessibility · **Standard**: WCAG 2.1 SC 1.4.3
- **Measured**: white on `#8b7bf0` = **3.39:1** at 11–12px. Two documented
  alternatives already pass: white on `primary-deep` `#6c5ce7` = 4.86:1, and
  near-black `base` on `primary` = 5.76:1.
- **Impact**: the one loud action per screen is the least legible text on it.
- **Recommendation**: pick one and make it the rule in `DESIGN.md` — either the
  button fills with `primary-deep`, or its label flips to `base`. The second
  matches The Commitment Rule (solid accent, near-black text) already used by
  the confirm button.

### [P1] Every album cover ships without an `alt` attribute

- **Location**: `ui.ex` `cover/1` (68 images on one Biblioteca screen)
- **Category**: Accessibility · **Standard**: WCAG 2.1 SC 1.1.1
- **Impact**: a screen reader announces the file URL, or nothing coherent, for
  every row.
- **Recommendation**: `alt=""` — explicitly empty. The art is decorative here:
  the title and artist sit next to it as real text, so a description would only
  duplicate them. This is a one-line fix in one component.

### [P1] Nine form fields carry a placeholder instead of a label

- **Location**: search box and the min/max pairs (nota, energia, BPM) in
  `library_live.ex`
- **Category**: Accessibility · **Standard**: WCAG 2.1 SC 3.3.2
- **Impact**: the placeholder vanishes on focus, so the field loses its name
  exactly while being filled; screen readers get nothing before that.
- **Recommendation**: `aria-label` on each input. The visible layout already
  labels the pairs ("NOTA min — max"), so no visual change is needed.

### [P2] Animations ignore `prefers-reduced-motion`

- **Location**: `animate-pulse` in 6 places (job/progress dots), `animate-spin`
  on the now-playing vinyl. Only the three generated flash spinners use
  `motion-safe:`.
- **Category**: Accessibility · **Standard**: WCAG 2.1 SC 2.3.3 (AAA) / good practice
- **Impact**: small, but the pulses are permanent while a job runs.
- **Recommendation**: `motion-safe:animate-pulse` at the call sites, or one
  `@media (prefers-reduced-motion: reduce)` block. Keep the state change visible
  — the dot should stay coloured, just stop pulsing.

### [P2] Biblioteca has no `h1`

- **Location**: `library_live.ex` — the page title is an `<h2>`; the document
  has no `h1`.
- **Category**: Accessibility · **Standard**: WCAG 2.1 SC 1.3.1
- **Impact**: heading navigation starts at level 2 with nothing above it.
- **Recommendation**: promote the page title to `h1` on the screens that use
  `h2` for it (Biblioteca, Painel), keeping the 22px Title step.

### [P2] 107 interactive targets under 24×24px

- **Location**: across the app; densest in Discotecagem (28 of 151 buttons,
  smallest 74×20px).
- **Category**: Accessibility · **Standard**: WCAG 2.2 SC 2.5.8 (AA, 24×24)
- **Impact**: real in the booth, where the console is operated in a hurry and
  in the dark. Much less so at the desk with a trackpad.
- **Recommendation**: this is a deliberate density trade, not an accident — but
  the *console* is the surface where a mis-click costs a live set. Raise the
  minimum height there to 24px before touching the curation screens.

### [P2] REC SET truncates 79 texts at 1280px

- **Location**: `rec_set_live.ex` track rows
- **Category**: Responsive
- **Impact**: titles like "Forró 2001 - NENZINHO BOA FÉ" cut mid-word. Nothing
  overflows the viewport, so it is legibility rather than breakage.
- **Recommendation**: the same treatment the library just got — a floor on the
  flexible column, expendable columns leaving first (The Title-Never-Yields Rule).

### [P3] Below ~1147px the library grid stops fitting

- **Category**: Responsive · The narrow template needs 636px and the rail plus
  filters take 511px of any viewport.
- **Recommendation**: only worth doing if a narrower window is a real scenario;
  the filters column would have to collapse first.

### [P3] Cover initials sit at ~3.4:1 on their gradient

- **Category**: Accessibility · The placeholder initials are white/90 over the
  `primary-deep → primary` gradient. Borderline, and the text is redundant with
  the title beside it.

## Patterns

- **The accessibility gaps are token-level, not sprinkled.** Two colour tokens
  and one component account for the bulk of the AA failures, which means three
  edits fix hundreds of elements. That is the opposite of the usual audit.
- **Naming is already disciplined.** 334 buttons on one screen and **zero**
  without an accessible name — `title`/`aria-label` are used consistently.
- **What the detector reads and what the browser reads still differ.** Every
  finding above except the last two came from measuring the live DOM; none of
  them appear in a source scan.

## Positive findings

- All 68 images lazy-load; `will-change` appears nowhere; the vinyl spin is
  paused unless audio is actually playing.
- Landmarks (`nav`, `main`) and `aria-live` on the flash group are in place.
- Theming is a closed system: one theme, `color-scheme: dark`, no second design
  language since daisyUI left, and the detector finds zero colour or type drift.
- Keyboard focus is visible app-wide in the booth's own colour.
- No horizontal overflow on any of the three dense screens at 1280px.

## Recommended actions

1. **[P1] `/impeccable harden`** — the four AA fixes: lift `ink-faint`, settle
   white-on-primary, `alt=""` on covers, `aria-label` on the filter inputs.
2. **[P2] `/impeccable adapt`** — REC SET's flexible column, and the console's
   24px target floor.
3. **[P2] `/impeccable polish`** — reduced-motion guards and the `h1` promotion.

Re-run the audit after the fixes to see the score move; accessibility is the
only dimension with real headroom.
