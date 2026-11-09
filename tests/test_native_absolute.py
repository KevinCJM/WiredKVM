"""Native absolute HID, ordering and recovery through fake UART/capture pipes.

These tests never open a serial device, EventTap, physical mouse or keyboard.
"""
from __future__ import annotations

from collections import Counter
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

ROOT = Path(__file__).resolve().parents[1]
CLIENT = Path(os.environ.get("WK_NATIVE_TEST_CLIENT", ROOT / "build/wiredkvm-native"))
CAPTURE = ROOT / "tests/fake_desktop_capture.py"


def wait_until(predicate, timeout=2.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(0.005)
    return bool(predicate())


class FakeSession:
    def __init__(self, events=(), *, absolute=True, side="right", policy=None,
                 extra=(), source="macos"):
        self.events = events
        self.absolute = absolute
        self.side = side
        self.policy = policy
        self.extra = extra
        self.source = source
        self.frames = []
        self.counts = Counter()
        self.stop = threading.Event()
        self.output = ("", "")

    def __enter__(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wk-native-absolute-")
        self.work = Path(self.temp.name)
        self.server = socket.socket()
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(1)
        self.server.settimeout(0.1)
        self.worker = threading.Thread(target=self.peer, daemon=True)
        self.worker.start()
        env = dict(os.environ, WK_TEST_EVENTS=json.dumps(self.events),
                   WK_TEST_ABSOLUTE="1" if self.absolute else "0",
                   WK_TEST_INVERT_SCROLL="1" if "--invert-scroll" in self.extra else "0",
                   WK_INVERT_SCROLL="1",
                   WK_TEST_STARTED=str(self.work / "started"),
                   WK_TEST_COMMANDS=str(self.work / "commands"))
        args = [str(CLIENT), "--transport", f"tcp:127.0.0.1:{self.server.getsockname()[1]}",
                "--source", self.source, "--target", "desktop", "--position", self.side,
                "--capture", str(CAPTURE)]
        if self.absolute:
            args.append("--absolute-mouse")
        self.proc = subprocess.Popen(args + list(self.extra), cwd=ROOT, env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        return self

    def peer(self):
        try:
            while not self.stop.is_set():
                try:
                    channel, _ = self.server.accept()
                    break
                except socket.timeout:
                    continue
            else:
                return
            with channel:
                channel.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                with channel.makefile("rb") as stream:
                    for wire in stream:
                        fields = wire.decode("ascii").strip().split(",")
                        if len(fields) != 6 or fields[0] != "WK1":
                            return
                        _, seq, kind, a, b, _ = fields
                        frame = {"kind": kind, "a": int(a), "b": int(b), "at": time.monotonic()}
                        self.frames.append(frame)
                        self.counts[kind] += 1
                        reply, delay = self.policy(self, frame) if self.policy else ("ACK", 0)
                        if reply is None:
                            continue
                        time.sleep(delay)
                        frame["reply"] = reply
                        frame["ack_at"] = time.monotonic()
                        message = f"{reply},{seq}\n" if reply in ("ACK", "WAIT") else reply + "\n"
                        channel.sendall(message.encode("ascii"))
        except (OSError, ValueError):
            pass

    def commands(self):
        path = self.work / "commands"
        if not path.exists():
            return []
        result = []
        for line in path.read_text(encoding="utf-8").splitlines():
            try:
                result.append(json.loads(line))
            except json.JSONDecodeError:
                pass
        return result

    def returns(self):
        return [(at, text) for at, text in self.commands() if text.startswith("RETURN")]

    def finish(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
        self.output = self.proc.communicate(timeout=3)
        return self.output

    def __exit__(self, *_):
        try:
            self.finish()
        finally:
            self.stop.set()
            self.server.close()
            self.worker.join(timeout=2)
            self.temp.cleanup()


class AbsoluteMouseTests(unittest.TestCase):
    def test_scroll_option_reaches_capture_and_default_clears_inherited_value(self):
        for extra in ((), ("--invert-scroll",)):
            with self.subTest(extra=extra), FakeSession(extra=extra) as s:
                started = wait_until(lambda: (s.work / "started").exists())
                self.assertTrue(started, s.finish() if not started else "")

    def test_old_firmware_rejected_before_capture_for_live_and_check(self):
        def old_firmware(_, frame):
            return ("ERR,unsupported", 0) if frame["kind"] == "Q" else ("ACK", 0)
        for source in ("macos", "check-hid"):
            with self.subTest(source=source), FakeSession(source=source, policy=old_firmware) as s:
                out, err = s.proc.communicate(timeout=2)
                self.assertNotEqual(s.proc.returncode, 0)
                self.assertIn("ABSOLUTE_MOUSE_UNSUPPORTED", err)
                self.assertFalse((s.work / "started").exists())
                self.assertNotIn("CPP_CAPTURE_STARTED", out)
                self.assertEqual([f["kind"] for f in s.frames], ["P", "Q"])

    def test_absolute_check_is_non_injecting_and_queries_capability(self):
        with FakeSession(source="check-hid") as s:
            out, err = s.proc.communicate(timeout=2)
            self.assertEqual(s.proc.returncode, 0, err)
            self.assertIn("CPP_USB_HID_READY", out)
            self.assertEqual([f["kind"] for f in s.frames], ["P", "Q", "S"])
            self.assertFalse((s.work / "started").exists())

    def test_entry_coordinates_and_integrated_motion_for_both_sides(self):
        for side, inward in (("right", 1), ("left", -1)):
            events = [(0, "D 1000 800"), (0, "E 2500 0"), (0.03, f"M {100 * inward} 10"),
                      (0.03, f"M {20 * inward} -5"), (0.03, "B 1 0"),
                      (0.03, f"M {10 * inward} 3"), (0.03, "B 0 0")]
            with self.subTest(side=side), FakeSession(events, side=side) as s:
                self.assertTrue(wait_until(lambda: s.counts["B"] == 2), s.frames)
                absolute = [f for f in s.frames if f["kind"] == "A"]
                self.assertEqual(len(absolute), 4)
                logical_x = [0, 100, 120, 130] if side == "right" else [999, 899, 879, 869]
                self.assertEqual([f["a"] for f in absolute], [(x * 32767 + 499) // 999 for x in logical_x])
                self.assertEqual([f["b"] for f in absolute], [(y * 32767 + 399) // 799 for y in (200, 210, 205, 208)])
                self.assertNotIn("M", [f["kind"] for f in s.frames])
                self.assertNotIn("D", [f["kind"] for f in s.frames])
                self.assertFalse(s.returns())

    def test_automatic_control_plane_dimensions_are_validated_before_entry(self):
        for dimensions in ("D 319 1080", "D 1920 16385", "D 1000 800 trailing"):
            with self.subTest(dimensions=dimensions), FakeSession([(0, dimensions), (0, "E 5000 0")]) as s:
                _, err = s.proc.communicate(timeout=2)
                self.assertNotEqual(s.proc.returncode, 0, err)
                self.assertEqual(s.counts["A"], 0)

    def test_automatic_dimensions_change_between_handoffs_without_target_geometry(self):
        events = []
        for width, height in ((320, 320), (2560, 1440), (16384, 16384)):
            events += [(0.02, "R 0 0"), (0.02, f"D {width} {height}"),
                       (0.02, "E 10000 0"), (0.02, "M 127 -127")]
        with FakeSession(events) as s:
            self.assertTrue(wait_until(lambda: s.counts["A"] == 6))
            positions = [f for f in s.frames if f["kind"] == "A"]
            for index, (width, height) in enumerate(((320, 320), (2560, 1440), (16384, 16384))):
                entry, motion = positions[2 * index:2 * index + 2]
                self.assertEqual((entry["a"], entry["b"]), (0, 32767))
                self.assertEqual(motion["a"], (127 * 32767 + (width - 1) // 2) // (width - 1))
                self.assertEqual(motion["b"], ((height - 128) * 32767 + (height - 1) // 2) // (height - 1))
            self.assertNotIn("D", [f["kind"] for f in s.frames])

    def test_control_plane_cannot_change_during_active_handoff(self):
        with FakeSession([(0, "D 1000 800"), (0, "E 5000 0"), (0.03, "D 2000 1200")]) as s:
            _, err = s.proc.communicate(timeout=2)
            self.assertNotEqual(s.proc.returncode, 0)
            self.assertIn("Cannot change desktop control plane during a handoff", err)

    def test_absolute_queue_keeps_latest_position_without_crossing_click(self):
        def slow_first_position(session, frame):
            return "ACK", 0.09 if frame["kind"] == "A" and session.counts["A"] == 1 else 0
        events = [(0, "E 5000 0"), (0.02, "M 60 0"), (0, "M 70 0"),
                  (0, "M 70 0"), (0, "B 1 0"), (0, "M 10 0"),
                  (0, "M 20 0"), (0, "B 0 0")]
        with FakeSession(events, policy=slow_first_position,
                         extra=("--desktop-width", "1000", "--desktop-height", "800")) as s:
            self.assertTrue(wait_until(lambda: s.counts["B"] == 2))
            frames = [f for f in s.frames if f["kind"] in ("A", "B")]
            self.assertEqual([f["kind"] for f in frames], ["A", "A", "B", "A", "B"])
            self.assertEqual([f["a"] for f in frames if f["kind"] == "A"],
                             [0, (200 * 32767 + 499) // 999, (230 * 32767 + 499) // 999])

    def test_return_waits_for_boundary_ack_and_cancels_later_keys(self):
        for side, inward in (("right", 1), ("left", -1)):
            events = [(0, "E 7500 0"), (0.03, f"M {100 * inward} 0"),
                      (0.03, f"M {-127 * inward} 0"), (0.03, f"M {-50 * inward} 0"),
                      (0, "B 1 0"), (0, "T 4 1"), (0, "T 4 0")]
            boundary = 0 if side == "right" else 32767
            def slow_boundary(session, frame):
                wait = frame["kind"] == "A" and frame["a"] == boundary and session.counts["A"] > 2
                return "ACK", 0.035 if wait else 0
            with self.subTest(side=side), FakeSession(events, side=side, policy=slow_boundary) as s:
                self.assertTrue(wait_until(lambda: any(text.startswith("RETURN ") for _, text in s.returns())))
                returned_at, command = next((at, text) for at, text in s.returns() if text.startswith("RETURN "))
                self.assertLessEqual(abs(int(command.split()[1]) - 7500), 5)
                boundary_report = [f for f in s.frames if f["kind"] == "A"][-1]
                self.assertEqual(boundary_report["a"], boundary)
                self.assertGreaterEqual(returned_at, boundary_report["ack_at"])
                self.assertFalse(any(f["kind"] in ("B", "T") for f in s.frames))
                self.assertTrue(wait_until(lambda: s.counts["R"] >= 2))

    def test_drag_and_disabled_auto_return_do_not_switch(self):
        for mode in ("drag", "disabled"):
            events = [(0, "E 5000 0")]
            if mode == "drag":
                events += [(0.02, "B 1 0")]
            events += [(0.02, "M -127 0"), (0.02, "M -127 0")]
            with self.subTest(mode=mode), FakeSession(events,
                    extra=("--no-auto-return",) if mode == "disabled" else ()) as s:
                self.assertTrue(wait_until(lambda: s.counts["A"] >= 2))
                time.sleep(0.12)
                self.assertIsNone(s.proc.poll())
                self.assertFalse(s.returns())

    def test_invalid_desktop_dimensions_and_iphone_absolute_fail_before_transport(self):
        for extra in (("--desktop-width", "319"), ("--desktop-height", "16385"),
                      ("--absolute-mouse", "--target", "iphone")):
            result = subprocess.run([str(CLIENT), "--transport", "/dev/not-a-real-port", *extra],
                                    capture_output=True, text=True, timeout=2)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("Cannot open USB COM", result.stderr)


class NativeLatencyRecoveryTests(unittest.TestCase):
    def test_relative_burst_has_no_24ms_cap_and_key_order_is_preserved(self):
        keys = ["B 1 0", "B 0 0", "C 8 0", "T 4 1", "T 4 0", "C 0 0"]
        events = [(0, "M 127 0")] * 64 + [(0, value) for value in keys]
        with FakeSession(events, absolute=False, policy=lambda *_: ("ACK", 0.001)) as s:
            self.assertTrue(wait_until(lambda: s.counts["C"] == 2))
            motion = [f for f in s.frames if f["kind"] == "M"]
            self.assertEqual(len(motion), 64)
            elapsed = motion[-1]["at"] - motion[0]["at"]
            self.assertLess(elapsed, 0.6, f"64 reports took {elapsed:.3f}s")
            actual = [f'{f["kind"]} {f["a"]} {f["b"]}' for f in s.frames if f["kind"] in "BCT"]
            self.assertEqual(actual, keys)
            self.assertNotIn("Q", [f["kind"] for f in s.frames])
            print(f"NATIVE_SYNTHETIC_MOTION_64_MS={elapsed * 1000:.1f}")

    def test_wait_retries_button_before_release_without_50ms_delay(self):
        def reject_first_button(session, frame):
            return ("WAIT", 0) if frame["kind"] == "B" and session.counts["B"] == 1 else ("ACK", 0)
        with FakeSession([(0, "B 1 0"), (0, "B 0 0")], absolute=False, policy=reject_first_button) as s:
            self.assertTrue(wait_until(lambda: s.counts["B"] == 3))
            buttons = [f for f in s.frames if f["kind"] == "B"]
            self.assertEqual([f["a"] for f in buttons], [1, 1, 0])
            self.assertLess(buttons[1]["at"] - buttons[0]["at"], 0.04)

    def test_first_unmounted_status_returns_within_250ms(self):
        def unplug(session, frame):
            return ("WAIT", 0) if frame["kind"] == "S" and session.counts["S"] > 1 else ("ACK", 0)
        with FakeSession(absolute=False, policy=unplug) as s:
            self.assertTrue(wait_until(s.returns))
            startup = next(f for f in s.frames if f["kind"] == "S")
            elapsed = s.returns()[0][0] - startup["ack_at"]
            self.assertLess(elapsed, 0.25)
            self.assertEqual(s.counts["S"], 2)
            s.proc.wait(timeout=2)
            self.assertNotEqual(s.proc.returncode, 0)
            print(f"NATIVE_SYNTHETIC_USB_UNPLUG_RETURN_MS={elapsed * 1000:.1f}")

    def test_silent_serial_returns_within_300ms_without_stale_link_renewal(self):
        def silence(session, frame):
            after_preflight = session.counts["S"] >= 1 and frame["kind"] != "S"
            silent_status = frame["kind"] == "S" and session.counts["S"] > 1
            return (None, 0) if after_preflight or silent_status else ("ACK", 0)
        with FakeSession(absolute=False, policy=silence) as s:
            self.assertTrue(wait_until(s.returns))
            startup = next(f for f in s.frames if f["kind"] == "S")
            elapsed = s.returns()[0][0] - startup["ack_at"]
            self.assertLess(elapsed, 0.30)
            self.assertEqual(sum(text == "LINK" for _, text in s.commands()), 1)
            print(f"NATIVE_SYNTHETIC_SERIAL_SILENCE_RETURN_MS={elapsed * 1000:.1f}")


if __name__ == "__main__":
    unittest.main()
