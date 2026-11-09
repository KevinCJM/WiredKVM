"""Check an already-built portable app, without launch services or device access.

CLI branches exercised below must return before NSApplication/USB/pasteboard.
No application is opened and the current WiredKVM processes are not touched.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
BUILD_OUTPUT = os.environ.get("WK_PORTABLE_TEST_BUILD")


class PortableCompanionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not BUILD_OUTPUT:
            raise ValueError("Pass --build PATH or set WK_PORTABLE_TEST_BUILD")
        cls.output = Path(BUILD_OUTPUT).resolve()
        cls.manifest = json.loads((cls.output / "manifest.json").read_text())
        cls.binary = Path(cls.manifest["binary"])

    def test_exact_build_inputs_and_binary(self):
        self.assertEqual(hashlib.sha256(self.binary.read_bytes()).hexdigest(), self.manifest["sha256"])
        for name, digest in self.manifest["sources"].items():
            self.assertEqual(hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), digest, name)

    def test_compiled_binary_has_no_installer_or_login_registration(self):
        symbols = subprocess.check_output(["/usr/bin/nm", str(self.binary)], text=True)
        for name in ["WKCompanionInstall", "WKLoginItem", "WKFirstRunWindow", "SMAppService"]:
            self.assertNotIn(name, symbols)
        self.assertFalse(any("Install" in s or "SelfTest" in s for s in self.manifest["sources"]))
        self.assertIn("host/clipboard/WKTransferTree.swift", self.manifest["sources"])
        self.assertIn("native/transfer-tree/src/lib.rs", self.manifest["sources"])
        self.assertIn("wk_tree_create", symbols)

    def test_portable_check_returns_without_runtime(self):
        result = subprocess.run([str(self.binary), "--portable-check"], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), dict(mode="portable", installer=False, loginItem=False,
                                                       persistentPreferences=False, automaticSetupEject=False,
                                                       collections=True, binaryBulk=True, legacyInputRelay=False))
        self.assertEqual(result.stderr, "")

    def test_installed_first_run_and_implicit_legacy_host_rejected(self):
        for arguments in [["--first-run"], ["--self-test"], ["--role", "host", "--socket", "/private/tmp/not-opened.sock"]]:
            result = subprocess.run([str(self.binary), *arguments], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertIn("usage:", result.stderr)

    def test_app_identity_and_bundle_not_an_installer(self):
        app = self.binary.parents[2]
        plist = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        self.assertEqual(plist["CFBundleIdentifier"], "com.wiredkvm.portable")
        self.assertTrue(plist["LSUIElement"])
        self.assertFalse((app / "Contents/Resources").exists())
        self.assertFalse((app / "Contents/Library/LoginItems").exists())
        result = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R",
                                 '=identifier "com.wiredkvm.portable"', str(app)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--build", default=BUILD_OUTPUT)
    args, remaining = parser.parse_known_args()
    BUILD_OUTPUT = args.build
    unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)
