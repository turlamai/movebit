# Contributing to MoveBit

Thank you for looking under the hood. MoveBit is source-available
(BUSL-1.1, see [LICENSE](LICENSE)); by submitting a pull request you
agree your contribution is licensed under BUSL-1.1, with the same MIT
change date as the rest of the Work.

## Ground rules

1. **One contract, two native hosts.** `app/backend.rkt` declares the
   RVT1 RPC/Event/State surface the SwiftUI and WinUI 3 hosts render
   from. Changing any of it is a two-platform change, not a local edit:
   sync both hosts and commit the regenerated tracked clients
   (`windows/GeneratedBackend.hpp`,
   `macos-host/Sources/RivetHost/GeneratedBackend.swift`) in the same
   commit. Changes under `shared/i18n/` likewise require `raco rivet i18n`;
   the two generated i18n tables (`windows/GeneratedI18n.hpp`,
   `macos-host/Sources/RivetHost/GeneratedI18n.swift`) are build inputs,
   and CI rejects drift with `git diff --exit-code`. The Racket domain
   engine stays platform-neutral — its tests still run on Linux machines
   (issue #169) — but no Linux host ships.
2. **Hosts render; the backend decides.** All policy — scheduling, idle
   accounting, update trust, storage — lives in the Racket domain core
   (`racket/`, `app/backend.rkt`). Hosts forward user actions over RVT1
   and carry out installation steps the backend has already verified.
   They never implement crypto or policy.
3. **Safety is a hard contract.** No fullscreen forced break, no focus
   theft, no forced input interception, no click-outside dismissal, no
   hidden meeting surveillance (issues #54, #90).
4. **Fail honestly.** Failed update checks, unsupported sessions,
   absent idle APIs: report what failed and what MoveBit falls back to.
   No invented idle data, no silent fallbacks, and no `continue-on-error`
   jobs, empty tests, skipped UI or force-killed processes as success
   evidence.
5. **Privacy is a feature.** Reminder and accounting work is local;
   update checks and release downloads contact GitHub Releases only. No
   accounts, no telemetry, no keystroke recording — idle detection asks
   the OS how long ago the last input was, nothing more. New storage
   stays under the platform data directory and keeps that claim true.
6. **Tests pin contracts.** If you change behavior a test covers, change
   the test in the same commit and say why. Updater changes must keep
   `racket/tests/update-test.rkt` green (signed-feed verification,
   attacker-negative fixtures, rollback).
7. **Keep the product slim.** The settings window holds sound, quiet
   hours, auto-update checks and language — nothing else (issue #140).
   The balanced 50/60/20 cadence is a product default, not a setter;
   propose UX additions in an issue before wiring a new control.
8. **Both languages, one truth.** User-visible behavior changes update
   `docs/USER-GUIDE.md` and `docs/USER-GUIDE.zh-CN.md` (plus the README
   entry points) in the same change. `VERSION` is single-source; the
   release tag must equal it (`scripts/check-release-version.sh`).

## Before you push

```bash
bash scripts/check-release-version.sh   # VERSION == rivet.rktd
raco rivet i18n                          # then confirm the two GeneratedI18n tables diff clean
raco test racket/                        # domain core + updater tests
raco rivet doctor                        # toolchain self-check
```

If you touched a platform host, build it (`raco rivet build` on
macOS/Windows) and say whether you could verify the packaged app
locally. Product-facing slices owe packaged acceptance
(`raco rivet acceptance --json`): a green unit suite or a screenshot
alone is not completion evidence.

## Reporting issues

Include: OS + version, MoveBit version, installation channel (MSI,
portable ZIP, DMG), steps to reproduce,
expected and actual results. Security issues go through
[SECURITY.md](SECURITY.md), not public issues.
