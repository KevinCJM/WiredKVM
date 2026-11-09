"""X1 virtual media over fake UART; never opens real serial or input capture."""
from __future__ import annotations

import json
import fcntl
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


def frame(body):
    return f"{body},{zlib.crc32(body.encode()):08x}\n".encode()


def wait_for(predicate, seconds=3):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(.005)
    return bool(predicate())


class Session:
    def __init__(self, directory, *, old=False, events=(), publish_busy=0, serial_speed=False):
        self.work = Path(directory)
        self.image = self.work / "exchange.img"
        self.ipc = self.work / "exchange.sock"
        self.old = old
        self.events = events
        self.publish_busy = publish_busy
        self.serial_speed = serial_speed
        self.frames = []
        self.hid = []
        self.generation = 0
        self.channel = None
        self.lock = threading.Lock()

    def __enter__(self):
        (self.work / "started").unlink(missing_ok=True)
        self.server = socket.socket()
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(1)
        self.worker = threading.Thread(target=self.peer, daemon=True)
        self.worker.start()
        env = dict(os.environ, WK_TEST_EVENTS=json.dumps(self.events), WK_TEST_ABSOLUTE="1",
                   WK_TEST_INVERT_SCROLL="0", WK_TEST_STARTED=str(self.work / "started"),
                   WK_TEST_COMMANDS=str(self.work / "commands"))
        self.proc = subprocess.Popen([
            str(CLIENT), "--transport", f"tcp:127.0.0.1:{self.server.getsockname()[1]}",
            "--source", "macos", "--target", "desktop", "--absolute-mouse",
            "--capture", str(CAPTURE), "--exchange-image", str(self.image),
            "--exchange-socket", str(self.ipc),
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        assert wait_for(lambda: (self.work / "started").exists() or self.proc.poll() is not None)
        if self.proc.poll() is not None:
            raise AssertionError(self.proc.communicate())
        return self

    def send(self, body):
        with self.lock:
            payload = frame(body)
            if self.serial_speed:
                for offset in range(0, len(payload), 64):
                    fragment = payload[offset:offset + 64]
                    self.channel.sendall(fragment)
                    time.sleep(len(fragment) / 92160)
            else:
                self.channel.sendall(payload)

    def peer(self):
        try:
            self.channel, _ = self.server.accept()
            with self.channel, self.channel.makefile("rb") as stream:
                for line in stream:
                    if self.serial_speed:
                        time.sleep(len(line) / 92160)
                    parts = line.decode().strip().split(",")
                    if parts[0] == "WK1":
                        self.hid.append((parts[2], time.monotonic()))
                        with self.lock:
                            self.channel.sendall(f"ACK,{parts[1]}\n".encode())
                    else:
                        body, crc = line.decode().strip().rsplit(",", 1)
                        assert int(crc, 16) == zlib.crc32(body.encode())
                        self.frames.append(parts[:-1])
                        if parts[1] == "Q":
                            if self.old:
                                self.channel.sendall(b"ERR,bad-format\n")
                            else:
                                self.send("X1,S,0,ABSENT")
                        elif parts[1] == "O":
                            self.send(f"X1,S,{self.generation},ABSENT")
                        elif parts[1] == "P":
                            if self.publish_busy:
                                self.publish_busy -= 1
                                self.send(f"X1,S,{self.generation},BUSY")
                            else:
                                self.generation = int(parts[2])
                                self.send(f"X1,S,{self.generation},PRESENT")
        except (OSError, ValueError):
            pass

    def command(self, command):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(4)
            client.connect(str(self.ipc))
            client.sendall((command + "\n").encode())
            return client.recv(1024).decode().strip()

    def publish(self):
        assert self.command("PUBLISH").startswith("OK PUBLISHING ")
        assert wait_for(lambda: self.command("STATUS").startswith("OK REMOTE "))
        return self.generation

    def reply(self, kind, request):
        return next((p for p in self.frames if p[1] == kind and len(p) >= 4 and p[3] == str(request)), None)

    def finish(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
        return self.proc.communicate(timeout=4)

    def __exit__(self, *_):
        self.finish()
        self.server.close()
        self.worker.join(timeout=2)


class ExchangeNativeTests(unittest.TestCase):
    def test_publish_retries_tinyusb_completion_barrier(self):
        with tempfile.TemporaryDirectory(prefix="wk-x1-") as directory:
            (Path(directory) / "exchange.img").write_bytes(b"a" * 1024)
            with Session(directory, publish_busy=2) as s:
                s.publish()
                publications = [p for p in s.frames if p[1] == "P"]
                self.assertEqual(len(publications), 3)
                self.assertEqual(len({p[2] for p in publications}), 1)

    def test_initial_missing_image_local_permission_and_old_firmware(self):
        for old in (False, True):
            with self.subTest(old=old), tempfile.TemporaryDirectory(prefix="wk-x1-") as directory:
                with Session(directory, old=old) as s:
                    self.assertEqual(s.ipc.stat().st_mode & 0o777, 0o600)
                    if not old:
                        self.assertEqual(s.command("STATUS"), "OK AVAILABLE 0")
                    self.assertEqual(s.command("LOCAL"), "ERR CAP_UNSUPPORTED" if old else "OK LOCAL 0")
                    self.assertIsNone(s.proc.poll())
                    self.assertTrue(wait_for(lambda: sum(k == "P" for k, _ in s.hid) > 1))

    def test_read_write_crc_offsets_safe_eject_and_local_return(self):
        with tempfile.TemporaryDirectory(prefix="wk-x1-") as directory:
            image = Path(directory) / "exchange.img"
            image.write_bytes(bytes(range(256)) * 4)
            with Session(directory) as s:
                self.assertEqual(s.command("LOCAL"), "OK LOCAL 1024")
                generation = s.publish()
                marker = Path(str(image) + ".remote_dirty")
                self.assertTrue(marker.exists())
                with image.open("r+b") as lock_probe:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(lock_probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertEqual(s.command("LOCAL"), "ERR NEED_EJECT")
                s.send(f"X1,R,{generation},1,1,0,512")
                self.assertTrue(wait_for(lambda: s.reply("D", 1)))
                self.assertEqual(bytes.fromhex(s.reply("D", 1)[4]), bytes(range(256)) * 2)
                data = b"\x00hello\xff\n\r\x80"
                s.send(f"X1,W,{generation},2,0,17,{data.hex()}")
                self.assertTrue(wait_for(lambda: s.reply("A", 2)))
                self.assertEqual(image.read_bytes()[17:17+len(data)], data)
                s.send(f"X1,S,{generation},EJECTED")
                self.assertTrue(wait_for(lambda: s.command("STATUS").startswith("OK EJECTED ")))
                self.assertFalse(marker.exists())
                with image.open("r+b") as lock_probe:
                    fcntl.flock(lock_probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertEqual(s.command("LOCAL"), "OK LOCAL 1024")

    def test_disconnect_preserves_dirty_and_restores_local_input(self):
        with tempfile.TemporaryDirectory(prefix="wk-x1-") as directory:
            image = Path(directory) / "exchange.img"
            image.write_bytes(b"a" * 1024)
            with Session(directory, events=[(0, "E 5000 0")]) as s:
                s.publish()
                s.channel.shutdown(socket.SHUT_RDWR)
                self.assertTrue(wait_for(lambda: s.proc.poll() is not None))
                self.assertTrue(Path(str(image) + ".remote_dirty").exists())
                commands = (s.work / "commands").read_text()
                self.assertIn("RETURN", commands)

    def test_out_of_range_bad_crc_and_stale_generation_cannot_write(self):
        with tempfile.TemporaryDirectory(prefix="wk-x1-") as directory:
            image = Path(directory) / "exchange.img"
            image.write_bytes(b"a" * 1024)
            with Session(directory) as s:
                generation = s.publish()
                s.send(f"X1,W,{generation},3,2,0,ff")
                self.assertTrue(wait_for(lambda: s.reply("F", 3)))
                s.send(f"X1,W,{generation},4,1,511,ffff")
                self.assertTrue(wait_for(lambda: s.reply("F", 4)))
                s.send(f"X1,W,{generation ^ 1},5,0,0,ff")
                with s.lock:
                    s.channel.sendall(f"X1,W,{generation},6,0,0,ff,00000000\n".encode())
                time.sleep(.05)
                self.assertFalse(s.reply("A", 5))
                self.assertFalse(s.reply("A", 6))
                self.assertEqual(image.read_bytes(), b"a" * 1024)

    def test_shutdown_keeps_dirty_and_recovery_requires_target_eject(self):
        with tempfile.TemporaryDirectory(prefix="wk-x1-") as directory:
            image = Path(directory) / "exchange.img"
            image.write_bytes(b"a" * 1024)
            marker = Path(str(image) + ".remote_dirty")
            with Session(directory) as s:
                s.publish()
            self.assertTrue(marker.exists())
            with Session(directory) as s:
                self.assertEqual(s.command("LOCAL"), "ERR NEED_EJECT")
                generation = s.publish()
                s.send(f"X1,S,{generation},EJECTED")
                self.assertTrue(wait_for(lambda: s.command("STATUS").startswith("OK EJECTED ")))
                self.assertEqual(s.command("LOCAL"), "OK LOCAL 1024")

    def test_symlink_image_and_replaced_dirty_image_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="wk-x1-") as directory:
            image = Path(directory) / "exchange.img"
            other = Path(directory) / "other.img"
            other.write_bytes(b"a" * 1024)
            image.symlink_to(other)
            with Session(directory) as s:
                self.assertEqual(s.command("PUBLISH"), "ERR IMAGE_OPEN_FAILED")
            image.unlink()
            image.write_bytes(b"b" * 1024)
            with Session(directory) as s:
                s.publish()
            other.replace(image)
            with Session(directory) as s:
                self.assertEqual(s.command("PUBLISH"), "ERR IMAGE_CHANGED")
                self.assertEqual(s.command("LOCAL"), "ERR NEED_EJECT")

    def test_storage_keeps_keyboard_and_heartbeat_running(self):
        events = [(0, "E 5000 0"), (.2, "T 4 1"), (.02, "T 4 0")]
        with tempfile.TemporaryDirectory(prefix="wk-x1-") as directory:
            (Path(directory) / "exchange.img").write_bytes(b"a" * 4096)
            with Session(directory, events=events) as s:
                generation = s.publish()
                for request in range(1, 40):
                    s.send(f"X1,R,{generation},{request},0,0,512")
                    self.assertTrue(wait_for(lambda: s.reply("D", request)))
                self.assertTrue(wait_for(lambda: sum(kind == "T" for kind, _ in s.hid) == 2))
                self.assertIsNone(s.proc.poll())
                stamps = [at for kind, at in s.hid if kind == "P"]
                self.assertGreater(len(stamps), 2)
                self.assertLess(max(b-a for a, b in zip(stamps, stamps[1:])), .25)

    def test_serial_rate_fragmented_blocks_preserve_frames_and_hid(self):
        events = [(0, "E 5000 0")]
        events += [(.01, "M 2 0") for _ in range(20)]
        events += [(.01, "B 1 0"), (.02, "B 0 0"), (.01, "T 4 1"), (.02, "T 4 0")]
        with tempfile.TemporaryDirectory(prefix="wk-x1-") as directory:
            image = Path(directory) / "exchange.img"
            image.write_bytes(b"a" * 4096)
            with Session(directory, events=events, serial_speed=True) as s:
                generation = s.publish()
                for request in range(1, 41):
                    if request % 2:
                        payload = bytes([request]) * 512
                        s.send(f"X1,W,{generation},{request},0,0,{payload.hex()}")
                        self.assertTrue(wait_for(lambda: s.reply("A", request)))
                    else:
                        s.send(f"X1,R,{generation},{request},0,0,512")
                        self.assertTrue(wait_for(lambda: s.reply("D", request)))
                        self.assertEqual(bytes.fromhex(s.reply("D", request)[4]), bytes([request-1]) * 512)
                self.assertIsNone(s.proc.poll())
                self.assertEqual(sum(kind == "T" for kind, _ in s.hid), 2)
                self.assertEqual(sum(kind == "B" for kind, _ in s.hid), 2)
                stamps = [at for kind, at in s.hid if kind == "P"]
                self.assertLess(max(b-a for a, b in zip(stamps, stamps[1:])), .25)


if __name__ == "__main__":
    unittest.main()
