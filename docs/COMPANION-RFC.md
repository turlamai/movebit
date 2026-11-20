# Health reminder UX contract — companion-style cues (RFC / implementation baseline)

> **V1 reset, approved 2026-10-26:** The owner confirms v0.x was an experiment with **no real users**. The next release is the first real health-reminder product; clean-slate UX, RPC, settings and data schemas are explicitly allowed. No migration, legacy presentation opt-in or mandatory backwards compatibility. Execution: [#55](https://github.com/turlamai/movebit/issues/55). This document defines the **target** experience, not already shipped behavior.

**New product default:** small character delivers concise water, stand-up and eye-rest cues; if the native surface cannot be input-safe, use a non-blocking native notification/tray fallback. **Remove** fullscreen forced-break / delayed skip / strict onboarding / previous popup modes from v1. Existing published v0.x releases remain historical; do not overwrite version tags.

**Semantic health message first:** cue includes due kinds, suggested action (drink-water / stand-and-stretch / rest-eyes), and visual gesture; Done is self-reported acknowledgement, Later defers by backend policy. Quiet/presentation suppression must not manufacture completion or drop a pending event. See #55 for the due → pending → acknowledged/snoozed/expired state-machine task.


Status: **SHIPPED in v0.0.1 (2026-10-27)** — the character-delivered cue lifecycle, tray Done/Later/Hide/Focus, quiet queuing with a bounded summary and the Mubi design system are live in the product. Product implementation tracker: [#51](https://github.com/turlamai/movebit/issues/51). Desktop-session acceptance evidence is tracked in #56 D4 / #58.

[中文](COMPANION-RFC.zh-CN.md) · English

## Product purpose: reminders first, character second

**MoveBit remains a hydration, stand-up and eye-rest reminder app.** The scheduler's active-time detection, per-kind reminder cadence, snooze, pause, history and statistics are the product. A friendly animated character is a **presentation interface** that makes a due reminder easier to notice and more pleasant to act on; it is not a standalone desktop pet, virtual friend or pet-care game.

**North-star:** deliver timely, recognizable, actionable water/sit/micro cues **without blocking work**. Prioritize accurate timing and clear actions first, non-interference and user control second, charm third. Do not introduce autonomous attention-seeking cues that are unrelated to health reminders. A cute animation is never evidence that the user has actually drank water or rested.

**A representative moment:** when the **existing water reminder** becomes due, a small original character near the screen edge holds up a cup, optionally with a clear short message. The user can acknowledge, snooze, or hide it without losing focus. The cue communicates an existing health reminder, not a request to interact with a pet.

## Non-negotiable design rules

1. **User stays in control.** Character-delivered health reminders are the v1 default; no old-user opt-in/migration or legacy forced-break mode. The user can acknowledge, snooze, hide and choose Focus; keyboard/tray fallback stays accessible.
2. **Zero interaction interception outside the pet.** No invisible input-taking rectangular overlay, no keyboard focus theft; native pointer hit-testing or explicit fallback. User can hide/quit even when the backend cannot respond.
3. **Edge-docked by default.** Movement is small and bounded. Never cross central content autonomously during normal work. Presentation/Focus mode stops movement and cueing; automated suppression must be based on actually available OS signals, backed by manual control.
4. **One reminder moment, one cue.** The Racket orchestrator already coalesces due sit, water and micro events; a single cue may retain multiple kinds for correct snooze semantics. Do not create extra reminders from the animation lifecycle.
5. **No diversion into pet software.** Ambient motion is optional and subordinate to actual reminders. No separate play loops, feeding, rewards, pets needing attention, repeated begging, negative moods from missed reminders, punishment, scores, artificial dependence or unsupported health claims.
6. **Accessibility.** Respect Reduce Motion, give keyboard and assistive-tech users equivalent actions, support multilingual content, and record native platform behavior rather than asserting parity without tests.

## First pet and gesture inventory

| Existing reminder | Pet gesture (original assets only) | Controls |
| --- | --- | --- |
| Water | Holds a tiny cup, briefly glances up | Done · Later · Hide |
| Micro | Blink/stretch/look far away | Done · Later · Hide |
| Sit | Stands up/invites a stretch | Done · Later · Hide |
| Merged event | One combined gesture; preserve all due kinds | All relevant due kinds handled together |
| No reminder | Quiet by default; optional sparse subtle idle motion | Focus · Hide; optional reposition |

Modes for MVP: `idle`, `water`, `stretch` (sit), `blink` (micro), `quiet`, `static` (Reduce Motion); optional short celebratory acknowledgement. No roaming, pet mood system or play mode in the reminder MVP. Animations are a **visual expression of backend-owned reminders**, not a second source of health events.

## Reminder semantics and product success

- `Due` is determined by the existing backend scheduler. `Shown` means a cue was actually displayed; `Acknowledged` means the user responded; `Snoozed` means the backend defers the kind(s) by its configured period. **Acknowledged ≠ verified drinking or physical break.** 
- Preserve every kind in a merged event and its correct `Later` mapping. Hiding/suppressing a cue must not fabricate a successful health action, count a completion, change scheduled periods or silently lose an overdue reminder; choose and test explicit deferral/expiry semantics.
- The visual cue must clearly communicate **what action is being suggested**: drink water, stand/move, or look away from the screen. A cute unexplained symbol is insufficient.
- Compare against the legacy gentle-toast baseline on reminder recognition, user-reported willingness to act, correct Done/Later semantics, nuisance/disable rates, and interruption/focus errors. Delight and duration of interaction are **secondary** indicators.

## Engineering boundaries

- Shared `racket/movebit/` domain logic owns cycle timing, coalescing, silence/presentation policy and allowed cue intent; no new UI-only health scheduler.
- The first foundation is `racket/movebit/companion-cue.rkt`, a **pure, currently unwired** semantic health cue mapper from already-merged kinds to a suggested health action, gesture and `character | notification | quiet` delivery. Default = character; unsafe host capability = non-blocking notification; Focus = quiet (not completion). Full pending/expiry lifecycle is a separate Racket task in #55.
- `macos-host/`, `windows/` implement local native pet surfaces, input regions/transparent hit-testing, docking, pointer drag and animations. Each platform must document reliable capabilities and fall back honestly when safe overlay behavior is unavailable.
- A new clean-install v1 schema is allowed to break v0.x config/history/RPC. Coordinate **breaking** API/schema changes across both native hosts, generated clients, wire/schema tests and packaged acceptance in coherent slices; no v0.x compatibility shims required.
- No new screen-recording/accessibility permission request to detect meetings. Privacy stays local. Degrade to a small static companion/tray or the existing gentle toast if safe overlay behavior is unavailable.
- The old toast/micro/force-cover presentation is to be retired for v1; keep only safe native-notification/tray fallback on platforms where character windows cannot be implemented without obstructing work. No side-by-side legacy product mode.

## Delivery / verification

Implementation is sliced and tracked in [#51](https://github.com/turlamai/movebit/issues/51). Native work begins with **correct, usable water/sit/micro reminders and input safety**, not collectible pets or elaborate animations. Verify on all supported hosts and packaged builds: typing/clicking/selection underneath the pet, focus restoration, changing displays, OS scaling, sleep/wake, fullscreen/presentation, Reduce Motion, keyboard/readers, backend crash, snooze/away-reset and explicit opt-out.

Use `raco test racket/`, wire/schema checks and `raco rivet acceptance --json` (packaged app, native UI). Report actual measured results and platform gaps; tests passing on one host do not prove parity. Keep public docs in English and Chinese.
