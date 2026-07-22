#!/usr/bin/env python3
"""Parse one bounded upstream tar.gz and copy only the verified runtime members."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import zlib


MAX_COMPRESSED = 128 * 1024 * 1024
MAX_UNCOMPRESSED = 160 * 1024 * 1024
MAX_MEMBER = 80 * 1024 * 1024
MAX_TOTAL_MEMBER_BYTES = 96 * 1024 * 1024
MAX_TOTAL_MEMBERS = 64
MAX_PAX_BYTES = 4096
MAX_PAX_RECORDS = 8
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


def read_exact(source, size: int, label: str) -> bytes:
    chunks: list[bytes] = []
    remaining = size
    while remaining:
        chunk = source.read(min(1024 * 1024, remaining))
        if not chunk:
            fail(f"{label} is truncated")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def discard_exact(source, size: int) -> None:
    remaining = size
    while remaining:
        chunk = source.read(min(1024 * 1024, remaining))
        if not chunk:
            fail("member data is truncated")
        remaining -= len(chunk)


def consume_padding(source, size: int) -> None:
    padding = (-size) % BLOCK
    if padding and read_exact(source, padding, "member padding") != bytes(padding):
        fail("member padding is missing or nonzero")


def parse_pax_metadata(data: bytes) -> dict[str, str]:
    metadata: dict[str, str] = {}
    position = 0
    records = 0
    while position < len(data):
        separator = data.find(b" ", position)
        if separator < 0:
            fail("PAX record has no length separator")
        length_bytes = data[position:separator]
        if not length_bytes or any(byte not in b"0123456789" for byte in length_bytes):
            fail("PAX record length is not canonical decimal")
        if len(length_bytes) > 1 and length_bytes.startswith(b"0"):
            fail("PAX record length has leading zeroes")
        length = int(length_bytes)
        end = position + length
        if end > len(data) or end <= separator + 1:
            fail("PAX record length is invalid")
        record = data[separator + 1:end]
        if not record.endswith(b"\n") or b"=" not in record[:-1]:
            fail("PAX record is malformed")
        key_bytes, value_bytes = record[:-1].split(b"=", 1)
        try:
            key = key_bytes.decode("ascii", "strict")
            value = value_bytes.decode("ascii", "strict")
        except UnicodeDecodeError:
            fail("PAX metadata is not ASCII")
        if key not in {"uid", "mtime"}:
            fail(f"unsupported PAX metadata key: {key!r}")
        if key in metadata:
            fail(f"duplicate PAX metadata key: {key!r}")
        if key == "uid" and not re.fullmatch(r"[0-9]{1,20}", value):
            fail("PAX uid is not a bounded decimal integer")
        if key == "mtime" and not re.fullmatch(r"[0-9]{1,20}(?:\.[0-9]{1,9})?", value):
            fail("PAX mtime is not a bounded nonnegative timestamp")
        metadata[key] = value
        position = end
        records += 1
        if records > MAX_PAX_RECORDS:
            fail("PAX metadata record count exceeds policy")
    if not metadata:
        fail("PAX metadata is empty")
    return metadata


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
    seen_expected: set[str] = set()
    total_member_bytes = 0
    total_members = 0
    pending_pax: dict[str, str] | None = None
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
            total_members += 1
            if total_members > MAX_TOTAL_MEMBERS:
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
            typeflag = header[156:157]
            size = parse_octal(header[124:136], "member size")
            mode = parse_octal(header[100:108], "member mode") & 0o7777
            if size > MAX_MEMBER:
                fail("archive member size exceeds policy")
            total_member_bytes += size
            if total_member_bytes > MAX_TOTAL_MEMBER_BYTES:
                fail("archive member total exceeds policy")

            if typeflag == b"x":
                if pending_pax is not None:
                    fail("consecutive PAX metadata headers are unsupported")
                if effective_name != "././@PaxHeader" or prefix_field or mode != 0:
                    fail("PAX metadata header is not canonical")
                if size > MAX_PAX_BYTES:
                    fail("PAX metadata size exceeds policy")
                pending_pax = parse_pax_metadata(read_exact(source, size, "PAX metadata"))
                consume_padding(source, size)
                continue

            if not effective_name or effective_name.startswith("/") or "\\" in effective_name:
                fail(f"unsafe member path: {effective_name!r}")
            segments = effective_name.split("/")
            if any(segment in ("", ".", "..") for segment in segments):
                fail(f"non-canonical member path: {effective_name!r}")
            if len(segments) != 2 or segments[0] != prefix:
                fail(f"unexpected archive member prefix: {effective_name!r}")
            if effective_name in seen:
                fail(f"duplicate effective member path: {effective_name!r}")
            if typeflag not in (b"\0", b"0"):
                fail(f"unexpected metadata or member type {typeflag!r}")
            if mode not in (0o644, 0o755):
                fail(f"non-canonical member mode for {effective_name!r}")
            if effective_name in expected:
                output_name, expected_mode = expected[effective_name]
                if mode != expected_mode:
                    fail(f"non-canonical member mode for {effective_name!r}")
                copy_exact(source, destination / output_name, size)
                os.chmod(destination / output_name, expected_mode)
                seen_expected.add(effective_name)
            else:
                discard_exact(source, size)
            consume_padding(source, size)
            seen.add(effective_name)
            pending_pax = None
        if pending_pax is not None:
            fail("PAX metadata is not followed by a member")
        if seen_expected != set(expected):
            fail("archive does not contain all required members")
    finally:
        source.close()


if __name__ == "__main__":
    main()
