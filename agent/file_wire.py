"""WiredKVM bulk file transport: streaming over a dedicated USB-wired TCP socket.

No ESP32 UART/HID involvement. HMAC-SHA256 mutual challenge handshake and
authenticated records; 1 MiB buffers, no third-party packages. Payloads are
not encrypted: the USB direct link is trusted, other links are disallowed.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import socket
import struct
from collections.abc import Callable

PORT = 45773
MAGIC = b"WKFILE1"
NONCE_SIZE = 16
TAG_SIZE = 32
CHUNK_SIZE = 1024 * 1024
MAX_METADATA = 4 * 1024 * 1024
MAX_FILE_COUNT = 10000
MAX_ROOTS = 128
MAX_TOTAL_BYTES = 256 * (1024 ** 3)
MAX_RECORD = MAX_METADATA
HEADER_SIZE = 9


class FileProtocolError(RuntimeError):
    pass


def recv_exact(sock: socket.socket, size: int) -> bytes:
    """Receive an exact count without storing more than the requested bytes."""
    data = bytearray()
    while len(data) < size:
        part = sock.recv(size - len(data))
        if not part:
            raise FileProtocolError("file transfer connection closed prematurely")
        data.extend(part)
    return bytes(data)


def mac(key: bytes, data: bytes) -> bytes:
    return hmac.new(key, data, hashlib.sha256).digest()


def client_handshake(sock: socket.socket, pairing_key: bytes) -> bytes:
    """Mutual authentication: server proves key possession, both use fresh nonces."""
    if len(pairing_key) != 32:
        raise FileProtocolError("invalid pairing key")
    greeting = recv_exact(sock, len(MAGIC) + NONCE_SIZE)
    if not greeting.startswith(MAGIC):
        raise FileProtocolError("unexpected file server greeting")
    server_nonce = greeting[len(MAGIC):]
    client_nonce = os.urandom(NONCE_SIZE)
    challenge = server_nonce + client_nonce
    sock.sendall(MAGIC + client_nonce + mac(pairing_key, b"WKFILE client " + challenge))
    response = recv_exact(sock, len(MAGIC) + TAG_SIZE)
    if not response.startswith(MAGIC) or not hmac.compare_digest(
        response[len(MAGIC):], mac(pairing_key, b"WKFILE server " + challenge)
    ):
        raise FileProtocolError("bulk server failed mutual authentication")
    return mac(pairing_key, b"WKFILE session " + challenge)


def server_handshake(sock: socket.socket, pairing_key: bytes) -> bytes:
    if len(pairing_key) != 32:
        raise FileProtocolError("invalid pairing key")
    server_nonce = os.urandom(NONCE_SIZE)
    sock.sendall(MAGIC + server_nonce)
    request = recv_exact(sock, len(MAGIC) + NONCE_SIZE + TAG_SIZE)
    if not request.startswith(MAGIC):
        raise FileProtocolError("bulk handshake magic mismatch")
    client_nonce = request[len(MAGIC):len(MAGIC) + NONCE_SIZE]
    challenge = server_nonce + client_nonce
    if not hmac.compare_digest(
        request[-TAG_SIZE:], mac(pairing_key, b"WKFILE client " + challenge)
    ):
        raise FileProtocolError("unauthenticated bulk client")
    sock.sendall(MAGIC + mac(pairing_key, b"WKFILE server " + challenge))
    return mac(pairing_key, b"WKFILE session " + challenge)


class FramedStream:
    """One receiver and one sender at a time, with monotonically increasing seq."""

    def __init__(self, sock: socket.socket, key: bytes):
        self.sock = sock
        self.key = key
        self.send_seq = 0
        self.recv_seq = 0

    def send(self, kind: str, payload: bytes = b"") -> None:
        if len(kind) != 1 or kind not in "MDEQACT":
            raise ValueError("invalid file record type")
        if len(payload) > (MAX_METADATA if kind == "M" else CHUNK_SIZE):
            raise ValueError("file record too large")
        hdr = struct.pack("!cII", kind.encode("ascii"), self.send_seq, len(payload))
        self.sock.sendall(hdr + payload + mac(self.key, b"WKFILE record " + hdr + payload))
        self.send_seq = (self.send_seq + 1) & 0xFFFFFFFF

    def recv(self, expected: str | tuple[str, ...], *, max_length: int = MAX_RECORD) -> bytes:
        hdr = recv_exact(self.sock, HEADER_SIZE)
        kind, seq, size = struct.unpack("!cII", hdr)
        if seq != self.recv_seq:
            raise FileProtocolError("file record sequence mismatch")
        self.recv_seq = (self.recv_seq + 1) & 0xFFFFFFFF
        kind = kind.decode("ascii", "strict")
        if kind not in ((expected,) if isinstance(expected, str) else expected):
            raise FileProtocolError("file record type mismatch")
        if size > min(max_length, MAX_RECORD):
            raise FileProtocolError("file record too large")
        payload = recv_exact(self.sock, size)
        signature = recv_exact(self.sock, TAG_SIZE)
        if not hmac.compare_digest(signature, mac(self.key, b"WKFILE record " + hdr + payload)):
            raise FileProtocolError("file data integrity failure")
        return payload


def json_bytes(obj: object) -> bytes:
    data = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(data) > MAX_METADATA:
        raise FileProtocolError("file metadata exceeds 4 MiB")
    return data


def read_json(raw: bytes) -> dict:
    try:
        value = json.loads(raw.decode("utf-8", "strict"))
    except (UnicodeError, ValueError) as exc:
        raise FileProtocolError("invalid UTF-8 JSON metadata") from exc
    if not isinstance(value, dict):
        raise FileProtocolError("manifest must be a JSON object")
    return value
