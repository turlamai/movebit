<!--
Title format: type(scope): summary — e.g. fix(updater): keep the portable swap waiting for process exit
-->

## Summary

What changed and why. Link the issue it closes (`Fixes #NNN`) when there is one.

## Platform impact

The RVT1 contract (`app/backend.rkt` RPC/Event/State surface) is one contract
rendered by three native hosts (SwiftUI / WinUI 3 / GTK 4): changing any of it
is a three-platform change, with the hosts and their generated clients
regenerated in the same commit.

- [ ] No backend contract changes (RPC/Event/State untouched)
- [ ] Generated clients regenerated in the same commit
      (`linux/GeneratedBackend.hpp`, `windows/GeneratedBackend.hpp`,
      `macos-host/Sources/RivetHost/GeneratedBackend.swift`)
- [ ] `raco rivet i18n` run for changes under `shared/i18n/`; the three
      GeneratedI18n tables diff clean

## Tests

How this is covered: `raco test racket/`, `racket/tests/update-test.rkt`,
`tests/` (Permit boundary), platform host builds, packaged
acceptance (`raco rivet acceptance --json`), or a new test added in the same
commit — say which ran and on which platform.

## Checklist

- [ ] CHANGELOG.md updated for user-visible changes
- [ ] Docs updated in the same change (USER-GUIDE / README, both languages)
- [ ] Safety contract intact: no fullscreen takeover, no focus theft, no
      forced input interception (issue #54)
- [ ] Security-relevant behavior flagged per [SECURITY.md](SECURITY.md)
