# MoveBit user guide

**English** · [简体中文](USER-GUIDE.zh-CN.md)

Water, stand-up and eye-rest reminders delivered by Mubi（沐比）, a small original character at the edge of your screen — never a fullscreen cover, never stolen focus, never intercepted input.

## Availability

Current public preview: MIT-licensed source and no enabled paid activation or subscription. Select the actual published version from Releases; this guide does not claim the historical v0.0.1 baseline is the latest build.

## Platforms and installation

Official releases target Windows x64, macOS (Apple silicon and Intel) and Linux x64/arm64. Every platform ships a portable archive; Windows adds an MSI, macOS a DMG, Linux a deb, rpm and AppImage. Use the [official Releases](https://github.com/turlamai/movebit/releases), select an explicitly listed OS/architecture asset, and check the supplied SHA-256 sidecars. Preview assets may lack publisher signing or notarization; do not disable system-wide security protections to install them.

Platform notes: idle detection uses the native desktop APIs (GetLastInputInfo / CoreGraphics / XScreenSaver). On Linux, Mubi's card docks on X11 sessions; on Wayland the compositor does not let an app place a click-through card, so cues deliver as in-app reminder cards instead (reminders, history and updates work as usual).

## Your first session

1. Install and launch. The one-screen welcome shows Mubi, one sentence and a **Start** button — no cadence questions. The shipped rhythm is Balanced and silent; change it whenever you like in settings.
2. Meet Mubi. When a cycle is due, the character appears at the screen edge with a clear health suggestion and an actionable label. The card rests after a few seconds; Done / Later / Hide sit right on it.
3. Respond your way: **Done** (a self-report — never a measurement), **Later** (defers by the snooze interval), **Hide** (puts it away; the next cycle arrives on schedule). All three sit on the reminder card itself — the tray menu (Windows / macOS) reaches them too — and the character and its text stay pointer-through; only the action row accepts clicks.
4. Enable login startup only if you want background reminders. Treat the history charts as usage estimates, not health measurements.

## Mubi, focus mode and honesty

- The three gestures map to the three reminders: sit → stretch, water → raised cup, eye rest → closed eyes. Several due reminders merge into one cue with every meaning preserved.
- **Focus mode** (the tray toggle on Windows / macOS, a header button on Linux) queues cues silently during presentations and delivers ONE bounded summary when it ends — never a pile-up. Cues that were already on screen are not re-emitted.
- Unanswered cues expire after ten minutes and the next reminder arrives on its normal schedule. Silence never counts as completion, and nothing is lost.
- Personalize Mubi in settings: size S/M/L (body heights 60/78/104), motion (still/subtle/lively), dock position, label visibility. Reduce Motion (or motion "still") renders everything static.
- **Place Mubi…** in the menu (macOS and Windows tray, Linux X11 tray or header) turns the character into a draggable surface for up to 30 seconds; choose **Done placing** (or wait) and the position is remembered per display, scaled and clamped on monitor/DPI changes. A position saved by a synced profile is honored on every desktop; Wayland keeps the notification fallback.
- There is no fullscreen forced break anywhere in v0.0.1, and no way to opt back into one — that contract was removed on purpose.

## Reminder rhythm, quiet hours and honesty

MoveBit offers three named rhythms. They are product defaults, not medical advice — adjust them to your day:

| Preset | Stand up | Water | Eye rest |
| --- | --- | --- | --- |
| **Balanced** (default) | every 50 active min, suggest 5 min away | every 60 active min | every 20 active min, look away 20 s |
| **Gentle** | every 75 active min | every 90 active min | every 30 active min, look away 20 s |
| **Frequent** | every 30 active min | every 45 active min | every 15 active min, look away 20 s |

- Countdowns use **active time** at the desk, not wall-clock time: idle past the away threshold (5 minutes by default) counts as a real break and resets the cycles.
- **Customize** exposes per-kind switches, custom intervals, the snooze length, the away threshold, quiet hours, the character size/motion/dock and the language. Editing a cadence turns the rhythm label into Custom; the app never silently swaps your numbers for a preset.
- **Quiet hours** pause all reminders inside a local-time window (for example 22:00 to 07:00, wrapping midnight) and resume at the end; setting the same start and end means off. **Focus** remains the immediate meeting/presentation action.
- The main window shows the nearest next reminder and, per kind, how many invitations were actually **presented** next to how many you marked **Done**. Done is your own report: it never claims you drank water, stood up or rested your eyes.

## Work history

Today's active minutes, presented invitations and self-reported Done counts, plus the 7/30-day charts, live in the main window; history is retained for 370 days. A day or kind with no recorded evidence is shown as unknown, never as a completed action. Activity time counts only real keyboard/mouse presence — idle time past the away threshold (5 minutes by default) is treated as a real break and resets the cycles.

## Data, backup and recovery

Quit MoveBit and back up `config.json` and the `history/` folder: `~/Library/Application Support/movebit` on macOS, `~/.config/movebit` on Linux, `%APPDATA%\movebit` on Windows. The v1 config file carries a `SchemaVersion` marker; a file without it falls back to defaults rather than being half-migrated. Restore into a copy first.

## Network, keys and privacy

Reminder and accounting work is local. Update checks and release downloads contact GitHub Releases only. There is no account, no telemetry, no keystroke recording — idle detection asks the OS how long ago the last input was, nothing more. Mubi's panel never reads input.

## Updates and removal

The in-app **Check for updates** reads the Ed25519-signed `update-manifest.json`, verifies size and SHA-256 after download, and swaps the payload only through **Update & restart**. A failed check aborts without touching the current install. Removing the program does not erase the separate data directory; verify your backup before deleting personal data.

For Windows portable ZIP updates, a failed copy or an executable that Windows cannot start restores the previous installation and attempts to relaunch it. The updater records the failure in `updates/update-failed.txt` under the application data directory. Acceptance of a launch by Windows is not a full application-health check: a later crash, complete GUI restart and real-version rollback remain separate qualification gates. MSI updates use the Windows Installer handoff instead of this portable swap.

Before replacing a Windows portable installation, the helper waits up to two minutes for the previous process to exit. If exit cannot be confirmed, it leaves the installation untouched and records that the update was not applied; it does not force the application to quit. Close the existing application normally before trying the update again.

## Get help

Report problems in [GitHub Issues](https://github.com/turlamai/movebit/issues), in English or Chinese. Include the version, OS/architecture, installation channel, steps, expected and actual results. Do not attach keys, credentials, databases or complete logs. Public support has no guaranteed response time.

## Further reading

- [Project overview and development](../README.md)
- [Mubi design system](MUBI-DESIGN-SYSTEM.md)
- [Current licence](../LICENSE)
