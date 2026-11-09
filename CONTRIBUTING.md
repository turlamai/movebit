# Contributing to MoveBit

Thank you for looking under the hood. MoveBit is MIT-licensed
(see [LICENSE](LICENSE)); by submitting a pull request you agree your
contribution is licensed under MIT along with the rest of the project.

## Ground rules

1. **One contract, three native hosts.** `app/backend.rkt` declares the
   RVT1 RPC/Event/State surface the SwiftUI, WinUI 3 and GTK 4 hosts
   render from. Changing any of it is a three-platform change, not a
   local edit: sync all three hosts and commit the regenerated tracked
   clients (`linux/GeneratedBackend.hpp`, `windows/GeneratedBackend.hpp`,
   `macos-host/Sources/RivetHost/GeneratedBackend.swift`) in the same
   commit. Changes under `shared/i18n/` likewise require `raco rivet i18n`;
   the three generated i18n tables (`linux/GeneratedI18n.hpp`,
   `windows/GeneratedI18n.hpp`,
   `macos-host/Sources/RivetHost/GeneratedI18n.swift`) are build inputs,
   and CI rejects drift with `git diff --exit-code`.
2. **Hosts render; the backend decides.** All policy — scheduling, idle
   accounting, update trust, storage — lives in the Racket domain core
   (`racket/`, `app/backend.rkt`). Hosts forward user actions over RVT1
   and carry out installation steps the backend has already verified.
   They never implement crypto or policy.
3. **Safety is a hard contract.** No fullscreen forced break, no focus
   theft, no forced input interception, no click-outside dismissal, no
   hidden meeting surveillance (issues #54, #90). CI runs
   `python3 scripts/check-mubi-input-safety.py --self-test` before the
   expensive host builds; keep its contract true.
4. **Fail honestly.** Failed update checks, unsupported Wayland sessions,
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
   attacker-negative fixtures, rollback). Changes to the commercial
   boundary (`commercial-policy.rkt`, `permit-adapter.rkt`,
   `license-store.rkt`) must keep `integration-tests/` green — CI runs
   them on Linux against a pinned Permit package, and ordinary Free
   builds must keep working with no Permit dependency.
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
raco rivet i18n                          # then confirm the three GeneratedI18n tables diff clean
raco test racket/                        # domain core + updater tests
raco rivet doctor                        # toolchain self-check
```

If you touched a platform host, build it (`raco rivet build` on
macOS/Windows; `raco rivet package` for the Linux host, which needs the
embeddable Racket CS runtime) and say whether you could verify the
packaged app locally. Product-facing slices owe packaged acceptance
(`raco rivet acceptance --json`): a green unit suite or a screenshot
alone is not completion evidence. The Permit integration contract is a
Linux CI step (`.github/workflows/ci.yml`) that installs the pinned
Permit package and runs `raco test integration-tests/`; replicate it
when you touch those files.

## Reporting issues

Include: OS + version, MoveBit version, installation channel (MSI,
portable ZIP, DMG, deb/rpm/AppImage/Flatpak/tar.gz), steps to reproduce,
expected and actual results. Security issues go through
[SECURITY.md](SECURITY.md), not public issues.
