#!/usr/bin/env python3
"""Generate deterministic offline GitHub/API and archive fixtures."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import struct
import tarfile
import zlib


VERSION = "v1.16.1"
PREFIX = f"release-{VERSION}-x86_64"
ARCHIVE_NAME = f"firecracker-{VERSION}-x86_64.tgz"
CHECKSUM_NAME = f"{ARCHIVE_NAME}.sha256.txt"
BASE_URL = f"https://github.com/firecracker-microvm/firecracker/releases/download/{VERSION}"
API_BASE = "https://api.github.com/repos/firecracker-microvm/firecracker"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def elf(output: str, machine: int = 62) -> bytes:
    message = (output + "\n").encode()
    code_prefix = (
        b"\xb8\x01\x00\x00\x00"  # mov eax, write
        b"\xbf\x01\x00\x00\x00"  # mov edi, stdout
    )
    code_suffix = (
        b"\xba" + struct.pack("<I", len(message)) + b"\x0f\x05"
        b"\xb8\x3c\x00\x00\x00\x31\xff\x0f\x05"
    )
    lea_end = len(code_prefix) + 7
    code_length = len(code_prefix) + 7 + len(code_suffix)
    displacement = code_length - lea_end
    code = code_prefix + b"\x48\x8d\x35" + struct.pack("<i", displacement) + code_suffix + message
    header_size = 64
    program_size = 56
    entry_offset = header_size + program_size
    total_size = entry_offset + len(code)
    ident = b"\x7fELF\x02\x01\x01\x00" + bytes(8)
    header = ident + struct.pack(
        "<HHIQQQIHHHHHH", 2, machine, 1, 0x400000 + entry_offset, header_size, 0,
        0, header_size, program_size, 1, 0, 0, 0,
    )
    program = struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, total_size, total_size, 0x1000)
    return header + program + code


def add_member(tar: tarfile.TarFile, name: str, data: bytes = b"", mode: int = 0o644, kind: bytes = tarfile.REGTYPE, linkname: str = "") -> None:
    info = tarfile.TarInfo(name)
    info.size = len(data) if kind in (tarfile.REGTYPE, tarfile.AREGTYPE) else 0
    info.mode = mode
    info.mtime = 0
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.type = kind
    info.linkname = linkname
    tar.addfile(info, io.BytesIO(data) if info.size else None)


def members(scenario: str):
    machine = 183 if scenario == "wrong-arch" else 62
    firecracker = b"not an elf" if scenario == "non-elf" else elf("Firecracker v1.16.1", machine)
    jailer_output = "Jailer v1.15.0" if scenario == "mismatched-version" else "Jailer v1.16.1"
    jailer = elf(jailer_output)
    firecracker_digest = "0" * 64 if scenario == "wrong-internal-digest" else sha256(firecracker)
    sums = (f"{firecracker_digest}  firecracker-{VERSION}-x86_64\n{sha256(jailer)}  jailer-{VERSION}-x86_64\n").encode()
    result = [
        (f"{PREFIX}/SHA256SUMS", sums, 0o644, tarfile.REGTYPE, ""),
        (f"{PREFIX}/firecracker-{VERSION}-x86_64", firecracker, 0o755, tarfile.REGTYPE, ""),
        (f"{PREFIX}/jailer-{VERSION}-x86_64", jailer, 0o755, tarfile.REGTYPE, ""),
    ]
    if scenario == "oversized-total":
        large = bytes(33 * 1024 * 1024)
        return [
            (f"{PREFIX}/SHA256SUMS", large, 0o644, tarfile.REGTYPE, ""),
            (f"{PREFIX}/firecracker-{VERSION}-x86_64", large, 0o755, tarfile.REGTYPE, ""),
            (f"{PREFIX}/jailer-{VERSION}-x86_64", large, 0o755, tarfile.REGTYPE, ""),
        ]
    hostile = {
        "absolute": ("/absolute", b"bad", 0o644, tarfile.REGTYPE, ""),
        "parent": (f"{PREFIX}/../escape", b"bad", 0o644, tarfile.REGTYPE, ""),
        "dot": (f"{PREFIX}/./extra", b"bad", 0o644, tarfile.REGTYPE, ""),
        "duplicate-normalized": (f"{PREFIX}//firecracker-{VERSION}-x86_64", b"bad", 0o755, tarfile.REGTYPE, ""),
        "symlink": (f"{PREFIX}/link", b"", 0o777, tarfile.SYMTYPE, "SHA256SUMS"),
        "hardlink": (f"{PREFIX}/hard", b"", 0o777, tarfile.LNKTYPE, f"{PREFIX}/SHA256SUMS"),
        "device": (f"{PREFIX}/device", b"", 0o600, tarfile.CHRTYPE, ""),
        "fifo": (f"{PREFIX}/fifo", b"", 0o600, tarfile.FIFOTYPE, ""),
        "socket": (f"{PREFIX}/socket", b"", 0o600, b"s", ""),
        "sparse": (f"{PREFIX}/sparse", b"", 0o600, tarfile.GNUTYPE_SPARSE, ""),
        "pax": (f"{PREFIX}/pax", b"path=x\n", 0o600, tarfile.XHDTYPE, ""),
        "global-pax": (f"{PREFIX}/global", b"path=x\n", 0o600, tarfile.XGLTYPE, ""),
        "gnu-longname": ("././@LongLink", b"long\0", 0o600, tarfile.GNUTYPE_LONGNAME, ""),
        "unexpected-type": (f"{PREFIX}/unknown", b"", 0o600, b"X", ""),
        "unexpected-member": (f"{PREFIX}/README", b"unexpected", 0o644, tarfile.REGTYPE, ""),
        "extra-executable": (f"{PREFIX}/extra", elf("extra"), 0o755, tarfile.REGTYPE, ""),
        "bad-mode": (f"{PREFIX}/extra", b"bad", 0o666, tarfile.REGTYPE, ""),
    }
    if scenario == "unexpected-prefix":
        result = [(str(PurePosixPath("wrong-prefix", PurePosixPath(n).name)), d, m, k, l) for n, d, m, k, l in result]
    elif scenario in hostile:
        result.append(hostile[scenario])
    elif scenario == "duplicate-effective":
        result.append(result[1])
    return result


def mutate_header(tar_data: bytes, scenario: str) -> bytes:
    data = bytearray(tar_data)
    if scenario == "invalid-encoding":
        data[0] = 0xFF
    elif scenario == "embedded-nul":
        data[5] = 0
        data[6:10] = b"EVIL"
    elif scenario == "oversized-member":
        data[124:136] = f"{80 * 1024 * 1024 + 1:011o}\0".encode()
    else:
        return tar_data
    data[148:156] = b"        "
    checksum = sum(data[:512])
    data[148:156] = f"{checksum:06o}\0 ".encode()
    return bytes(data)


def gzip_bytes(data: bytes) -> bytes:
    output = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as stream:
        stream.write(data)
    return output.getvalue()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--scenario", default="valid")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for member in members(args.scenario):
            add_member(tar, *member)
    tar_data = mutate_header(tar_buffer.getvalue(), args.scenario)
    if args.scenario == "decompression-bomb":
        compressor = zlib.compressobj(9, zlib.DEFLATED, 16 + zlib.MAX_WBITS)
        chunks = [compressor.compress(bytes(1024 * 1024)) for _ in range(161)]
        archive = b"".join(chunks) + compressor.flush()
    else:
        archive = gzip_bytes(tar_data)
    archive_digest = sha256(archive)
    sidecar_value = "0" * 64 if args.scenario == "wrong-sidecar-digest" else archive_digest
    checksum = f"{sidecar_value}  {ARCHIVE_NAME}\n".encode()
    api_archive = "1" * 64 if args.scenario == "wrong-api-archive-digest" else archive_digest
    api_checksum = "2" * 64 if args.scenario == "wrong-api-checksum-digest" else sha256(checksum)
    release = {
        "url": f"{API_BASE}/releases/tags/{VERSION}",
        "tag_name": VERSION,
        "draft": args.scenario == "draft",
        "prerelease": args.scenario == "prerelease",
        "assets": [
            {"id": 1001, "name": ARCHIVE_NAME, "url": f"{API_BASE}/releases/assets/1001", "browser_download_url": f"{BASE_URL}/{ARCHIVE_NAME}", "size": len(archive), "digest": f"sha256:{api_archive}"},
            {"id": 1002, "name": CHECKSUM_NAME, "url": f"{API_BASE}/releases/assets/1002", "browser_download_url": f"{BASE_URL}/{CHECKSUM_NAME}", "size": len(checksum), "digest": f"sha256:{api_checksum}"},
        ],
    }
    if args.scenario == "oversized-metadata":
        release["assets"][0]["size"] = 128 * 1024 * 1024 + 1
    if args.scenario == "wrong-api-archive-size":
        release["assets"][0]["size"] = len(archive) + 1
    if args.scenario == "malicious-api-url":
        release["assets"][0]["url"] = "https://example.invalid/asset"
    (args.output_dir / ARCHIVE_NAME).write_bytes(archive)
    (args.output_dir / CHECKSUM_NAME).write_bytes(checksum)
    (args.output_dir / f"firecracker-release-{VERSION}.json").write_text(json.dumps(release, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
