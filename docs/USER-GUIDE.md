# MoveBit user guide

**English** · [简体中文](USER-GUIDE.zh-CN.md)

Water, stand-up and eye-rest reminders delivered by Mubi（沐比）, a small original character who walks onto your screen at each break, waits — topmost and unmissable — until you answer, and plays by itself between reminders. It never steals keyboard focus, never covers your work, and everything outside Mubi itself stays click-through.

## Availability

Current public preview: MIT-licensed source and no enabled paid activation or subscription. Select the actual published version from Releases; this guide does not claim the historical v0.0.1 baseline is the latest build.

## Platforms and installation

Official releases target Windows x64, macOS (Apple silicon and Intel) and Linux x64/arm64. Every platform ships a portable archive; Windows adds an MSI, macOS a DMG, Linux a deb, rpm, AppImage and Flatpak bundle. Use the [official Releases](https://github.com/turlamai/movebit/releases), select an explicitly listed OS/architecture asset, and check the release's `SHA256SUMS` file. On Linux the Flatpak bundle installs with `flatpak --user install ./movebit-<version>-linux-<arch>.flatpak` (app id `site.jrtx.movebit`; it carries the app payload only, and the GNOME Platform runtime is pulled from your Flatpak remote on first install). Preview assets may lack publisher signing or notarization; do not disable system-wide security protections to install them.

Platform notes: idle detection uses the native desktop APIs (GetLastInputInfo / CoreGraphics / XScreenSaver). On Linux, Mubi's card docks on X11 sessions; on Wayland the compositor does not let an app place a click-through card, so cues deliver as in-app reminder cards instead (reminders, history and updates work as usual).

## Your first session

1. Install and launch. The one-screen welcome shows Mubi, one sentence and a **Start** button — no cadence questions. The shipped rhythm is Balanced and silent; change it whenever you like in settings.
2. Meet Mubi. When a cycle is due, the character walks to the center of your work area — above every window — and WAITS with a clear health suggestion until you answer. No timer withdraws it and clicking elsewhere does nothing.
3. Respond your way: **pet Mubi** (tap the character — a self-report, never a measurement), the **Later** tag on its bubble (defers by 10 active minutes), or the tray's Done / Later / Hide. Outside Mubi itself everything stays pointer-through; the tray menu reaches all actions at any time.
4. Enable login startup only if you want background reminders. Treat the history charts as usage estimates, not health measurements.

## Mubi, focus mode and honesty

- The three gestures map to the three reminders: sit → stretch, water → raised cup, eye rest → closed eyes. Several due reminders merge into one cue with every meaning preserved.
- **Focus mode** (the tray toggle on Windows / macOS, a header button on Linux) queues cues silently during presentations and delivers ONE bounded summary when it ends — never a pile-up. Cues that were already on screen are not re-emitted.
- An unanswered invitation stays on screen — silence is never counted as completion, and nothing is lost. A reminder firing while one is open merges into the same invitation: always exactly one Mubi, every meaning preserved.
- While a water / stand / eye cue is open, the menu can offer an optional **20 s eye rest** or **2 min stretch** card: nothing counts down until you press Start, Done is your explicit self-report, and Hide/Esc ends it without claiming a break.
- Mubi plays by itself between reminders — rolls, tilts, blinks, little hops near its dock — like a pet waiting nearby. System Reduce Motion renders everything static.
- **Place Mubi…** in the menu (macOS, the Windows tray, and the Linux X11 tray or header) turns the character into a draggable surface for up to 30 seconds; choose **Done placing** (or wait) and the position is remembered per display, scaled and clamped on monitor/DPI changes. On Wayland the compositor owns placement, so the character keeps the notification fallback.
- There is no fullscreen forced break anywhere in v0.0.1, and no way to opt back into one — that contract was removed on purpose.

## Rhythm, quiet hours and honesty

There is one balanced cadence, shipped as the product default and not configurable: stand up every 50 active minutes, water every 60, eye rest every 20 (look away 20 s). "Not now" lives in the tray, not in settings — **Focus** defers everything, **Pause** silences an hour, **Later** snoozes one cue.

- Countdowns use **active time** at the desk, not wall-clock time: idle past the away threshold (5 minutes) counts as a real break and resets the cycles.
- The settings window keeps exactly four controls: sound (one soft chime per arrival), quiet hours, auto update checks and the language.
- **Quiet hours** pause all reminders inside a local-time window (for example 22:00 to 07:00, wrapping midnight) and resume at the end; setting the same start and end means off. **Focus** remains the immediate meeting/presentation action.
- The main window shows the nearest next reminder and, per kind, how many invitations were actually **presented** next to how many you marked **Done**. Done is your own report: it never claims you drank water, stood up or rested your eyes.

## Work history

Today's active minutes, presented invitations and self-reported Done counts, plus the 7/30-day charts, live in the main window; history is retained for 370 days. A day or kind with no recorded evidence is shown as unknown, never as a completed action. Activity time counts only real keyboard/mouse presence — idle time past the away threshold (5 minutes by default) is treated as a real break and resets the cycles.

## Data, backup and recovery

Quit MoveBit and back up `config.json` and the `history/` folder: `~/Library/Application Support/movebit` on macOS, `~/.config/movebit` on Linux, `%APPDATA%\movebit` on Windows. The v1 config file carries a `SchemaVersion` marker; a file without it falls back to defaults rather than being half-migrated. Restore into a copy first.

## Network, keys and privacy

Reminder and accounting work is local. Update checks and release downloads contact GitHub Releases only. There is no account, no telemetry, no keystroke recording — idle detection asks the OS how long ago the last input was, nothing more. Mubi's panel never reads input.

## Updates and removal

The in-app **Check for updates** reads the Ed25519-signed `update-manifest.json`, verifies size and SHA-256 after download, and swaps the payload only through **Update & restart**. A failed check aborts without touching the current install. AppImage installs take that in-place update; deb, rpm and Flatpak installs are owned by their package managers, and portable tar.gz installs are yours to manage — for all of these the updater downloads the verified artifact and shows guidance instead of swapping. Update with the package manager (`flatpak --user update site.jrtx.movebit` for the Flatpak bundle) or install the new release over the old one.

For Windows portable ZIP updates, a failed copy or an executable that Windows cannot start restores the previous installation and attempts to relaunch it. The updater records the failure in `updates/update-failed.txt` under the application data directory. Acceptance of a launch by Windows is not a full application-health check: a later crash, complete GUI restart and real-version rollback remain separate qualification gates. MSI updates use the Windows Installer handoff instead of this portable swap.

Before replacing a Windows portable installation, the helper waits up to two minutes for the previous process to exit. If exit cannot be confirmed, it leaves the installation untouched and records that the update was not applied; it does not force the application to quit. Close the existing application normally before trying the update again.

Removing the program does not erase your data. `config.json` and the `history/` folder live in the separate data directory (`~/Library/Application Support/movebit` on macOS, `~/.config/movebit` on Linux, `%APPDATA%\movebit` on Windows; a Flatpak install keeps its sandboxed copy under `~/.var/app/site.jrtx.movebit/`, and `flatpak --user uninstall --delete-data site.jrtx.movebit` removes it together with the app). Uninstall the program per platform:

- **Windows** — remove the MSI from Settings → Apps (Apps & Features); a portable ZIP is removed by deleting its folder.
- **macOS** — drag MoveBit from Applications to the Trash.
- **Linux** — remove the deb/rpm with the package manager that installed it (the deb installs to `/opt/movebit`), delete an AppImage, tar.gz or zip copy like any standalone file or folder, and remove the Flatpak bundle with `flatpak --user uninstall site.jrtx.movebit`.

Login-autostart entries the app manages itself — the `MoveBit` value under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` on Windows, `~/Library/LaunchAgents/com.turlamai.movebit.plist` on macOS, and `~/.config/autostart/movebit.desktop` on Linux — are user-level settings that can outlive the program; delete them if you no longer want MoveBit to start at login. Deleting personal data is a separate, explicit action after you have verified your backup.

## Get help

Report problems in [GitHub Issues](https://github.com/turlamai/movebit/issues), in English or Chinese. Include the version, OS/architecture, installation channel, steps, expected and actual results. Do not attach keys, credentials, databases or complete logs. Public support has no guaranteed response time.

## Further reading

- [Project overview and development](../README.md)
- [Mubi design system](MUBI-DESIGN-SYSTEM.md)
- [Current licence](../LICENSE)
