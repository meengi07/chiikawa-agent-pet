#!/usr/bin/env python3
"""Check release packages and write SHA256SUMS. Uses only Python's standard library."""
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import zipfile

root = Path(__file__).resolve().parent.parent
if len(sys.argv) not in (2, 3) or sys.argv[1] not in (
    'mac', 'windows', 'all'
):
    raise SystemExit(
        'Usage: check-release.py {mac|windows|all} [package-directory]'
    )
release_platform = sys.argv[1]
version = (root / "VERSION").read_text().strip()
if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version):
    raise SystemExit("VERSION must contain MAJOR.MINOR.PATCH")
directory = root / "build/release"
if release_platform != 'all':
    directory /= release_platform
directory = Path(sys.argv[2]) if len(sys.argv) == 3 else directory / version
expected = []
if release_platform in ('mac', 'all'):
    expected.extend([
        f"ChiikawaPet-{version}-mac-arm64.dmg",
        f"ChiikawaPet-{version}-mac-x86_64.dmg",
    ])
if release_platform in ('windows', 'all'):
    expected.extend([
        f"ChiikawaPet-{version}-win-x64-setup.exe",
        f"ChiikawaPet-{version}-win-x64.zip",
    ])
for name in expected:
    path = directory / name
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(f"Missing or empty release package: {name}")
    if name.endswith(".dmg"):
        with path.open("rb") as stream:
            stream.seek(-512, 2)
            if stream.read(4) != b"koly":
                raise SystemExit(f"Invalid DMG trailer: {name}")
    if name.endswith(".exe"):
        with path.open("rb") as stream:
            header = stream.read(64)
            if header[:2] != b"MZ":
                raise SystemExit(f"Invalid Windows executable: {name}")
            stream.seek(struct.unpack_from("<I", header, 0x3C)[0])
            if stream.read(4) != b"PE\0\0":
                raise SystemExit(f"Invalid PE signature: {name}")
    if name.endswith(".zip"):
        with zipfile.ZipFile(path) as archive:
            names = set(archive.namelist())
            required = {"ChiikawaPet.exe", "ChiikawaPet.dll", "ChiikawaPet.deps.json", "coreclr.dll",
                        "PresentationFramework.dll", "README.md", "README.ko.md", "LICENSE",
                        "ARTWORK-NOTICE.md", "VERSION"}
            if not required <= names or archive.testzip() is not None:
                raise SystemExit(f"Incomplete or corrupt portable ZIP: {name}")
            for package in ('Microsoft.NETCore.App.Runtime.win-x64', 'Microsoft.WindowsDesktop.App.Runtime.win-x64'):
                if not any(name.startswith(f'licenses/{package}/LICENSE') for name in names):
                    raise SystemExit(f'Missing runtime license: {package}')
            if archive.read("VERSION").decode().strip() != version:
                raise SystemExit("Portable ZIP version does not match VERSION")
            dependencies = json.loads(archive.read("ChiikawaPet.deps.json"))
            if f"ChiikawaPet/{version}" not in dependencies["libraries"]:
                raise SystemExit("Windows app version does not match VERSION")
            assembly = archive.read("ChiikawaPet.dll")
            for sprite in ("chiikawa", "hachiware", "usagi", "momonga", "claude-logo", "codex-logo"):
                if f"sprites/{sprite}.png".encode("utf-16le") not in assembly:
                    raise SystemExit(f"Missing embedded PNG: {sprite}")
checksums = []
for name in expected:
    with (directory / name).open("rb") as stream:
        checksums.append(f"{hashlib.file_digest(stream, 'sha256').hexdigest()}  {name}\n")
(directory / "SHA256SUMS").write_text(
    "".join(checksums), encoding="ascii", newline="\n"
)
print(f"Verified {len(expected)} {release_platform} packages for v{version}; wrote SHA256SUMS")
