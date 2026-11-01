# MoveBit 2026 Product Experience Reboot (Proposal)

**Status: design proposal dated 2026-10-31, NOT shipped behavior, proven adoption or an offer for sale.**  
**English** · [简体中文](PRODUCT-EXPERIENCE-2026.zh-CN.md)  
Parent [#86](https://github.com/turlamai/movebit/issues/86). Workstreams: [#87](https://github.com/turlamai/movebit/issues/87), [#88](https://github.com/turlamai/movebit/issues/88), [#89](https://github.com/turlamai/movebit/issues/89), [#90](https://github.com/turlamai/movebit/issues/90), [#91](https://github.com/turlamai/movebit/issues/91), [#92](https://github.com/turlamai/movebit/issues/92), [#94](https://github.com/turlamai/movebit/issues/94). The #51/#54/#56 safety and original-art contracts still hold. Commercial policy is governed by #81/PR #82; this document does not change published MIT source rights.

## The product in one sentence

**MoveBit is a delightful desktop wellness companion that knows when to help and when to disappear.**

MoveBit is neither a bare timer nor a pet game. It makes drinking water, moving away from the chair and looking away from the screen easier to remember, while respecting work. Its character, Mubi, makes the experience emotionally appealing, never manipulative. Order of priority: trustworthy guidance > user control > warmth > decoration.

## Evidence-based audit of the current repository

- `racket/movebit/config.rkt`: 45 active minutes to move, 30 to drink, 30 for eye rest (20 seconds), 10 to snooze, 5 to reset after away. Appearance offers S/M/L, three motion levels and dock position, but there is no whole-day routine preset.
- `racket/movebit/scheduler.rkt`: single scheduler and merged due kinds. Daily `sit-reminders/water-reminders/micro-breaks` are incremented **when a reminder fires**, not when users confirm doing something. UI must not imply completed care.
- `racket/movebit/orchestrator.rkt` already models presented, acknowledged, snoozed and expired cue transitions; it is the right basis for truthful event data.
- `macos-host/Sources/RivetHost/Companion.swift` has original vector shapes, an idle blink and short water/stand/eye gestures. Most idle time is deliberately quiet; richer but bounded expression is an opportunity, not proof of three-host readiness.
- `macos-host/Sources/RivetHost/OnboardingView.swift` introduces the product with a droplet emoji and presets only for water, sit and sound. It lacks real Mubi preview, overall routine choice and explicit quiet preference.
- The main macOS/Windows/Linux screens are heavy on activity totals, 7/30-day bars, statistics and numeric controls; everyday next action is less prominent.
- Main-branch `AGENTS.md` and `PRICING*.md` contain a historical free-only directive. Open PR #82 proposes Free + Pro; do not create competing pricing edits, or pretend paid entitlements already exist.

## Four critical moments

**First run (target under 60 seconds):** Mubi appears in its original vector appearance, breathing softly. Explain the three behaviors. Pick a Gentle/Balanced/Active routine and preview the actual reminder bubble and motion; choose dock and sound (proposed default off); finish without account, paywall or unnecessary permissions. Skip remains a full-value path. Say clearly that activity time is estimated, not typed content recorded.

**At work:** Mubi docks away from the working area. It blinks and shifts its gaze occasionally, not in a permanent attention loop. The user can find the next cue and instantly Pause, Focus or Hide. A deliberate click on the *shape*, where precise non-activating hit regions are proven, may give a tiny wave/nod; otherwise leave the character fully pointer-through and provide tray/keyboard equivalents. Never force a fake transparent click rectangle. On Wayland honor compositor limitations and use an honest fallback.

**A cue is due:** One backend merged cue produces one small readable notice and one expressive gesture; preserve every due kind and offer Done / Later / Hide. A disappearing bubble never means that hydration, movement or eye rest happened. Reduce Motion produces accessible static advice. Quiet/presentation periods cannot generate a backlog of nags. Only the Racket core decides when a health cue exists.

**End of work:** Mubi settles and rests quietly, without guilt animation or punitive “pet hunger”. An optional daily summary can say: “X estimated minutes active; Y reminders shown; Z actions you marked done.” These are distinct data classes. Weekly reflections observe patterns, not health diagnoses.

## Mubi: subtle life, intentional interaction

| Semantic state | Expression | Strict guardrail |
| --- | --- | --- |
| idle | Rare blink, slight breath, brief gaze movement | User-disableable; no endless bounce, sound or attention loop |
| curious | A brief look, tilt or wave | Only explicit user interaction, rate-limited, never schedules a health cue |
| away / return | Resting eyes / a single welcoming stretch | Existing away signal only; no app-window or keystroke monitoring |
| water / move / eyes | Cup / stretch / faraway gaze and clear text | Only actual health reminders trigger these states |
| ack / snooze | Small nod / settling pose | Acknowledge remains a self-report, never sensed compliance |
| focus / hidden / reduce-motion | Static or absent | Higher priority than all decorative motion |

Keep `Assets/mubi/source/mubi-master.svg` and `Assets/mubi/tokens.json` as editable, original, MIT-compatible canonical source. Animation states are shared across native hosts, not unrelated pictures. The *still pose must already look premium*. No feeding, mood punishment, guilt streaks, random loot, compulsive play or advertisement. Test dark/light, 60/78/104 optical sizes, focus and mouse-through, accessibility, CPU/GPU/wakeups and battery impact on packaged native builds.

## Timing proposals — product hypotheses, not medical prescriptions

| Kind | Current default | Balanced proposal | User freedom |
| --- | --- | --- | --- |
| Water | 30 active min | **60 active min** | Off, or 5–180 min; never infer how much water was drunk |
| Stand and move | 45 active min | **50 active min**, suggest about 5 min away | Off, or 10–240 min; cannot diagnose posture |
| Eyes | 30 active min, 20 sec | **20 active min**, look away for 20 sec | Off, quieter ambient-only cue option, configurable timing |
| Away-reset | 5 min | Keep 5 min | Return resets accumulated cycles if a real break occurred |
| Snooze | 10 active min | Keep 10 + quick choices | Merged cue kinds and clock semantics remain deterministic |

Gentle candidate: water/move/eyes = 90/60/30 active minutes; Active candidate = 45/45/20. Final values need qualitative user testing; each preset shows its exact values. Editing one turns the preset into Custom; changing presets never silently overwrites a Custom routine. The “next reminder” is an **active-time estimate**, not a wall-clock promise.

The 20-minute gaze reminder is a familiar eye-rest heuristic, and US OSHA suggests brief breaks from computer tasks; a particular drinking interval is not a universal medical requirement. To prevent 20-minute nuisance, explore quiet visual-only eye hints, merging and opt-in sound. Every category must be easy to disable. No medical efficacy claims.

Explicitly test pause/focus, quiet periods crossing midnight, lock/sleep/wake, clock corrections, idle provider failure, merged due kinds, repeated actions, failed presentation, and backend unavailability. A failed notification must never count as displayed or Done.

## Information architecture

**Home:** recognisable Mubi state, next helpful reminder, current work session, immediate actions (Done/Later/Focus/Pause where relevant), and a compact honest today snapshot.

**Insights:** 7/30-day estimated activity, longest continuous work, *reminders vs user-confirmed actions* separately, modest context-aware observations. No synthetic cups consumed, posture detection, unverified “success rate” or health score. Missing historical event data = unknown, not zero.

**Settings:** Basic: routine preset, each kind on/off, size/animation/dock, quiet/sound/focus. Advanced: interval details, away thresholds, language, export/restore, updates. Choices apply and preview consistently; show persistence or failure clearly; keyboard, screen-reader and scaling support throughout.

## Canonical event data and privacy

Separate `triggered`, `presented`, `acknowledged`, `snoozed`, `dismissed`, `expired` and `not_delivered` per kind and day. Merged events count each constituent kind once. Store stable event IDs, reconcile retries and device shards idempotently. Earlier history storing only fired reminders has **unknown acknowledgments**, not a presumed zero. Active minutes are system activity estimates, not diagnosed sedentary time. Keep all content local by default; research requires voluntary feedback or informed minimal measurement, never background keystroke or app-content collection.

## Useful fun: Mubi helps you act instead of merely notifying you

**Opt-in experiments #94:** Two tiny polished guided experiences transform a glance at a notification into a voluntary action:

1. **20-second eye-rest companion:** Only when the user explicitly starts it, Mubi looks toward an imagined faraway horizon and shows a simple 20-second prompt. Stop, Skip and self-reported Done remain available. There is no eye tracking or assertion that the user looked away.
2. **1–2-minute movement mini-session:** Mubi demonstrates two or three very gentle optional movements. Users can follow at their own pace, skip each or stop; no risky medical coaching or camera/body inference.
3. **Hydration acknowledgment:** An optional tiny cup “cheers” response after the user deliberately marks drinking. Any later water-volume log must use explicit voluntary entry, never guess.

Personality comes from more carefully crafted poses and responses, not around-the-clock movement or increasing the number of nags. None of these experiences auto-start, steal focus or lock the desktop. Focus/away/Reduce Motion and immediate cancellation take precedence; first evaluate whether real users enjoy and use them before growing the behavior library.

## Sustainable revenue without weakening Free

**Free:** three dependable reminder kinds, attractive baseline Mubi, pause/focus/snooze, safe controls, basic configuration, existing history, data export/restore, accessibility, security fixes, offline use without login.

**Pro candidates to validate:** optional original expressive pose packs and personal visual touches; richer personalized routine schedules; honest weekly self-report trend insights; advanced themes and configurations. Pro must solve a *real additional job*, not repair an intentionally limited Free experience. Make a working cross-platform demo and talk to prospective users before licensing the feature.

**Offer hypothesis, not public pricing:** test one-time purchase with optional later paid major upgrades; don't impose a subscription without recurring delivered value. No real charging before #81/PR #82 decisions, Permit shared-core entitlement tests, Commerce verified/restore/refund sandbox, merchant compliance and packaged release gates. MIT already-published source rights remain intact.

## Sequenced delivery and product evidence

1. **P0 trust:** #87 schedule/presets and #88 truthful measurements.
2. **P1 desire to use:** #89 expressive companion and #90 first-run + UX redesign.
3. **P1 willingness to pay:** #91 test differentiated Pro value; do not infer market demand from a finished demo.
4. **Independent quality gate:** #92 actual packaged native validation.

Proposed acceptance research: 5 fresh users performing common tasks (choose a preset, turn off eyes, pause, confirm/snooze, find insights), 7 days of voluntary dogfood, and 8–12 value interviews. These are **future goals, not results**. Record task success, perceived annoyance, reminder disable/uninstall reasons and willingness to pay. Separate design decisions, code merged, CI, packaged OS acceptance and actual payments in every report.

## Code ownership / active-agent conflict avoidance

- Racket `config/scheduler/orchestrator/history`: canonical health timing and event truth.
- `app/backend.rkt` + `rivet-schema.json`: shared contract; hosts cannot invent independent schedulers.
- macOS / Windows / Linux native host directories: precise safe rendering, accessible actions, OS capability fallback.
- `shared/i18n`: single localized content source; `Assets/mubi`: original artwork.
- #81 / PR #82 own `PRICING.md` and `PRICING.zh-CN.md`. **This docs PR deliberately does not touch those paths.**
- Use small non-overlapping PRs, preserve concurrent checkout work, and never label untested UI or commerce as shipped.
