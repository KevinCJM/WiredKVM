"""Bidirectional macOS clipboard sync over the authenticated direct USB-C link.

This is an OS-Agent feature, not ESP firmware. WK1 still carries real HID
input; WK2 authenticates the control session, and WKFILE1 handles bulk bytes.
Clipboard bodies and filenames are never written to diagnostic logs.
"""
from __future__ import annotations

import hashlib
import json
import socket
import struct
import subprocess
import threading
import time
from pathlib import Path
from typing import Callable

from discovery import MACOS_IP_BOUND_IF, is_linklocal
from file_wire import (CHUNK_SIZE, FileProtocolError, FramedStream, PORT as FILE_PORT,
                       client_handshake, json_bytes, read_json, server_handshake)
from file_receiver import FileServer
from file_copy import prepare_files, send_files

SYNC_PORT = 45774
MAX_CLIPBOARD_BYTES = 80 * 1024 * 1024
MAX_IMAGE_BYTES = 48 * 1024 * 1024
MAX_TEXT_BYTES = 16 * 1024 * 1024
POLL_SECONDS = 0.35
HEARTBEAT_SECONDS = 4.0


def log(message: str) -> None:
    print(message, flush=True)


class MacOSClipboard:
    """Uses a short-lived AppKit tool, never shell commands or clipboard logs."""

    def __init__(self, executable: Path):
        if not executable.is_file():
            raise RuntimeError("clipboard-native is missing; build the AppKit helper")
        self.executable = executable

    def _run(self, option: str, value: dict | None = None) -> dict:
        data = None if value is None else json.dumps(
            value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        if data is not None and len(data) > MAX_CLIPBOARD_BYTES:
            raise ValueError("clipboard payload exceeds 80 MiB")
        result = subprocess.run(
            [str(self.executable), option], input=data, capture_output=True,
            timeout=12, check=False,
        )
        if result.returncode or len(result.stdout) > MAX_CLIPBOARD_BYTES:
            raise RuntimeError(f"native clipboard {option} failed")
        try:
            obj = json.loads(result.stdout)
        except (UnicodeError, ValueError) as exc:
            raise RuntimeError("native clipboard produced invalid JSON") from exc
        if not isinstance(obj, dict):
            raise RuntimeError("native clipboard response must be an object")
        return obj

    def state(self) -> int:
        value = self._run("--state").get("change")
        if type(value) is not int or value < 0:
            raise RuntimeError("invalid native clipboard revision")
        return value

    def snapshot(self) -> dict:
        snap = self._run("--snapshot")
        if snap.get("kind") not in ("text", "image", "files", "empty", "unsupported"):
            raise RuntimeError("invalid native clipboard type")
        if type(snap.get("change")) is not int:
            raise RuntimeError("native clipboard snapshot lacks revision")
        return snap

    def apply(self, snap: dict) -> int:
        value = self._run("--apply", snap).get("change")
        if type(value) is not int or value < 0:
            raise RuntimeError("invalid native clipboard apply revision")
        return value


def wired_connection(peer: str, local: str, interface: str | None,
                     port: int) -> socket.socket:
    if not ((is_linklocal(peer) and is_linklocal(local)) or
            (peer == local == "127.0.0.1")):
        raise ValueError("clipboard sync must use a direct wired link")
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        if interface:
            sock.setsockopt(socket.IPPROTO_IP, MACOS_IP_BOUND_IF,
                            struct.pack("I", socket.if_nametoindex(interface)))
        sock.bind((local, 0))
        sock.settimeout(6)
        sock.connect((peer, port))
        sock.settimeout(12)
        return sock
    except BaseException:
        sock.close()
        raise


def validate_clipboard_payload(snap: dict) -> dict:
    """Whitelist OS clipboard representations, with strict size constraints."""
    kind = snap.get("kind")
    if kind == "empty":
        return {"kind": "empty"}
    if kind == "text":
        value = snap.get("text")
        if (not isinstance(value, str) or not value or "\x00" in value or
                len(value.encode("utf-8")) > MAX_TEXT_BYTES):
            raise FileProtocolError("invalid text clipboard payload")
        result = {"kind": "text", "text": value}
        for format_name in ("html", "rtf"):
            encoded = snap.get(format_name)
            if encoded is not None:
                if not isinstance(encoded, str) or len(encoded) > MAX_CLIPBOARD_BYTES:
                    raise FileProtocolError("invalid rich text representation")
                result[format_name] = encoded
        return result
    if kind == "image":
        import base64
        encoded = snap.get("png")
        if not isinstance(encoded, str) or len(encoded) > (MAX_IMAGE_BYTES * 4 // 3 + 4):
            raise FileProtocolError("invalid PNG clipboard payload")
        try:
            png = base64.b64decode(encoded, validate=True)
        except ValueError as exc:
            raise FileProtocolError("malformed PNG clipboard") from exc
        if not png.startswith(b"\x89PNG\r\n\x1a\n") or len(png) > MAX_IMAGE_BYTES:
            raise FileProtocolError("PNG clipboard data invalid or oversized")
        return {"kind": "image", "png": encoded}
    raise FileProtocolError("clipboard type is unsupported by bridge")


class ClipboardSession:
    """One authenticated duplex connection with independent send/receive seq."""

    def __init__(self, sock: socket.socket, session_key: bytes, clipboard: object,
                 file_sender: Callable[[list[str], Callable[[], bool]], dict],
                 *, poll_seconds: float = POLL_SECONDS,
                 authorized: Callable[[], bool] = lambda: True):
        self.sock = sock
        self.channel = FramedStream(sock, session_key)
        self.clipboard = clipboard
        self.file_sender = file_sender
        self.authorized = authorized
        self.poll_seconds = poll_seconds
        self.stop_event = threading.Event()
        self._board_lock = threading.Lock()
        self._last_remote_revision: int | None = None
        self._outgoing: threading.Thread | None = None
        self._watch_ready = threading.Event()
        self._last_sent = time.monotonic()
        self.counters = {"sent": 0, "received": 0, "files": 0}

    def stop(self) -> None:
        self.stop_event.set()
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()
        if self._outgoing and threading.current_thread() != self._outgoing:
            self._outgoing.join(timeout=2)

    def set_received_files(self, paths: list[str]) -> None:
        """Called only by the authenticated file receiver after atomic commit."""
        with self._board_lock:
            self._last_remote_revision = self.clipboard.apply(
                {"kind": "files", "files": paths})
        self.counters["files"] += 1
        log(f"CLIP_SYNC_RECV kind=files count={len(paths)}")

    def _send_frame(self, snap: dict) -> None:
        raw = json.dumps(snap, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        if len(raw) > MAX_CLIPBOARD_BYTES:
            raise FileProtocolError("clipboard JSON exceeds 80 MiB")
        self.channel.send("M", json_bytes({"kind": "blob", "size": len(raw)}))
        digest = hashlib.sha256()
        for at in range(0, len(raw), CHUNK_SIZE):
            block = raw[at:at + CHUNK_SIZE]
            self.channel.send("D", block)
            digest.update(block)
        self.channel.send("E", digest.digest())
        self._last_sent = time.monotonic()
        self.counters["sent"] += 1
        log(f"CLIP_SYNC_SENT kind={snap['kind']} bytes={len(raw)}")

    def _send_watch_updates(self) -> None:
        try:
            with self._board_lock:
                last_seen = self.clipboard.state()
            self._watch_ready.set()
            while not self.stop_event.wait(self.poll_seconds):
                if not self.authorized():
                    raise FileProtocolError("WK2 control session no longer authorized")
                with self._board_lock:
                    revision = self.clipboard.state()
                    if revision == last_seen:
                        snap = None
                    else:
                        last_seen = revision
                        if revision == self._last_remote_revision:
                            snap = None
                        else:
                            snap = self.clipboard.snapshot()
                if snap is not None and snap.get("change") != revision:
                    # Clipboard changed again while it was being captured.
                    continue
                if snap is not None:
                    kind = snap.get("kind")
                    if kind == "files":
                        paths = snap.get("files")
                        if not isinstance(paths, list) or not paths:
                            raise FileProtocolError("invalid Finder clipboard selection")
                        try:
                            outcome = self.file_sender(paths, self.stop_event.is_set)
                            if not outcome.get("clipboard_set"):
                                raise FileProtocolError("remote file clipboard was not updated")
                        except (OSError, ValueError, FileProtocolError, RuntimeError) as exc:
                            log(f"CLIP_SYNC_FILE_SKIPPED class={type(exc).__name__}")
                            continue  # A rejected file selection must not disable text sync.
                        log(f"CLIP_SYNC_SENT kind=files count={len(paths)}")
                        self.counters["sent"] += 1
                    elif kind in ("text", "image", "empty"):
                        try:
                            safe = validate_clipboard_payload(snap)
                        except FileProtocolError:
                            log("CLIP_SYNC_PAYLOAD_SKIPPED unsupported_or_oversized")
                            continue
                        self._send_frame(safe)
                    # Unknown native clipboard types stay local; do not clear peer.
                if time.monotonic() - self._last_sent > HEARTBEAT_SECONDS:
                    self.channel.send("M", json_bytes({"kind": "heartbeat"}))
                    self._last_sent = time.monotonic()
        except (OSError, ValueError, FileProtocolError, RuntimeError,
                subprocess.SubprocessError) as exc:
            if not self.stop_event.is_set():
                log(f"CLIP_SYNC_SEND_ERROR class={type(exc).__name__}")
                self.stop()

    def _receive_one(self) -> None:
        meta = read_json(self.channel.recv("M", max_length=512))
        kind = meta.get("kind")
        if kind == "heartbeat":
            return
        if kind != "blob" or type(meta.get("size")) is not int:
            raise FileProtocolError("unsupported clipboard message")
        size = meta["size"]
        if not 1 <= size <= MAX_CLIPBOARD_BYTES:
            raise FileProtocolError("invalid clipboard payload size")
        content = bytearray()
        digest = hashlib.sha256()
        while len(content) < size:
            block = self.channel.recv("D", max_length=min(CHUNK_SIZE, size - len(content)))
            if not block:
                raise FileProtocolError("clipboard contained empty chunk")
            digest.update(block)
            content.extend(block)
        actual = self.channel.recv("E", max_length=32)
        if actual != digest.digest():
            raise FileProtocolError("clipboard SHA256 mismatch")
        try:
            snap = json.loads(content.decode("utf-8", "strict"))
        except (UnicodeError, ValueError) as exc:
            raise FileProtocolError("clipboard JSON malformed") from exc
        if not isinstance(snap, dict):
            raise FileProtocolError("clipboard payload must be JSON object")
        safe = validate_clipboard_payload(snap)
        with self._board_lock:
            self._last_remote_revision = self.clipboard.apply(safe)
        self.counters["received"] += 1
        log(f"CLIP_SYNC_RECV kind={safe['kind']} bytes={size}")

    def run(self) -> None:
        self._outgoing = threading.Thread(
            target=self._send_watch_updates, name="wiredkvm-clip-watch", daemon=True)
        self._outgoing.start()
        try:
            while not self.stop_event.is_set():
                try:
                    self._receive_one()
                except socket.timeout:
                    # Heartbeats from both sides should keep this alive.
                    raise FileProtocolError("clipboard peer heartbeat timed out")
        except (OSError, FileProtocolError, ValueError, RuntimeError) as exc:
            if not self.stop_event.is_set():
                log(f"CLIP_SYNC_RECV_ERROR class={type(exc).__name__}")
        finally:
            self.stop()


class ClipboardServer:
    """Mac mini side: only open during a valid WK2 authenticated session."""

    def __init__(self, bind: str, key: bytes, authorized: Callable[[str], bool],
                 clipboard: object, *, interface: str | None = None,
                 port: int = SYNC_PORT):
        if not is_linklocal(bind) and bind != "127.0.0.1":
            raise ValueError("clipboard server must bind on direct wired IP")
        self.bind, self.key, self.authorized = bind, key, authorized
        self.interface, self.port, self.clipboard = interface, port, clipboard
        self._server: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._session: ClipboardSession | None = None
        self._lock = threading.Lock()

    def start(self) -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((self.bind, self.port))
            sock.listen(1)
            sock.settimeout(0.35)
        except BaseException:
            sock.close()
            raise
        self._server = sock
        self._thread = threading.Thread(target=self._run, daemon=True,
                                        name="wiredkvm-clipboard-server")
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._server:
            self._server.close()
        with self._lock:
            session = self._session
        if session:
            session.stop()
        if self._thread:
            self._thread.join(timeout=2)

    def set_received_files(self, paths: list[str]) -> None:
        with self._lock:
            session = self._session
        if session is None or session.stop_event.is_set():
            raise RuntimeError("no active authenticated clipboard session")
        session.set_received_files(paths)

    def _run(self) -> None:
        assert self._server
        while not self._stop.is_set():
            try:
                client, addr = self._server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with client:
                try:
                    if not self.authorized(addr[0]):
                        raise FileProtocolError("clipboard peer has no WK2 session")
                    client.settimeout(12)
                    secret = server_handshake(client, self.key)

                    def send_selected(paths: list[str], cancelled: Callable[[], bool]) -> dict:
                        plan = prepare_files(paths)
                        with wired_connection(addr[0], self.bind, self.interface,
                                              FILE_PORT) as data_sock:
                            return send_files(data_sock, self.key, plan,
                                              cancelled=cancelled, clipboard_only=True)

                    session = ClipboardSession(
                        client, secret, self.clipboard, send_selected,
                        authorized=lambda: self.authorized(addr[0]),
                    )
                    with self._lock:
                        self._session = session
                    log("CLIP_SYNC_CONNECTED peer=MacBook")
                    session.run()
                except (OSError, ValueError, FileProtocolError, RuntimeError) as exc:
                    if not self._stop.is_set():
                        log(f"CLIP_SYNC_REJECT class={type(exc).__name__}")
                finally:
                    with self._lock:
                        self._session = None


class ClipboardClient:
    """MacBook side: start after WK2 HELLO, stop with the controller Link."""

    def __init__(self, peer: str, local: str, interface: str, key: bytes,
                 clipboard: object, *, port: int = SYNC_PORT,
                 inbox: Path | None = None):
        self.peer, self.local, self.interface = peer, local, interface
        self.key, self.clipboard, self.port, self.inbox = key, clipboard, port, inbox
        self.sock: socket.socket | None = None
        self.session: ClipboardSession | None = None
        self.file_server: FileServer | None = None
        self.thread: threading.Thread | None = None

    def start(self) -> None:
        self.sock = wired_connection(self.peer, self.local, self.interface, self.port)
        try:
            secret = client_handshake(self.sock, self.key)
            def send_selected(paths: list[str], cancelled: Callable[[], bool]) -> dict:
                plan = prepare_files(paths)
                with wired_connection(self.peer, self.local, self.interface, FILE_PORT) as bulk:
                    return send_files(bulk, self.key, plan, cancelled=cancelled,
                                      clipboard_only=True)
            self.session = ClipboardSession(self.sock, secret, self.clipboard, send_selected)

            class NoInjector:
                mode = "observe"
            self.file_server = FileServer(
                self.local, self.key, NoInjector(),
                authorized=lambda ip: ip == self.peer and
                    self.session is not None and not self.session.stop_event.is_set(),
                clipboard_writer=self.session.set_received_files,
                inbox=self.inbox,
            )
            self.file_server.start()
            self.thread = threading.Thread(target=self.session.run, daemon=True,
                                           name="wiredkvm-clipboard-client")
            self.thread.start()
            if not self.session._watch_ready.wait(timeout=6):
                raise RuntimeError("clipboard watcher failed to initialize")
            log("CLIP_SYNC_CONNECTED peer=Mac mini")
        except BaseException:
            self.stop()
            raise

    def stop(self) -> None:
        if self.session:
            self.session.stop()
        if self.file_server:
            self.file_server.stop()
        if self.sock:
            self.sock.close()
        if self.thread and self.thread != threading.current_thread():
            self.thread.join(timeout=2)
