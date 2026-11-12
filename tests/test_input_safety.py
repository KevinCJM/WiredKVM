"""Capture ownership regressions. No EventTap, real input, USB or clipboard writes."""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ["host/macos_capture.swift", "host/WKPointingSource.swift", "host/WKRawTouch.swift",
           "host/clipboard/WKScrollRelay.swift", "host/clipboard/WKGestureRelay.swift"]


@unittest.skipUnless(sys.platform == "darwin", "macOS capture only")
class InputSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        existing = os.environ.get("WK_SAFETY_CAPTURE_BUILD")
        if existing:
            work = Path(existing).resolve()
            manifest = json.loads((work / "manifest.json").read_text())
            assert manifest["sources"] == {
                name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in SOURCES}
            cls.binary = work / "macos-capture"
            assert manifest["sha256"] == hashlib.sha256(cls.binary.read_bytes()).hexdigest()
        else:
            # Retain owned fixtures; never recursively clean project files.
            work = Path(tempfile.mkdtemp(prefix="wk-input-safety-", dir="/private/tmp"))
            main = work / "main.swift"
            main.write_bytes((ROOT / SOURCES[0]).read_bytes())
            cls.binary = work / "macos-capture"
            cmd = ["/usr/bin/swiftc", "-O", "-D", "WK_PIXEL_SCROLL", "-D", "WK_RAW_TOUCH",
                   "-target", platform.machine() + "-apple-macosx13.0",
                   "-module-cache-path", str(work / "modules"), "-framework", "ApplicationServices",
                   "-framework", "Cocoa", "-framework", "IOKit", "-lcompression", str(main),
                   *[str(ROOT / name) for name in SOURCES[1:]], "-o", str(cls.binary)]
            built = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            (work / "compile.log").write_text(built.stdout + built.stderr)
            if built.returncode:
                raise AssertionError(built.stderr)
        print("INPUT_SAFETY_FIXTURES_RETAINED", work)

    def run_case(self, flag):
        env = dict(os.environ, WK_TARGET_ABSOLUTE="1", WK_WIRED_INPUT="1", WK_WIRED_CLIPBOARD="1")
        env.pop("WK_RAW_TOUCH_HELPER", None)
        result = subprocess.run([str(self.binary), flag], env=env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def test_secure_input_sleep_and_session_loss_release_all_input_once(self):
        rows = self.run_case("--self-test-input-safety")
        self.assertEqual([r for r in rows if r == "R 0 0"], ["R 0 0"])
        self.assertFalse(any(r.startswith(("M ", "T ", "W ", "H D ")) for r in rows))
        self.assertTrue(any(r.startswith("CAPTURE_INPUT_SAFETY_PASS") for r in rows))

    def test_keyboard_drag_and_scroll_serializers_are_preserved(self):
        for flag in ["--self-test-key-events", "--self-test-mouse-drag", "--self-test-scroll"]:
            with self.subTest(flag=flag):
                self.assertTrue(self.run_case(flag))

    def test_same_machine_clipboard_shortcuts_keep_their_normal_route(self):
        for flag in ["--self-test-wired-clipboard-intents", "--self-test-clipboard-event-routing"]:
            with self.subTest(flag=flag):
                self.assertTrue(self.run_case(flag))


if __name__ == "__main__":
    unittest.main()
