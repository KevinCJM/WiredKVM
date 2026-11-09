"""Opaque C1 transport and real TinyUSB descriptors, without hardware access."""
from __future__ import annotations
import ctypes as ct
from pathlib import Path
import subprocess
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]


class ClipboardChannelFirmwareTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workspaces = Path.home() / '.local/share/esp32-agent/workspaces'
        candidates = [workspaces / name / 'managed_components/espressif__tinyusb/src'
                      for name in ('wiredkvm-clipboard', 'wiredkvm-exchange', 'wiredkvm-installer')]
        tinyusb = next((p for p in candidates if (p / 'class/msc/msc_device.h').exists()), None)
        if tinyusb is None:
            raise unittest.SkipTest('production TinyUSB headers are unavailable')
        cls.temp = tempfile.TemporaryDirectory(prefix='wk-clipboard-firmware-')
        cls.addClassCleanup(cls.temp.cleanup)
        temp = Path(cls.temp.name)
        (temp / 'tusb_config.h').write_text('''#pragma once
#define CFG_TUSB_MCU OPT_MCU_NONE
#define CFG_TUSB_OS OPT_OS_NONE
#define CFG_TUD_ENABLED 1
#define CFG_TUD_MAX_SPEED OPT_MODE_FULL_SPEED
#define CFG_TUD_HID 3
#define CFG_TUD_MSC 1
#define CFG_TUD_MSC_EP_BUFSIZE 512
#define CFG_TUSB_DEBUG 0
#define TUP_DCD_ENDPOINT_MAX 8
''')
        (temp / 'tinyusb.h').write_text('''#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_log.h"
#include "device/usbd.h"
typedef enum { TINYUSB_EVENT_ATTACHED, TINYUSB_EVENT_DETACHED, TINYUSB_EVENT_SUSPENDED } tinyusb_event_id_t;
typedef struct { tinyusb_event_id_t id; } tinyusb_event_t;
typedef struct {
 struct { const tusb_desc_device_t *device; const uint8_t *full_speed_config;
          const char **string; unsigned string_count; } descriptor;
 void (*event_cb)(tinyusb_event_t *, void *);
} tinyusb_config_t;
esp_err_t tinyusb_driver_install(const tinyusb_config_t *cfg);
''')
        library = temp / 'firmware.dylib'
        extra = []
        if getattr(cls, 'FLASH_SETUP', False):
            extra = ['-DCONFIG_WIREDKVM_FLASH_SETUP=1',
                     str(ROOT / 'firmware/main/flash_setup.c'),
                     str(ROOT / 'tests/support/flash_setup_fixture.c')]
        built = subprocess.run([
            '/usr/bin/clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
            '-dynamiclib', '-fPIC', '-I', str(temp), '-I', str(tinyusb),
            '-I', str(ROOT / 'tests/support/firmware_mock'), '-I', str(ROOT / 'firmware/main'),
            str(ROOT / 'tests/support/clipboard_firmware_fixture.c'),
            str(ROOT / 'firmware/main/wire_protocol.c'), '-o', str(library)] + extra,
            capture_output=True, text=True, timeout=30)
        if built.returncode:
            raise AssertionError(built.stderr)
        cls.lib = ct.CDLL(str(library))
        cls.lib.fc_feed.argtypes = [ct.c_char_p, ct.c_uint]
        cls.lib.fc_tx.argtypes = [ct.c_uint]
        cls.lib.fc_tx.restype = cls.lib.fc_exchange_tx.restype = ct.c_char_p
        cls.lib.fc_pop.argtypes = [ct.c_void_p]
        cls.lib.fc_pop.restype = ct.c_bool
        cls.lib.fc_accept.argtypes = [ct.c_bool]
        cls.lib.fc_usb_report.restype = ct.POINTER(ct.c_uint8)
        cls.lib.wk_clipboard_usb_output.argtypes = [ct.c_char_p, ct.c_size_t]
        cls.lib.wk_clipboard_usb_output.restype = ct.c_bool
        cls.lib.tud_hid_set_report_cb.argtypes = [ct.c_uint8, ct.c_uint8, ct.c_int,
                                               ct.c_char_p, ct.c_uint16]
        cls.lib.wk_fixture_config_descriptor.restype = ct.POINTER(ct.c_uint8)
        cls.lib.tud_hid_descriptor_report_cb.argtypes = [ct.c_uint8]
        cls.lib.tud_hid_descriptor_report_cb.restype = ct.POINTER(ct.c_uint8)
        cls.lib.wk_fixture_uart.restype = ct.c_char_p
        cls.lib.wk_fixture_reports.restype = ct.c_char_p
        cls.lib.wk_fixture_pump.argtypes = [ct.c_char_p, ct.c_uint]
        cls.lib.wk_fixture_pump.restype = ct.c_int64
        cls.lib.wk_fixture_usb.argtypes = [ct.c_bool, ct.c_bool, ct.c_int]
        cls.lib.wk_fixture_interface_ready.argtypes = [ct.c_uint, ct.c_bool]

    def setUp(self):
        self.lib.fc_reset()

    @staticmethod
    def frame(payload):
        return f'C1,{payload.hex()},{zlib.crc32(payload):08x}\n'.encode()

    @staticmethod
    def wk_frame(kind='Q', sequence=14):
        body = f'WK1,{sequence},{kind},0,0'.encode()
        crc = 0
        for value in body:
            crc ^= value
            for _ in range(8):
                crc = ((crc << 1) ^ (7 if crc & 128 else 0)) & 255
        return body + f',{crc:02X}\n'.encode()

    def feed(self, data):
        self.lib.fc_feed(data, len(data))

    def pop(self):
        report = ct.create_string_buffer(64)
        return report.raw if self.lib.fc_pop(report) else None

    def test_composite_preserves_keyboard_absolute_mouse_and_msc(self):
        p = self.lib.wk_fixture_config_descriptor()
        data = bytes(p[:p[2] | p[3] << 8])
        self.assertEqual(data[4], 4)
        interfaces, endpoints = [], []
        at = 0
        while at < len(data):
            length, kind = data[at:at + 2]
            self.assertGreater(length, 0)
            if kind == 4:
                interfaces.append((data[at + 2], data[at + 4], data[at + 5]))
            if kind == 5:
                endpoints.append((data[at + 2], int.from_bytes(data[at + 4:at + 6], 'little')))
            at += length
        self.assertEqual(interfaces, [(0, 1, 3), (1, 1, 3), (2, 2, 8), (3, 1, 3)])
        self.assertEqual(endpoints, [(0x81, 16), (0x82, 16), (3, 64), (0x83, 64), (0x84, 64)])
        self.assertEqual(self.lib.fc_pid(), 0x700c)

    def test_vendor_report_has_64_byte_input_output_without_report_id(self):
        raw = bytes(self.lib.tud_hid_descriptor_report_cb(2)[:self.lib.fc_descriptor_length()])
        items, at = [], 0
        while at < len(raw):
            tag = raw[at]
            length = (0, 1, 2, 4)[tag & 3]
            items.append((tag & 0xfc, int.from_bytes(raw[at + 1:at + 1 + length], 'little')))
            at += length + 1
        self.assertIn((0x04, 0xff60), items)
        self.assertIn((0x08, 0x61), items)
        self.assertIn((0x74, 8), items)
        self.assertIn((0x94, 64), items)
        self.assertEqual([value for tag, value in items if tag in (0x80, 0x90)], [2, 2])
        self.assertFalse(any(tag == 0x84 for tag, _ in items))
        self.assertFalse(self.lib.tud_hid_descriptor_report_cb(3))

    def test_uart_raw_crc_round_trip_and_fragmented_line(self):
        payload = bytes(range(64))
        frame = self.frame(payload)
        for value in frame[:-1]:
            self.feed(bytes([value]))
        self.assertIsNone(self.pop())
        self.feed(b'\n')
        self.assertEqual(self.pop(), payload)
        self.assertTrue(self.lib.wk_clipboard_usb_output(payload, 64))
        self.assertEqual(self.lib.fc_tx(512), frame)
        self.assertEqual(self.lib.fc_tx(512), b'')

    def test_bad_crc_length_hex_and_overflow_are_dropped_then_recover(self):
        valid = self.frame(bytes([0xab]) * 64)
        malformed = [valid.replace(b'ab', b'aB', 1), valid.replace(b'ab', b'gg', 1),
                     valid[:-3] + b'00\n', valid[:3] + valid[5:],
                     valid[:3] + b'ab' + valid[3:], valid[:-1] + b'\r\n',
                     b'C' * 2048 + b'\n', b'C1,\n', valid.replace(b'C1', b'C2', 1)]
        for frame in malformed:
            with self.subTest(frame=frame[:30]):
                self.feed(frame)
                self.assertIsNone(self.pop())
        self.feed(valid)
        self.assertEqual(self.pop(), bytes([0xab]) * 64)
        self.assertEqual(self.lib.wk_fixture_uart(), b'')

    def test_both_queues_are_bounded_fifo_and_wrap(self):
        for value in range(12):
            payload = bytes([value]) * 64
            self.feed(self.frame(payload))
            self.assertEqual(self.lib.wk_clipboard_usb_output(payload, 64), value < 8)
        for value in range(8):
            self.assertEqual(self.pop(), bytes([value]) * 64)
            self.assertEqual(self.lib.fc_tx(512), self.frame(bytes([value]) * 64))
        self.assertIsNone(self.pop())
        self.assertEqual(self.lib.fc_tx(512), b'')
        payload = bytes([99]) * 64
        self.feed(self.frame(payload))
        self.assertEqual(self.pop(), payload)

    def test_short_destination_preserves_queued_output(self):
        payload = bytes(64)
        self.assertFalse(self.lib.wk_clipboard_usb_output(payload, 63))
        self.assertFalse(self.lib.wk_clipboard_usb_output(payload + b'x', 65))
        self.assertTrue(self.lib.wk_clipboard_usb_output(payload, 64))
        self.assertEqual(self.lib.fc_tx(141), b'')
        self.assertEqual(self.lib.fc_tx(142), self.frame(payload))

    def test_set_report_callback_filters_interface_id_type_size(self):
        payload = bytes(range(64))
        for instance, report_id, report_type, size in [(0, 0, 2, 64), (1, 0, 2, 64),
                (2, 1, 2, 64), (2, 0, 1, 64), (2, 0, 3, 64), (2, 0, 2, 63)]:
            self.lib.tud_hid_set_report_cb(instance, report_id, report_type, payload, size)
        self.assertEqual(self.lib.fc_tx(512), b'')
        self.lib.tud_hid_set_report_cb(2, 0, 2, payload, 64)
        self.assertEqual(self.lib.fc_tx(512), self.frame(payload))
        self.assertEqual(self.lib.wk_fixture_delays(), 0)
        self.assertEqual(self.lib.wk_fixture_uart(), b'')

    def test_usb_poll_is_one_packet_without_blocking_other_interfaces(self):
        for value in (41, 42):
            self.feed(self.frame(bytes([value]) * 64))
        self.lib.wk_fixture_interface_ready(2, False)
        self.lib.wk_usb_clipboard_poll()
        self.assertEqual(self.lib.fc_usb_reports(), 0)
        self.feed(self.wk_frame())
        self.assertEqual(self.lib.wk_fixture_uart(), b'ACK,14\n')
        self.assertEqual(self.lib.wk_fixture_delays(), 0)
        self.lib.wk_fixture_interface_ready(2, True)
        self.lib.wk_usb_clipboard_poll()
        self.assertEqual(self.lib.fc_usb_reports(), 1)
        self.assertEqual(bytes(self.lib.fc_usb_report()[:64]), bytes([41]) * 64)
        self.assertEqual((self.lib.fc_usb_instance(), self.lib.fc_usb_id(), self.lib.fc_usb_length()),
                         (2, 0, 64))
        self.assertEqual(self.pop(), bytes([42]) * 64)

    def test_detach_and_offline_clear_both_queues(self):
        for detach in (True, False):
            self.feed(self.frame(bytes(64)))
            self.lib.wk_clipboard_usb_output(bytes(64), 64)
            if detach:
                self.lib.fc_detach()
            else:
                self.lib.wk_fixture_usb(False, False, 0)
                self.lib.wk_usb_clipboard_poll()
            self.assertIsNone(self.pop())
            self.assertEqual(self.lib.fc_tx(512), b'')
        self.lib.tud_hid_set_report_cb(2, 0, 2, bytes(64), 64)
        self.assertEqual(self.lib.fc_tx(512), b'')

    def test_failed_usb_submission_does_not_block_uart_or_retry_forever(self):
        self.feed(self.frame(bytes(64)))
        self.lib.fc_accept(False)
        self.lib.wk_usb_clipboard_poll()
        self.lib.wk_usb_clipboard_poll()
        self.assertEqual(self.lib.fc_usb_reports(), 1)
        self.assertEqual(self.lib.wk_fixture_delays(), 0)
        self.feed(self.wk_frame())
        self.assertIn(b'ACK,14\n', self.lib.wk_fixture_uart())

    def test_set_configuration_and_quick_suspend_retire_queued_reports(self):
        for event in (self.lib.fc_attach, self.lib.fc_suspend):
            with self.subTest(event=event):
                self.feed(self.frame(bytes(64)))
                self.lib.wk_clipboard_usb_output(bytes(64), 64)
                # No poll in the unavailable state: a quick resume must still
                # not expose packets buffered before its lifecycle callback.
                event()
                self.lib.wk_usb_clipboard_poll()
                self.assertEqual(self.lib.fc_usb_reports(), 0)
                self.assertEqual(self.lib.fc_tx(512), b'')

    def test_partial_uart_frame_cannot_cross_usb_epoch(self):
        frame = self.frame(bytes(range(64)))
        for event in (self.lib.fc_detach, self.lib.fc_attach, self.lib.fc_suspend):
            with self.subTest(event=event):
                self.feed(frame[:73])
                event()
                self.feed(frame[73:])
                self.assertIsNone(self.pop())
                self.feed(frame)
                self.assertEqual(self.pop(), bytes(range(64)))
                self.feed(self.wk_frame())
                self.assertIn(b'ACK,14\n', self.lib.wk_fixture_uart())

    def test_mixed_c1_x1_and_wk1_do_not_corrupt_other_parsers(self):
        exchange_body = b'X1,Q,0'
        exchange = exchange_body + f',{zlib.crc32(exchange_body):08x}\n'.encode()
        payload = bytes(range(64))
        self.feed(self.frame(payload) + exchange + self.wk_frame() + self.frame(payload))
        self.assertEqual(self.lib.wk_fixture_uart(), b'ACK,14\n')
        self.assertTrue(self.lib.fc_exchange_tx().startswith(b'X1,S,0,ABSENT,'))
        self.assertEqual(self.pop(), payload)
        self.assertEqual(self.pop(), payload)

    def test_main_prioritizes_wk1_and_emits_one_clipboard_frame_per_iteration(self):
        self.lib.fc_schedule(3, 2048)
        frame = self.wk_frame()
        self.lib.wk_fixture_pump(frame, len(frame))
        output = self.lib.wk_fixture_uart()
        self.assertEqual(output, b'WK_READY,1,UART0\nACK,14\n' + self.frame(bytes(64)))
        self.assertEqual(self.lib.fc_tx(512), self.frame(bytes([1]) + bytes(63)))
        self.assertEqual(self.lib.fc_tx(512), self.frame(bytes([2]) + bytes(63)))

    def test_full_size_setup_lines_and_new_protocol_reports_preserve_hid(self):
        # Feed a real-size 512-byte X1 block response through the production
        # demultiplexer. No disk is mounted and no physical serial port is used.
        body = b'X1,D,1,1,' + bytes(range(256)).hex().encode() * 2
        exchange = body + f',{zlib.crc32(body):08x}\n'.encode()
        payload = b'WKC3' + bytes(range(60))
        for sequence in range(40):
            stream = self.frame(payload) + exchange + self.wk_frame(sequence=sequence)
            for offset in range(0, len(stream), 37):
                self.feed(stream[offset:offset+37])
            self.assertEqual(self.pop(), payload)
        self.assertNotIn(b'ERR,', self.lib.wk_fixture_uart())
        self.assertIn(b'ACK,39\n', self.lib.wk_fixture_uart())

    def test_main_keeps_uart_headroom_and_preserves_unsent_report(self):
        self.lib.fc_schedule(1, 200)
        frame = self.wk_frame()
        self.lib.wk_fixture_pump(frame, len(frame))
        self.assertEqual(self.lib.wk_fixture_uart(), b'WK_READY,1,UART0\nACK,14\n')
        self.assertEqual(self.lib.fc_tx(512), self.frame(bytes(64)))


if __name__ == '__main__':
    unittest.main()
