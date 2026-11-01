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
#   <key-der-path> Ed25519 private key in DER (OneAsymmetricKey) form; the
#                  CI secret stores it base64-encoded.
#
# Emits <dist-dir>/update-manifest.json — a single signed channel manifest
# (the family format: schema + payload + Ed25519 signature block) carrying
# every platform's installable. Env overrides: RELEASE_ASSET_BASE_URL,
# RIVET_UPDATE_KEY_ID. Clients verify the signature against the key embedded
# in racket/movebit/update.rkt before any version decision.

set -euo pipefail

TAG="${1:?usage: make-update-manifest.sh <tag> <dist-dir> <key-der-path>}"
DIST="${2:?usage: make-update-manifest.sh <tag> <dist-dir> <key-der-path>}"
KEY_PATH="${3:?usage: make-update-manifest.sh <tag> <dist-dir> <key-der-path>}"
VERSION="${TAG#v}"
KEY_ID="${RIVET_UPDATE_KEY_ID:-movebit-2026-10}"
BASE_URL="${RELEASE_ASSET_BASE_URL:-https://github.com/turinglambdaai/movebit/releases/download/$TAG}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$VERSION" == "$(tr -d '[:space:]' < "$ROOT/VERSION")" ]] || {
  echo "error: tag $TAG does not match VERSION '$(cat "$ROOT/VERSION")'" >&2; exit 1; }

for artifact in "$DIST/movebit-$VERSION-macos-arm64.zip" \
                "$DIST/movebit-$VERSION-macos-x64.zip" \
                "$DIST/movebit-$VERSION-windows-x64.zip" \
                "$DIST/movebit-$VERSION-windows-x64.msi" \
                "$DIST/movebit-$VERSION-linux-x64.tar.gz" \
                "$DIST/movebit-$VERSION-linux-arm64.tar.gz" \
                "$DIST/movebit-$VERSION-linux-x64.AppImage" \
                "$DIST/movebit-$VERSION-linux-arm64.AppImage"; do
  [[ -f "$artifact" ]] || { echo "error: missing $artifact" >&2; exit 1; }
done

# ---- build + sign the merged manifest with rivet's own signer ---------------
MANIFEST="$DIST/update-manifest.json"

SCRIPT="$(mktemp /tmp/movebit-manifest-XXXXXX.rkt)"
trap 'rm -f "$SCRIPT"' EXIT

cat > "$SCRIPT" <<RKT
#lang racket/base
(require rivet/distribution
         racket/date
         racket/file
         racket/format)
(define version "$VERSION")
(define base-url "$BASE_URL")
(define dist (path->complete-path "$DIST"))
(define key-path (path->complete-path "$KEY_PATH"))
(define key-id "$KEY_ID")
(define build (hash-ref (file->value (build-path (path->complete-path "$ROOT") "rivet.rktd")) 'build))

;; Rivet main added a trailing component discriminator to update-artifact
;; (rivet/distribution/manifest.rkt): one feed may carry several installables
;; per platform, and the client selects by component. MoveBit ships plain
;; component-less artifacts, so append #f when the linked rivet's constructor
;; takes it (the v0.12.0 pin does; older pins predate the field) — the same
;; arity branch racket/movebit/update.rkt makes for updater-config. No
;; backticks in this comment: this block lives inside a bash heredoc, where
;; they are command substitution, not quoting.
(define artifact-tail
  (if (equal? (procedure-arity update-artifact) 8) (list #f) '()))

(define (artifact platform architecture file installer)
  (define path (build-path dist file))
  (unless (file-exists? path)
    (error 'make-update-manifest "missing installer: ~a" path))
  (apply update-artifact platform architecture
                   (string-append base-url "/" file)
                   (sha256-file/hex path)
                   (file-size path)
                   installer
                   '()
                   artifact-tail))

(define manifest
  (update-manifest "site.jrtx.movebit"
                   version
                   build
                   'stable
                   ;; published-at: RFC 3339, second precision, UTC
                   (let ([d (seconds->date (current-seconds) #f)])
                     (format "~a-~a-~aT~a:~a:~aZ"
                             (date-year d)
                             (~r (date-month d) #:min-width 2 #:pad-string "0")
                             (~r (date-day d) #:min-width 2 #:pad-string "0")
                             (~r (date-hour d) #:min-width 2 #:pad-string "0")
                             (~r (date-minute d) #:min-width 2 #:pad-string "0")
                             (~r (date-second d) #:min-width 2 #:pad-string "0")))
                   "0.0.0"
                   #f
                   #t
                   100
                   (list (artifact 'macos 'arm64
                                   (format "movebit-~a-macos-arm64.zip" version) 'zip)
                         (artifact 'macos 'x64
                                   (format "movebit-~a-macos-x64.zip" version) 'zip)
                         (artifact 'windows 'x64
                                   (format "movebit-~a-windows-x64.zip" version) 'zip)
                         ;; Windows MSI installs (Program Files) cannot swap
                         ;; the portable zip in place — those installs select
                         ;; the 'msi entry by install-kind and hand off to
                         ;; a passive msiexec upgrade.
                         (artifact 'windows 'x64
                                   (format "movebit-~a-windows-x64.msi" version) 'msi)
                         ;; Linux tar.gz stays for manual installs. AppImage is a
                         ;; separate first-class signed update artifact.
                         (artifact 'linux 'x64
                                   (format "movebit-~a-linux-x64.tar.gz" version) 'tar-gz)
                         (artifact 'linux 'arm64
                                   (format "movebit-~a-linux-arm64.tar.gz" version) 'tar-gz)
                         (artifact 'linux 'x64
                                   (format "movebit-~a-linux-x64.AppImage" version) 'appimage)
                         (artifact 'linux 'arm64
                                   (format "movebit-~a-linux-arm64.AppImage" version) 'appimage))))

;; write-signed-manifest validates the struct against the manifest schema
;; before signing, so a malformed manifest fails the release instead of
;; shipping something every client would reject.
(call-with-output-file (build-path dist "update-manifest.json")
  #:exists 'truncate/replace
  (lambda (out)
    (write-signed-manifest manifest
                           (read-ed25519-private-key key-path)
                           key-id
                           out)
    (newline out)))
(printf "manifest: ~a (8 artifacts, key-id ~a)\\n"
        (build-path dist "update-manifest.json") key-id)
RKT

racket "$SCRIPT"
