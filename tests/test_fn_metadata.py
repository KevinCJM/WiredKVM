"""Real firmware USB report path, with hardware mocked and no real input."""
import ctypes as ct
import struct
import zlib
import test_clipboard_channel_firmware as base


class FnMetadataTests(base.ClipboardChannelFirmwareTests):
    def setUp(self):
        super().setUp()
        self.lib.wk_usb_keyboard.argtypes = [ct.c_uint8, ct.POINTER(ct.c_uint8)]
        self.lib.wk_usb_keyboard.restype = ct.c_bool
        self.lib.fc_advance.argtypes = [ct.c_uint]
        self.lib.wk_fixture_use_usb_keyboard.argtypes = [ct.c_bool]

    def keyboard(self, modifiers, key=0):
        self.assertTrue(self.lib.wk_usb_keyboard(modifiers, (ct.c_uint8 * 6)(key, 0, 0, 0, 0, 0)))

    def metadata(self):
        self.lib.wk_usb_clipboard_poll()
        data = bytes(self.lib.fc_usb_report()[:64])
        self.assertEqual(data[:5], b'WKFN\x01')
        self.assertEqual(zlib.crc32(data[:60]), struct.unpack_from('<I', data, 60)[0])
        return data

    def test_short_fn_preserves_press_and_release_metadata(self):
        self.keyboard(16)
        down = self.metadata()
        self.assertEqual(down[5:7], b'\x01\x01')
        self.lib.fc_advance(80)
        self.keyboard(0)
        up = self.metadata()
        self.assertEqual(up[5:7], b'\x02\x01')
        self.assertEqual(up[8:16], down[8:16])
        self.assertEqual(struct.unpack_from('<I', up, 24)[0], 80)

    def test_fn_chord_remains_ineligible_after_regular_key_release(self):
        self.keyboard(16); self.metadata()
        self.keyboard(16, 4); self.keyboard(16)
        self.lib.fc_advance(80); self.keyboard(0)
        self.assertEqual(self.metadata()[6], 0)

    def test_other_modifiers_prevent_tap(self):
        self.keyboard(18)
        self.assertEqual(self.metadata()[6], 0)

    def test_remote_release_cancels_queued_tap(self):
        self.lib.wk_fixture_use_usb_keyboard(True)
        self.keyboard(16); self.metadata()
        self.lib.fc_advance(80); self.keyboard(0)
        self.lib.wk_usb_cancel_fn_tap()
        self.assertEqual(self.metadata()[5], 3)

    def test_vendor_backpressure_cannot_block_keyboard(self):
        self.lib.wk_fixture_interface_ready(2, False)
        self.keyboard(16); self.lib.fc_advance(80); self.keyboard(0)
        self.assertEqual(self.lib.fc_usb_reports(), 2) # Globe down/up use instance 0.
        self.lib.wk_fixture_interface_ready(2, True)
        self.assertEqual(self.metadata()[5], 1)
        self.assertEqual(self.metadata()[5], 2)

    def test_expired_reports_cancel_instead_of_triggering_late(self):
        self.keyboard(16); self.lib.fc_advance(600)
        self.assertEqual(self.metadata()[5], 3)

    def test_usb_epoch_discards_old_reports(self):
        self.keyboard(16); down = self.metadata()
        self.lib.fc_detach(); self.lib.fc_attach()
        self.keyboard(16); new = self.metadata()
        self.assertNotEqual(new[8:12], down[8:12])
