#!/usr/bin/env python3
"""Offline guards only: no USB, CoreGraphics, processes, or cursor operations."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import tempfile
import time
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("absolute_probe", HERE / "probe_absolute_book.py")
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)


def fixture():
    source = (HERE / "candidate-stage1-pointer-nopref-20261105/generated/descriptors.c").read_text()
    desc = bytes(int(x, 0) for x in re.search(r"absolute\[\] = \{(.*?)\};", source, re.S).group(1).split(",") if x.strip())
    driver = {"IOUserClass": "AppleUserHIDEventDriver", "PrimaryUsagePage": 1, "PrimaryUsage": 1,
              "AbsolutePointer": {"Elements": [{"UsagePage": 1, "Usage": usage, "ReportID": 3,
                                                  "Min": 0, "Max": 32767, "ReportSize": 16,
                                                  "IsRelative": False} for usage in (48, 49)]}}
    def device(vid, pid, version, location, children, serial=p.SERIAL):
        return {"IOObjectClass": "IOUSBHostDevice", "idVendor": vid, "idProduct": pid,
                "bcdDevice": version, "locationID": location, "IORegistryEntryID": location + 1,
                "USB Serial Number": serial, "IORegistryEntryChildren": children}
    def interface(children):
        return {"IOObjectClass": "IOUSBHostInterface", "bInterfaceNumber": 1,
                "IORegistryEntryChildren": children}
    return [device(0x1a86, 0x4070, 0x0200, 1, [interface([{"IOCalloutDevice": "/dev/cu.usbmodemTEST"}])]),
            device(0x05ac, 0x0265, 0x026a, 2, [interface([{"ReportDescriptor": desc}, driver])]),
            device(0x1a86, 0x8010, 0x0222, 3, [], p.PROBE_SERIAL)]


class Guards(unittest.TestCase):
    def test_crc_and_only_absolute_frames(self):
        self.assertEqual(p.crc8(b"123456789"), 0xF4)
        for i, (x, y) in enumerate(p.POINTS):
            b = p.frame(i, round(x * 32767), round(y * 32767))
            body, crc = b.rstrip().rsplit(b",", 1)
            self.assertEqual(body.split(b",")[2], b"A")
            self.assertEqual(int(crc, 16), p.crc8(body))
        with self.assertRaises(RuntimeError): p.frame(0, -1, 0)
        with self.assertRaises(RuntimeError): p.frame(0, 0, 32768)

    def test_strict_pair_and_driver(self):
        d = fixture(); self.assertEqual(p.select_pair(d)["target_bcd"], 0x026a)
        driver = d[1]["IORegistryEntryChildren"][0]["IORegistryEntryChildren"][1]
        driver["MultiAxisPointer"] = {}
        with self.assertRaisesRegex(RuntimeError, "MultiAxisPointer"): p.select_pair(d)
        del driver["MultiAxisPointer"]; del driver["AbsolutePointer"]
        with self.assertRaisesRegex(RuntimeError, "AbsolutePointer"): p.select_pair(d)

    def test_current_multiaxis_cannot_be_accepted(self):
        import json
        d = fixture()
        observed = json.loads((HERE.parents[1] / "results/mt2-flash-pointer-20261105/book-pointer-parser-properties.json").read_text())
        d[1]["IORegistryEntryChildren"][0]["IORegistryEntryChildren"][1] = observed[0]["properties"]
        with self.assertRaisesRegex(RuntimeError, "MultiAxisPointer"): p.select_pair(d)

    def test_identity_and_format_fail_closed(self):
        mutations = [lambda d: d.pop(), lambda d: d.append(copy.deepcopy(d[0])),
                     lambda d: d[1].update(bcdDevice=0x0269),
                     lambda d: d[2].update({"USB Serial Number": "another-board"}),
                     lambda d: d[1]["IORegistryEntryChildren"][0]["IORegistryEntryChildren"][0].update(ReportDescriptor=b"bad"),
                     lambda d: d[1]["IORegistryEntryChildren"][0]["IORegistryEntryChildren"][1]["AbsolutePointer"]["Elements"][0].update(IsRelative=True)]
        for mutation in mutations:
            d = fixture(); mutation(d)
            with self.assertRaises(RuntimeError): p.select_pair(d)

    def test_dry_run_has_no_device_or_framework_access(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = str(Path(tmp) / "plan.json")
            with patch.object(p.sys, "argv", ["probe", "--out", output]), patch.object(p, "execute", side_effect=AssertionError("device access")), patch.object(p, "live_pair", side_effect=AssertionError("registry")), patch.object(p, "Cursor", side_effect=AssertionError("CoreGraphics")):
                self.assertEqual(p.main(), 0)
            with patch.object(p.sys, "argv", ["probe", "--out", output]):
                with self.assertRaises(FileExistsError): p.main()

    def test_ack_requires_exact_sequence_and_rejects_wait(self):
        with patch.object(p.select, "select", return_value=([7], [], [])), patch.object(p.os, "read", side_effect=[b"ACK,41\nACK,4", b"2\n"]):
            self.assertEqual(p.read_ack(7, 42), ["ACK,41", "ACK,42"])
        with patch.object(p.select, "select", return_value=([7], [], [])), patch.object(p.os, "read", return_value=b"WAIT,42\n"):
            with self.assertRaisesRegex(RuntimeError, "rejected"): p.read_ack(7, 42)

    def test_two_cables_require_valid_explicit_flash_proof(self):
        d = fixture(); d.pop()
        with self.assertRaisesRegex(RuntimeError, "flash-proof"): p.select_pair(d)
        evidence = {"flashed": True, "readback_verified": True, "reset_run": True,
                    "probe_serial": p.PROBE_SERIAL, "chip_id": "0x46740011",
                    "uid": "ad21ad506c54c6c6", "firmware_sha256": p.FIRMWARE_SHA, "bytes": 71704}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "flash-result.json"; path.write_text(json.dumps(evidence))
            proof = p.load_flash_proof(path)
            self.assertFalse(p.select_pair(d, proof)["dbg_present"])
            for key, bad in [("readback_verified", False), ("uid", "different"),
                             ("firmware_sha256", "different"), ("bytes", 28524)]:
                invalid = dict(evidence); invalid[key] = bad; path.write_text(json.dumps(invalid))
                with self.assertRaisesRegex(RuntimeError, "differs"): p.load_flash_proof(path)
            path.write_text(json.dumps(evidence)); old = time.time() - 7 * 3600; os.utime(path, (old, old))
            with self.assertRaisesRegex(RuntimeError, "stale"): p.load_flash_proof(path)

    def test_flash_proof_does_not_override_live_driver_or_wrong_probe(self):
        d = fixture(); proof = {"test_fixture": True}
        d[2]["USB Serial Number"] = "wrong"
        with self.assertRaisesRegex(RuntimeError, "Unexpected or multiple"): p.select_pair(d, proof)
        d = fixture(); d.append(copy.deepcopy(d[2]))
        with self.assertRaisesRegex(RuntimeError, "Unexpected or multiple"): p.select_pair(d, proof)
        d = fixture(); d.pop(); d[1]["bcdDevice"] = 0x0269
        with self.assertRaisesRegex(RuntimeError, "version"): p.select_pair(d, proof)


if __name__ == "__main__":
    unittest.main()
