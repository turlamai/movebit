# Third-party notices

MoveBit builds on the components below. Each entry names where the
component enters the shipped artifacts and the license it is distributed
under; consult the upstream license files for full terms. The Rivet
toolchain and Permit are first-party TurLamAI projects (MIT) consumed as
pinned packages — not third-party code — so they are not listed here.

## Racket CS runtime

Every platform host embeds the statically linked Racket CS runtime
([racket/racket](https://github.com/racket/racket), 9.x). Racket is
distributed under the MIT license and the Apache License 2.0, at your
option; the Racket CS runtime system additionally embeds Chez Scheme,
distributed under the Apache License 2.0 (per Racket's `LICENSE.txt`).

## GTK 4 and GLib

The Linux host is a GTK 4 application. GTK and GLib are licensed under
the GNU Lesser General Public License, version 2.1 or later. Depending
on the Linux install shape the libraries come from two places:

- deb / rpm / AppImage / tar.gz: GTK 4 and its system libraries are the
  only runtime dependencies and are supplied by the distribution.
- `.flatpak` bundles: GTK 4, GLib and the rest of the desktop stack are
  supplied by the GNOME Platform 50 runtime (`org.gnome.Platform`), which
  bundles further desktop libraries under their own free-software
  licenses; see the runtime's documentation for complete notices.

## lz4 (Flatpak bundles only)

`.flatpak` bundles build [lz4](https://github.com/lz4/lz4) v1.9.4
library-only (`make lib-release`, pinned git tag and commit
`5ff839680134437dbf4678f3d0c7b371d84f4964`; see
`flatpak/site.jrtx.movebit.yml`). The `lib` directory of lz4 — the part
built and shipped here — is licensed BSD 2-Clause; the repository's other
files carry GPL-2.0-or-later terms and are not built into the bundle.

## ncurses / libtinfo (Flatpak bundles only)

`.flatpak` bundles build ncurses 6.5 from the pinned upstream archive
(`https://ftp.gnu.org/pub/gnu/ncurses/ncurses-6.5.tar.gz`, SHA-256
`136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6`),
library-only: just `libtinfo.so.6`, without programs and without a
terminfo database install. ncurses is distributed under an MIT-style
X-consortium license (copyright 1998-2023 Thomas E. Dickey and the Free
Software Foundation; see the `COPYING` file in the source archive).

## AppImageKit runtime (`.AppImage` artifacts)

`.AppImage` release artifacts contain the type-2 AppImage runtime from
[AppImage/AppImageKit](https://github.com/AppImage/AppImageKit),
licensed MIT. The build tool is the pinned official `appimagetool` 1.9.1
release, checksum-verified in `linux/build-appimage.sh`.
AppImageKit's license does not apply to the contents of the AppImage:
those are MoveBit's MIT payload plus the entries above.
