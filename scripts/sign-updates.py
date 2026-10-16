#!/usr/bin/env python3
"""Clients verify these exact JSON bytes, not a reserialized document."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent


def openssl_output(arguments: list[str], data: bytes | None = None) -> bytes:
    """Do not expose signing inputs through OpenSSL error diagnostics."""
    result = subprocess.run(
        ["openssl", *arguments], input=data, capture_output=True, timeout=30
    )
    if result.returncode:
        raise ValueError("OpenSSL could not validate or sign update metadata.")
    return result.stdout


def main() -> None:
    if len(sys.argv) != 2:
        raise ValueError("Usage: sign-updates.py <release-package-directory>")
    directory = Path(sys.argv[1]).resolve()
    version = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version):
        raise ValueError("VERSION must contain MAJOR.MINOR.PATCH.")
    if any(int(part) > 65535 for part in version.split(".")):
        raise ValueError("VERSION exceeds native package version limits.")
    private_key = os.environ.get("UPDATE_SIGNING_PRIVATE_KEY", "").encode()
    if not private_key:
        raise ValueError("UPDATE_SIGNING_PRIVATE_KEY is required.")
    public_key = ROOT / "UPDATE_PUBLIC_KEY"
    pinned = openssl_output(
        ["pkey", "-pubin", "-in", str(public_key), "-outform", "DER"]
    )
    derived = openssl_output(["pkey", "-pubout", "-outform", "DER"], private_key)
    if derived != pinned:
        raise ValueError("Signing key does not match the pinned update key.")

    assets = []
    for suffix in (
        "mac-arm64.dmg", "mac-x86_64.dmg", "win-x64-setup.exe", "win-x64.zip"
    ):
        name = f"ChiikawaPet-{version}-{suffix}"
        package = directory / name
        size = package.stat().st_size
        if not 0 < size <= 512 * 1024 * 1024:
            raise ValueError(f"Invalid update package size: {name}")
        with package.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        assets.append({
            "name": name,
            "url": (
                "https://github.com/meengi07/chiikawa-agent-pet/"
                f"releases/download/v{version}/{name}"
            ),
            "sha256": digest,
            "size": size,
        })
    manifest = json.dumps(
        {"schemaVersion": 1, "version": version, "assets": assets},
        separators=(",", ":"), ensure_ascii=True,
    ).encode("utf-8") + b"\n"

    with tempfile.TemporaryDirectory(prefix="chiikawa-update-sign-") as temp:
        private_path = Path(temp) / "private.pem"
        with private_path.open("xb") as stream:
            private_path.chmod(0o600)
            stream.write(private_key)
        manifest_path = Path(temp) / "updates.json"
        manifest_path.write_bytes(manifest)
        signature = openssl_output([
            "dgst", "-sha256", "-sign", str(private_path), str(manifest_path)
        ])
        signature_path = Path(temp) / "updates.der"
        signature_path.write_bytes(signature)
        openssl_output([
            "dgst", "-sha256", "-verify", str(public_key),
            "-signature", str(signature_path), str(manifest_path),
        ])
    (directory / "updates.json").write_bytes(manifest)
    (directory / "updates.sig").write_bytes(base64.b64encode(signature) + b"\n")
    print(f"Signed v{version} update metadata for {len(assets)} packages.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"Update signing failed: {error}") from None
