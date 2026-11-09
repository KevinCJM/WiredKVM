#!/usr/bin/env python3
"""Explicit, bounded live probe of native Finder opening and normal MSC eject.

Uses synthetic capture only (no local EventTap or clipboard access). Sends the
documented global Finder shortcut, Go to Folder for WIREDKVM, and ordinary eject.
Never types commands, installs target code, force-ejects, or mounts the image.
Stop the ordinary controller first. Never used by tests/build scripts.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", required=True)
    parser.add_argument("--port", required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--settle-seconds", type=float, default=12,
                        help="Bounded mount pacing only; never evidence of Finder readiness")
    args = parser.parse_args()
    if not 0 <= args.settle_seconds <= 30:
        parser.error("settle-seconds must be between 0 and 30")
    if not args.image.is_file():
        parser.error("existing exchange image required; probe does not create one")
    events = []
    result = {"status": "FAILED", "file_copy_verified": False}
    with tempfile.TemporaryDirectory(prefix="wk-finder-live-", dir="/private/tmp") as folder:
        work = Path(folder)
        control = work / "input.sock"
        exchange = work / "exchange.sock"
        env = dict(os.environ, WK_TEST_EVENTS=json.dumps([[0.2, "F PASTE IN 0"]]),
                   WK_TEST_ABSOLUTE="1", WK_TEST_INVERT_SCROLL="0",
                   WK_TEST_STARTED=str(work / "started"), WK_TEST_COMMANDS=str(work / "commands"))
        log = (work / "native.log").open("w+")
        process = subprocess.Popen([
            str(ROOT / "build/file-transfer/wiredkvm-native"), "--transport", args.port,
            "--baud", "921600", "--source", "macos", "--target", "desktop", "--absolute-mouse",
            "--capture", str(ROOT / "tests/fake_desktop_capture.py"),
            "--exchange-image", str(args.image), "--exchange-socket", str(exchange),
            "--file-transfer-socket", str(control),
        ], env=env, stdout=log, stderr=log)
        started = time.monotonic()
        deadline = started + 40 + args.settle_seconds
        phase = "connect"

        def request(path, command):
            if time.monotonic() > deadline:
                raise TimeoutError("bounded probe deadline")
            with socket.socket(socket.AF_UNIX) as channel:
                channel.settimeout(2)
                channel.connect(str(path))
                channel.sendall((command + "\n").encode())
                reply = b""
                while b"\n" not in reply and len(reply) < 1024:
                    part = channel.recv(1024)
                    if not part:
                        raise RuntimeError("closed IPC")
                    reply += part
            text = reply.decode().strip()
            # Fixed protocol fields only; no clipboard contents or user paths.
            events.append({"seconds": round(time.monotonic() - started, 3),
                           "phase": phase, "command": command, "reply": text})
            if not text.startswith("OK "):
                raise RuntimeError(text)
            return text.split()

        try:
            while not control.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            status = request(control, "STATUS")
            while status[1] != "PENDING":
                time.sleep(0.05)
                status = request(control, "STATUS")
            identifier = status[2]
            request(control, "BEGIN " + identifier)
            request(exchange, "PUBLISH") # Same existing image; dirty marker retained.
            while request(exchange, "STATUS2")[1] != "REMOTE":
                time.sleep(0.1)
            generation = request(exchange, "STATUS2")[3]
            phase = "mount-pacing-not-confirmation"
            settle_until = time.monotonic() + args.settle_seconds
            while time.monotonic() < settle_until:
                request(control, "KEEP " + identifier)
                state = request(exchange, "STATUS2")
                if state[1] != "REMOTE" or state[3] != generation:
                    raise RuntimeError("media changed while awaiting mount activity")
                time.sleep(0.25)

            def key(mods, usage):
                request(control, f"KEY {identifier} {mods} {usage}")
                request(control, f"KEY {identifier} 0 0")

            phase = "finder-shortcut"
            key(12, 44) # Option-Command-Space, global Finder search window.
            time.sleep(0.8)
            phase = "go-to-volume"
            key(10, 10) # Shift-Command-G
            time.sleep(0.4)
            key(8, 4) # Select path field.
            for character in "/Volumes/WIREDKVM":
                if character == "/": key(0, 56)
                elif character.isupper(): key(2, ord(character) - ord("A") + 4)
                else: key(0, ord(character) - ord("a") + 4)
            key(0, 40)
            time.sleep(0.7)
            phase = "normal-eject"
            key(8, 8) # Normal Command-E. No prompt dismissal/retry/force.
            phase = "await-ejected"
            while True:
                request(control, "KEEP " + identifier)
                state = request(exchange, "STATUS2")
                if state[1] == "EJECTED" and state[3] == generation:
                    result.update(status="EJECTED", generation=generation,
                                  finder_route_verified="normal-eject-observed")
                    break
                time.sleep(0.15)
            request(control, "END " + identifier)
        except Exception as error:
            result["error"] = str(error)
            result["failed_phase"] = phase
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.terminate(); process.wait(timeout=3)
            log.seek(0)
            result["native_log"] = log.read()[-6000:]
            log.close()
            result["events"] = events
            args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps({key: value for key, value in result.items() if key not in ("events", "native_log")}, ensure_ascii=False))
    return 0 if result["status"] == "EJECTED" else 1


if __name__ == "__main__":
    raise SystemExit(main())
