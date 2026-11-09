"""Real flash validator and composite MSC callbacks, with a synthetic partition."""
import ctypes as ct
import importlib.util
from pathlib import Path
import struct
import unittest
import zlib

if __package__:
    from . import test_clipboard_channel_firmware as base
else:
    import test_clipboard_channel_firmware as base

spec = importlib.util.spec_from_file_location('pack_flash_setup', base.ROOT / 'scripts/pack_flash_setup.py')
packer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packer)


class FlashSetupTests(base.ClipboardChannelFirmwareTests):
    # All existing HID, descriptor and clipboard regression tests also run with
    # the flash backend compiled in, including when its image is missing.
    FLASH_SETUP = True

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.lib.fs_configure.argtypes = [ct.c_void_p, ct.c_uint]
        cls.lib.fs_fail_read.argtypes = [ct.c_bool]
        cls.lib.fs_partition_size.argtypes = [ct.c_uint]
        cls.lib.wk_flash_setup_matches.argtypes = [ct.c_uint32, ct.c_uint32]
        cls.lib.wk_flash_setup_matches.restype = ct.c_bool
        cls.lib.wk_flash_setup_read.argtypes = [ct.c_uint32, ct.c_void_p, ct.c_uint32]
        cls.lib.wk_flash_setup_read.restype = ct.c_bool
        cls.lib.tud_msc_read10_cb.argtypes = [ct.c_uint8, ct.c_uint32, ct.c_uint32, ct.c_void_p, ct.c_uint32]
        cls.lib.tud_msc_write10_cb.argtypes = cls.lib.tud_msc_read10_cb.argtypes
        cls.lib.tud_msc_test_unit_ready_cb.argtypes = [ct.c_uint8]
        cls.lib.tud_msc_test_unit_ready_cb.restype = ct.c_bool

    def setUp(self):
        super().setUp()
        self.lib.fs_configure(None, 0)
        self.lib.wk_flash_setup_init()
        self.image = bytes(range(256)) * 20
        self.crc = zlib.crc32(self.image)

    def load(self, asset=None):
        data = packer.pack(self.image) if asset is None else asset
        self.lib.fs_configure(data, len(data))
        self.lib.wk_flash_setup_init()
        self.lib.fs_validate()

    def send_x(self, *fields):
        body = ','.join(map(str, ('X1', *fields))).encode()
        self.feed(body + f',{zlib.crc32(body):08x}\n'.encode())

    def publish(self):
        self.send_x('J', 77, len(self.image) // 512, self.crc)
        self.assertIn(b',77,PRESENT,', self.lib.fc_exchange_tx())
        # First Test Unit Ready reports the normal media-change unit attention.
        self.lib.tud_msc_test_unit_ready_cb(0)
        self.assertTrue(self.lib.tud_msc_test_unit_ready_cb(0))

    def test_validated_flash_reads_without_uart_and_preserves_hid(self):
        self.load()
        self.assertTrue(self.lib.wk_flash_setup_matches(10, self.crc))
        self.assertEqual(self.lib.fs_yields(), 2)
        self.publish()
        out = ct.create_string_buffer(512)
        self.assertEqual(self.lib.tud_msc_read10_cb(0, 3, 0, out, 512), 512)
        self.assertEqual(out.raw, self.image[1536:2048])
        self.assertEqual(self.lib.fc_exchange_tx(), b'')  # no X1 read request
        self.feed(self.wk_frame(sequence=61))
        self.assertIn(b'ACK,61\n', self.lib.wk_fixture_uart())
        self.assertEqual(self.lib.tud_msc_write10_cb(0, 0, 0, out, 512), -1)
        self.assertEqual(self.lib.fc_exchange_tx(), b'')  # no write request
        self.assertFalse(self.lib.wk_flash_setup_matches(10, self.crc ^ 1))
        self.assertFalse(self.lib.wk_flash_setup_matches(11, self.crc))
        self.lib.vTaskDelay(50)  # 500 ms, metadata rate limit.
        self.assertIn(b'X1,T,77,512,', self.lib.fc_exchange_tx())
        self.assertEqual(self.lib.fc_exchange_tx(), b'')

    def test_image_validation_is_deferred_and_failure_keeps_hid(self):
        data = packer.pack(self.image)
        self.lib.fs_configure(data, len(data))
        self.lib.wk_flash_setup_init()
        self.assertEqual(self.lib.fs_reads(), 0)
        self.assertFalse(self.lib.wk_flash_setup_matches(10, self.crc))
        self.send_x('J', 1, 10, self.crc)
        self.assertIn(b',ERROR,', self.lib.fc_exchange_tx())
        self.feed(self.wk_frame(sequence=62))
        self.assertIn(b'ACK,62\n', self.lib.wk_fixture_uart())
        self.lib.fs_validate()
        self.assertTrue(self.lib.wk_flash_setup_matches(10, self.crc))

    def test_corrupt_missing_truncated_and_oversize_images_never_publish(self):
        good = packer.pack(self.image)
        cases = [b'', good[:23], good[:-1]]
        for offset in (0, 8, 12, 16, 20, 4096, len(good) - 1):
            damaged = bytearray(good); damaged[offset] ^= 1; cases.append(bytes(damaged))
        # Header CRC is correct but image length overflows partition capacity.
        header = struct.pack('<8sIII', b'WKSETUP1', 1, 0xfffffe00, self.crc)
        cases.append(header + struct.pack('<I', zlib.crc32(header)) + good[24:])
        for asset in cases:
            with self.subTest(size=len(asset), prefix=asset[:8]):
                self.load(asset)
                self.assertFalse(self.lib.wk_flash_setup_matches(10, self.crc))
                self.send_x('J', 77, 10, self.crc)
                self.assertIn(b',ERROR,', self.lib.fc_exchange_tx())
        for bad in (b'', b'a' * 513, b'a' * (packer.PARTITION_BYTES - 4096 + 512)):
            with self.assertRaises(ValueError):
                packer.pack(bad)

    def test_wrong_image_binding_and_out_of_range_reads_fail_closed(self):
        self.load()
        for blocks, crc in ((11, self.crc), (10, self.crc ^ 1)):
            self.send_x('J', 77, blocks, crc)
            self.assertIn(b',ERROR,', self.lib.fc_exchange_tx())
        self.publish()
        out = ct.create_string_buffer(512)
        for lun, lba, offset, length in ((1,0,0,1),(0,10,0,1),(0,0,512,1),(0,0,511,2),(0,0,0,0),(0,0,0,513),(0,0xffffffff,0,1)):
            self.assertEqual(self.lib.tud_msc_read10_cb(lun,lba,offset,out,length), -1)
        self.assertFalse(self.lib.wk_flash_setup_read(0xffffffff, out, 512))
        self.assertFalse(self.lib.wk_flash_setup_read(5120, out, 1))
        self.lib.fs_fail_read(True)
        self.assertEqual(self.lib.tud_msc_read10_cb(0,0,0,out,512), -1)

    def test_detach_during_flash_read_rejects_completion_and_retired_media(self):
        self.load(); self.publish()
        out = ct.create_string_buffer(512)
        self.lib.fs_detach_on_read()
        self.assertEqual(self.lib.tud_msc_read10_cb(0,0,0,out,512), -1)
        self.assertFalse(self.lib.tud_msc_test_unit_ready_cb(0))
        self.lib.fc_attach()
        self.assertFalse(self.lib.tud_msc_test_unit_ready_cb(0))

    def test_withdraw_and_eject_cannot_leave_readable_flash_media(self):
        self.load(); self.publish()
        self.send_x('O', 77)
        self.assertIn(b',ABSENT,', self.lib.fc_exchange_tx())
        out = ct.create_string_buffer(512)
        self.assertEqual(self.lib.tud_msc_read10_cb(0,0,0,out,512), -1)
        self.send_x('J', 77, 10, self.crc)
        self.assertIn(b',ERROR,', self.lib.fc_exchange_tx())


if __name__ == '__main__':
    unittest.main()
