#!/usr/bin/env python3
"""Resolve a reviewed Firecracker version policy, failing closed on ambiguity."""

from __future__ import annotations

import json
from pathlib import Path
import re
import sys


VERSION = re.compile(r"^v[0-9]+[.][0-9]+[.][0-9]+$")
POLICY_URL = "https://github.com/firecracker-microvm/firecracker/blob/main/docs/RELEASE_POLICY.md"
SUPPORT = {"supported", "deprecated", "eol", "revoked"}


def fail(message: str) -> None:
    print(f"runtime policy resolution failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    if len(sys.argv) != 3:
        fail(f"usage: {sys.argv[0]} POLICY_JSON VERSION")
    path = Path(sys.argv[1])
    version = sys.argv[2]
    if not VERSION.fullmatch(version):
        fail("invalid version")
    try:
        policy = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(str(error))
    if set(policy) != {"schema_version", "versions"} or policy["schema_version"] != 1 or not isinstance(policy["versions"], dict):
        fail("invalid policy root")
    record = policy["versions"].get(version)
    if not isinstance(record, dict):
        fail("version has no reviewed policy record")
    required = {
        "production_release", "default_seccomp", "support_state", "binary_origin",
        "seccomp_evidence", "policy_url", "reviewed_at",
    }
    if set(record) != required:
        fail("policy record fields are not exact")
    if record["production_release"] is not True:
        fail("policy does not classify this as a production release")
    if record["default_seccomp"] is not True:
        fail("policy does not establish default seccomp")
    if record["support_state"] not in SUPPORT:
        fail("invalid support state")
    if record["binary_origin"] != "official-github-release":
        fail("policy does not bind official release binaries")
    if record["seccomp_evidence"] != "upstream-release-default-build-contract":
        fail("unreviewed seccomp evidence boundary")
    if record["policy_url"] != POLICY_URL:
        fail("unexpected release policy URL")
    if not isinstance(record["reviewed_at"], str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", record["reviewed_at"]):
        fail("invalid review date")
    json.dump(record, sys.stdout, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
