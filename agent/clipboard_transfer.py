"""Explicit, authenticated UTF-8 clipboard extension for the simulator Agent.

The packets travel on the existing physically wired WK2 HMAC/TCP channel.
They do not travel through the ESP32 UART/HID firmware and therefore are
NOT a capability of an Agent-free physical ESP32-S3.
"""
from __future__ import annotations

import hashlib
import time
from collections.abc import Iterator

from net_protocol import CLIPBOARD_CHUNK_BYTES, MAX_CLIPBOARD_BYTES, Packet

CLIPBOARD_TRANSFER_TIMEOUT = 10.0


def clipboard_packets(text: str) -> Iterator[Packet]:
    if not isinstance(text, str) or "\x00" in text:
        raise ValueError("clipboard must be UTF-8 text without NUL")
    data = text.encode("utf-8")
    if not 1 <= len(data) <= MAX_CLIPBOARD_BYTES:
        raise ValueError("clipboard text must be 1..32768 UTF-8 bytes")
    yield Packet(0, "U", (len(data),))
    for offset in range(0, len(data), CLIPBOARD_CHUNK_BYTES):
        yield Packet(0, "D", tuple(data[offset:offset + CLIPBOARD_CHUNK_BYTES]))
    yield Packet(0, "X", tuple(hashlib.sha256(data).digest()))


class ClipboardAssembler:
    """Per-TCP-session clipboard assembler; only completed transfers are applied."""

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.expected = 0
        self.buf = bytearray()
        self.deadline = 0.0
        self.active = False

    def accept(self, packet: Packet, now: float | None = None) -> str | None:
        now = time.monotonic() if now is None else now
        if packet.kind not in ("U", "D", "X"):
            raise ValueError("not a clipboard packet")
        if self.active and now > self.deadline:
            self.reset()
            raise ValueError("clipboard transfer timeout")

        if packet.kind == "U":
            # No overlapping transactions, no unbounded allocations.
            if self.active:
                self.reset()
                raise ValueError("clipboard transaction already active")
            count = packet.args[0]
            if not 1 <= count <= MAX_CLIPBOARD_BYTES:
                raise ValueError("clipboard length invalid")
            self.expected = count
            self.deadline = now + CLIPBOARD_TRANSFER_TIMEOUT
            self.active = True
            return None

        if not self.active:
            raise ValueError("clipboard transaction not started")
        if packet.kind == "D":
            if not 1 <= len(packet.args) <= CLIPBOARD_CHUNK_BYTES:
                self.reset()
                raise ValueError("clipboard chunk out of range")
            if len(self.buf) + len(packet.args) > self.expected:
                self.reset()
                raise ValueError("clipboard byte count exceeded")
            self.buf.extend(packet.args)
            return None

        try:
            if len(self.buf) != self.expected:
                raise ValueError("clipboard transfer incomplete")
            if hashlib.sha256(self.buf).digest() != bytes(packet.args):
                raise ValueError("clipboard content hash mismatch")
            try:
                value = self.buf.decode("utf-8", errors="strict")
            except UnicodeError as exc:
                raise ValueError("clipboard is not valid UTF-8") from exc
            if "\x00" in value:
                raise ValueError("clipboard contains NUL")
            return value
        finally:
            self.reset()
