#!/usr/bin/env python3
"""Fail-closed MoveBit release key preflight (stdlib + OpenSSL).

The release secret is a DER Ed25519 PKCS#8 private key. Require its public
counterpart to equal the DER SPKI trust root embedded in the shipped Racket
updater, before any expensive native release packaging or publication.
Never print private key bytes. Offline self-tests use throwaway keys.
"""
from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UPDATER = ROOT / "racket" / "movebit" / "update.rkt"
ED25519_SPKI_HEADER = bytes.fromhex("302a300506032b6570032100")


def embedded_public_key() -> bytes:
    text = UPDATER.read_text(encoding="utf-8")
    match = re.search(
        r'\(define\s+current-update-public-key-hex\s+\(string-append\s+'
        r'"([0-9a-fA-F]+)"\s+"([0-9a-fA-F]+)"\s*\)\)',
        text,
    )
    if not match:
        raise ValueError("cannot read committed Racket updater trust root")
    public = bytes.fromhex(match.group(1) + match.group(2))
    if len(public) != 44 or not public.startswith(ED25519_SPKI_HEADER):
        raise ValueError("embedded update public key is not an Ed25519 SPKI")
    return public


def derive_public_key(private_path: Path) -> bytes:
    try:
        result = subprocess.run(
            ["openssl", "pkey", "-inform", "DER", "-in", str(private_path),
             "-pubout", "-outform", "DER"],
            check=True, capture_output=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError("release key is not a valid OpenSSL Ed25519 DER private key") from error
    public = result.stdout
    if len(public) != 44 or not public.startswith(ED25519_SPKI_HEADER):
        raise ValueError("release key is not Ed25519")
    return public


def verify(private_path: Path, trusted_public: bytes) -> None:
    actual_public = derive_public_key(private_path)
    if actual_public != trusted_public:
        raise ValueError("release private key does not match the updater's embedded public key")


def self_test() -> None:
    # Check that the checked-in public key can always be parsed, independently
    # from a production signing secret (never available on PRs).
    embedded_public_key()
    with tempfile.TemporaryDirectory(prefix="movebit-key-contract-") as tmp:
        tmp_path = Path(tmp)
        pem = tmp_path / "private.pem"
        der = tmp_path / "private.der"
        subprocess.run(
            ["openssl", "genpkey", "-algorithm", "ed25519", "-out", str(pem)],
            check=True, capture_output=True,
        )
        subprocess.run(
            ["openssl", "pkey", "-in", str(pem), "-outform", "DER", "-out", str(der)],
            check=True, capture_output=True,
        )
        test_public = derive_public_key(der)
        verify(der, test_public)
        for bad_public in (test_public[:-1] + bytes([test_public[-1] ^ 1]),
                           embedded_public_key() if embedded_public_key() != test_public else bytes(44)):
            try:
                verify(der, bad_public)
            except ValueError:
                pass
            else:
                raise AssertionError("wrong signing key was accepted")
        invalid = tmp_path / "invalid.der"
        invalid.write_bytes(b"not a key")
        try:
            verify(invalid, test_public)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid DER was accepted")
    print("release update-key contract: positive and negative offline checks passed")


def main() -> int:
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif len(sys.argv) == 2:
            verify(Path(sys.argv[1]), embedded_public_key())
            print("release update-key contract: private key matches shipped updater")
        else:
            print("usage: check-release-update-key.py --self-test | key.der", file=sys.stderr)
            return 2
    except (ValueError, AssertionError, subprocess.CalledProcessError) as error:
        print(f"release update-key contract: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
