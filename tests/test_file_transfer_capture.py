"""Capture-side file intent and cancellation tests, with no live EventTap.

Builds a private binary in a temporary directory. Self-test paths serialize
synthetic events only; no key is posted and no general clipboard object is read.
"""
from __future__ import annotations

import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin", "macOS capture only")
class FileCaptureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="wk-file-capture-tests-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binary = Path(cls.temp.name) / "capture"
        result = subprocess.run(
            ["/usr/bin/swiftc", "-O", "-target",
             f"{platform.machine()}-apple-macosx13.0", "-module-cache-path",
             str(Path(cls.temp.name) / "modules"), "-framework", "ApplicationServices",
             "-framework", "Cocoa", str(ROOT / "host/macos_capture.swift"),
             "-o", str(cls.binary)],
            capture_output=True, text=True, timeout=90)
        if result.returncode:
            raise AssertionError(result.stderr)

    def run_capture(self, flag, *, enabled=True, absolute=True, iphone=False):
        env = dict(os.environ)
        for key in ("WK_FILE_TRANSFER", "WK_TARGET_ABSOLUTE", "WK_TARGET_IPHONE",
                    "WK_CLIPBOARD_SYNC", "WK_INVERT_SCROLL"):
            env.pop(key, None)
        if enabled:
            env["WK_FILE_TRANSFER"] = "1"
        if absolute:
            env["WK_TARGET_ABSOLUTE"] = "1"
        if iphone:
            env["WK_TARGET_IPHONE"] = "1"
        run = subprocess.run([str(self.binary), flag], env=env,
                             capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        return run.stdout.splitlines()

    def test_file_routing_requires_explicit_absolute_mac_opt_in(self):
        for enabled, absolute, iphone, expected in (
                (False, True, False, False),
                (True, True, False, True),
                (True, False, False, False),
                (True, True, True, False)):
            with self.subTest(enabled=enabled, absolute=absolute, iphone=iphone):
                output = self.run_capture("--self-test-file-intents", enabled=enabled,
                                          absolute=absolute, iphone=iphone)
                self.assertEqual(output, [
                    "FILE_INTENTS_PASS enabled=" + str(expected).lower() +
                    " expiry=true revision=true cut_passthrough=true"])

    def test_pairing_local_cancel_and_synthetic_bypass(self):
        self.assertEqual(self.run_capture("--self-test-file-event-routing"), [
            "F CANCEL", "F CANCEL",
            "FILE_EVENT_ROUTING_PASS release_pair=true synthetic_bypass=true local_cancel=true",
        ])

    def test_retry_cannot_overtake_previous_native_idle_acknowledgement(self):
        self.assertEqual(self.run_capture("--self-test-file-idle-handshake"), [
            "F CANCEL",
            "FILE_IDLE_HANDSHAKE_PASS retry_waits=true stale_busy_not_resurrected=true",
        ])

    def test_single_regular_file_rejects_directory_link_missing_and_multiple(self):
        self.assertEqual(self.run_capture("--self-test-file-pasteboard"), [
            "FILE_PASTEBOARD_PASS single_regular=true multi_directory_link_text_rejected=true",
        ])

    def test_existing_keyboard_pointer_and_scroll_serialization_unchanged(self):
        for flag in ("--self-test-key-events", "--self-test-mouse-drag",
                     "--self-test-scroll", "--self-test-entry-metadata",
                     "--self-test-screen-side", "--self-test-return-shortcut",
                     "--self-test-clipboard-shortcut"):
            with self.subTest(flag=flag):
                self.assertEqual(self.run_capture(flag, enabled=False),
                                 self.run_capture(flag, enabled=True))


if __name__ == "__main__":
    unittest.main()
