#!/usr/bin/env python3
"""Live USB-C/WK2 clipboard e2e with PRIVATE macOS pasteboards; no user content read."""
from __future__ import annotations

import argparse
import base64
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent if (HERE.parent / "agent").is_dir() else HERE
sys.path.insert(0, str(ROOT / "agent") if (ROOT / "agent").is_dir() else str(ROOT))
sys.path.insert(0, str(ROOT / "host") if (ROOT / "host").is_dir() else str(ROOT))

from clipboard_sync import ClipboardClient, MacOSClipboard, wired_connection
from discovery import discover
from net_protocol import Packet, encode, read_key

PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9ZtH01kAAAAASUVORK5CYII="
BOARD = os.environ.get("WK_CLIPBOARD_TEST_BOARD", "")
TAG = os.environ.get("WK_CLIPBOARD_TEST_TAG", "wiredkvm_e2e")
TIMEOUT = 32.0


def expect(board: MacOSClipboard, kind: str, check, stage: str) -> dict:
    until = time.monotonic() + TIMEOUT
    last_kind = "none"
    while time.monotonic() < until:
        sample = board.snapshot()
        last_kind = sample["kind"]
        if last_kind == kind and check(sample):
            print(f"WIRED_CLIP_E2E_OK stage={stage} kind={kind}", flush=True)
            return sample
        time.sleep(.16)
    raise TimeoutError(f"stage={stage} expected={kind} received={last_kind}")


def text_value(label: str, *, rich: bool = False) -> dict:
    data = {"kind": "text", "text": f"{TAG} {label} 中文 😀"}
    if rich:
        data["html"] = base64.b64encode(b"<b>WiredKVM Rich Text</b>").decode()
    return data


def is_text(label: str):
    return lambda d: d.get("text") == text_value(label)["text"]


def create_fixture(parent: Path, who: str) -> list[str]:
    picture = parent / f"{who}-sample.png"
    picture.write_bytes(base64.b64decode(PNG))
    directory = parent / f"{who}-folder"
    directory.mkdir()
    (directory / "nested-中文.txt").write_text("WiredKVM E2E folder", encoding="utf-8")
    return [str(picture), str(directory)]


def validate_received_files(sample: dict, who: str) -> bool:
    paths = sample.get("files", [])
    if not isinstance(paths, list) or len(paths) != 2:
        return False
    observed = {Path(path).name: Path(path) for path in paths}
    picture = observed.get(f"{who}-sample.png")
    directory = observed.get(f"{who}-folder")
    return bool(picture and directory and picture.is_file() and directory.is_dir() and
                picture.read_bytes() == base64.b64decode(PNG) and
                (directory / "nested-中文.txt").read_text(encoding="utf-8") ==
                "WiredKVM E2E folder")


def mini(board: MacOSClipboard) -> None:
    with tempfile.TemporaryDirectory(prefix="wiredkvm-mini-source-") as temp:
        selected = create_fixture(Path(temp), "mini")
        received = expect(board, "text", is_text("BOOK_TEXT"), "Book_to_Mini_text")
        assert received.get("html") == base64.b64encode(
            b"<b>WiredKVM Rich Text</b>").decode()
        board.apply(text_value("MINI_TEXT", rich=True))
        expect(board, "text", is_text("BOOK_ACK_TEXT"), "Book_ack_text")
        board.apply({"kind": "image", "png": PNG})
        expect(board, "text", is_text("BOOK_ACK_IMAGE"), "Book_ack_Mini_image")
        board.apply(text_value("MINI_READY_BOOK_IMAGE"))
        expect(board, "image", lambda d: d.get("png") == PNG, "Book_to_Mini_image")
        board.apply(text_value("MINI_ACK_IMAGE"))
        expect(board, "files", lambda s: validate_received_files(s, "book"),
               "Book_to_Mini_files_and_folder")
        board.apply(text_value("MINI_ACK_FILES"))
        expect(board, "text", is_text("BOOK_READY_MINI_FILES"), "Book_ready_for_Mini_files")
        board.apply({"kind": "files", "files": selected})
        expect(board, "text", is_text("BOOK_ACK_FILES"), "Book_ack_Mini_files")
        print("WIRED_CLIP_E2E_MINI_PASS reverse_text_image_files_folder=true", flush=True)


def book(board: MacOSClipboard, token_file: Path) -> None:
    key = read_key(str(token_file))
    endpoint = discover(key, interface="en6", timeout=5)
    control = wired_connection(endpoint.peer_ip, endpoint.local_ip, endpoint.interface,
                               endpoint.peer_port)
    quit_heartbeat = threading.Event()
    client = None
    try:
        control.sendall(encode(Packet(0, "H"), key))
        control.settimeout(5)
        if not control.recv(128).startswith(b"AUTH_OK\n"):
            raise RuntimeError("WK2 control authentication failed")
        control.settimeout(None)

        def ping() -> None:
            seq = 1
            while not quit_heartbeat.wait(.35):
                try:
                    control.sendall(encode(Packet(seq, "P"), key))
                except OSError:
                    return
                seq = (seq + 1) & 0xFFFFFFFF

        threading.Thread(target=ping, daemon=True).start()
        with tempfile.TemporaryDirectory(prefix="wiredkvm-book-e2e-") as temp:
            folder = Path(temp)
            selected = create_fixture(folder, "book")
            client = ClipboardClient(endpoint.peer_ip, endpoint.local_ip,
                                     endpoint.interface, key, board,
                                     inbox=folder / "BookInbox")
            client.start()
            board.apply(text_value("BOOK_TEXT", rich=True))
            received = expect(board, "text", is_text("MINI_TEXT"), "Mini_to_Book_text")
            assert received.get("html") == base64.b64encode(
                b"<b>WiredKVM Rich Text</b>").decode()
            board.apply(text_value("BOOK_ACK_TEXT"))
            expect(board, "image", lambda d: d.get("png") == PNG, "Mini_to_Book_image")
            board.apply(text_value("BOOK_ACK_IMAGE"))
            expect(board, "text", is_text("MINI_READY_BOOK_IMAGE"), "Mini_ready_for_Book_image")
            board.apply({"kind": "image", "png": PNG})
            expect(board, "text", is_text("MINI_ACK_IMAGE"), "Mini_ack_Book_image")
            board.apply({"kind": "files", "files": selected})
            expect(board, "text", is_text("MINI_ACK_FILES"), "Mini_ack_Book_files")
            board.apply(text_value("BOOK_READY_MINI_FILES"))
            expect(board, "files", lambda s: validate_received_files(s, "mini"),
                   "Mini_to_Book_files_and_folder")
            board.apply(text_value("BOOK_ACK_FILES"))
            time.sleep(1)
            if client.session is None or client.session.stop_event.is_set():
                raise RuntimeError("clipboard session disconnected during e2e")
            print("WIRED_CLIP_E2E_BOOK_PASS both_directions=true types=text,rich,image,files,folder",
                  flush=True)
    finally:
        quit_heartbeat.set()
        if client:
            client.stop()
        control.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--role", required=True, choices=("book", "mini"))
    parser.add_argument("--token-file", type=Path)
    args = parser.parse_args()
    if not BOARD.startswith("com.wiredkvm.test."):
        raise RuntimeError("refusing to test the user's general clipboard")
    binary = (ROOT / "build/clipboard-native")
    board = MacOSClipboard(binary)
    print(f"WIRED_CLIP_E2E_START role={args.role} private_board=true", flush=True)
    try:
        if args.role == "book":
            if args.token_file is None:
                raise ValueError("MacBook requires --token-file")
            book(board, args.token_file)
        else:
            mini(board)
        return 0
    finally:
        subprocess.run([str(binary), "--release-test-board"], capture_output=True,
                       timeout=5, check=False)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, TimeoutError, AssertionError) as exc:
        print(f"WIRED_CLIP_E2E_FAIL {type(exc).__name__}: {exc}", file=sys.stderr,
              flush=True)
        raise SystemExit(1)
