"""Direct USB-C NCM bulk file sender; ESP32-S3 does NOT process file bytes.

Source paths are obtained from Finder's actual file-URL pasteboard, only on an
explicit assisted-paste trigger. No archives, whole-file buffers, or cloud.
"""
from __future__ import annotations

import hashlib
import os
import posixpath
import socket
import stat
import time
from dataclasses import dataclass
from pathlib import Path
from collections.abc import Callable, Sequence

from file_wire import (CHUNK_SIZE, MAX_FILE_COUNT, MAX_ROOTS, MAX_TOTAL_BYTES,
                       FileProtocolError, FramedStream, client_handshake,
                       json_bytes, read_json)


@dataclass(frozen=True)
class SourceEntry:
    relative: str
    kind: str  # d (directory), f (file), l (internal relative symlink)
    source: Path
    size: int = 0
    mtime_ns: int = 0
    inode: int = 0
    target: str = ""  # relative symlink target, never a MacBook absolute path


@dataclass(frozen=True)
class FilePlan:
    entries: tuple[SourceEntry, ...]
    roots: tuple[str, ...]
    total_bytes: int
    file_count: int

    def manifest(self) -> dict:
        return {
            "version": 1,
            "roots": list(self.roots),
            "total_bytes": self.total_bytes,
            "file_count": self.file_count,
            "entries": [
                {**{"path": e.relative, "kind": e.kind, "size": e.size,
                    "mtime_ns": e.mtime_ns},
                 **({"target": e.target} if e.kind == "l" else {})}
                for e in self.entries
            ],
        }


def prepare_files(paths: Sequence[str | Path]) -> FilePlan:
    if not 1 <= len(paths) <= MAX_ROOTS:
        raise FileProtocolError("select 1..128 files or folders")
    roots: list[str] = []
    entries: list[SourceEntry] = []
    casefolded: set[str] = set()
    total = 0
    file_count = 0

    def add(source: Path, relative: str, depth: int, root_dir: Path | None) -> None:
        nonlocal total, file_count
        if depth > 32:
            raise FileProtocolError("source folder nesting exceeds 32 levels")
        st = source.lstat()
        if stat.S_ISLNK(st.st_mode):
            # A nested symlink is preserved only if its resolved target stays
            # inside the explicitly selected directory. Do not follow links
            # into a home folder or other private files unintentionally.
            if root_dir is None:
                raise FileProtocolError("unexpected symlink in single-file selection")
            try:
                resolved = source.resolve(strict=True)
            except (OSError, RuntimeError) as exc:
                raise FileProtocolError("broken or cyclic symbolic link") from exc
            if not resolved.is_relative_to(root_dir):
                raise FileProtocolError(
                    "symbolic link points outside selected folder; "
                    "select its target separately to copy its contents"
                )
            target_inside_root = resolved.relative_to(root_dir)
            visible_root = relative.split("/", 1)[0]
            target_in_transfer = posixpath.join(visible_root, *target_inside_root.parts)
            target_relative = posixpath.relpath(
                target_in_transfer, posixpath.dirname(relative)
            )
            # Preserve the exact relative link spelling when it is safe:
            # macOS frameworks may depend on their internal link structure.
            original_target = os.readlink(source)
            if not posixpath.isabs(original_target):
                original_destination = posixpath.normpath(posixpath.join(
                    posixpath.dirname(relative), original_target
                ))
                if original_destination.split("/", 1)[0] == visible_root:
                    target_relative = original_target
            entries.append(SourceEntry(relative, "l", source, target=target_relative))
            if len(entries) > MAX_FILE_COUNT:
                raise FileProtocolError("file selection exceeds 10,000 items")
            return
        folded = relative.casefold()
        if folded in casefolded:
            raise FileProtocolError("duplicate/case-colliding file names")
        casefolded.add(folded)
        if stat.S_ISDIR(st.st_mode):
            entries.append(SourceEntry(relative, "d", source))
            with os.scandir(source) as iterator:
                children = sorted(iterator, key=lambda entry: entry.name.casefold())
            for child in children:
                add(source / child.name, relative + "/" + child.name, depth + 1, root_dir)
        elif stat.S_ISREG(st.st_mode):
            if st.st_size < 0 or st.st_size > MAX_TOTAL_BYTES - total:
                raise FileProtocolError("total file selection exceeds 256 GiB")
            file_count += 1
            total += st.st_size
            entries.append(SourceEntry(relative, "f", source, st.st_size,
                                       st.st_mtime_ns, st.st_ino))
        else:
            raise FileProtocolError("only ordinary files and folders are supported")
        if len(entries) > MAX_FILE_COUNT:
            raise FileProtocolError("file selection exceeds 10,000 items")

    for raw in paths:
        source = Path(raw).expanduser().absolute()
        if source.name in ("", ".", ".."):
            raise FileProtocolError("invalid file selection")
        if source.name.casefold() in {name.casefold() for name in roots}:
            raise FileProtocolError("duplicate source root names")
        roots.append(source.name)
        # An explicitly selected root symlink is intentional. Materialize its
        # real file/directory contents under its original Finder-visible name.
        try:
            resolved_root = source.resolve(strict=True)
        except (OSError, RuntimeError) as exc:
            raise FileProtocolError("selected item is missing, broken or cyclic") from exc
        root_dir = resolved_root if resolved_root.is_dir() else None
        add(resolved_root, source.name, 0, root_dir)

    result = FilePlan(tuple(entries), tuple(roots), total, file_count)
    json_bytes(result.manifest())  # reject excessive metadata BEFORE connecting
    return result


def send_files(sock: socket.socket, pairing_key: bytes, plan: FilePlan, *,
               cancelled: Callable[[], bool] = lambda: False,
               progress: Callable[[int, int], None] | None = None,
               clipboard_only: bool = False) -> dict:
    sock.settimeout(12)
    channel = FramedStream(sock, client_handshake(sock, pairing_key))
    manifest = plan.manifest()
    if clipboard_only:
        manifest["clipboard_only"] = True
    channel.send("M", json_bytes(manifest))
    approved = read_json(channel.recv("A", max_length=4096))
    if not approved.get("accepted"):
        reason = approved.get("reason", "")
        code = reason if reason in ("insufficient_disk_space",) else "rejected"
        raise FileProtocolError(f"Mac mini rejected file transfer: {code}")
    sent = 0
    next_update = time.monotonic()
    for entry in plan.entries:
        if entry.kind != "f":
            # Directories and safe symbolic links are metadata-only entries.
            continue
        if cancelled():
            raise FileProtocolError("file transfer cancelled")
        file_hash = hashlib.sha256()
        # An exclusive read of a path which has become a symlink is forbidden.
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(entry.source, flags)
        try:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode) or before.st_ino != entry.inode or (
                before.st_size != entry.size or before.st_mtime_ns != entry.mtime_ns
            ):
                raise FileProtocolError("source file changed since paste was requested")
            with os.fdopen(fd, "rb", buffering=0, closefd=False) as source:
                remaining = entry.size
                while remaining:
                    if cancelled():
                        raise FileProtocolError("file transfer cancelled")
                    chunk = source.read(min(CHUNK_SIZE, remaining))
                    if not chunk:
                        raise FileProtocolError("source file truncated during transfer")
                    channel.send("D", chunk)
                    file_hash.update(chunk)
                    remaining -= len(chunk)
                    sent += len(chunk)
                    now = time.monotonic()
                    if progress and now >= next_update:
                        progress(sent, plan.total_bytes)
                        next_update = now + 1
            after = os.fstat(fd)
            if after.st_size != before.st_size or after.st_mtime_ns != before.st_mtime_ns:
                raise FileProtocolError("source file changed during transfer")
        finally:
            os.close(fd)
        channel.send("E", file_hash.digest())
        ack = read_json(channel.recv("A", max_length=4096))
        if not ack.get("ok"):
            raise FileProtocolError("Mini refused or failed file verification")
    if cancelled():
        raise FileProtocolError("file transfer cancelled")
    channel.send("Q")
    answer = read_json(channel.recv("T", max_length=4096))
    if not answer.get("staged"):
        raise FileProtocolError("Mini did not finalize file transfer")
    if progress:
        progress(sent, plan.total_bytes)
    return answer
