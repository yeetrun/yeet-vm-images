#!/usr/bin/env python3
"""Parse one bounded upstream tar.gz and copy only the verified runtime members."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import stat
import sys
import tempfile
import zlib


MAX_COMPRESSED = 128 * 1024 * 1024
MAX_UNCOMPRESSED = 160 * 1024 * 1024
MAX_MEMBER = 80 * 1024 * 1024
MAX_TOTAL_MEMBER_BYTES = 96 * 1024 * 1024
MAX_TOTAL_MEMBERS = 3
BLOCK = 512


def fail(message: str) -> None:
    print(f"archive inspection failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_string(field: bytes, label: str) -> str:
    before, separator, after = field.partition(b"\0")
    if separator and any(after):
        fail(f"{label} contains embedded NUL data")
    try:
        return before.decode("utf-8", "strict")
    except UnicodeDecodeError:
        fail(f"{label} is not valid UTF-8")


def parse_octal(field: bytes, label: str) -> int:
    if field and field[0] & 0x80:
        fail(f"{label} uses unsupported base-256 encoding")
    value = field.rstrip(b"\0 ").lstrip(b" ")
    if not value or any(byte not in b"01234567" for byte in value):
        fail(f"{label} is not canonical octal")
    return int(value, 8)


def copy_exact(source, output: Path, size: int) -> str:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(output, flags, 0o600)
    digest = hashlib.sha256()
    remaining = size
    try:
        while remaining:
            chunk = source.read(min(1024 * 1024, remaining))
            if not chunk:
                fail("member data is truncated")
            view = memoryview(chunk)
            while view:
                written = os.write(descriptor, view)
                if written <= 0:
                    fail("member write made no progress")
                view = view[written:]
            digest.update(chunk)
            remaining -= len(chunk)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return digest.hexdigest()


def decompress(archive: Path):
    info = archive.lstat()
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        fail("archive is not a regular file")
    if info.st_size <= 0 or info.st_size > MAX_COMPRESSED:
        fail("compressed archive size exceeds policy")
    temporary = tempfile.TemporaryFile()
    decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
    total = 0
    with archive.open("rb") as source:
        while True:
            compressed = source.read(1024 * 1024)
            if not compressed:
                break
            if decompressor.eof:
                fail("archive contains trailing or concatenated gzip data")
            pending = compressed
            while pending:
                try:
                    output = decompressor.decompress(pending, MAX_UNCOMPRESSED - total + 1)
                except zlib.error as error:
                    fail(f"invalid gzip stream: {error}")
                total += len(output)
                if total > MAX_UNCOMPRESSED:
                    fail("decompressed archive exceeds policy")
                temporary.write(output)
                pending = decompressor.unconsumed_tail
                if decompressor.unused_data:
                    fail("archive contains trailing or concatenated gzip data")
    try:
        output = decompressor.flush(MAX_UNCOMPRESSED - total + 1)
    except zlib.error as error:
        fail(f"invalid gzip trailer: {error}")
    total += len(output)
    if total > MAX_UNCOMPRESSED:
        fail("decompressed archive exceeds policy")
    temporary.write(output)
    if not decompressor.eof:
        fail("truncated gzip stream")
    temporary.seek(0)
    return temporary


def main() -> None:
    if len(sys.argv) != 4:
        fail(f"usage: {sys.argv[0]} ARCHIVE TAG DESTINATION")
    archive = Path(sys.argv[1])
    tag = sys.argv[2]
    destination = Path(sys.argv[3])
    prefix = f"release-{tag}-x86_64"
    expected = {
        f"{prefix}/SHA256SUMS": ("SHA256SUMS", 0o644),
        f"{prefix}/firecracker-{tag}-x86_64": (f"firecracker-{tag}-x86_64", 0o755),
        f"{prefix}/jailer-{tag}-x86_64": (f"jailer-{tag}-x86_64", 0o755),
    }
    if not destination.is_dir() or destination.is_symlink() or any(destination.iterdir()):
        fail("destination must be an empty real directory")

    source = decompress(archive)
    seen: set[str] = set()
    total_member_bytes = 0
    zero_blocks = 0
    try:
        while True:
            header = source.read(BLOCK)
            if len(header) != BLOCK:
                fail("tar stream is truncated")
            if header == bytes(BLOCK):
                zero_blocks += 1
                if zero_blocks == 2:
                    trailing = source.read()
                    if any(trailing):
                        fail("tar stream has nonzero data after its end marker")
                    break
                continue
            if zero_blocks:
                fail("tar stream has a single zero block")
            if len(seen) >= MAX_TOTAL_MEMBERS:
                fail("archive member count exceeds policy")
            stored_checksum = parse_octal(header[148:156], "header checksum")
            checksum_header = bytearray(header)
            checksum_header[148:156] = b"        "
            if sum(checksum_header) != stored_checksum:
                fail("tar header checksum is invalid")
            if header[257:263] != b"ustar\0" or header[263:265] != b"00":
                fail("archive member is not canonical POSIX ustar")
            name = parse_string(header[0:100], "member name")
            prefix_field = parse_string(header[345:500], "member prefix")
            effective_name = f"{prefix_field}/{name}" if prefix_field else name
            if not effective_name or effective_name.startswith("/") or "\\" in effective_name:
                fail(f"unsafe member path: {effective_name!r}")
            segments = effective_name.split("/")
            if any(segment in ("", ".", "..") for segment in segments):
                fail(f"non-canonical member path: {effective_name!r}")
            if effective_name in seen:
                fail(f"duplicate effective member path: {effective_name!r}")
            typeflag = header[156:157]
            if typeflag not in (b"\0", b"0"):
                fail(f"unexpected metadata or member type {typeflag!r}")
            size = parse_octal(header[124:136], "member size")
            mode = parse_octal(header[100:108], "member mode") & 0o7777
            if size > MAX_MEMBER:
                fail("archive member size exceeds policy")
            total_member_bytes += size
            if total_member_bytes > MAX_TOTAL_MEMBER_BYTES:
                fail("archive member total exceeds policy")
            if effective_name not in expected:
                fail(f"unexpected archive member: {effective_name!r}")
            output_name, expected_mode = expected[effective_name]
            if mode != expected_mode:
                fail(f"non-canonical member mode for {effective_name!r}")
            copy_exact(source, destination / output_name, size)
            padding = (-size) % BLOCK
            if padding and source.read(padding) != bytes(padding):
                fail("member padding is missing or nonzero")
            os.chmod(destination / output_name, expected_mode)
            seen.add(effective_name)
        if seen != set(expected):
            fail("archive does not contain exactly the required members")
    finally:
        source.close()


if __name__ == "__main__":
    main()
