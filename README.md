# MoveBit

> **v0.0.1 — the fresh start (2026-10-27).** The rebooted MoveBit first shipped as v0.0.1 by owner decision: a historical restart of the version line, not a statement of the current release. For the latest published build, check Releases. The old experimental v0.5.0 line (with its fullscreen forced breaks) is retired history — v0.0.1 contains no fullscreen break anywhere and no migration path from v0.5.

A desktop health reminder app: water, stand-up and eye-rest cues delivered by **Mubi（沐比）**, a small original character who walks onto your screen at each break, waits — topmost and unmissable — until you answer, and plays by itself while you work. It never steals keyboard focus, never covers your work, and everything outside Mubi itself stays click-through. One Racket domain core (the canonical reminder state machine) drives first-party native hosts on Windows, macOS, and Linux over [Rivet](https://github.com/turlamai/rivet)'s typed RPC.

[![release](https://img.shields.io/github/v/release/turlamai/movebit)](https://github.com/turlamai/movebit/releases/latest) ![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey) ![built with](https://img.shields.io/badge/built%20with-Rivet-c15f3c) [![CI](https://github.com/turlamai/movebit/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/movebit/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/license-BUSL--1.1-blue)](LICENSE)

**English** · [中文](README.zh-CN.md)

## Start here

Current preview is free and source-available under BUSL-1.1 (each version converts to MIT on its change date). A Free + Pro commercial edition is planned, but no paid activation, checkout or subscription is shipped or enabled yet; see [pricing policy](PRICING.md). Desktop previews for macOS, Windows and Linux. Idle detection depends on the desktop session; unsupported Wayland sessions fall back to elapsed time. On Linux, Mubi's companion card docks on X11 sessions — Wayland compositors don't let an app place a click-through card, so cues deliver as in-app reminder cards there.

[Installation, first use, privacy, backup and recovery](docs/USER-GUIDE.md) · [简体中文](docs/USER-GUIDE.zh-CN.md)

## Why

Most reminder tools lose the moment the notification becomes easy to dismiss — or they overcorrect with a fullscreen takeover. MoveBit is designed around a stronger contract:

- **Track active work instead of blindly counting wall-clock time.** Session-wide idle detection is available on Windows, macOS, Linux/X11, and Wayland sessions that expose an idle API. Otherwise MoveBit deliberately falls back to elapsed time instead of inventing idle data.
- **Deliver reminders you cannot miss and must answer.** Mubi（沐比）, a small original character, walks to the center of your work area on every break and waits there — above every window — until you respond. **Pet Mubi = Done** (a self-report), the bubble's Later tag defers, the tray keeps Done / Later / Hide reachable. A reminder that can be covered by another app or dismissed by a stray click is not a reminder.
- **Stay honest about what a click means.** Done is a self-report, never a measurement. Silence never counts as completion either: an unanswered invitation stays on screen, and a reminder firing while one is open merges into the same invitation (one Mubi, every meaning preserved) — nothing is settled behind your back. Focus mode queues cues and returns one bounded summary — never a pile-up.
- **Do not nag after a real break.** Being idle beyond the away threshold resets every reminder cycle when you return, and the break itself is never counted as active work.
- **Show patterns, not just today's number.** 7-day and 30-day activity history tracks continuous-work streaks, recent longest sessions, active-day averages, and the busiest recent day.
- **Ship native installers and portable archives for every supported desktop.** Windows gets an MSI plus a portable ZIP, macOS gets a DMG plus a portable ZIP on both Apple silicon and Intel, and Linux gets a portable tar.gz and zip plus a deb, an rpm, an AppImage, and a Flatpak bundle.

## Architecture

MoveBit is rebuilt on [Rivet](https://github.com/turlamai/rivet): all policy lives in one Racket domain core (`app/backend.rkt` + `racket/`), and every platform host is a thin native shell that renders state and forwards user actions over typed RPC (RVT1):

| Host | Stack | Directory |
| --- | --- | --- |
| Windows | WinUI 3 (C++/WinRT), embedded Racket CS | `windows/` |
| macOS | SwiftUI | `macos-host/` |
| Linux | GTK 4, embedded Racket CS | `linux/` |

The Racket runtime is statically linked into each host — no external interpreter, no .NET, no Electron. Config and history files, paths, and formats are identical across hosts (`%APPDATA%\movebit` on Windows, the platform application-data directory elsewhere), so an install upgrades in place.

## Features

- ⏱️ **Active-work monitoring** — Windows `GetLastInputInfo`, macOS CoreGraphics, Linux/X11 XScreenSaver, Wayland session-bus backends where available
- 🐹 **Mubi, the reminder character** — walks to your work area and waits, topmost, with clear advice text, screen-reader labels and Reduce Motion support. Between reminders it plays by itself — rolls, tilts, blinks, little hops — like a pet waiting nearby. Petting it answers the cue.
- 💧 **Three independent cycles** — water, sit and eye rest on the one balanced cadence (50 / 60 / 20 active minutes); several due reminders merge into one cue with every meaning preserved
- ✅ **An honest cue lifecycle** — due → pending/displayed → acknowledged (self-reported) | snoozed; invitations persist until answered and never pile up — a new reminder merges into the open one
- 🎯 **Focus mode** — presentation silence that queues cues and returns one bounded summary; tray Done/Later/Hide stay reachable at all times
- 📊 **7 / 30-day history** — switchable activity chart backed by up to 370 days of persisted history
- 🧠 **Work-pattern insights** — current continuous session, today's/recent longest session, active-day average, busiest recent day
- 🌓 **中文 / English** — switched in app or resolved from the system UI language
- 🔁 **Autostart on login** — Windows registry / macOS LaunchAgent / Linux XDG autostart, owned by the backend
- ⏸️ **Pause for one hour** — with exact pause-expiry accounting
- 🔒 **Single-instance activation** — relaunching surfaces the existing instance instead of duplicating it
- 📦 **Native + portable distribution** — Windows MSI, macOS DMG, portable ZIPs, Linux tar.gz/zip/deb/rpm/AppImage/Flatpak

## Install

Grab your build from [Releases](https://github.com/turlamai/movebit/releases/latest):

| Platform | Portable archive | Installer |
| --- | --- | --- |
| macOS Apple silicon | `movebit-<version>-macos-arm64.zip` | `movebit-<version>-macos-arm64.dmg` |
| macOS Intel | `movebit-<version>-macos-x64.zip` | `movebit-<version>-macos-x64.dmg` |
| Windows x64 | `movebit-<version>-windows-x64.zip` | `movebit-<version>-windows-x64.msi` |
| Windows ARM64 | runs the x64 build via Windows on ARM's x64 emulation | — |
| Linux x64 | `movebit-<version>-linux-x64.tar.gz` · `.zip` | `movebit-<version>-linux-x64.deb` · `-x86_64.rpm` · `.AppImage` · `.flatpak` |
| Linux arm64 | `movebit-<version>-linux-arm64.tar.gz` · `.zip` | `movebit-<version>-linux-arm64.deb` · `-aarch64.rpm` · `.AppImage` · `.flatpak` |

Assets follow one lowercase scheme, `movebit-<version>-<os>-<arch>.<ext>` (for example `movebit-0.0.6-macos-arm64.dmg`). Release downloads include one checked `SHA256SUMS` file covering all versioned packages and the Ed25519-signed `update-manifest.json` for in-app updates. Per-file checksum sidecars and duplicate versionless installers are not published.

Platform notes:

- **Windows** — run the MSI for a normal installed app, or unpack the portable ZIP anywhere you like. On ARM64 Windows, use the x64 assets: Windows on ARM runs them through its x64 emulation, and no native ARM64 build is published.
- **macOS** — open the DMG and drag the app to Applications (or another folder); the portable ZIP is the same app bundle without the disk image. Builds are ad-hoc signed, not notarized, so Gatekeeper may require an explicit first-launch approval (right-click → Open, or `xattr -cr /Applications/MoveBit.app`). Notarization is deferred until paid Apple developer credentials are available.
- **Linux** — install the deb (`sudo apt install ./movebit-<version>-linux-<arch>.deb`), install the rpm, run the AppImage, or unpack the tar.gz and run the host inside; GTK 4 and its system libraries are the only runtime dependencies, everything else is bundled. The deb installs to `/opt/movebit` with a `movebit` command and a desktop entry. The Flatpak bundle (app id `site.jrtx.movebit`) installs with `flatpak --user install ./movebit-<version>-linux-<arch>.flatpak`; it carries the app payload only and pulls the GNOME Platform runtime from your Flatpak remote on first install.

> Release binaries carry no publisher code signature. Windows SmartScreen or macOS Gatekeeper may therefore show a warning on first launch. Paid code signing/notarization is the remaining distribution roadmap item.

## How it works

Three independent cycles advance on a 30-second scheduler tick, all on one balanced cadence that is the product's default and needs no studying:

- **Sit cycle** accumulates active work only. At 50 active minutes it becomes a cue — Mubi stands up and invites a stretch.
- **Water cycle** runs independently — every 60 active minutes Mubi raises a cup.
- **Eye-rest cycle** runs independently — every 20 active minutes Mubi closes its eyes and suggests looking far away.

Idle time at or above the away threshold (5 minutes) freezes accumulation. On return, all cycles restart from zero. Oversized clock jumps such as system sleep are clamped so stale reminders are not dumped after wake.

Each due tick merges into ONE cue that moves through an explicit lifecycle: `due → pending/displayed → acknowledged | snoozed`. Done is a self-report (never a measurement) — on screen it is petting Mubi; Later defers every merged kind by 10 active minutes; Hide claims nothing. An invitation never expires or auto-dismisses: it waits on top of every window until answered, and a reminder firing while one is open merges into it. Focus mode queues cues silently and delivers one bounded summary when it ends.

Daily stats are flushed to the history store every few minutes, archived across day boundaries, and pruned to the most recent 370 days.

## Configuration

Settings live in `%APPDATA%\movebit\config.json` on Windows or the platform application-data directory on macOS/Linux. The defaults are the product: there is no rhythm to study, no per-kind switches and no presentation options — the balanced cadence (50/60/20), one companion presentation and drag-to-place (plus Move Aside) cover it. Four controls remain in the settings window, and the backend clamps and re-announces every change:

| Setting | Default |
| --- | --- |
| Sound (one soft chime per arrival) | on |
| Quiet hours window | off, 22:00–07:00 |
| Auto update checks | on |
| Language | auto (system), zh / en |

"Not now" lives in the tray, not in settings: Focus defers everything, Pause silences an hour, Later snoozes one cue. The on-disk config carries a `SchemaVersion` marker (v5); older on-disk schemas migrate, keeping your language, quiet hours, sound and Mubi position; a file without a known marker is foreign and falls back to defaults.

## Build from source

Prerequisites: [Racket CS](https://racket-lang.org) (9.x), the [rivet](https://github.com/turlamai/rivet) CLI linked into it, and per-host toolchains (Visual Studio with WinUI for Windows, GTK 4 dev packages for Linux, Xcode for macOS).

```bash
git clone https://github.com/turlamai/rivet.git ../rivet
raco pkg install --auto --no-docs --link ../rivet/rivet ../rivet/rivet-cli

raco rivet doctor        # toolchain self-check
raco test racket/        # domain core tests
raco rivet build         # generate the client, compile the backend, build this platform's host
```

Linux packaging scripts (deb / rpm / AppImage) live under `packaging/linux/` and operate on rivet's staged `dist/` payload.

## Release process

1. Bump the single-source `VERSION` file; `scripts/check-release-version.sh` enforces `VERSION == rivet.rktd`, and the release tag must equal it too (for example `0.3.1` ↔ `v0.3.1`).
2. Add a `CHANGELOG.md` section for the version — the release validate job greps for it.
3. Merge only with CI green (Racket tests plus the Windows/macOS/Linux host matrix).
4. Push the version tag. Release automation builds macOS DMG + portable ZIP (arm64 and x64), the Windows MSI + portable ZIP, the Linux tar.gz + zip (x64 + arm64) plus deb, rpm, AppImage, and Flatpak bundle installers, one consolidated `SHA256SUMS` manifest and the signed `update-manifest.json`; one GitHub Release is created only after every required package succeeds, with the release notes taken from the matching CHANGELOG section.

## Roadmap

- [x] Tray icon with quick actions (open / pause / exit) on Windows
- [x] In-app signed-manifest updates shipped on all three hosts ([0.5.0](https://github.com/turlamai/movebit/releases/tag/v0.5.0)): cancellable downloads, Windows MSI self-update through a passive msiexec handoff, and backup + rollback around the zip swap.
- [x] Cancellation, signature-rejection and rollback evidence at the updater test level (`racket/tests/update-test.rkt`, runs on CI).
- [x] v0.0.1 published as the fresh-start baseline with the signed update feed live (`update-manifest.json` on every release).
- [ ] Live N→N+1 update evidence recorded for every supported install shape (the updater tests prove the mechanics; a recorded real update per shape is still to do).
- [ ] Windows code signing and macOS signing/notarization
- [ ] Windows/Linux gesture-motion polish measurements (packaged desktop review, #56 D4)
- **Not planned: mobile (iOS / iPadOS / Android) and watchOS.** MoveBit guards against long uninterrupted sitting at a desk — a problem that only exists where people work at a computer for hours. On phones and tablets people stand, walk, or recline, so there is nothing to guard against. The product is desktop cross-platform by design: macOS, Windows, and Linux.

## License

[BUSL-1.1](LICENSE)
