"""Production ESP parser/state machine and USB send paths with mocked hardware.

No physical COM, HID input, GUI launch, or flash access is used.
"""
from __future__ import annotations
import ctypes as ct
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FirmwareAbsoluteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="wk-firmware-absolute-")
        cls.addClassCleanup(cls.temp.cleanup)
        library = Path(cls.temp.name) / "firmware.dylib"
        # Use the installed production TinyUSB headers when available, so the
        # USB descriptor checks exercise its actual byte-generating macros.
        candidates = [Path.home() / ".local/share/esp32-agent/workspaces" / name /
                      "managed_components/espressif__tinyusb/src"
                      for name in ("wiredkvm-installer", "wiredkvm-board", "wiredkvm-usb")]
        tinyusb = next((path for path in candidates if (path / "class/hid/hid_device.h").exists()), None)
        cls.real_tinyusb_headers = tinyusb is not None
        include_args = []
        if tinyusb:
            (Path(cls.temp.name) / "tusb_config.h").write_text(
                "#pragma once\n#define CFG_TUSB_MCU OPT_MCU_NONE\n"
                "#define CFG_TUSB_OS OPT_OS_NONE\n#define CFG_TUD_ENABLED 1\n"
                "#define CFG_TUD_MAX_SPEED OPT_MODE_FULL_SPEED\n#define CFG_TUD_HID 2\n"
                "#define CFG_TUSB_DEBUG 0\n#define TUP_DCD_ENDPOINT_MAX 8\n")
            include_args = ["-DWK_TEST_REAL_TINYUSB=1", "-I", cls.temp.name, "-I", str(tinyusb)]
        built = subprocess.run([
            "/usr/bin/clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
            "-dynamiclib", "-fPIC", *include_args, "-I", str(ROOT / "tests/support/firmware_mock"),
            "-I", str(ROOT / "firmware/main"),
            str(ROOT / "tests/support/wk_firmware_fixture.c"),
            str(ROOT / "firmware/main/wire_protocol.c"), "-o", str(library),
        ], capture_output=True, text=True, timeout=30)
        if built.returncode:
            raise AssertionError(built.stderr)
        cls.lib = ct.CDLL(str(library))
        cls.lib.wk_fixture_feed.argtypes = [ct.c_char_p, ct.c_uint]
        cls.lib.wk_fixture_pump.argtypes = [ct.c_char_p, ct.c_uint]
        cls.lib.wk_fixture_pump.restype = ct.c_int64
        cls.lib.wk_fixture_fail.argtypes = [ct.c_char, ct.c_int]
        cls.lib.wk_fixture_usb.argtypes = [ct.c_bool, ct.c_bool, ct.c_int]
        cls.lib.wk_fixture_suspend.argtypes = [ct.c_bool]
        cls.lib.wk_fixture_interface_ready.argtypes = [ct.c_uint, ct.c_bool]
        cls.lib.wk_fixture_config_descriptor.restype = ct.POINTER(ct.c_uint8)
        cls.lib.tud_hid_descriptor_report_cb.argtypes = [ct.c_uint8]
        cls.lib.tud_hid_descriptor_report_cb.restype = ct.POINTER(ct.c_uint8)
        cls.lib.wk_fixture_report_descriptor_length.argtypes = [ct.c_uint]
        cls.lib.wk_fixture_uart.restype = ct.c_char_p
        cls.lib.wk_fixture_reports.restype = ct.c_char_p
        cls.lib.wk_fixture_watchdog_release.restype = ct.c_bool
        cls.lib.wk_usb_absolute_mouse.argtypes = [ct.c_uint8, ct.c_uint16, ct.c_uint16,
                                                ct.c_int8, ct.c_int8]
        cls.lib.wk_usb_absolute_mouse.restype = ct.c_bool
        cls.lib.wk_usb_mouse.argtypes = [ct.c_uint8, ct.c_int8, ct.c_int8, ct.c_int8, ct.c_int8]
        cls.lib.wk_usb_mouse.restype = ct.c_bool
        cls.lib.wk_usb_keyboard.argtypes = [ct.c_uint8, ct.POINTER(ct.c_uint8)]
        cls.lib.wk_usb_keyboard.restype = ct.c_bool
        cls.lib.wk_fixture_use_usb_keyboard.argtypes = [ct.c_bool]

    def setUp(self):
        self.lib.wk_fixture_reset()
        self.sequence = 0

    @staticmethod
    def frame(kind, a=0, b=0, sequence=0):
        body = f"WK1,{sequence},{kind},{a},{b}".encode()
        crc = 0
        for value in body:
            crc ^= value
            for _ in range(8):
                crc = ((crc << 1) ^ (0x07 if crc & 0x80 else 0)) & 0xff
        return body + f",{crc:02X}\n".encode()

    def send(self, kind, a=0, b=0, *, sequence=None):
        if sequence is None:
            sequence = self.sequence
            self.sequence += 1
        frame = self.frame(kind, a, b, sequence)
        # Also exercise the incremental parser across a split frame.
        self.lib.wk_fixture_feed(frame[:5], 5)
        self.lib.wk_fixture_feed(frame[5:], len(frame) - 5)
        return self.lib.wk_fixture_uart().decode().splitlines()[-1]

    def reports(self):
        return self.lib.wk_fixture_reports().decode().splitlines()

    def test_absolute_coordinate_bounds_are_checked_before_hid(self):
        for a, b in ((0, 0), (32767, 32767), (0, 32767)):
            self.assertTrue(self.send("A", a, b).startswith("ACK,"))
        accepted = self.reports()
        for a, b in ((-1, 0), (32768, 0), (0, -1), (0, 32768)):
            self.assertEqual(self.send("A", a, b), "ERR,range")
        self.assertEqual(self.reports(), accepted)

    def test_short_uart_frame_is_processed_without_waiting_for_128_bytes(self):
        frame = self.frame("Q", sequence=42)
        waited_us = self.lib.wk_fixture_pump(frame, len(frame))
        self.assertEqual(waited_us, 0, "A short WK1 packet must not wait one 10 ms tick")
        self.assertIn("ACK,42", self.lib.wk_fixture_uart().decode().splitlines())

    def test_capability_probe_is_side_effect_free_even_without_usb(self):
        self.lib.wk_fixture_usb(False, False, 0)
        self.assertEqual(self.send("Q", sequence=3), "ACK,3")
        self.assertEqual(self.send("Q", sequence=3), "ACK,3")
        self.assertEqual(self.send("Q", 1, 0), "ERR,range")
        self.assertTrue(self.send("S").startswith("WAIT,"))
        self.assertEqual(self.reports(), [])

    def test_button_scroll_and_release_preserve_absolute_position(self):
        self.send("A", 123, 32000)
        self.send("B", 1)
        self.send("W", -2, 3)
        self.send("C", 8)
        self.send("T", 4, 1)
        self.send("R")
        self.assertEqual(self.reports(), [
            "A,0,123,32000,0,0", "A,1,123,32000,0,0",
            "A,1,123,32000,-2,3", "K,8,0,0,0,0", "K,8,4,0,0,0",
            "K,0,0,0,0,0", "A,0,123,32000,0,0",
        ])

    def test_relative_mode_still_works_after_absolute_session(self):
        self.send("A", 100, 200)
        self.send("B", 1)
        self.send("M", 5, -6)
        self.send("W", 1, -1)
        self.send("R")
        self.assertEqual(self.reports()[2:5], [
            "A,0,100,200,0,0", "M,1,5,-6,0,0", "M,1,0,0,1,-1",
        ])
        self.assertEqual(self.reports()[-1], "M,0,0,0,0,0")

    def test_release_resets_session_to_relative_before_first_click_or_scroll(self):
        for held_button in (False, True):
            with self.subTest(held_button=held_button):
                self.lib.wk_fixture_reset()
                self.send("A", 100, 200)
                if held_button:
                    self.send("B", 1)
                self.lib.wk_fixture_clear_output()
                self.assertTrue(self.send("R").startswith("ACK,"))
                released = ["K,0,0,0,0,0", "A,0,100,200,0,0"] if held_button else []
                self.assertEqual(self.reports(), released)
                self.send("B", 1)
                self.send("W", 2, -1)
                self.assertEqual(self.reports()[-2:], ["M,1,0,0,0,0", "M,1,0,0,2,-1"])

    def test_failed_absolute_report_rolls_back_position_and_can_retry(self):
        self.send("A", 100, 200)
        self.lib.wk_fixture_fail(b"A", 1)
        self.assertEqual(self.send("A", 300, 400, sequence=7), "WAIT,7")
        self.send("B", 1)
        self.assertEqual(self.reports()[-1], "A,1,100,200,0,0")
        self.assertEqual(self.send("A", 300, 400, sequence=7), "ACK,7")
        count = len(self.reports())
        self.assertEqual(self.send("A", 300, 400, sequence=7), "ACK,7")
        self.assertEqual(len(self.reports()), count, "Successful duplicate must not move twice")

    def test_failed_mode_switch_cannot_leave_old_buttons_pressed(self):
        self.send("M", 1, 2)
        self.send("B", 1)
        self.lib.wk_fixture_fail(b"A", 1)
        self.assertEqual(self.send("A", 500, 600, sequence=8), "WAIT,8")
        self.assertEqual(self.reports()[-1], "M,0,0,0,0,0")
        self.assertEqual(self.send("A", 500, 600, sequence=8), "ACK,8")
        self.send("R")
        self.assertEqual(self.reports()[-1], "A,0,500,600,0,0")

    def test_release_retries_instead_of_acknowledging_a_lost_button_up(self):
        self.send("A", 42, 99)
        self.send("B", 1)
        self.lib.wk_fixture_fail(b"A", 1)
        self.assertEqual(self.send("R", sequence=9), "WAIT,9")
        self.send("W", 1, 0)
        self.assertEqual(self.reports()[-1], "A,1,42,99,1,0",
                         "Rejected R must retain the old absolute mode and button state")
        self.assertEqual(self.send("R", sequence=9), "ACK,9")
        self.assertEqual(self.reports()[-1], "A,0,42,99,0,0")

    def test_watchdog_uses_current_mouse_mode_and_retries_failure(self):
        self.send("A", 42, 99)
        self.send("B", 1)
        self.lib.wk_fixture_fail(b"A", 1)
        self.assertFalse(self.lib.wk_fixture_watchdog_release())
        self.assertTrue(self.lib.wk_fixture_watchdog_release())
        self.assertEqual(self.reports()[-1], "A,0,42,99,0,0")

    def test_usb_absolute_report_id_range_and_no_disconnect_wait(self):
        self.assertTrue(self.lib.wk_usb_absolute_mouse(5, 0, 32767, -2, 3))
        self.assertEqual(self.lib.wk_fixture_last_usb_instance(), 1)
        self.assertEqual(self.reports(), ["a,5,0,32767,-2,3"])
        self.assertFalse(self.lib.wk_usb_absolute_mouse(0, 32768, 0, 0, 0))
        self.lib.wk_fixture_usb(False, False, 0)
        self.assertFalse(self.lib.wk_usb_absolute_mouse(0, 0, 0, 0, 0))
        self.assertEqual(self.lib.wk_fixture_delays(), 0)

    def test_usb_interfaces_have_distinct_endpoints_and_descriptor_lengths(self):
        size = self.lib.wk_fixture_config_descriptor_length()
        descriptor = bytes(self.lib.wk_fixture_config_descriptor()[:size])
        self.assertEqual(descriptor[:2], bytes((9, 2)))
        self.assertEqual(int.from_bytes(descriptor[2:4], "little"), size)
        self.assertEqual(descriptor[4], 2)
        interfaces, endpoints, lengths = [], [], []
        index = 9
        while index < size:
            length, kind = descriptor[index:index + 2]
            self.assertGreaterEqual(length, 2)
            item = descriptor[index:index + length]
            if kind == 4:
                interfaces.append(item[2])
            elif kind == 5:
                endpoints.append(item[2])
                self.assertEqual(int.from_bytes(item[4:6], "little"), 16)
            elif kind == 0x21:
                lengths.append(int.from_bytes(item[7:9], "little"))
            index += length
        self.assertEqual(interfaces, [0, 1])
        self.assertEqual(endpoints, [0x81, 0x82])
        self.assertEqual(lengths, [self.lib.wk_fixture_report_descriptor_length(0),
                                   self.lib.wk_fixture_report_descriptor_length(1)])
        self.assertFalse(self.lib.tud_hid_descriptor_report_cb(2))

    def test_production_absolute_descriptor_has_no_relative_xy_elements(self):
        if not self.real_tinyusb_headers:
            self.skipTest("Production TinyUSB headers require an existing ESP-IDF workspace")
        def items(instance):
            raw = bytes(self.lib.tud_hid_descriptor_report_cb(instance)[
                :self.lib.wk_fixture_report_descriptor_length(instance)])
            result, index = [], 0
            while index < len(raw):
                prefix = raw[index]
                size = (0, 1, 2, 4)[prefix & 3]
                result.append((prefix & 0xfc, int.from_bytes(raw[index + 1:index + 1 + size], "little")))
                index += 1 + size
            return result
        relative, absolute = items(0), items(1)
        self.assertEqual([value for tag, value in relative if tag == 0x84], [1, 2, 4])
        self.assertEqual([value for tag, value in absolute if tag == 0x84], [3])
        # Track the current Usage Page and Usage list through real HID items.
        page, usages, absolute_xy, relative_xy = 0, [], [], []
        for tag, value in absolute:
            if tag == 0x04:
                page = value
            elif tag == 0x08:
                usages.append(value)
            elif tag == 0x80:
                if page == 1:
                    axes = [usage for usage in usages if usage in (0x30, 0x31)]
                    (relative_xy if value & 4 else absolute_xy).extend(axes)
                usages = []
            elif tag in (0xa0, 0xc0):
                usages = []
        self.assertEqual(absolute_xy, [0x30, 0x31])
        self.assertEqual(relative_xy, [])

    def test_globe_report_uses_consumer_page_and_16_bit_payload(self):
        if not self.real_tinyusb_headers:
            self.skipTest('requires production TinyUSB descriptors')
        raw = bytes(self.lib.tud_hid_descriptor_report_cb(0)[
            :self.lib.wk_fixture_report_descriptor_length(0)])
        self.assertIn(bytes((0x05, 0x0c, 0x09, 0x01, 0xa1, 0x01, 0x85, 4)), raw)
        keys = (ct.c_uint8 * 6)()
        self.assertTrue(self.lib.wk_usb_keyboard(16, keys))
        self.assertEqual(self.reports(), ['k,0,0,0,0,0', 'g,669,0,0,0,0'])
        self.assertTrue(self.lib.wk_usb_keyboard(18, keys))
        self.assertEqual(self.reports()[-1], 'k,2,0,0,0,0')
        self.assertTrue(self.lib.wk_usb_keyboard(0, keys))
        self.assertEqual(self.reports()[-2:], ['k,0,0,0,0,0', 'g,0,0,0,0,0'])

    def test_failed_globe_release_is_retryable_without_stuck_shift(self):
        self.lib.wk_fixture_use_usb_keyboard(True)
        self.assertTrue(self.send('C', 18).startswith('ACK,'))
        self.lib.wk_fixture_fail(b'g', 1)
        self.assertEqual(self.send('R', sequence=31), 'WAIT,31')
        self.assertEqual(self.send('R', sequence=31), 'ACK,31')
        self.assertIn('g,0,0,0,0,0', self.reports())
        self.assertTrue(self.lib.wk_fixture_watchdog_release())

    def test_partial_keyboard_press_is_released_after_logical_rollback(self):
        self.lib.wk_fixture_use_usb_keyboard(True)
        self.lib.wk_fixture_fail(b'g', 1)
        self.assertEqual(self.send('C', 18, sequence=21), 'WAIT,21')
        self.assertEqual(self.reports(), ['k,2,0,0,0,0'])
        self.assertTrue(self.lib.wk_fixture_watchdog_release())
        self.assertEqual(self.reports()[-2:], ['k,0,0,0,0,0', 'M,0,0,0,0,0'])

    def test_absolute_endpoint_busy_cannot_block_relative_mouse_or_keyboard(self):
        self.lib.wk_fixture_interface_ready(1, False)
        self.assertTrue(self.lib.wk_usb_mouse(1, 4, -5, 0, 0))
        self.assertEqual(self.lib.wk_fixture_last_usb_instance(), 0)
        keys = (ct.c_uint8 * 6)(4, 0, 0, 0, 0, 0)
        self.assertTrue(self.lib.wk_usb_keyboard(8, keys))
        self.assertEqual(self.lib.wk_fixture_last_usb_instance(), 0)
        self.assertFalse(self.lib.wk_usb_absolute_mouse(1, 100, 200, 0, 0))
        self.lib.wk_fixture_interface_ready(1, True)
        self.lib.wk_fixture_interface_ready(0, False)
        self.assertTrue(self.lib.wk_usb_absolute_mouse(1, 100, 200, 0, 0))
        self.assertEqual(self.lib.wk_fixture_last_usb_instance(), 1)
        self.assertFalse(self.lib.wk_usb_mouse(1, 4, -5, 0, 0))

    def test_usb_ready_wait_advances_real_ticks_and_remains_bounded(self):
        self.lib.wk_fixture_usb(True, False, 1)
        self.assertTrue(self.lib.wk_usb_absolute_mouse(0, 10, 20, 0, 0))
        self.assertEqual(self.lib.wk_fixture_delays(), 1)
        self.lib.wk_fixture_usb(True, False, 0)
        self.assertFalse(self.lib.wk_usb_absolute_mouse(0, 10, 20, 0, 0))
        self.assertEqual(self.lib.wk_fixture_delays(), 2)

    def test_suspended_but_mounted_bus_immediately_reports_unavailable(self):
        # USB/OTG unplugged while CH343 COM keeps the S3 powered: historical
        # configuration can survive until a new bus reset, but SOF has stopped.
        self.lib.wk_fixture_usb(True, False, 0)
        self.assertEqual(self.send("S", sequence=7), "ACK,7",
                         "An endpoint in flight is not a disconnected host")
        self.lib.wk_fixture_suspend(True)
        self.assertEqual(self.send("S", sequence=7), "WAIT,7",
                         "A repeated S must recheck bus state, not stale mount state")
        self.assertFalse(self.lib.wk_usb_absolute_mouse(0, 10, 20, 0, 0))
        self.assertEqual(self.lib.wk_fixture_delays(), 0)
        self.assertEqual(self.reports(), [])
        self.lib.wk_fixture_suspend(False)
        self.assertEqual(self.send("S", sequence=7), "ACK,7")


if __name__ == "__main__":
    unittest.main()
