"""Authenticated, wired-only discovery for the Stage-2 WiredKVM pair.

All probes and answers are signed using the existing 32-byte pairing key.
IP_BOUND_IF (macOS, value 25) scopes broadcast and incoming packets to one
physical Ethernet interface. No Wi-Fi or Bluetooth discovery is used.
"""
from __future__ import annotations

import hashlib
import hmac
import ipaddress
import os
import re
import select
import socket
import struct
import subprocess
import threading
import time
from dataclasses import dataclass

DISCOVERY_PORT = 45770
DISCOVERY_VERSION = "WKDISC1"
MACOS_IP_BOUND_IF = 25
MAX_DISCOVERY_FRAME = 256
BROADCAST_ADDRESS = "169.254.255.255"


@dataclass(frozen=True, slots=True)
class WiredInterface:
    name: str
    ip: str


@dataclass(frozen=True, slots=True)
class DiscoveredPeer:
    peer_ip: str
    peer_port: int
    local_ip: str
    interface: str


class DiscoveryError(RuntimeError):
    pass


def is_linklocal(ip: str) -> bool:
    try:
        address = ipaddress.IPv4Address(ip)
    except ipaddress.AddressValueError:
        return False
    return address.is_link_local and ip not in ("169.254.0.0", "169.254.255.255")


def wired_interfaces(ifconfig_output: str | None = None) -> list[WiredInterface]:
    """Return active, Ethernet-named macOS interfaces with link-local IPv4."""
    if ifconfig_output is None:
        ifconfig_output = subprocess.check_output(
            ["/sbin/ifconfig", "-a"], text=True, timeout=5
        )
    found: list[WiredInterface] = []
    current: str | None = None
    ipv4: list[str] = []
    active = False

    def flush() -> None:
        if current and re.fullmatch(r"en\d+", current) and active:
            for addr in ipv4:
                if is_linklocal(addr):
                    found.append(WiredInterface(current, addr))

    for line in ifconfig_output.splitlines():
        match_iface = re.match(r"^([A-Za-z0-9]+): flags=", line)
        if match_iface:
            flush()
            current = match_iface.group(1)
            ipv4 = []
            active = False
            continue
        match_ip = re.match(r"^\s+inet (\d+\.\d+\.\d+\.\d+)(?:\s|$)", line)
        if match_ip:
            ipv4.append(match_ip.group(1))
        if re.match(r"^\s+status:\s*active\s*$", line):
            active = True
    flush()
    return found


def _mac(key: bytes, body: bytes) -> bytes:
    if len(key) != 32:
        raise ValueError("WiredKVM pairing key must contain 32 bytes")
    return hmac.new(key, body, hashlib.sha256).hexdigest().encode("ascii")


def _verified_fields(frame: bytes, key: bytes, field_count: int) -> list[str]:
    if len(frame) > MAX_DISCOVERY_FRAME or not frame.endswith(b"\n"):
        raise ValueError("discovery frame length")
    body, sep, signature = frame[:-1].rpartition(b",")
    if not sep or len(signature) != 64:
        raise ValueError("discovery signature missing")
    if not hmac.compare_digest(_mac(key, body), signature):
        raise ValueError("discovery authentication failed")
    try:
        parts = body.decode("ascii").split(",")
    except UnicodeDecodeError as err:
        raise ValueError("discovery frame must be ASCII") from err
    if len(parts) != field_count or parts[0] != DISCOVERY_VERSION:
        raise ValueError("discovery format invalid")
    return parts


def _nonce_valid(value: str) -> bool:
    return bool(re.fullmatch(r"[0-9a-f]{32}", value))


def encode_probe(key: bytes, nonce: str) -> bytes:
    if not _nonce_valid(nonce):
        raise ValueError("expected a 16-byte nonce in lowercase hex")
    body = f"{DISCOVERY_VERSION},Q,{nonce}".encode("ascii")
    return body + b"," + _mac(key, body) + b"\n"


def decode_probe(frame: bytes, key: bytes) -> str:
    parts = _verified_fields(frame, key, 3)
    if parts[1] != "Q" or not _nonce_valid(parts[2]):
        raise ValueError("discovery request invalid")
    return parts[2]


def encode_advertisement(key: bytes, nonce: str, ip: str, port: int) -> bytes:
    if not _nonce_valid(nonce) or not is_linklocal(ip) or not 1 <= port <= 65535:
        raise ValueError("invalid discovery advertisement")
    body = f"{DISCOVERY_VERSION},A,{nonce},{ip},{port}".encode("ascii")
    return body + b"," + _mac(key, body) + b"\n"


def decode_advertisement(frame: bytes, key: bytes, nonce: str, source_ip: str) -> tuple[str, int]:
    parts = _verified_fields(frame, key, 5)
    if parts[1] != "A" or parts[2] != nonce or not _nonce_valid(parts[2]):
        raise ValueError("discovery nonce mismatch")
    if parts[3] != source_ip or not is_linklocal(parts[3]):
        raise ValueError("discovery address mismatch")
    if not re.fullmatch(r"[1-9][0-9]{0,4}", parts[4]):
        raise ValueError("discovery port invalid")
    port = int(parts[4])
    if port > 65535:
        raise ValueError("discovery port out of range")
    return parts[3], port


def _scope_socket(sock: socket.socket, interface: str) -> None:
    ifindex = socket.if_nametoindex(interface)
    # Strictly bind IP to this wired interface. Never silently fall back to
    # unscoped discovery on Wi-Fi if the OS refuses IP_BOUND_IF.
    sock.setsockopt(socket.IPPROTO_IP, MACOS_IP_BOUND_IF, struct.pack("I", ifindex))


def discover(
    key: bytes, *, interface: str = "auto", timeout: float = 4,
    port: int = DISCOVERY_PORT,
) -> DiscoveredPeer:
    """Broadcast on active wired-only interfaces; accept only HMAC replies."""
    if timeout <= 0:
        raise ValueError("timeout must be positive")
    candidates = [
        candidate for candidate in wired_interfaces()
        if interface == "auto" or candidate.name == interface
    ]
    if not candidates:
        raise DiscoveryError(
            f"No active USB/Ethernet link-local address found (interface={interface}). "
            "Connect both Macs with the data cable and check their network interfaces."
        )

    nonce = os.urandom(16).hex()
    packet = encode_probe(key, nonce)
    opened: dict[socket.socket, WiredInterface] = {}
    try:
        for candidate in candidates:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
                _scope_socket(sock, candidate.name)
                sock.bind((candidate.ip, 0))
            except OSError:
                sock.close()
                continue
            opened[sock] = candidate
        if not opened:
            raise DiscoveryError("Failed to open a wired-only discovery socket")
        end = time.monotonic() + timeout
        next_send = 0.0
        while time.monotonic() < end:
            now = time.monotonic()
            if now >= next_send:
                for sock in opened:
                    try:
                        sock.sendto(packet, (BROADCAST_ADDRESS, port))
                    except OSError:
                        pass
                next_send = now + 0.5
            wait = min(0.25, max(0.0, end - time.monotonic()))
            readable, _, _ = select.select(list(opened), [], [], wait)
            for sock in readable:
                try:
                    answer, address = sock.recvfrom(MAX_DISCOVERY_FRAME + 16)
                    ip, tcp_port = decode_advertisement(answer, key, nonce, address[0])
                except (ValueError, OSError):
                    continue
                selected = opened[sock]
                if selected.ip == ip:
                    continue
                return DiscoveredPeer(ip, tcp_port, selected.ip, selected.name)
    finally:
        for sock in opened:
            sock.close()
    choices = ", ".join(f"{c.name}={c.ip}" for c in candidates)
    raise DiscoveryError(
        f"No authenticated Mac mini Agent replied on wired network ({choices}). "
        "Start Mac mini WiredKVM-Agent and verify USB networking and pairing."
    )


class DiscoveryResponder:
    """Reply only to authenticated probes received on the selected wired port."""

    def __init__(
        self, key: bytes, *, bind_ip: str, interface: str, tcp_port: int,
        port: int = DISCOVERY_PORT,
    ) -> None:
        if not is_linklocal(bind_ip):
            raise ValueError("discovery requires a link-local, wired bind address")
        self.key = key
        self.bind_ip = bind_ip
        self.tcp_port = tcp_port
        self.stop_event = threading.Event()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            _scope_socket(self.sock, interface)
            self.sock.bind(("0.0.0.0", port))
            self.sock.settimeout(0.25)
        except Exception:
            self.sock.close()
            raise
        self.thread = threading.Thread(target=self._run, name="wiredkvm-discovery", daemon=True)

    def start(self) -> None:
        self.thread.start()

    def _run(self) -> None:
        while not self.stop_event.is_set():
            try:
                frame, sender = self.sock.recvfrom(MAX_DISCOVERY_FRAME + 16)
            except socket.timeout:
                continue
            except OSError:
                break
            if not is_linklocal(sender[0]) or sender[0] == self.bind_ip:
                continue
            try:
                nonce = decode_probe(frame, self.key)
                response = encode_advertisement(
                    self.key, nonce, self.bind_ip, self.tcp_port
                )
                self.sock.sendto(response, sender)
            except (OSError, ValueError):
                continue

    def close(self) -> None:
        self.stop_event.set()
        self.sock.close()
        if self.thread.is_alive():
            self.thread.join(timeout=1.5)
