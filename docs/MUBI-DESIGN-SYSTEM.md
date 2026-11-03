# Mubi（沐比）— MoveBit design system

[中文](MUBI-DESIGN-SYSTEM.zh-CN.md) · English

The authoritative visual/interaction spec lives in [issue #56](https://github.com/turlamai/movebit/issues/56) (design freeze, owner-approved 2026-10-26). This document is the repo-side implementation reference: where the art comes from, what hosts must render, and how to verify. Mubi is a **means of delivering health reminders** (charter #51), never a pet product.

![Mubi contact sheet](../assets/mubi/contact-sheet.png)

## Sources of truth

| Artifact | Path | Role |
| --- | --- | --- |
| Design tokens | `assets/mubi/tokens.json` | Colors, sizes, timing, docking rules — the single shared source hosts read/verify against |
| Master artwork | `assets/mubi/source/mubi-master.svg` | Six-state reference (generated; see below) |
| Art generator | `scripts/gen-mubi-art.mjs` | The editable source. Emits the master + per-state SVGs (`.rivet/build/mubi/`). **Do not hand-edit the SVGs** — change the generator or tokens and regenerate |
| Contact sheet | `assets/mubi/contact-sheet.png` | White-document and dark-IDE rows at body size M, plus an S/M/L idle strip. Regenerate with the renderer tool (see docs build note) |

Provenance: all Mubi artwork is **original, project-owned** vector work drawn for this repository under the #56 art direction; MIT-compatible. No third-party mascot, brand asset or imitation is used.

## Proportions (frozen)

Canvas 120×140 units. Body silhouette ~100×108, widest near the lower middle, soft tapered crown, broad weighted lower arc. Two **leaf/fins** rooted into the crown — left rises ~16 leaning out, right ~13 leaning slightly inward; explicitly **not** tall animal ears. Eyes: charcoal ovals ~6 wide at a fixed 27-unit spacing just above the centerline. Mouth absent at idle; a 2-unit curve only for `ack`. The earlier prototype's rabbit-ear ellipses (closed PR #53) are retired art, not reference.

**Silhouette test:** at 60 logical px and as a flat single-color mask, Mubi stays identifiable; face details stay legible at S.

## Color tokens

| Token | Hex | Usage |
| --- | --- | --- |
| `mubi.body` | `#F6EEDF` | Warm cream ivory primary body |
| `mubi.body.light` / `mubi.body.deep` | `#FBF5E9` / `#E8D7BE` | Volume gradient stops (top-left light → lower-right deep) |
| `mubi.shadow` | `#D8C8B5` | Form/contact shade — never a dark outline |
| `mubi.ink` | `#2D2A28` | Eyes, essential facial detail |
| `mubi.fin` | `#F1E4CC` | Fin fill |
| `cue.water` / `cue.move` / `cue.eyes` / `cue.done` / `cue.focus` | `#62B6FF` / `#FF8C6B` / `#65C8B8` / `#F2C96B` / `#8DA1B5` | Small semantic accents (cup, stretch hint, gaze-off, glint, focus tint) |
| `label.text.light` / `label.surface.light` | `#2D2A28` / `#FFFDFB` | Capsule text / surface |

**Dark mode is independently art-directed:** the body stays warm ivory; hosts reduce the rim-light opacity (0.45 light → 0.30 dark, per `tokens.json → rendering`) and use low-glare capsule surfaces. Never auto-invert. Contrast targets: 4.5:1 for reminder text, 3:1 for essential non-text; adjust surfaces/text rather than assuming accent hexes are readable text.

## Sizes and docking

Body height in logical units (macOS pt / WinUI effective px / GTK CSS px): **S 60 · M 78 (default) · L 104**. The enclosing transparent surface may grow for fins/props/label but the **body height is the contract**; use optical correction at S. Default dock bottom-right inside the visible work area with ≥16 clearance; alternatives bottom-left / top-right; never autonomously cross the document center; re-clamp on display/scale/safe-area changes. The panel is **fully pointer-through** (issue #54 fallback) — tray/keyboard carry Done / Later / Hide / Focus.

## Animation language

"Fewer motions, better motions" (#56 §4). One merged due moment → one cue → **one** expressive gesture; label fades in 160–220 ms, reads 4–6 s, fades out 180–240 ms; the label's disappearance never marks the reminder done. States: `idle` (rare blink ≤180 ms, breath ≤2 units), `water` (cup raise, 700–900 ms), `stand` (body lengthens ×1.06 bottom-anchored + stretch hint, 800–1100 ms, displacement 4–8 units), `eyes` (closed-eye arcs + mint gaze-off — the quietest state), `ack` (nod + warm glint, 350–500 ms), `focus` (static, quiet tint, no ambient motion). Reduce Motion → static artwork of the actual due kind, same text/actions. All numbers are design targets tuned against packaged builds. Implemented: macOS runs the gestures natively (SwiftUI) plus the rare idle blink; Windows runs them as timer-driven element updates; Linux as 33 ms cairo redraws — all honoring the still/subtle/lively preference and Reduce Motion. Hosts record real idle/active renderer cost instead of inventing budgets.

## Host implementation contract

- Embed the canonical path strings from `assets/mubi/tokens.json → geometry` (body, fins, eyes, closed-eye arcs, ack mouth) and the color tokens; **no magic hex values** outside a token map.
- Native gradients replace SVG filters: body = linear gradient `body.light → body → body.deep`; rim light = radial white gradient (opacity per light/dark); lower shade = vertical `shadow` fade; focus tint = radial ring.
- One character, parameterized transforms — states must read as the same Mubi, never six mascots.
- Localized copy lives in `shared/i18n/{zh,en}.json`; never baked into art.
- Settings (v1 config): Mubi size S/M/L, motion still/subtle/lively (default subtle), dock position, labels. Health reminder intervals stay more prominent than character customization.

## Verification

`node scripts/gen-mubi-art.mjs` regenerates the master; the contact sheet is the visual acceptance reference for host renders (compare packaged screenshots against it at S/M/L, light/dark). Real acceptance gates: `raco rivet acceptance --json` per platform plus the desk-work checklist in #56 D4 — no "done" claim while a supported platform lacks evidence.
