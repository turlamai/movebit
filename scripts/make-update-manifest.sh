#!/usr/bin/env bash
# Build the MoveBit update manifest (rivet format) and merge platform
# artifacts from a release dist directory.
#
# Usage: scripts/make-update-manifest.sh <tag> <dist-dir> <key-der-path>
#   <tag>          release tag, e.g. v1.6.0 (must match the VERSION file)
#   <dist-dir>     directory containing the packaged archives, i.e. the
#                  names the release pipeline produces:
#                    movebit-<version>-macos-arm64.zip
#                    movebit-<version>-macos-x64.zip
#                    movebit-<version>-windows-x64.zip
#                    movebit-<version>-windows-x64.msi
#                    movebit-<version>-linux-x64.tar.gz
#                    movebit-<version>-linux-arm64.tar.gz
#                    movebit-<version>-linux-x64.AppImage
#                    movebit-<version>-linux-arm64.AppImage
#   <key-der-path> Ed25519 private key in DER (OneAsymmetricKey) form; the
#                  CI secret stores it base64-encoded.
#
# The signing, artifact hashing, schema validation, and feed format live in
# `raco rivet sign-manifest`; this wrapper owns only MoveBit's artifact
# matrix and identity. The tarball installer is `targz` (the family feed
# symbol), so an installed client selects it for its install kind.
#
# Env overrides: RELEASE_ASSET_BASE_URL, RIVET_UPDATE_KEY_ID.
set -euo pipefail

TAG="${1:?usage: make-update-manifest.sh <tag> <dist-dir> <key-der-path>}"
DIST="${2:?usage: make-update-manifest.sh <tag> <dist-dir> <key-der-path>}"
KEY_PATH="${3:?usage: make-update-manifest.sh <tag> <dist-dir> <key-der-path>}"
VERSION="${TAG#v}"
KEY_ID="${RIVET_UPDATE_KEY_ID:-movebit-2026-10}"
BASE_URL="${RELEASE_ASSET_BASE_URL:-https://github.com/turlamai/movebit/releases/download/$TAG}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$(cd "$DIST" && pwd)"
cd "$ROOT"

raco rivet check-release-version "$TAG"

BUILD="$(sed -nE 's/.*\(build \. ([0-9]+)\).*/\1/p' "$ROOT/rivet.rktd" | head -n1)"
[[ -n "$BUILD" ]] || {
  echo "error: could not read build from rivet.rktd" >&2
  exit 1
}
[[ -f "$KEY_PATH" ]] || {
  echo "error: missing signing key $KEY_PATH" >&2
  exit 1
}

raco rivet sign-manifest \
  --application-id site.jrtx.movebit \
  --version "$VERSION" \
  --build "$BUILD" \
  --channel stable \
  --base-url "$BASE_URL" \
  --key-id "$KEY_ID" \
  --private-key "$KEY_PATH" \
  --output "$DIST/update-manifest.json" \
  --artifact "macos:arm64:zip:$DIST/movebit-$VERSION-macos-arm64.zip" \
  --artifact "macos:x64:zip:$DIST/movebit-$VERSION-macos-x64.zip" \
  --artifact "windows:x64:zip:$DIST/movebit-$VERSION-windows-x64.zip" \
  --artifact "windows:x64:msi:$DIST/movebit-$VERSION-windows-x64.msi" \
  --artifact "linux:x64:targz:$DIST/movebit-$VERSION-linux-x64.tar.gz" \
  --artifact "linux:arm64:targz:$DIST/movebit-$VERSION-linux-arm64.tar.gz" \
  --artifact "linux:x64:appimage:$DIST/movebit-$VERSION-linux-x64.AppImage" \
  --artifact "linux:arm64:appimage:$DIST/movebit-$VERSION-linux-arm64.AppImage" \
  --rollback-allowed

echo "manifest: $DIST/update-manifest.json (8 artifacts, key-id $KEY_ID)"
