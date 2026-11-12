#!/usr/bin/env bash
# Hand-rolled .deb around rivet's staged Linux payload (RivetHost + res/ +
# runtime/ + app/). FHS layout: the self-contained app lives under
# /opt/movebit, /usr/bin/movebit is a symlink, plus a desktop entry and the
# hicolor icon. The Racket CS runtime is statically linked into RivetHost,
# so the only runtime Depends are the GTK4 stack (which pulls glib/cairo/
# pango) and libtinfo6 that the embedded runtime links against.
#
# Usage: build-deb.sh <version> <payload-dir> <arch> [output-dir]
#   <payload-dir>  rivet's staged package dir, i.e. dist/movebit-linux-<arch>/
#   <arch>         x64 | arm64  (deb Architecture: amd64 | arm64)
set -euo pipefail

version="${1:?usage: build-deb.sh <version> <payload-dir> <arch> [output-dir]}"
payload="${2:?usage: build-deb.sh <version> <payload-dir> <arch> [output-dir]}"
arch="${3:?usage: build-deb.sh <version> <payload-dir> <arch> [output-dir]}"
out_dir="${4:-dist}"
root="$(cd "$(dirname "$0")/.." && pwd)"

case "$arch" in
  x64) deb_arch=amd64 ;;
  arm64) deb_arch=arm64 ;;
  *) echo "error: unsupported arch '$arch' (want x64 or arm64)" >&2; exit 1 ;;
esac

[[ -x "$payload/RivetHost" ]] || { echo "error: $payload/RivetHost missing" >&2; exit 1; }
[[ -f "$payload/res/core.zo" ]] || { echo "error: $payload/res/core.zo missing" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pkg="$work/pkg"
mkdir -p "$pkg/DEBIAN" "$pkg/opt/movebit" "$pkg/usr/bin" \
  "$pkg/usr/share/applications" "$pkg/usr/share/icons/hicolor/256x256/apps"

cp -R "$payload"/. "$pkg/opt/movebit/"
chmod +x "$pkg/opt/movebit/RivetHost"
ln -s /opt/movebit/RivetHost "$pkg/usr/bin/movebit"

cat > "$pkg/DEBIAN/control" <<EOF
Package: movebit
Version: ${version}
Section: utils
Priority: optional
Architecture: ${deb_arch}
Maintainer: turlamai
Homepage: https://movebit.jrtx.site/
Depends: libgtk-4-1, libtinfo6
Description: Healthy work rhythm companion
 MoveBit tracks active work time and provides sit, water, and micro-break
 reminders. The package is self-contained; GTK 4 is the only external
 runtime dependency.
EOF

cat > "$pkg/usr/share/applications/movebit.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=MoveBit
Comment=Healthy work rhythm companion
Exec=/usr/bin/movebit
Icon=movebit
Terminal=false
Categories=Utility;
StartupNotify=false
EOF

cp "$root/assets/icon.png" "$pkg/usr/share/icons/hicolor/256x256/apps/movebit.png"

case "$out_dir" in
  /*) dest="$out_dir" ;;
  *) dest="$root/$out_dir" ;;
esac

mkdir -p "$dest"
artifact="$dest/movebit-${version}-linux-${arch}.deb"
dpkg-deb --build --root-owner-group "$pkg" "$artifact"

# Verify the package: metadata parses, payload and entries are present.
[[ "$(dpkg-deb --field "$artifact" Package)" == "movebit" ]]
[[ "$(dpkg-deb --field "$artifact" Version)" == "$version" ]]
[[ "$(dpkg-deb --field "$artifact" Architecture)" == "$deb_arch" ]]
dpkg-deb --contents "$artifact" > "$work/contents.txt"
grep -q '\./opt/movebit/RivetHost$' "$work/contents.txt"
grep -q '\./opt/movebit/res/core\.zo$' "$work/contents.txt"
grep -q '\./usr/share/applications/movebit\.desktop$' "$work/contents.txt"
grep -q '\./usr/share/icons/hicolor/256x256/apps/movebit\.png$' "$work/contents.txt"
# Symlink line carries a " -> target" suffix; anchor on the name only.
grep -q '\./usr/bin/movebit' "$work/contents.txt"
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$pkg/usr/share/applications/movebit.desktop"
fi

hash="$(sha256sum "$artifact" | awk '{print $1}')"
printf '%s  %s\n' "$hash" "$(basename "$artifact")" > "$artifact.sha256"
echo "deb: $artifact (${deb_arch}, $(du -h "$artifact" | cut -f1))"
