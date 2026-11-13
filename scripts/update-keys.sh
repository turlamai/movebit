#!/usr/bin/env bash
# Generate the Ed25519 keypair used to sign MoveBit update manifests
# (family contract: taskly shared/spec/UPDATE.md).
#
#   scripts/update-keys.sh [private-key-path]
#
# Default private key location: ~/.movebit/update-signing-key.pem — OUTSIDE
# the repository. The private key never enters the repo; CI signs releases
# with the GitHub secret UPDATE_ED25519_PRIVATE_KEY_B64, which stores the
# key base64-encoded in DER (OneAsymmetricKey) form — exactly what
# make-update-manifest.sh and `raco rivet release` consume.
#
# Outputs, in order:
#   1. the private key path
#   2. the DER base64 to paste into the GitHub secret (gh secret set
#      UPDATE_ED25519_PRIVATE_KEY_B64)
#   3. the SPKI hex replacement for racket/movebit/update.rkt
#      (current-update-public-key-hex)
#
# Rotate = ship a build that trusts the next key before releases stop
# being signed with the old one (see the family UPDATE spec). Current
# clients verify signatures, so a rotation needs an overlap release: there
# is no "no shipped client verifies yet" shortcut.

set -euo pipefail

KEY_PATH="${1:-$HOME/.movebit/update-signing-key.pem}"
KEY_ID="${RIVET_UPDATE_KEY_ID:-movebit-2026-10}"

# Ed25519 needs OpenSSL 3+ (macOS ships LibreSSL, which cannot do it).
OPENSSL_BIN="${OPENSSL_BIN:-}"
if [[ -z "$OPENSSL_BIN" ]]; then
  for candidate in /opt/homebrew/opt/openssl@3/bin/openssl \
                   /usr/local/opt/openssl@3/bin/openssl openssl; do
    if command -v "$candidate" >/dev/null 2>&1 \
       && "$candidate" version 2>/dev/null | grep -q "OpenSSL 3"; then
      OPENSSL_BIN="$candidate"
      break
    fi
  done
fi
[[ -n "$OPENSSL_BIN" ]] || {
  echo "error: OpenSSL 3.x required for Ed25519 (brew install openssl@3," >&2
  echo "       or set OPENSSL_BIN=/path/to/openssl)" >&2
  exit 1
}

if [[ -f "$KEY_PATH" ]]; then
  echo "Private key already exists: $KEY_PATH" >&2
  echo "Delete it first if you really want to rotate (rotating requires a" >&2
  echo "public-key rollout release — see the family UPDATE spec)." >&2
  exit 1
fi

mkdir -p "$(dirname "$KEY_PATH")"
umask 077
"$OPENSSL_BIN" genpkey -algorithm ed25519 -out "$KEY_PATH"

DER_B64="$("$OPENSSL_BIN" pkey -in "$KEY_PATH" -outform DER 2>/dev/null | base64 | tr -d '\n')"
PUB_HEX="$("$OPENSSL_BIN" pkey -in "$KEY_PATH" -pubout -outform DER 2>/dev/null | tail -c 32 | od -An -tx1 | tr -d ' \n')"

echo "Private key: $KEY_PATH  (back this up)"
echo "key-id: $KEY_ID"
echo "GitHub secret (gh secret set UPDATE_ED25519_PRIVATE_KEY_B64):"
echo "  $DER_B64"
echo "Public key: replace current-update-public-key-hex in"
echo "racket/movebit/update.rkt with these two literals:"
echo "  \"302a300506032b6570032100\""
echo "  \"$PUB_HEX\""
