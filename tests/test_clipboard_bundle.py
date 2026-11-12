"""Compile the real bundle adapter against isolated, unique macOS pasteboards.

No general clipboard, USB, input tap, service, or target computer is accessed.
The two prefix extracts are actual production wire/diagnostic declarations;
they avoid linking the production app entrypoint or opening any transport.
"""
from __future__ import annotations
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin", "macOS pasteboard adapter")
class ClipboardBundleTests(unittest.TestCase):
    def test_standard_bundle(self):
        paths = [ROOT / "host/clipboard" / (name + ".swift") for name in
                 ("WKClipboardProtocol", "WKClipboardContent", "WKClipboardBundle", "WKStreamFiles", "WiredKVMCompanion")]
        paths.append(ROOT / "tests/clipboard_bundle_selftest.swift")
        before = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
        with tempfile.TemporaryDirectory(prefix="wk-clipboard-bundle-") as directory:
            out = Path(directory)
            stream = paths[3].read_text().split("private func streamErrorCode(", 1)[0]
            metadata = paths[4].read_text().split("// Main-thread coordinator.", 1)[0]
            support = out / "support.swift"
            support.write_text(stream + "\n" + metadata)
            binary = out / "clipboard-bundle-selftest"
            command = ["/usr/bin/swiftc", "-O", "-parse-as-library", "-module-cache-path", str(out / "swift-cache"),
                       "-framework", "AppKit", "-framework", "IOKit", str(paths[0]), str(paths[1]),
                       str(paths[2]), str(support), str(paths[5]), "-o", str(binary)]
            build = subprocess.run(command, capture_output=True, text=True, timeout=180)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([binary], capture_output=True, text=True, timeout=90)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("CLIPBOARD_BUNDLE_SELFTEST PASS", run.stdout)
            for marker in ("standard-text-html-rtf-item-order-private-filter", "same-item-text-image-single-PNG-TIFF-normalization",
                           "separate-wire-and-decoded-image-budgets",
                           "file-reference-no-source-path-no-file-read-order", "revision-capture-apply-local-wins-cancellation",
                           "limits-malformed-integrity-unsupported"):
                self.assertIn(marker + " PASS", run.stdout)
        after = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
        self.assertEqual(before, after, "sources changed during compile/test")


if __name__ == "__main__":
    unittest.main()
