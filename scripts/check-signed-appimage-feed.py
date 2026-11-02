#!/usr/bin/env python3
"""Verify the exact signed AppImage release contract before publication.

The Ed25519 signature authenticates the *payload bytes*, not the JSON
serialization of the wrapper. Verify first, parse only after authentication.
"""
import base64
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def trusted_public() -> bytes:
    source = (ROOT / "racket/movebit/update.rkt").read_text(encoding="utf-8")
    match = re.search(
        r'\(define\s+current-update-public-key-hex\s+\(string-append\s+'
        r'"([0-9a-fA-F]+)"\s+"([0-9a-fA-F]+)"\s*\)\)', source)
    if not match:
        raise ValueError("embedded update trust root is unreadable")
    public = bytes.fromhex(match.group(1) + match.group(2))
    if len(public) != 44 or not public.startswith(bytes.fromhex("302a300506032b6570032100")):
        raise ValueError("embedded trust root is not an Ed25519 SPKI")
    return public


def verify(feed: Path, dist: Path, public: bytes, version: str) -> None:
    wrapper = json.loads(feed.read_text(encoding="utf-8"))
    if wrapper.get("schema") != 1 or wrapper.get("signature", {}).get("algorithm") != "ed25519":
        raise ValueError("invalid signed feed wrapper")
    if wrapper["signature"].get("key_id") != "movebit-2026-10":
        raise ValueError("unexpected signing key id")
    payload = base64.b64decode(wrapper["payload"], validate=True)
    signature = base64.b64decode(wrapper["signature"]["value"], validate=True)
    with tempfile.TemporaryDirectory(prefix="movebit-verify-feed-") as tmp:
        tmp = Path(tmp)
        (tmp / "public.der").write_bytes(public)
        (tmp / "payload").write_bytes(payload)
        (tmp / "signature").write_bytes(signature)
        result = subprocess.run(
            ["openssl", "pkeyutl", "-verify", "-pubin",
             "-inkey", str(tmp / "public.der"), "-keyform", "DER",
             "-rawin", "-in", str(tmp / "payload"),
             "-sigfile", str(tmp / "signature")],
            capture_output=True)
        if result.returncode:
            raise ValueError("Ed25519 manifest signature does not match embedded trust root")
    manifest = json.loads(payload)
    if (manifest.get("schema") != 1
            or manifest.get("application_id") != "site.jrtx.movebit"
            or manifest.get("version") != version
            or manifest.get("channel") != "stable"):
        raise ValueError("wrong application, channel, schema, or release version")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list):
        raise ValueError("signed artifact list missing")
    for arch in ("x64", "arm64"):
        name = f"movebit-{version}-linux-{arch}.AppImage"
        matching = [a for a in artifacts
                    if a.get("platform") == "linux"
                    and a.get("architecture") == arch
                    and a.get("installer") == "appimage"
                    and a.get("component") is None]
        if len(matching) != 1:
            raise ValueError(f"expected exactly one signed AppImage entry for {arch}")
        artifact = matching[0]
        if artifact.get("url") != (
                f"https://github.com/turlamai/movebit/releases/download/v{version}/{name}"):
            raise ValueError(f"unexpected signed AppImage URL for {arch}")
        path = dist / name
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"missing or unsafe AppImage asset: {name}")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if artifact.get("sha256") != digest or artifact.get("size") != path.stat().st_size:
            raise ValueError(f"signed AppImage hash/size differs from release bytes: {name}")


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="movebit-feed-test-") as tmp:
        d = Path(tmp)
        priv = d / "private.pem"
        pub = d / "public.der"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", str(priv)],
                       check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", str(priv), "-pubout",
                        "-outform", "DER", "-out", str(pub)],
                       check=True, capture_output=True)
        version = "9.9.9"
        artifacts = []
        for arch in ("x64", "arm64"):
            name = f"movebit-{version}-linux-{arch}.AppImage"
            path = d / name
            path.write_bytes(f"fake-AppImage-{arch}".encode())
            artifacts.append({
                "platform": "linux", "architecture": arch, "installer": "appimage",
                "url": f"https://github.com/turlamai/movebit/releases/download/v{version}/{name}",
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "size": path.stat().st_size, "arguments": []})
        manifest = {"schema": 1, "application_id": "site.jrtx.movebit",
                    "version": version, "channel": "stable", "artifacts": artifacts}
        payload = json.dumps(manifest).encode()
        (d / "payload").write_bytes(payload)
        subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", str(priv),
                        "-rawin", "-in", str(d / "payload"), "-out", str(d / "signature")],
                       check=True, capture_output=True)
        feed = d / "update-manifest.json"
        wrapper = {"schema": 1, "payload": base64.b64encode(payload).decode(),
                   "signature": {"algorithm": "ed25519", "key_id": "movebit-2026-10",
                                 "value": base64.b64encode((d / "signature").read_bytes()).decode()}}
        feed.write_text(json.dumps(wrapper))
        verify(feed, d, pub.read_bytes(), version)
        original = (d / f"movebit-{version}-linux-x64.AppImage").read_bytes()
        (d / f"movebit-{version}-linux-x64.AppImage").write_bytes(b"attacker replacement")
        try:
            verify(feed, d, pub.read_bytes(), version)
            raise AssertionError("tampered AppImage was accepted")
        except ValueError:
            pass
        (d / f"movebit-{version}-linux-x64.AppImage").write_bytes(original)
        bad = dict(wrapper)
        bad["payload"] = base64.b64encode(payload + b" ").decode()
        feed.write_text(json.dumps(bad))
        try:
            verify(feed, d, pub.read_bytes(), version)
            raise AssertionError("tampered signed payload was accepted")
        except ValueError:
            pass
        feed.write_text(json.dumps(wrapper))
        (d / f"movebit-{version}-linux-arm64.AppImage").unlink()
        try:
            verify(feed, d, pub.read_bytes(), version)
            raise AssertionError("missing arm64 AppImage was accepted")
        except ValueError:
            pass
    print("signed AppImage feed: positive, payload tamper, signature tamper and missing-arch checks passed")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif len(sys.argv) == 3:
            verify(Path(sys.argv[1]), Path(sys.argv[2]), trusted_public(),
                   (ROOT / "VERSION").read_text().strip())
            print("signed AppImage feed matches embedded trust root and exact x64/arm64 release bytes")
        else:
            raise ValueError("usage: check-signed-appimage-feed.py --self-test | <feed> <dist>")
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
