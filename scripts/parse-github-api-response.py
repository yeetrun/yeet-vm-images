#!/usr/bin/env python3
"""Parse one `gh api --include` response and enforce its exact HTTP status."""

from __future__ import annotations

import json
from pathlib import Path
import re
import sys


def fail(message: str) -> None:
    print(f"GitHub API response validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    if len(sys.argv) != 4:
        fail(f"usage: {sys.argv[0]} RAW EXPECTED_STATUS BODY_OUTPUT")
    raw = Path(sys.argv[1]).read_bytes().replace(b"\r\n", b"\n")
    boundary = raw.find(b"\n\n")
    if boundary < 0:
        fail("missing header/body boundary")
    headers = raw[:boundary].decode("ascii", "strict").splitlines()
    body = raw[boundary + 2 :]
    match = re.fullmatch(r"HTTP/[0-9]+(?:[.][0-9]+)? ([0-9]{3})(?: .*)?", headers[0])
    if not match or match.group(1) != sys.argv[2]:
        fail(f"expected HTTP {sys.argv[2]}")
    parsed_headers: dict[str, str] = {}
    for line in headers[1:]:
        if ":" not in line:
            fail("malformed response header")
        name, value = line.split(":", 1)
        lowered = name.strip().lower()
        if lowered in parsed_headers:
            fail(f"duplicate response header: {lowered}")
        parsed_headers[lowered] = value.strip()
    try:
        json.loads(body)
    except (UnicodeError, json.JSONDecodeError) as error:
        fail(f"invalid JSON body: {error}")
    Path(sys.argv[3]).write_bytes(body)
    print(parsed_headers.get("etag", ""))


if __name__ == "__main__":
    main()
