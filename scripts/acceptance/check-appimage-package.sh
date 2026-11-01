#!/usr/bin/env bash
# Exercise the actual Rivet Linux release AppImage, not just 'raco rivet package'.
# This smoke verifies the exact ELF architecture and extracts the executable
# filesystem without FUSE. It does not claim GUI launch or in-place upgrade.
set -euo pipefail

arch="${1:?usage: check-appimage-package.sh x64|arm64}"
case "$arch" in
  x64) expected_machine='Advanced Micro Devices X86-64' ;;
  arm64) expected_machine='AArch64' ;;
  *) echo "unsupported architecture: $arch" >&2; exit 2 ;;
esac

version="$(tr -d '\r\n' < VERSION)"
shopt -s nullglob
images=(dist/movebit-*-linux-*.AppImage)
if (( ${#images[@]} != 1 )); then
  printf 'expected exactly one native AppImage; found %s\n' "${#images[@]}" >&2
  printf '%s\n' "${images[@]}" >&2
  exit 1
fi

appimage="${images[0]}"
[[ -s "$appimage" && -x "$appimage" ]] || {
  echo "release AppImage is missing, empty or nonexecutable" >&2
  exit 1
}
file "$appimage"
machine="$(readelf -h "$appimage" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')"
[[ "$machine" == "$expected_machine" ]] || {
  echo "AppImage ELF machine '$machine' does not match $arch" >&2
  exit 1
}

# Verify the built AppImage runtime itself runs and can extract the payload.
# No network or FUSE access and no user-installed application are needed.
timeout 25s "$appimage" --appimage-version
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
(
  cd "$workdir"
  timeout 90s "$GITHUB_WORKSPACE/$appimage" --appimage-extract >/dev/null
  test -x squashfs-root/AppRun
  find squashfs-root -maxdepth 4 -name '*.desktop' -type f | grep -q .
)
printf 'AppImage release build/extraction smoke passed: %s (%s)\n' "$appimage" "$arch"
