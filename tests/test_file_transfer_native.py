"""Leased automation over a fake UART and capture pipe; no physical input."""
from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

if __package__:
    from .test_exchange_native import Session, frame, wait_for
else:
    from test_exchange_native import Session, frame, wait_for

ROOT = Path(__file__).resolve().parents[1]
CLIENT = Path(os.environ.get("WK_NATIVE_TEST_CLIENT", ROOT / "build/wiredkvm-native"))


class FileSession:
    def __init__(self, directory, events=(), key_delay=0, no_key_ack=False, stale_file=False):
        self.work = Path(directory)
        self.socket = self.work / "file.sock"
        self.exchange = self.work / "exchange.sock"
        self.events, self.key_delay, self.no_key_ack = events, key_delay, no_key_ack
        self.stale_file = stale_file
        self.frames = []
        self.output = ("", "")

    def __enter__(self):
        self.server = socket.socket()
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(1)
        self.server.settimeout(3)
        self.worker = threading.Thread(target=self.peer, daemon=True)
        self.worker.start()
        if self.stale_file:
            self.socket.write_text("do not delete")
        env = dict(os.environ, WK_TEST_EVENTS=json.dumps(self.events), WK_TEST_ABSOLUTE="1",
                   WK_TEST_INVERT_SCROLL="0", WK_TEST_STARTED=str(self.work / "started"),
                   WK_TEST_COMMANDS=str(self.work / "commands"))
        self.proc = subprocess.Popen([
            str(CLIENT), "--transport", f"tcp:127.0.0.1:{self.server.getsockname()[1]}",
            "--source", "macos", "--target", "desktop", "--absolute-mouse",
            "--capture", str(ROOT / "tests/fake_desktop_capture.py"),
            "--exchange-image", str(self.work / "image.img"),
            "--exchange-socket", str(self.exchange), "--file-transfer-socket", str(self.socket),
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        assert wait_for(lambda: (self.work / "started").exists() or self.proc.poll() is not None)
        return self

    def peer(self):
        try:
            channel, _ = self.server.accept()
            with channel, channel.makefile("rb") as stream:
                for line in stream:
                    fields = line.decode().strip().split(",")
                    if fields[0] == "X1":
                        if fields[1] == "Q":
                            channel.sendall(frame("X1,S,0,ABSENT"))
                        elif fields[1] == "O":
                            channel.sendall(frame("X1,S,0,ABSENT"))
                    else:
                        record = (fields[2], int(fields[3]), int(fields[4]), time.monotonic())
                        self.frames.append(record)
                        if fields[2] == "K":
                            if self.no_key_ack:
                                continue
                            time.sleep(self.key_delay)
                        channel.sendall(f"ACK,{fields[1]}\n".encode())
        except (OSError, ValueError):
            pass

    def command(self, line, path=None):
        with socket.socket(socket.AF_UNIX) as channel:
            channel.settimeout(3)
            channel.connect(str(path or self.socket))
            channel.sendall((line + "\n").encode())
            return channel.recv(1024).decode().strip()

    def intent(self):
        assert wait_for(lambda: self.command("STATUS").startswith("OK PENDING"))
        return int(self.command("STATUS").split()[2])

    def finish(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
        self.output = self.proc.communicate(timeout=4)
        return self.output

    def __exit__(self, *_):
        self.finish()
        self.server.close()
        self.worker.join(timeout=2)


class FileRuntimeTests(unittest.TestCase):
    def test_commands_need_actual_paste_intent_and_private_socket(self):
        with tempfile.TemporaryDirectory(prefix="wk-file-") as directory, FileSession(directory) as s:
            self.assertEqual(s.socket.stat().st_mode & 0o777, 0o600)
            self.assertTrue(s.command("STATUS").startswith("OK IDLE"))
            self.assertEqual(s.command("BEGIN 1"), "ERR STALE_INTENT")
            self.assertEqual(s.command("KEY 1 8 25"), "ERR STALE_INTENT")
            self.assertFalse(any(f[0] == "K" for f in s.frames))

    def test_keys_wait_for_ack_with_local_pointer_and_end_releases(self):
        with tempfile.TemporaryDirectory(prefix="wk-file-") as directory, FileSession(
                directory, [(0.04, "F PASTE IN 12")], key_delay=.08) as s:
            intent = s.intent()
            self.assertEqual(s.command(f"BEGIN {intent}"), f"OK ACTIVE {intent}")
            self.assertEqual(s.command(f"KEY {intent} 256 25"), "ERR BAD_COMMAND")
            self.assertEqual(s.command(f"KEY {intent} 8 3"), "ERR BAD_COMMAND")
            start = time.monotonic()
            self.assertEqual(s.command(f"KEY {intent} 8 25"), f"OK KEY {intent}")
            self.assertGreaterEqual(time.monotonic() - start, .07)
            self.assertEqual(s.command(f"KEY {intent} 0 0"), f"OK KEY {intent}")
            self.assertEqual(s.command(f"END {intent}"), f"OK END {intent}")
            self.assertTrue(s.command("STATUS").startswith("OK IDLE"))
            self.assertEqual([f[:3] for f in s.frames if f[0] == "K"], [("K", 8, 25), ("K", 0, 0)])
            self.assertFalse(any(f[0] == "A" for f in s.frames), "local automation must not move pointer")
            out, err = s.finish()
            self.assertIn(f"CPP_FILE_TRANSFER id={intent} direction=IN change=12", err)
            self.assertNotIn("CPP_WIREDKVM_ERROR", err)

    def test_cancel_while_key_waits_drops_later_keys_and_preserves_heartbeat(self):
        with tempfile.TemporaryDirectory(prefix="wk-file-") as directory, FileSession(
                directory, [(0.05, "F PASTE IN 12"), (.2, "F CANCEL")], no_key_ack=True) as s:
            intent = s.intent()
            self.assertEqual(s.command(f"BEGIN {intent}"), f"OK ACTIVE {intent}")
            self.assertEqual(s.command(f"KEY {intent} 8 25"), "ERR CANCELLED USER_INPUT")
            self.assertEqual(s.command(f"KEY {intent} 8 4"), "ERR STALE_INTENT")
            self.assertIsNone(s.proc.poll())
            self.assertTrue(wait_for(lambda: len([f for f in s.frames if f[0] == "P"]) >= 4))
            keys = [f for f in s.frames if f[0] == "K"]
            self.assertEqual(len(keys), 1)
            self.assertTrue(wait_for(lambda: any(f[0] == "R" and f[3] > keys[0][3] for f in s.frames)))

    def test_owner_pid_cannot_be_replaced_by_other_same_user_process(self):
        with tempfile.TemporaryDirectory(prefix="wk-file-") as directory, FileSession(
                directory, [(0.04, "F PASTE OUT 6")]) as s:
            intent = s.intent()
            s.command(f"BEGIN {intent}")
            code = "import socket,sys;s=socket.socket(socket.AF_UNIX);s.connect(sys.argv[1]);s.sendall((sys.argv[2]+'\\n').encode());print(s.recv(1024).decode().strip())"
            result = subprocess.run([sys.executable, "-c", code, str(s.socket), f"KEY {intent} 8 25"],
                                    capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.strip(), "ERR WRONG_OWNER")
            self.assertEqual(s.command(f"KEEP {intent}"), f"OK ACTIVE {intent}")
            self.assertEqual(s.command(f"CANCEL {intent}"), f"OK CANCEL {intent}")
            self.assertFalse(any(f[0] == "K" for f in s.frames))

    def test_owner_exit_invalidates_lease_without_waiting_for_lease_timeout(self):
        with tempfile.TemporaryDirectory(prefix="wk-file-") as directory, FileSession(
                directory, [(0.04, "F PASTE OUT 6")]) as s:
            intent = s.intent()
            code = "import socket,sys;s=socket.socket(socket.AF_UNIX);s.connect(sys.argv[1]);s.sendall((sys.argv[2]+'\\n').encode());print(s.recv(1024).decode().strip())"
            result = subprocess.run([sys.executable, "-c", code, str(s.socket), f"BEGIN {intent}"],
                                    capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.strip(), f"OK ACTIVE {intent}")
            self.assertTrue(wait_for(lambda: "OWNER_EXITED" in s.command("STATUS"), seconds=1))
            self.assertEqual(s.command(f"KEY {intent} 8 25"), "ERR STALE_INTENT")
            self.assertIsNone(s.proc.poll())

    def test_new_intent_invalidates_old_intent_even_for_original_owner(self):
        with tempfile.TemporaryDirectory(prefix="wk-file-") as directory, FileSession(
                directory, [(0.04, "F PASTE OUT 6"), (.2, "F PASTE IN 7")]) as s:
            old = s.intent()
            self.assertEqual(s.command(f"BEGIN {old}"), f"OK ACTIVE {old}")
            self.assertTrue(wait_for(lambda: s.command("STATUS").startswith("OK PENDING")))
            new = int(s.command("STATUS").split()[2])
            self.assertGreater(new, old)
            self.assertEqual(s.command(f"KEY {old} 8 25"), "ERR STALE_INTENT")
            self.assertEqual(s.command(f"CANCEL {old}"), "ERR STALE_INTENT")
            self.assertEqual(s.command(f"BEGIN {new}"), f"OK ACTIVE {new}")
            self.assertEqual(s.command(f"END {new}"), f"OK END {new}")

    def test_real_remote_input_cancels_and_pointer_edge_return_still_works(self):
        events = [(0, "D 1000 800"), (0, "E 5000 0"), (.04, "F PASTE OUT 6"),
                  (.2, "M 100 0"), (.05, "M -100 0"), (.05, "M -60 0")]
        with tempfile.TemporaryDirectory(prefix="wk-file-") as directory, FileSession(directory, events) as s:
            intent = s.intent()
            s.command(f"BEGIN {intent}")
            self.assertTrue(wait_for(lambda: s.command("STATUS").startswith("OK IDLE")))
            self.assertEqual(s.command(f"KEY {intent} 8 25"), "ERR STALE_INTENT")
            self.assertTrue(wait_for(lambda: (s.work / "commands").exists()))
            self.assertTrue(wait_for(lambda: "RETURN " in (s.work / "commands").read_text()))
            self.assertIsNone(s.proc.poll())

    def test_disconnected_ipc_client_cancels_unacknowledged_key(self):
        with tempfile.TemporaryDirectory(prefix="wk-file-") as directory, FileSession(
                directory, [(0.04, "F PASTE IN 6")], no_key_ack=True) as s:
            intent = s.intent()
            s.command(f"BEGIN {intent}")
            channel = socket.socket(socket.AF_UNIX)
            channel.connect(str(s.socket))
            channel.sendall(f"KEY {intent} 8 25\n".encode())
            self.assertTrue(wait_for(lambda: any(f[0] == "K" for f in s.frames)))
            channel.close()
            self.assertTrue(wait_for(lambda: s.command("STATUS").startswith("OK IDLE")))
            time.sleep(.3)
            self.assertIsNone(s.proc.poll())

    def test_pending_intent_expires_without_stopping_keyboard_controller(self):
        with tempfile.TemporaryDirectory(prefix="wk-file-") as directory, FileSession(
                directory, [(0.04, "F PASTE IN 6")]) as s:
            intent = s.intent()
            self.assertTrue(wait_for(lambda: s.command("STATUS").startswith("OK IDLE"), seconds=11))
            self.assertIn("LEASE_EXPIRED", s.command("STATUS"))
            self.assertEqual(s.command(f"BEGIN {intent}"), "ERR STALE_INTENT")
            self.assertIsNone(s.proc.poll())

    def test_existing_regular_socket_path_is_never_unlinked(self):
        with tempfile.TemporaryDirectory(prefix="wk-file-") as directory, FileSession(directory, stale_file=True) as s:
            _, err = s.proc.communicate(timeout=3)
            self.assertIn("FILE_SOCKET_EXISTS", err)
            self.assertEqual(s.socket.read_text(), "do not delete")
            self.assertFalse((s.work / "started").exists())

    def test_status2_reports_observations_without_granting_media(self):
        with tempfile.TemporaryDirectory(prefix="wk-file-") as directory, FileSession(directory) as s:
            status = s.command("STATUS2", s.exchange).split()
            self.assertEqual(status, ["OK", "AVAILABLE", "0", "0", "0", "0", "0", "0", "0", "-"])
            self.assertEqual(s.command("STATUS", s.exchange), "OK AVAILABLE 0")

    def test_status2_counts_completed_io_per_generation_not_finder_success(self):
        with tempfile.TemporaryDirectory(prefix="wk-file-") as directory:
            (Path(directory) / "exchange.img").write_bytes(b"a" * 1024)
            with Session(directory) as s:
                generation = s.publish()
                s.send(f"X1,W,{generation},11,0,1,616263")
                self.assertTrue(wait_for(lambda: s.reply("A", 11)))
                s.send(f"X1,R,{generation},12,0,0,4")
                self.assertTrue(wait_for(lambda: s.reply("D", 12)))
                values = s.command("STATUS2").split()
                self.assertEqual(values, ["OK", "REMOTE", "1024", str(generation), "1", "4", "3", "0", "1", "-"])
                self.assertEqual(s.command("LOCAL"), "ERR NEED_EJECT")
                s.send(f"X1,S,{generation},EJECTED")
                self.assertTrue(wait_for(lambda: s.command("STATUS").startswith("OK EJECTED")))
                self.assertEqual(s.command("LOCAL"), "OK LOCAL 1024")
                next_generation = s.publish()
                values = s.command("STATUS2").split()
                self.assertEqual(values[3:9], [str(next_generation), "0", "0", "0", "0", "1"])


if __name__ == "__main__":
    unittest.main()
