#!/usr/bin/env python3
"""Verify cross-field and byte-level contracts for one runtime release bundle."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


RUNTIME = re.compile(r"^firecracker-(v[0-9]+[.][0-9]+[.][0-9]+)-yeet-v[1-9][0-9]*$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")


def fail(message: str) -> None:
    print(f"runtime bundle verification failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main() -> None:
    if len(sys.argv) != 6:
        fail(f"usage: {sys.argv[0]} BUNDLE RUNTIME_ID TARGET POLICY RESOLVER")
    bundle = Path(sys.argv[1])
    runtime_id = sys.argv[2]
    target = sys.argv[3]
    policy_path = Path(sys.argv[4])
    resolver = sys.argv[5]
    match = RUNTIME.fullmatch(runtime_id)
    if not match or not COMMIT.fullmatch(target):
        fail("invalid runtime ID or target")
    version = match.group(1)
    if not bundle.is_dir() or bundle.is_symlink():
        fail("bundle is not a real directory")
    expected_names = ["firecracker", "jailer", "runtime-manifest.json", "runtime-checksums.txt"]
    if sorted(entry.name for entry in bundle.iterdir()) != sorted(expected_names):
        fail("bundle does not contain exactly four expected assets")
    for name in expected_names:
        path = bundle / name
        mode = path.lstat().st_mode
        if not stat.S_ISREG(mode) or stat.S_ISLNK(mode):
            fail(f"asset is not a regular file: {name}")
        expected_mode = 0o755 if name in ("firecracker", "jailer") else 0o644
        if stat.S_IMODE(mode) != expected_mode:
            fail(f"asset mode is not canonical: {name}")
    try:
        manifest = json.loads((bundle / "runtime-manifest.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(str(error))
    if manifest.get("runtime_id") != runtime_id or manifest.get("architecture") != "amd64":
        fail("manifest subject does not match requested runtime")
    upstream = manifest.get("upstream", {})
    if upstream.get("repository") != "firecracker-microvm/firecracker" or upstream.get("version") != version or upstream.get("tag") != version:
        fail("manifest upstream identity mismatch")
    base = f"https://github.com/firecracker-microvm/firecracker/releases/download/{version}"
    if upstream.get("archive_url") != f"{base}/firecracker-{version}-x86_64.tgz" or upstream.get("checksum_url") != f"{base}/firecracker-{version}-x86_64.tgz.sha256.txt":
        fail("manifest upstream URL mismatch")
    components = manifest.get("components", {})
    for name, label in (("firecracker", "Firecracker"), ("jailer", "Jailer")):
        component = components.get(name, {})
        if component.get("path") != name or component.get("sha256") != digest(bundle / name):
            fail(f"manifest component digest mismatch: {name}")
        if component.get("version_output") != f"{label} {version}":
            fail(f"manifest component version mismatch: {name}")
    provenance = manifest.get("provenance", {})
    if provenance.get("repository") != "yeetrun/yeet-vm-images" or provenance.get("commit") != target:
        fail("manifest provenance does not match release target")
    try:
        policy = json.loads(subprocess.check_output([resolver, str(policy_path), version], text=True))
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        fail(f"cannot resolve reviewed policy: {error}")
    if manifest.get("classification") != {"production_release": policy["production_release"], "default_seccomp": policy["default_seccomp"]}:
        fail("manifest classification does not match reviewed policy")
    if manifest.get("support") != {"state": policy["support_state"], "policy_url": policy["policy_url"]}:
        fail("manifest support does not match reviewed policy")
    checksum_path = bundle / "runtime-checksums.txt"
    try:
        lines = checksum_path.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError) as error:
        fail(str(error))
    checksum_names = ["firecracker", "jailer", "runtime-manifest.json"]
    expected_lines = [f"{digest(bundle / name)}  {name}" for name in checksum_names]
    if lines != expected_lines:
        fail("runtime checksums are not exact, unique, canonical, and independently valid")


if __name__ == "__main__":
    main()
