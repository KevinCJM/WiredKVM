"""Transparent C1 reports over fake UART/local sockets; no hardware or OS input."""
from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
CLIENT = Path(os.environ.get("WK_NATIVE_TEST_CLIENT", ROOT / "build/wiredkvm-native"))
CAPTURE = ROOT / "tests/fake_desktop_capture.py"


def report_frame(report):
    assert len(report) == 64
    return f"C1,{report.hex()},{zlib.crc32(report):08x}\n".encode()


def wait_for(predicate, seconds=3):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(.005)
    return bool(predicate())


class Session:
    def __init__(self, directory, events=(), slow=False, exchange=False, setup=False, foreign_media=False, publish_busy=0, setup_flash=False, input_only=False):
        self.work = Path(directory)
        self.ipc = self.work / "clipboard.sock"
        self.events, self.slow = events, slow
        self.input_only = input_only
        self.exchange = exchange or setup
        self.setup = setup
        self.setup_flash = setup_flash
        self.foreign_media = foreign_media
        self.publish_busy = publish_busy
        self.generation = 99 if foreign_media else 0
        self.media_socket = self.work / ("setup.sock" if setup else "exchange.sock")
        self.frames, self.reports, self.errors = [], [], []
        self.channel = None
        self.lock = threading.Lock()

    def __enter__(self):
        self.server = socket.socket()
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(1)
        self.worker = threading.Thread(target=self.peer, daemon=True)
        self.worker.start()
        env = dict(os.environ, WK_TEST_EVENTS=json.dumps(self.events), WK_TEST_ABSOLUTE="1",
                   WK_TEST_INVERT_SCROLL="0", WK_TEST_STARTED=str(self.work / "started"),
                   WK_TEST_COMMANDS=str(self.work / "commands"))
        env['WK_TEST_INPUT_ONLY'] = '1' if self.input_only else '0'
        extra = []
        if self.exchange:
            image = self.work / ("setup.img" if self.setup else "exchange.img")
            if not self.setup or not image.exists():
                image.write_bytes(b"a" * 1024)
            prefix = "--setup" if self.setup else "--exchange"
            extra = [prefix + "-image", str(image), prefix + "-socket", str(self.media_socket)]
            if self.setup_flash:
                extra += ["--setup-flash"]
        self.proc = subprocess.Popen([
            str(CLIENT), "--transport", f"tcp:127.0.0.1:{self.server.getsockname()[1]}",
            "--source", "macos", "--target", "desktop", "--absolute-mouse",
            "--capture", str(CAPTURE), "--input-socket" if self.input_only else "--clipboard-socket", str(self.ipc),
        ] + extra, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        assert wait_for(lambda: (self.work / "started").exists() or self.proc.poll() is not None)
        if self.proc.poll() is not None:
            raise AssertionError(self.proc.communicate())
        self.client = socket.socket(socket.AF_UNIX)
        self.client.settimeout(2)
        self.client.connect(str(self.ipc))
        # Marker confirms acceptance through the data path rather than a sleep.
        self.client.sendall(b'WKSC' + bytes(60) if self.input_only else bytes(64))
        assert wait_for(lambda: len(self.reports) >= 1)
        return self

    def peer(self):
        try:
            self.channel, _ = self.server.accept()
            with self.channel, self.channel.makefile("rb") as stream:
                for line in stream:
                    if self.slow:
                        time.sleep(len(line) / 92160)
                    parts = line.decode().strip().split(",")
                    self.frames.append((parts, time.monotonic()))
                    if parts[0] == "WK1":
                        with self.lock:
                            self.channel.sendall(f"ACK,{parts[1]}\n".encode())
                    elif parts[0] == "C1":
                        raw = bytes.fromhex(parts[1])
                        assert len(raw) == 64 and int(parts[2], 16) == zlib.crc32(raw)
                        self.reports.append(raw)
                    elif parts[0] == "X1" and self.exchange:
                        body, crc = line.decode().strip().rsplit(",", 1)
                        assert int(crc, 16) == zlib.crc32(body.encode())
                        if parts[1] == "Q":
                            self.send_exchange(f"X1,S,{self.generation}," + ("PRESENT" if self.foreign_media else "ABSENT"))
                        elif parts[1] == "O" and int(parts[2]) in (0, self.generation):
                            self.send_exchange(f"X1,S,{self.generation},ABSENT")
                        elif parts[1] in ("P", "I", "J"):
                            if self.foreign_media or self.publish_busy:
                                if self.publish_busy:
                                    self.publish_busy -= 1
                                self.send_exchange(f"X1,S,{parts[2]},BUSY")
                            else:
                                self.generation = int(parts[2])
                                self.send_exchange(f"X1,S,{self.generation},PRESENT")
                    else:
                        raise AssertionError(f"unexpected serial frame {parts}")
        except (OSError, ValueError):
            pass
        except Exception as error:
            self.errors.append(error)

    def send(self, payload, chunks=False):
        with self.lock:
            if chunks:
                for offset in range(0, len(payload), 7):
                    self.channel.sendall(payload[offset:offset + 7])
            else:
                self.channel.sendall(payload)

    def receive(self, size):
        result = b""
        while len(result) < size:
            fragment = self.client.recv(size - len(result))
            if not fragment:
                raise AssertionError("unexpected local EOF")
            result += fragment
        return result

    def send_exchange(self, body):
        self.send(f"{body},{zlib.crc32(body.encode()):08x}\n".encode())

    def exchange_command(self, command):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(2)
            client.connect(str(self.media_socket))
            client.sendall((command + "\n").encode())
            return client.recv(1024).decode()

    def commands(self):
        path = self.work / "commands"
        return path.read_text() if path.exists() else ""

    def finish(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
        return self.proc.communicate(timeout=4)

    def __exit__(self, *_):
        self.client.close()
        self.finish()
        self.server.close()
        self.worker.join(timeout=2)


class ClipboardNativeTests(unittest.TestCase):
    def test_input_only_preserves_hid_and_return_without_clipboard_commands(self):
        events = [(0, 'E 5000 0'), (.04, 'B 1 0'), (.02, 'M 20 10'), (.02, 'B 0 0'),
                  (.02, 'W 0 -1'), (0, 'C 8 0'), (0, 'T 6 1'), (0, 'T 6 0'), (0, 'C 0 0'),
                  (0, 'C COPY OUT 42'), (.04, 'M -127 0'), (.14, 'M -127 0')]
        with tempfile.TemporaryDirectory(prefix='wk-input-', dir='/tmp') as directory, Session(directory, events, slow=True, input_only=True) as s:
            s.client.sendall((b'WKC3' + bytes(60) + b'WKG2' + bytes(60)) * 128)
            self.assertTrue(wait_for(lambda: len(s.reports) == 129))
            self.assertTrue(all(r[:4] in (b'WKSC', b'WKG2') for r in s.reports))
            self.assertTrue(wait_for(lambda: 'RETURN' in s.commands()))
            kinds = [p[2] for p, _ in s.frames if p[0] == 'WK1']
            for kind in ('B', 'W', 'C', 'T', 'P'):
                self.assertIn(kind, kinds)
            s.proc.stdin.write('CLIPBOARD PASTE 42.1\n'); s.proc.stdin.flush()
            s.client.close()
            output, errors = s.finish()
            self.assertNotIn('CLIPBOARD', s.commands())
            self.assertNotIn('CPP_CLIPBOARD_INTENT', errors)
            self.assertEqual(s.proc.returncode, 0, errors)
            self.assertFalse(s.errors)

    def test_controller_exit_retains_safe_failure_code(self):
        with tempfile.TemporaryDirectory(prefix="wk-c1-error-", dir="/tmp") as directory, Session(directory) as s:
            s.send(b"ERR,overflow\n")
            self.assertTrue(wait_for(lambda: s.proc.poll() is not None))
            _, errors = s.finish()
            self.assertIn("CPP_WIREDKVM_FAILURE code=WK1_OVERFLOW\n", errors)
            self.assertNotEqual(s.proc.returncode, 0)

    def test_unit_codec_bounds_disconnect_private_socket_and_sync_ack(self):
        with tempfile.TemporaryDirectory(prefix="wk-c1-unit-", dir="/tmp") as directory:
            executable = Path(directory) / "unit"
            subprocess.run(["/usr/bin/clang++", "-std=c++17", "-O2", "-Wall", "-Wextra", "-Wpedantic",
                            "-Werror", str(ROOT / "tests/native_clipboard_test.cpp"), "-o", str(executable)], check=True)
            result = subprocess.run([str(executable), directory], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("CLIPBOARD_CHANNEL_UNIT_PASS", result.stdout)
            self.assertIn("CLIPBOARD_STATS_TEST_PASS", result.stdout)

    def test_bidirectional_split_stream_and_corrupt_frames(self):
        with tempfile.TemporaryDirectory(prefix="wk-c1-", dir="/tmp") as directory, Session(directory) as s:
            report = bytes(range(64))
            s.client.sendall(report[:7])
            time.sleep(.02)
            self.assertEqual(len(s.reports), 1)
            s.client.sendall(report[7:] + report[::-1])
            self.assertTrue(wait_for(lambda: len(s.reports) == 3))
            self.assertEqual(s.reports[1:], [report, report[::-1]])
            bad = report_frame(report)[:-9] + b"00000000\n"
            s.send(bad + b"C1,broken\n" + report_frame(report) + report_frame(report[::-1]), chunks=True)
            self.assertEqual(s.receive(128), report + report[::-1])
            self.assertIsNone(s.proc.poll())
            self.assertFalse(s.errors)

    def test_hid_heartbeat_and_edge_return_continue_during_bulk(self):
        events = [(0, "E 5000 0"), (.04, "B 1 0"), (.02, "M 20 10"), (.02, "B 0 0"),
                  (.02, "W 0 -1"), (0, "C 8 0"), (0, "T 6 1"), (0, "T 6 0"), (0, "C 0 0"),
                  (.04, "M -127 0"), (.14, "M -127 0")]
        with tempfile.TemporaryDirectory(prefix="wk-c1-", dir="/tmp") as directory, Session(directory, events, slow=True) as s:
            s.client.sendall(bytes(range(64)) * 256)
            self.assertTrue(wait_for(lambda: len(s.reports) >= 257))
            self.assertIsNone(s.proc.poll())
            self.assertFalse(s.errors)
            kinds = [p[2] for p, _ in s.frames if p[0] == "WK1"]
            self.assertIn("B", kinds)
            self.assertIn("W", kinds)
            self.assertIn("C", kinds)
            self.assertIn("T", kinds)
            pings = [t for p, t in s.frames if p[0] == "WK1" and p[2] == "P"]
            self.assertGreaterEqual(len(pings), 3)
            self.assertLess(max(b - a for a, b in zip(pings, pings[1:])), .2)
            self.assertIn("RETURN", s.commands())

    def test_guard_control_bridge_and_disconnect_cancel(self):
        events = [(0, "C COPY OUT 42"), (0, "C PASTE IN 42.7"), (0, "C CANCEL 42"),
                  (0, "C COPY OUT 43 100"), (0, "C COPY OUT 44 -2"), (0, "C COPY OUT 45 1.2"),
                  (0, "C COPY BAD 2"), (0, "C PASTE OUT " + "9" * 21)]
        with tempfile.TemporaryDirectory(prefix="wk-c1-", dir="/tmp") as directory, Session(directory, events) as s:
            s.proc.stdin.write("CLIPBOARD COPY 42\nCLIPBOARD PASTE 42.7\nCLIPBOARD CANCEL 42.8\n")
            s.proc.stdin.write("CLIPBOARD PASTE 1.2.3\n" + "x" * 300 + "\n")
            s.proc.stdin.flush()
            self.assertTrue(wait_for(lambda: "CLIPBOARD PASTE 42.7" in s.commands()))
            self.assertIn("CLIPBOARD COPY 42", s.commands())
            self.assertIn("CLIPBOARD CANCEL 42.8", s.commands())
            self.assertNotIn("1.2.3", s.commands())
            self.assertIn("CLIPBOARD CANCEL 0", s.commands())
            before = s.commands().count("CLIPBOARD CANCEL 0")
            s.client.close()
            self.assertTrue(wait_for(lambda: s.commands().count("CLIPBOARD CANCEL 0") > before))
            s.proc.stdin.close()
            s.proc.stdin = None
            self.assertTrue(wait_for(lambda: s.commands().count("CLIPBOARD CANCEL 0") > before + 1))
            output, errors = s.finish()
            self.assertIn("CPP_CLIPBOARD_INTENT C COPY OUT 42", errors)
            self.assertIn("CPP_CLIPBOARD_INTENT C PASTE IN 42.7", errors)
            self.assertIn("CPP_CLIPBOARD_INTENT C CANCEL 42", errors)
            self.assertIn("CPP_CLIPBOARD_INTENT C COPY OUT 43 100", errors)
            self.assertNotIn("CPP_CLIPBOARD_INTENT C COPY OUT 44", errors)
            self.assertNotIn("CPP_CLIPBOARD_INTENT C COPY OUT 45", errors)
            self.assertNotIn("CPP_CLIPBOARD_INTENT C COPY BAD", errors)
            self.assertNotIn("CPP_CLIPBOARD_INTENT C PASTE OUT 999", errors)
            self.assertIn("CPP_CAPTURE_STARTED", output)

    def test_exchange_and_clipboard_make_progress_together(self):
        with tempfile.TemporaryDirectory(prefix="wk-c1-", dir="/tmp") as directory, Session(directory, slow=True, exchange=True) as s:
            self.assertTrue(s.exchange_command("PUBLISH").startswith("OK PUBLISHING"))
            self.assertTrue(wait_for(lambda: s.exchange_command("STATUS").startswith("OK REMOTE")))
            generation = next(p[2] for p, _ in s.frames if p[:2] == ["X1", "P"])
            s.client.sendall(bytes(range(64)) * 256)
            self.assertTrue(wait_for(lambda: len(s.reports) >= 10))
            start = time.monotonic()
            s.send_exchange(f"X1,R,{generation},17,0,0,512")
            self.assertTrue(wait_for(lambda: any(p[:2] == ["X1", "D"] for p, _ in s.frames)))
            delivered = next(t for p, t in s.frames if p[:2] == ["X1", "D"])
            self.assertLess(delivered - start, .15)
            before = len(s.reports)
            self.assertLess(before, 257)
            self.assertTrue(wait_for(lambda: len(s.reports) == 257))
            self.assertFalse(s.errors)


if __name__ == "__main__":
    unittest.main()
