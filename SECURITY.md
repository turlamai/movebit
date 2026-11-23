# Security Policy

MoveBit keeps your data on your machine: activity history, settings and
self-reported outcomes live in plain JSON under the platform data
directory, and idle detection asks the OS exactly one fact — how long ago
the last input was. Reports are taken seriously and handled quickly.

## Reporting a vulnerability

Email **security@jrtx.site** (or open a GitHub security advisory on this
repository). Include reproduction steps, affected versions, and your
assessment of impact. You will get an acknowledgment within 72 hours.

Please do not open public issues for security problems.

## Scope

In scope:

- Update trust: verification of the Ed25519-signed `update-manifest.json`
  and its artifacts, key handling and rotation
  (`racket/movebit/update.rkt`, `scripts/make-update-manifest.sh`,
  `scripts/update-keys.sh`; key id `movebit-2026-10`)
- Local data handling: the config file, the per-device daily history
  shards (`racket/movebit/history.rkt`) and the per-machine bootstrap file
  (`racket/movebit/paths.rkt`)
- Idle detection: everything MoveBit learns from the OS about input
  presence (`GetLastInputInfo` / CoreGraphics) and what is recorded as a
  result
- The host/backend boundary: hosts render and install; the Racket backend
  (`app/backend.rkt`) decides. Crypto or policy sneaking into a native
  host is a bug.

Out of scope: social engineering, physical access attacks, and defects in
the OS-provided idle APIs themselves (GetLastInputInfo, CoreGraphics) —
those belong to the platform vendors.

## Design notes reviewers should know

- The backend owns no listening network port. Host ↔ backend RVT1 traffic
  runs over inherited file descriptors (`serve-fds`), and outbound network
  is limited to update checks and downloads against GitHub Releases.
- **Hosts never implement crypto.** Every signature check, digest
  computation and trust decision lives in the Racket backend (Rivet's
  distribution layer, with Ed25519 wired over the embedded runtime's
  FFI); the native hosts only carry out installation steps the backend
  has already verified and scripted.
- **Updates and installer trust are different layers.** The in-app updater
  verifies the Ed25519-signed manifest and the downloaded artifact's size
  and SHA-256 before any swap, and only self-applies where the install
  shape allows it: Windows portable ZIP swap (with backup and rollback) or
  a passive msiexec handoff for MSI installs under Program Files, and the
  macOS bundle swap. The signed feed answers windows + macos only
  (issue #169).
- The signed update feed **does not imply a publisher-signed installer**.
  macOS builds are ad-hoc signed (not notarized) and release binaries
  carry no publisher code signature; releases do publish a checked
  `SHA256SUMS` file covering every versioned package plus the signed
  `update-manifest.json`. Do not represent the feed signature as an
  independently trusted publisher identity.
- Local data is plain JSON under the platform data directory
  (`config.json`, `history/<day>/<device-id>.json`, `bootstrap.json`,
  `updates/`). Files are not encrypted; protection ultimately depends on
  OS user permissions and filesystem protection. Nothing here is
  telemetry: activity history stays on disk — or in a folder the user
  points MoveBit at for their own cross-device sync — and is never
  uploaded anywhere.

## Supported versions

Security fixes land on `main` first and ship with the next tagged release.
During the 0.x preview there is no LTS branch.
