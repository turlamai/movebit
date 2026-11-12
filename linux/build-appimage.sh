#!/usr/bin/env bash
# Hand-rolled AppImage around rivet's staged Linux payload. Downloads the
# official appimagetool (AppImage/appimagetool, tag-pinned, SHA-256-checked
# per architecture), assembles an AppDir (AppRun + desktop entry + icon +
# the self-contained payload under usr/share/movebit), then validates the
# built AppImage by self-extracting it and asserting the payload.
#
# Usage: build-appimage.sh <version> <payload-dir> <arch> [output-dir]
#   <payload-dir>  rivet's staged package dir, i.e. dist/movebit-linux-<arch>/
#   <arch>         x64 | arm64
#
# Set APPIMAGE_EXTRACT_AND_RUN=1 when FUSE is unavailable (CI runners) —
# both appimagetool and the produced AppImage are type-2 AppImages whose
# runtime honors it.
set -euo pipefail

version="${1:?usage: build-appimage.sh <version> <payload-dir> <arch> [output-dir]}"
payload="${2:?usage: build-appimage.sh <version> <payload-dir> <arch> [output-dir]}"
arch="${3:?usage: build-appimage.sh <version> <payload-dir> <arch> [output-dir]}"
out_dir="${4:-dist}"
root="$(cd "$(dirname "$0")/.." && pwd)"

# Pinned toolchain: AppImage/appimagetool release 1.9.1 (official, static,
# type-2 AppImage). Checksums captured from the release downloads.
APPIMAGETOOL_TAG=1.9.1
case "$arch" in
  x64)
    tool_arch=x86_64
    tool_sha256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
    ;;
  arm64)
    tool_arch=aarch64
    tool_sha256=f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158
    ;;
  *) echo "error: unsupported arch '$arch' (want x64 or arm64)" >&2; exit 1 ;;
esac

[[ -x "$payload/RivetHost" ]] || { echo "error: $payload/RivetHost missing" >&2; exit 1; }
[[ -f "$payload/res/core.zo" ]] || { echo "error: $payload/res/core.zo missing" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Fetch + verify the pinned appimagetool.
tool="$work/appimagetool-${tool_arch}.AppImage"
curl --fail --location --retry 3 --output "$tool" \
  "https://github.com/AppImage/appimagetool/releases/download/${APPIMAGETOOL_TAG}/appimagetool-${tool_arch}.AppImage"
echo "${tool_sha256}  $tool" | sha256sum -c -
chmod +x "$tool"

# Assemble the AppDir.
appdir="$work/MoveBit.AppDir"
mkdir -p "$appdir/usr/share/movebit"
cp -R "$payload"/. "$appdir/usr/share/movebit/"
chmod +x "$appdir/usr/share/movebit/RivetHost"

cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/share/movebit/RivetHost" "$@"
EOF
chmod +x "$appdir/AppRun"

cat > "$appdir/movebit.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=MoveBit
Comment=Healthy work rhythm companion
Exec=AppRun
Icon=movebit
Terminal=false
Categories=Utility;
StartupNotify=false
X-AppImage-Version=${version}
EOF

cp "$root/assets/icon.png" "$appdir/movebit.png"
ln -s movebit.png "$appdir/.DirIcon"

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$appdir/movebit.desktop"
fi

case "$out_dir" in
  /*) dest="$out_dir" ;;
  *) dest="$root/$out_dir" ;;
esac

mkdir -p "$dest"
artifact="$dest/movebit-${version}-linux-${arch}.AppImage"
APPIMAGE_EXTRACT_AND_RUN=1 "$tool" "$appdir" "$artifact"

# Validate: self-extract the produced AppImage and assert the payload.
extract="$work/extracted"
mkdir -p "$extract"
( cd "$extract" && "$artifact" --appimage-extract > /dev/null )
test -x "$extract/squashfs-root/AppRun"
test -x "$extract/squashfs-root/usr/share/movebit/RivetHost"
test -f "$extract/squashfs-root/usr/share/movebit/res/core.zo"
test -f "$extract/squashfs-root/movebit.desktop"

hash="$(sha256sum "$artifact" | awk '{print $1}')"
printf '%s  %s\n' "$hash" "$(basename "$artifact")" > "$artifact.sha256"
echo "AppImage: $artifact ($(du -h "$artifact" | cut -f1))"
