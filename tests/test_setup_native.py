"""Read-only setup media over synthetic UART; never mounts an image or opens HID."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zlib

if __package__:
    from .test_clipboard_native import CLIENT, Session, wait_for
else:
    from test_clipboard_native import CLIENT, Session, wait_for


class SetupMediaNativeTests(unittest.TestCase):
    def test_flash_publish_binds_exact_image_and_never_relays_storage_bytes(self):
        with tempfile.TemporaryDirectory(prefix="wk-flash-setup-", dir="/tmp") as directory:
            with Session(directory, setup=True, setup_flash=True, publish_busy=1) as s:
                self.assertTrue(s.exchange_command("PUBLISH").startswith("OK PUBLISHING"))
                self.assertTrue(wait_for(lambda: s.exchange_command("STATUS").startswith("OK REMOTE")))
                publications = [p for p, _ in s.frames if p[:2] == ["X1", "J"]]
                self.assertEqual(len(publications), 2)
                self.assertEqual(publications[0][3:5], ["2", str(zlib.crc32(b'a' * 1024))])
                self.assertEqual(publications[0], publications[1])
                s.send_exchange(f"X1,R,{s.generation},1,1,0,512")
                self.assertTrue(wait_for(lambda: any(p[:2] == ["X1", "F"] for p, _ in s.frames)))
                self.assertFalse(any(p[:2] == ["X1", "D"] for p, _ in s.frames))
                s.send_exchange(f"X1,T,{s.generation},4096")
                self.assertTrue(wait_for(lambda: s.exchange_command("STATUS2").split()[5] == "4096"))
                s.send_exchange(f"X1,T,{s.generation + 1},1")
                self.assertEqual(s.exchange_command("STATUS2").split()[5], "4096")
                self.assertTrue(s.exchange_command("LOCAL").startswith("OK LOCAL"))
                s.client.sendall(bytes(range(64)))
                self.assertTrue(wait_for(lambda: len(s.reports) == 2))
                self.assertIsNone(s.proc.poll())
                self.assertFalse(s.errors)

    def test_read_only_publish_read_reject_write_and_withdraw_keep_clipboard_running(self):
        with tempfile.TemporaryDirectory(prefix="wk-setup-", dir="/tmp") as directory:
            root = Path(directory)
            image = root / "setup.img"
            original = bytes(range(256)) * 4
            image.write_bytes(original)
            image.chmod(0o444)  # PUBLISH would fail if the native code requested O_RDWR.
            marker = root / "setup.img.remote_dirty"
            marker.symlink_to(root / "must-not-exist")
            marker_identity = marker.lstat()
            with Session(directory, setup=True, publish_busy=1) as s:
                self.assertTrue(s.exchange_command("PUBLISH").startswith("OK PUBLISHING"))
                self.assertTrue(wait_for(lambda: s.exchange_command("STATUS").startswith("OK REMOTE")))
                publications = [p for p, _ in s.frames if p[:2] == ["X1", "I"]]
                self.assertEqual(len(publications), 2)
                self.assertEqual(len({p[2] for p in publications}), 1)
                self.assertFalse(any(p[0] == "X1" and p[1] in ("O", "P") for p, _ in s.frames))
                generation = publications[0][2]
                s.send_exchange(f"X1,R,{generation},1,1,0,512")
                self.assertTrue(wait_for(lambda: any(p[:2] == ["X1", "D"] and p[3] == "1" for p, _ in s.frames)))
                received = next(bytes.fromhex(p[4]) for p, _ in s.frames if p[:2] == ["X1", "D"])
                self.assertEqual(received, original[512:])
                s.send_exchange(f"X1,W,{generation},2,0,0,ff")
                self.assertTrue(wait_for(lambda: any(p[:2] == ["X1", "F"] and p[3] == "2" for p, _ in s.frames)))
                self.assertFalse(any(p[:2] == ["X1", "A"] for p, _ in s.frames))
                status = s.exchange_command("STATUS2").split()
                self.assertEqual(status[4:9], ["0", "512", "0", "0", "0"])
                self.assertTrue(s.exchange_command("LOCAL").startswith("OK LOCAL"))
                withdrawal = next(p for p, _ in s.frames if p[:2] == ["X1", "O"])
                self.assertEqual(withdrawal[2], generation)
                s.client.sendall(bytes(range(64)))
                self.assertTrue(wait_for(lambda: len(s.reports) == 2))
                self.assertIsNone(s.proc.poll())
                self.assertFalse(s.errors)
            self.assertEqual(image.read_bytes(), original)
            self.assertEqual(image.stat().st_mode & 0o777, 0o444)
            self.assertEqual(marker.lstat().st_ino, marker_identity.st_ino)
            self.assertFalse((root / "must-not-exist").exists())

    def test_target_eject_and_shutdown_never_create_dirty_marker(self):
        with tempfile.TemporaryDirectory(prefix="wk-setup-", dir="/tmp") as directory:
            marker = Path(directory) / "setup.img.remote_dirty"
            with Session(directory, setup=True) as s:
                s.exchange_command("PUBLISH")
                self.assertTrue(wait_for(lambda: s.exchange_command("STATUS").startswith("OK REMOTE")))
                self.assertFalse(marker.exists())
                s.send_exchange(f"X1,S,{s.generation},EJECTED")
                self.assertTrue(wait_for(lambda: s.exchange_command("STATUS").startswith("OK EJECTED")))
                self.assertFalse(marker.exists())
            self.assertFalse(marker.exists())

    def test_never_withdraw_or_replace_unknown_existing_media(self):
        with tempfile.TemporaryDirectory(prefix="wk-setup-", dir="/tmp") as directory, Session(directory, setup=True, foreign_media=True) as s:
            self.assertEqual(s.exchange_command("PUBLISH").strip(), "ERR MEDIA_NOT_OWNED")
            self.assertEqual(s.exchange_command("LOCAL").strip(), "ERR MEDIA_NOT_OWNED")
            self.assertFalse(any(p[0] == "X1" and p[1] in ("O", "P", "I") for p, _ in s.frames))
            self.assertIsNone(s.proc.poll())

    def test_setup_cli_requires_absolute_pair_and_excludes_exchange(self):
        base = [str(CLIENT), "--transport", "/path-not-opened", "--source", "macos", "--target", "desktop"]
        for options in (["--setup-flash"], ["--setup-image", "/tmp/setup.img"],
                        ["--setup-image", "relative.img", "--setup-socket", "/tmp/setup.sock"],
                        ["--setup-image", "/tmp/setup.img", "--setup-socket", "/tmp/setup.sock",
                         "--exchange-image", "/tmp/exchange.img", "--exchange-socket", "/tmp/exchange.sock"]):
            with self.subTest(options=options):
                result = subprocess.run(base + options, capture_output=True, text=True, timeout=3)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("setup", result.stderr)
                self.assertNotIn("Cannot open", result.stderr)


if __name__ == "__main__":
    unittest.main()
