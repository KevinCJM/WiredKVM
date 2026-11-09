"""Exercise the production UART-backed MSC state machine without hardware.

Uses production TinyUSB descriptor macros and simulates its deferred async-I/O
contract, including reset between completion enqueue and completion execution.
"""
from __future__ import annotations
import ctypes as ct
from pathlib import Path
import subprocess
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]


class ExchangeFirmwareTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        candidates = [Path.home() / '.local/share/esp32-agent/workspaces' / name /
                      'managed_components/espressif__tinyusb/src'
                      for name in ('wiredkvm-exchange', 'wiredkvm-installer', 'wiredkvm-board')]
        tinyusb = next((p for p in candidates if (p / 'class/msc/msc_device.h').exists()), None)
        if tinyusb is None:
            raise unittest.SkipTest('production TinyUSB headers are unavailable')
        cls.temp = tempfile.TemporaryDirectory(prefix='wk-exchange-firmware-')
        cls.addClassCleanup(cls.temp.cleanup)
        temp = Path(cls.temp.name)
        (temp / 'tusb_config.h').write_text('''#pragma once
#define CFG_TUSB_MCU OPT_MCU_NONE
#define CFG_TUSB_OS OPT_OS_NONE
#define CFG_TUD_ENABLED 1
#define CFG_TUD_MAX_SPEED OPT_MODE_FULL_SPEED
#define CFG_TUD_HID 2
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
typedef enum { TINYUSB_EVENT_ATTACHED, TINYUSB_EVENT_DETACHED } tinyusb_event_id_t;
typedef struct { tinyusb_event_id_t id; } tinyusb_event_t;
typedef struct {
 struct { const tusb_desc_device_t *device; const uint8_t *full_speed_config;
          const char **string; unsigned string_count; } descriptor;
 void (*event_cb)(tinyusb_event_t *, void *);
} tinyusb_config_t;
esp_err_t tinyusb_driver_install(const tinyusb_config_t *cfg);
''')
        fixture = temp / 'fixture.c'
        fixture.write_text('''#define CONFIG_WIREDKVM_EXCHANGE_STORAGE 1
#define WK_TEST_REAL_TINYUSB 1
#define portMUX_TYPE int
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(lock) ((void)(lock))
#define portEXIT_CRITICAL(lock) ((void)(lock))
#include "''' + str(ROOT / 'tests/support/wk_firmware_fixture.c') + '''"
#include "''' + str(ROOT / 'firmware/main/exchange_storage.c') + '''"
const tusb_desc_device_t descriptor_dev_default = {.idProduct = 0x4004};
static void (*deferred_fn[32])(void *);
static void *deferred_arg[32];
static unsigned deferred_head, deferred_size;
static bool usb_pending;
static int completion_count, completion_result;
static uint8_t io_buffer[512];
static uint8_t sense_key, sense_asc;
void usbd_defer_func(osal_task_func_t fn, void *arg, bool in_isr) {
 (void)in_isr;
 unsigned at = (deferred_head + deferred_size++) % 32;
 deferred_fn[at] = fn; deferred_arg[at] = arg;
}
static void finish_io(void *arg) {
 if (!usb_pending) return;
 usb_pending = false;
 completion_result = (int)(intptr_t)arg;
 ++completion_count;
}
bool tud_msc_async_io_done(int32_t bytes, bool in_isr) {
 if (!usb_pending) return false;
 usbd_defer_func(finish_io, (void *)(intptr_t)bytes, in_isr); return true;
}
bool tud_msc_set_sense(uint8_t lun, uint8_t key, uint8_t asc, uint8_t ascq) {
 (void)lun; (void)ascq; sense_key = key; sense_asc = asc; return true;
}
void fx_reset(void) {
 wk_fixture_reset(); wk_exchange_init(); wk_exchange_usb_attached();
 deferred_head = deferred_size = 0; usb_pending = false;
 completion_count = completion_result = 0; sense_key = sense_asc = 0;
 memset(io_buffer, 0, sizeof(io_buffer));
}
void fx_feed(const uint8_t *p, unsigned n) {
 for (unsigned i = 0; i < n; ++i)
  if (!wk_exchange_feed(p[i])) wk_fixture_feed(p + i, 1);
}
const char *fx_tx(void) {
 static char out[WK_EXCHANGE_LINE_CAPACITY];
 size_t n = wk_exchange_next_tx(out, sizeof(out)); out[n] = 0; return out;
}
int fx_io(bool write, uint32_t lba, uint32_t offset, uint32_t size) {
 usb_pending = true;
 int n = write ? tud_msc_write10_cb(0, lba, offset, io_buffer, size)
               : tud_msc_read10_cb(0, lba, offset, io_buffer, size);
 if (n != TUD_MSC_RET_ASYNC) usb_pending = false;
 return n;
}
void fx_buffer(uint8_t value) { memset(io_buffer, value, sizeof(io_buffer)); }
const uint8_t *fx_data(void) { return io_buffer; }
void fx_poll(unsigned ms) { clock_us += (int64_t)ms * 1000; wk_exchange_poll(); }
void fx_drain_one(void) {
 if (!deferred_size) return;
 unsigned at = deferred_head; deferred_head = (at + 1) % 32; --deferred_size;
 deferred_fn[at](deferred_arg[at]);
}
void fx_drain(void) { while (deferred_size) fx_drain_one(); }
void fx_usb_reset(void) { usb_pending = false; wk_exchange_usb_ready(false); wk_exchange_usb_attached(); }
int fx_completions(void) { return completion_count; }
int fx_result(void) { return completion_result; }
int fx_sense(void) { return (sense_key << 8) | sense_asc; }
uint32_t fx_capacity(void) { uint32_t b; uint16_t s; tud_msc_capacity_cb(0, &b, &s); return b; }
int fx_eject(void) { return tud_msc_start_stop_cb(0, 0, false, true); }
int fx_flush(void) { const uint8_t c[16] = {0x35}; return tud_msc_scsi_cb(0, c, NULL, 0); }
''')
        library = temp / 'firmware.dylib'
        built = subprocess.run(['/usr/bin/clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                                '-dynamiclib', '-fPIC', '-I', str(temp), '-I', str(tinyusb),
                                '-I', str(ROOT / 'tests/support/firmware_mock'),
                                '-I', str(ROOT / 'firmware/main'), str(fixture),
                                str(ROOT / 'firmware/main/wire_protocol.c'), '-o', str(library)],
                               capture_output=True, text=True, timeout=30)
        if built.returncode:
            raise AssertionError(built.stderr)
        cls.lib = ct.CDLL(str(library))
        cls.lib.fx_feed.argtypes = [ct.c_char_p, ct.c_uint]
        cls.lib.fx_tx.restype = ct.c_char_p
        cls.lib.fx_io.argtypes = [ct.c_bool, ct.c_uint32, ct.c_uint32, ct.c_uint32]
        cls.lib.fx_buffer.argtypes = [ct.c_uint8]
        cls.lib.fx_data.restype = ct.POINTER(ct.c_uint8)
        cls.lib.fx_poll.argtypes = [ct.c_uint]
        cls.lib.fx_capacity.restype = ct.c_uint32
        cls.lib.wk_fixture_uart.restype = ct.c_char_p
        cls.lib.wk_fixture_config_descriptor.restype = ct.POINTER(ct.c_uint8)
        cls.lib.tud_msc_test_unit_ready_cb.argtypes = [ct.c_uint8]
        cls.lib.tud_msc_test_unit_ready_cb.restype = ct.c_bool
        cls.lib.tud_msc_is_writable_cb.argtypes = [ct.c_uint8]
        cls.lib.tud_msc_is_writable_cb.restype = ct.c_bool
        cls.lib.wk_exchange_usb_ready.argtypes = [ct.c_bool]

    def setUp(self):
        self.lib.fx_reset()

    @staticmethod
    def frame(*fields):
        body = ','.join(map(str, ('X1', *fields))).encode()
        return body + f',{zlib.crc32(body):08x}\n'.encode()

    def send(self, *fields):
        frame = self.frame(*fields)
        self.lib.fx_feed(frame, len(frame))

    def take(self):
        raw = self.lib.fx_tx()
        if not raw:
            return None
        body, crc = raw.rstrip(b'\n').rsplit(b',', 1)
        self.assertEqual(zlib.crc32(body), int(crc, 16))
        return body.decode().split(',')

    def publish(self, generation=77):
        self.send('P', generation, 32768)
        self.assertEqual(self.take(), ['X1', 'S', str(generation), 'PRESENT'])

    def test_composite_preserves_both_hid_and_adds_only_msc_endpoints(self):
        p = self.lib.wk_fixture_config_descriptor()
        data = bytes(p[:p[2] | p[3] << 8])
        self.assertEqual(data[4], 3)
        interfaces, endpoints = [], []
        at = 0
        while at < len(data):
            length, kind = data[at:at + 2]
            self.assertGreater(length, 0)
            if kind == 4:
                interfaces.append((data[at + 2], data[at + 5]))
            if kind == 5:
                endpoints.append(data[at + 2])
            at += length
        self.assertEqual(interfaces, [(0, 3), (1, 3), (2, 8)])
        self.assertEqual(endpoints, [0x81, 0x82, 0x03, 0x83])

    def test_absent_until_publish_and_new_media_attention(self):
        self.send('Q', 0)
        self.assertEqual(self.take(), ['X1', 'S', '0', 'ABSENT'])
        self.assertEqual(self.lib.fx_capacity(), 0)
        self.publish()
        self.assertEqual(self.lib.fx_capacity(), 32768)
        self.assertFalse(self.lib.tud_msc_test_unit_ready_cb(0))
        self.assertEqual(self.lib.fx_sense(), 0x0628)
        self.assertTrue(self.lib.tud_msc_test_unit_ready_cb(0))

    def test_read_is_async_until_matching_checked_controller_data(self):
        self.publish()
        self.assertEqual(self.lib.fx_io(False, 13, 0, 512), -2)
        req = self.take()
        self.assertEqual(req[:3] + req[4:], ['X1', 'R', '77', '13', '0', '512'])
        self.lib.fx_poll(20)
        self.assertEqual(self.lib.fx_completions(), 0)
        self.send('D', 76, req[3], '5a' * 512)
        self.lib.fx_poll(0)
        self.assertEqual(self.lib.fx_completions(), 0)
        self.send('D', 77, req[3], '5a' * 511)
        self.lib.fx_poll(0)
        self.assertEqual(self.lib.fx_completions(), 0)
        self.send('D', 77, req[3], '5a' * 512)
        self.lib.fx_poll(0)
        self.lib.fx_drain()
        self.assertEqual(self.lib.fx_result(), 512)
        self.assertEqual(bytes(self.lib.fx_data()[:512]), b'Z' * 512)

    def test_write_never_completes_before_durable_host_ack(self):
        self.publish()
        self.lib.fx_buffer(0x91)
        self.assertEqual(self.lib.fx_io(True, 7, 17, 32), -2)
        req = self.take()
        self.assertEqual(req[:3] + req[4:], ['X1', 'W', '77', '7', '17', '91' * 32])
        self.lib.fx_poll(100)
        self.lib.fx_drain()
        self.assertEqual(self.lib.fx_completions(), 0)
        self.assertFalse(self.lib.fx_eject())
        self.assertEqual(self.lib.fx_flush(), -1)
        self.send('A', 77, req[3])
        self.lib.fx_poll(0)
        self.lib.fx_drain()
        self.assertEqual(self.lib.fx_result(), 32)
        self.assertEqual(self.lib.fx_flush(), 0)
        self.assertTrue(self.lib.fx_eject())
        self.assertEqual(self.take(), ['X1', 'S', '77', 'EJECTED'])
        self.assertEqual(self.lib.fx_io(True, 1, 0, 512), -1)

    def test_setup_publish_is_read_only_and_write_protected_without_uart_write(self):
        self.assertFalse(self.lib.tud_msc_is_writable_cb(0))
        self.send('I', 91, 32768)
        self.assertEqual(self.take(), ['X1', 'S', '91', 'PRESENT'])
        self.assertEqual(self.lib.fx_capacity(), 32768)
        self.assertFalse(self.lib.tud_msc_is_writable_cb(0))
        self.assertFalse(self.lib.tud_msc_test_unit_ready_cb(0))  # New medium attention.
        self.assertTrue(self.lib.tud_msc_test_unit_ready_cb(0))
        self.assertEqual(self.lib.fx_io(True, 1, 0, 512), -1)
        self.assertEqual(self.lib.fx_sense(), 0x0727)
        self.assertIsNone(self.take(), 'Read-only setup must never ask the host to write a block')
        self.assertEqual(self.lib.fx_io(False, 2, 0, 512), -2)
        request = self.take()
        self.assertEqual(request[:3], ['X1', 'R', '91'])
        self.send('D', 91, request[3], '5a' * 512)
        self.lib.fx_poll(0); self.lib.fx_drain()
        self.assertEqual(self.lib.fx_result(), 512)
        self.assertEqual(bytes(self.lib.fx_data()[:512]), b'Z' * 512)
        self.assertEqual(self.lib.fx_flush(), 0)

    def test_setup_and_exchange_cannot_change_live_media_mode(self):
        self.send('I', 91, 32768)
        self.assertEqual(self.take(), ['X1', 'S', '91', 'PRESENT'])
        self.send('I', 91, 32768)
        self.assertEqual(self.take(), ['X1', 'S', '91', 'PRESENT'])
        self.send('P', 91, 32768)
        self.assertEqual(self.take(), ['X1', 'S', '91', 'BUSY'])
        self.assertFalse(self.lib.tud_msc_is_writable_cb(0))
        self.send('O', 91)
        self.assertEqual(self.take(), ['X1', 'S', '91', 'ABSENT'])
        self.assertEqual(self.lib.fx_capacity(), 0)
        self.assertFalse(self.lib.tud_msc_test_unit_ready_cb(0))
        self.publish(92)
        self.assertTrue(self.lib.tud_msc_is_writable_cb(0))
        self.send('I', 92, 32768)
        self.assertEqual(self.take(), ['X1', 'S', '92', 'BUSY'])
        self.assertTrue(self.lib.tud_msc_is_writable_cb(0))

    def test_setup_lease_expiry_and_detach_cannot_revive_old_generation(self):
        self.send('I', 91, 32768)
        self.assertEqual(self.take(), ['X1', 'S', '91', 'PRESENT'])
        self.lib.fx_poll(3000)
        self.assertEqual(self.take(), ['X1', 'S', '91', 'OFFLINE'])
        self.assertEqual(self.lib.fx_capacity(), 0)
        self.send('I', 91, 32768)
        self.assertEqual(self.take(), ['X1', 'S', '91', 'ERROR'])
        self.send('I', 92, 32768)
        self.assertEqual(self.take(), ['X1', 'S', '92', 'PRESENT'])
        self.lib.wk_exchange_usb_ready(False)
        self.assertEqual(self.take(), ['X1', 'S', '92', 'OFFLINE'])
        self.lib.wk_exchange_usb_ready(True)
        self.send('I', 92, 32768)
        self.assertEqual(self.take(), ['X1', 'S', '92', 'ERROR'])
        self.assertEqual(self.lib.fx_capacity(), 0)

    def test_crc_reject_and_wk1_input_coexist_without_parser_corruption(self):
        bad = bytearray(self.frame('P', 77, 32768))
        bad[7] ^= 1
        self.lib.fx_feed(bytes(bad), len(bad))
        self.assertEqual(self.lib.fx_capacity(), 0)
        # Known CRC8 from the existing production protocol helper.
        body = b'WK1,14,Q,0,0'
        crc = 0
        for value in body:
            crc ^= value
            for _ in range(8):
                crc = ((crc << 1) ^ (7 if crc & 128 else 0)) & 255
        frame = body + f',{crc:02X}\n'.encode()
        mixed = self.frame('P', 77, 32768) + frame + self.frame('Q', 0)
        self.lib.fx_feed(mixed, len(mixed))
        self.assertIn(b'ACK,14\n', self.lib.wk_fixture_uart())
        self.assertEqual(self.lib.fx_capacity(), 32768)
        self.assertEqual(self.lib.fx_io(False, 1, 0, 512), -2)
        # A pending disk operation must not occupy the UART event state machine.
        self.lib.wk_fixture_clear_output()
        self.lib.fx_feed(frame, len(frame))
        self.assertEqual(self.lib.wk_fixture_uart(), b'ACK,14\n')
        self.assertEqual(self.lib.fx_completions(), 0)

    def test_bounds_and_short_block_contract(self):
        self.publish()
        for lba, offset, size in [(32768, 0, 512), (1, 512, 1), (1, 511, 2),
                                  (1, 0, 513), (1, 0, 0)]:
            self.assertEqual(self.lib.fx_io(False, lba, offset, size), -1)
        self.assertIsNone(self.take())

    def test_timeout_fault_removes_media_and_late_answer_is_not_success(self):
        self.publish()
        self.assertEqual(self.lib.fx_io(True, 1, 0, 512), -2)
        req = self.take()
        self.lib.fx_poll(2000)
        self.send('H', 77)
        self.lib.fx_poll(1000)  # Lease is fresh; the individual I/O timed out.
        self.lib.fx_drain()
        self.assertEqual(self.lib.fx_result(), -1)
        self.assertEqual(self.lib.fx_capacity(), 0)
        self.send('A', 77, req[3])
        self.lib.fx_poll(0)
        self.lib.fx_drain()
        self.assertEqual(self.lib.fx_completions(), 1)
        self.send('P', 77, 32768)
        self.assertEqual(self.take(), ['X1', 'S', '77', 'ERROR'])
        self.assertEqual(self.take(), ['X1', 'S', '77', 'ERROR'])

    def test_host_storage_failure_is_not_reported_as_successful_write(self):
        self.publish()
        self.assertEqual(self.lib.fx_io(True, 2, 0, 512), -2)
        request = self.take()
        self.send('F', 77, request[3])
        self.lib.fx_poll(0)
        self.lib.fx_drain()
        self.assertEqual(self.lib.fx_result(), -1)
        self.assertEqual(self.lib.fx_capacity(), 0)
        self.assertEqual(self.take(), ['X1', 'S', '77', 'ERROR'])

    def test_lease_refresh_then_disconnect_retires_generation(self):
        self.publish()
        self.lib.fx_poll(2000)
        self.send('H', 77)
        self.lib.fx_poll(2000)
        self.assertEqual(self.lib.fx_capacity(), 32768)
        self.lib.wk_exchange_usb_ready(False)
        self.assertEqual(self.take(), ['X1', 'S', '77', 'OFFLINE'])
        self.lib.wk_exchange_usb_ready(True)
        self.send('P', 77, 32768)
        self.assertEqual(self.take(), ['X1', 'S', '77', 'ERROR'])
        self.publish(78)

    def test_old_async_completion_cannot_complete_read_after_usb_reset(self):
        self.publish()
        self.assertEqual(self.lib.fx_io(False, 1, 0, 512), -2)
        req = self.take()
        self.send('D', 77, req[3], 'a1' * 512)
        self.lib.fx_poll(0)  # Old completion queued, not executed.
        self.lib.fx_usb_reset()
        # New command racing ahead of the old completion must not be pending.
        self.assertEqual(self.lib.fx_io(False, 2, 0, 512), 0)
        self.lib.fx_drain()
        self.assertEqual(self.lib.fx_completions(), 0)
        self.assertEqual(self.take(), ['X1', 'S', '77', 'OFFLINE'])
        self.publish(78)
        self.assertEqual(self.lib.fx_io(False, 2, 0, 512), -2)
        newer = self.take()
        self.assertNotEqual(req[3], newer[3])
        self.send('D', 77, req[3], 'a2' * 512)
        self.lib.fx_poll(0)
        self.assertEqual(self.lib.fx_completions(), 0)
        self.send('D', 78, newer[3], 'b3' * 512)
        self.lib.fx_poll(0)
        self.lib.fx_drain()
        self.assertEqual(self.lib.fx_completions(), 1)
        self.assertEqual(bytes(self.lib.fx_data()[:512]), bytes([0xb3]) * 512)

    def test_withdraw_is_absent_not_clean_eject_and_busy_publish_is_refused(self):
        self.publish()
        self.send('P', 78, 32768)
        self.assertEqual(self.take(), ['X1', 'S', '78', 'BUSY'])
        self.send('O', 0)
        self.assertEqual(self.take(), ['X1', 'S', '77', 'ABSENT'])
        self.assertEqual(self.lib.fx_capacity(), 0)
        self.publish(78)

    def test_malformed_and_overlong_lines_do_not_disable_following_query(self):
        raw = b'X' * 1500 + b'\n'
        self.lib.fx_feed(raw, len(raw))
        self.send('P', 2**32, 100)
        self.send('Q', 0)
        self.assertEqual(self.take(), ['X1', 'S', '0', 'ABSENT'])


if __name__ == '__main__':
    unittest.main()
