#!/usr/bin/env python3
"""Fsync and atomically rename a verified directory without replacement."""

from __future__ import annotations

import ctypes
import errno
import hashlib
import os
from pathlib import Path
import stat
import sys
import time


RENAME_NOREPLACE = 1
RENAME_EXCL = 0x00000004
OPEN_DIR = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
DESTINATION_PUBLISHED = False


def die(message: str, status: int = 1) -> None:
    if DESTINATION_PUBLISHED and status == 1:
        print(
            "atomic no-replace rename completed; destination is published, but final "
            "verification or durability confirmation is incomplete; "
            f"do not retry it: {message}",
            file=sys.stderr,
        )
        raise SystemExit(4)
    print(f"atomic no-replace rename failed: {message}", file=sys.stderr)
    raise SystemExit(status)


def trusted_directory(info: os.stat_result, label: str) -> None:
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o022:
        die(f"{label} must be owned by the current uid and not group/other writable")


def fsync_fd(descriptor: int) -> None:
    try:
        os.fsync(descriptor)
    except OSError as error:
        if error.errno not in (errno.EINVAL, errno.ENOTSUP):
            raise


def digest_fd(descriptor: int) -> str:
    value = hashlib.sha256()
    os.lseek(descriptor, 0, os.SEEK_SET)
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            return value.hexdigest()
        value.update(chunk)


def snapshot(directory_fd: int) -> dict[str, tuple[int, int, int, str]]:
    result: dict[str, tuple[int, int, int, str]] = {}
    names = os.listdir(directory_fd)
    if not names:
        die("source directory is empty")
    for name in names:
        info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o022:
            die(f"source entry is not a trusted regular file: {name}")
        descriptor = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory_fd)
        try:
            fsync_fd(descriptor)
            result[name] = (info.st_dev, info.st_ino, stat.S_IMODE(info.st_mode), digest_fd(descriptor))
        finally:
            os.close(descriptor)
    fsync_fd(directory_fd)
    return result


def verify_snapshot(directory_fd: int, expected: dict[str, tuple[int, int, int, str]]) -> None:
    if sorted(os.listdir(directory_fd)) != sorted(expected):
        die("source contents changed during publication")
    for name, identity in expected.items():
        info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        descriptor = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory_fd)
        try:
            current = (info.st_dev, info.st_ino, stat.S_IMODE(info.st_mode), digest_fd(descriptor))
        finally:
            os.close(descriptor)
        if current != identity:
            die(f"source entry changed during publication: {name}")


def rename_relative(source_parent_fd: int, source_name: str, destination_parent_fd: int, destination_name: str) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    source_bytes = os.fsencode(source_name)
    destination_bytes = os.fsencode(destination_name)
    if sys.platform.startswith("linux"):
        try:
            rename = libc.renameat2
        except AttributeError:
            die("libc lacks renameat2; refusing a non-atomic fallback")
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(source_parent_fd, source_bytes, destination_parent_fd, destination_bytes, RENAME_NOREPLACE)
    elif sys.platform == "darwin":
        try:
            rename = libc.renameatx_np
        except AttributeError:
            die("libc lacks renameatx_np; refusing a non-atomic fallback")
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(source_parent_fd, source_bytes, destination_parent_fd, destination_bytes, RENAME_EXCL)
    else:
        die(f"unsupported platform {sys.platform}; refusing a non-atomic fallback")
    if result == 0:
        return
    error_number = ctypes.get_errno()
    if error_number == errno.EEXIST:
        die(f"destination already exists: {destination_name}", 3)
    if error_number in (errno.ENOSYS, errno.ENOTSUP):
        die("kernel lacks an atomic no-replace directory rename")
    die(os.strerror(error_number))


def main() -> None:
    global DESTINATION_PUBLISHED
    if len(sys.argv) != 3:
        die(f"usage: {sys.argv[0]} SOURCE_DIR DESTINATION_DIR", 2)
    fail_parent_fsync = os.environ.get("YEET_ATOMIC_TEST_FAIL_PARENT_FSYNC") == "1"
    if fail_parent_fsync and os.environ.get("YEET_RUNTIME_TEST_MODE") != "1":
        die("atomic failure injection is forbidden outside test mode")
    source = Path(sys.argv[1]).absolute()
    destination = Path(sys.argv[2]).absolute()
    source_parent_fd = os.open(source.parent, OPEN_DIR)
    destination_parent_fd = os.open(destination.parent, OPEN_DIR)
    source_fd = -1
    destination_fd = -1
    try:
        source_parent_info = os.fstat(source_parent_fd)
        destination_parent_info = os.fstat(destination_parent_fd)
        trusted_directory(source_parent_info, "source parent")
        trusted_directory(destination_parent_info, "destination parent")
        if source_parent_info.st_dev != destination_parent_info.st_dev:
            die("source and destination parents must be on the same filesystem")
        source_fd = os.open(source.name, OPEN_DIR, dir_fd=source_parent_fd)
        source_info = os.fstat(source_fd)
        trusted_directory(source_info, "source directory")
        expected = snapshot(source_fd)
        pause_file = os.environ.get("YEET_ATOMIC_TEST_PAUSE_FILE")
        if pause_file:
            if os.environ.get("YEET_RUNTIME_TEST_MODE") != "1":
                die("atomic test pause is forbidden outside test mode")
            Path(pause_file + ".ready").write_text("ready\n", encoding="ascii")
            deadline = time.monotonic() + 10
            while not Path(pause_file + ".continue").exists():
                if time.monotonic() >= deadline:
                    die("atomic test pause timed out")
                time.sleep(0.01)
        current_source_parent = source.parent.stat()
        current_destination_parent = destination.parent.stat()
        if (current_source_parent.st_dev, current_source_parent.st_ino) != (source_parent_info.st_dev, source_parent_info.st_ino):
            die("source parent was swapped before rename")
        if (current_destination_parent.st_dev, current_destination_parent.st_ino) != (destination_parent_info.st_dev, destination_parent_info.st_ino):
            die("destination parent was swapped before rename")
        current_source = os.stat(source.name, dir_fd=source_parent_fd, follow_symlinks=False)
        if (current_source.st_dev, current_source.st_ino) != (source_info.st_dev, source_info.st_ino):
            die("source directory was swapped before rename")
        verify_snapshot(source_fd, expected)
        rename_relative(source_parent_fd, source.name, destination_parent_fd, destination.name)
        DESTINATION_PUBLISHED = True
        destination_fd = os.open(destination.name, OPEN_DIR, dir_fd=destination_parent_fd)
        destination_info = os.fstat(destination_fd)
        if (destination_info.st_dev, destination_info.st_ino) != (source_info.st_dev, source_info.st_ino):
            die("renamed destination identity mismatch")
        verify_snapshot(destination_fd, expected)
        final_destination_parent = destination.parent.stat()
        if (final_destination_parent.st_dev, final_destination_parent.st_ino) != (destination_parent_info.st_dev, destination_parent_info.st_ino):
            die("destination parent changed during rename")
        fsync_fd(destination_fd)
        if fail_parent_fsync:
            raise OSError(errno.EIO, "injected destination-parent fsync failure")
        fsync_fd(destination_parent_fd)
        if source_parent_fd != destination_parent_fd:
            fsync_fd(source_parent_fd)
    except OSError as error:
        die(str(error))
    finally:
        for descriptor in (destination_fd, source_fd, destination_parent_fd, source_parent_fd):
            if descriptor >= 0:
                os.close(descriptor)


if __name__ == "__main__":
    main()
