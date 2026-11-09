"""Exchange-disk safety tests using the production Swift helper, without GUI/USB.

The default tests only use ordinary files and a private fake IPC socket. Set
WK_EXCHANGE_LOCAL_DISK_TEST=1 to include mounting an agent-created temporary
image on this Mac. Those tests never open a serial port or touch a target Mac.
"""
from __future__ import annotations

import hashlib
import json
import os
import plistlib
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CAPACITY = 256 * 1024 * 1024
HARNESS = r'''
import Foundation
import Darwin

@main struct ExchangeHarness {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            switch args[0] {
            case "self-test": try WKExchangeDisk.selfTest()
            case "ensure":
                try WKExchangeDisk(directory: URL(fileURLWithPath: args[1])).ensureImage()
                print("IMAGE_READY")
            case "attachment":
                let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
                let result = try WKExchangeDisk.attachment(in: data, image: URL(fileURLWithPath: args[2]))
                let fields: [String: String] = ["device": result?.device ?? "", "mount": result?.mount?.path ?? ""]
                print(String(data: try JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!)
            case "new-device":
                let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
                print(try WKExchangeDisk.newlyAttachedDevice(data))
            case "request":
                let disk = WKExchangeDisk(socketURL: URL(fileURLWithPath: args[1]))
                let reply = try disk.request(args[2], timeout: 1)
                print("\(reply.state)|\(reply.bytes)|\(reply.detail)")
            case "process":
                let output = try WKExchangeDisk.run(args[2], Array(args.dropFirst(3)), timeout: Double(args[1])!)
                FileHandle.standardOutput.write(output)
            case "open", "publish":
                let disk = WKExchangeDisk(directory: URL(fileURLWithPath: args[1]), socketURL: URL(fileURLWithPath: args[2]))
                if args[0] == "open" { print(try disk.openOnBook().path) }
                else { let reply = try disk.publishToMini(); print(reply.state) }
            default: throw WKExchangeError(message: "Unknown harness action")
            }
        } catch {
            fputs("EXCHANGE_TEST_ERROR: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
'''


class FakeController:
    """One command per connection; records whether a publication was attempted."""

    def __init__(self, path: Path, chunks=(), delay=0, close=True):
        self.path = path
        self.chunks = chunks
        self.delay = delay
        self.close = close
        self.commands = []
        self.errors = []
        self.stop = threading.Event()
        self.server = socket.socket(socket.AF_UNIX)
        try:
            self.server.bind(str(path))
            self.server.listen()
        except Exception:
            self.server.close()
            path.unlink(missing_ok=True)
            raise
        self.server.settimeout(0.1)
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        while not self.stop.is_set():
            try:
                client, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with client:
                try:
                    client.settimeout(2)
                    data = b""
                    while b"\n" not in data:
                        part = client.recv(64)
                        if not part:
                            break
                        data += part
                    self.commands.append(data)
                    for chunk in self.chunks:
                        if self.delay:
                            time.sleep(self.delay)
                        client.sendall(chunk)
                    if not self.close:
                        self.stop.wait(2)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                except Exception as error:
                    self.errors.append(error)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.server.close()
        self.thread.join(timeout=3)
        self.path.unlink(missing_ok=True)


@unittest.skipUnless(sys.platform == "darwin", "macOS Swift disk helper")
class ExchangeGUIHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="wk-exchange-swift-", dir="/private/tmp")
        root = Path(cls.build.name)
        harness = root / "Harness.swift"
        harness.write_text(HARNESS)
        cls.binary = root / "exchange-test"
        compiled = subprocess.run([
            "/usr/bin/swiftc", "-parse-as-library", "-module-cache-path", str(root / "cache"),
            str(ROOT / "host/gui/WiredKVMExchange.swift"), str(harness), "-o", str(cls.binary),
        ], capture_output=True, text=True, timeout=90)
        if compiled.returncode:
            cls.build.cleanup()
            raise RuntimeError(compiled.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.sandbox = tempfile.TemporaryDirectory(prefix="wk-exchange-test-", dir="/private/tmp")
        self.directory = Path(self.sandbox.name)
        self.sock = self.directory / "ipc.sock"

    def tearDown(self):
        self.sandbox.cleanup()

    def run_helper(self, *args, success=True, timeout=8):
        result = subprocess.run([str(self.binary), *map(str, args)],
                                capture_output=True, text=True, timeout=timeout)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("EXCHANGE_TEST_ERROR", result.stderr)
        return result

    def write_image(self, size=CAPACITY):
        image = self.directory / "exchange.img"
        with image.open("xb") as file:
            file.write(b"OWNED-EXISTING-IMAGE-SENTINEL")
            file.truncate(size)
        return image

    def attachment(self, plist, image, success=True):
        path = self.directory / "status.plist"
        path.write_bytes(plistlib.dumps(plist))
        result = self.run_helper("attachment", path, image, success=success)
        return json.loads(result.stdout) if success else result

    def test_production_self_test(self):
        self.assertIn("GUI_EXCHANGE_SELF_TEST_PASS", self.run_helper("self-test").stdout)

    def test_process_drains_large_stderr_without_blocking_stdout(self):
        script = "import os; os.write(2, b'E' * (2 * 1024 * 1024)); os.write(1, b'OUTPUT_COMPLETE\\n')"
        result = self.run_helper("process", "3", sys.executable, "-c", script, timeout=5)
        self.assertEqual(result.stdout, "OUTPUT_COMPLETE\n")

    def test_process_reports_error_tail_after_large_stderr(self):
        script = "import os; os.write(2, b'E' * (2 * 1024 * 1024) + b'FINAL_ERROR_DETAIL'); raise SystemExit(17)"
        result = self.run_helper("process", "3", sys.executable, "-c", script,
                                 success=False, timeout=5)
        self.assertIn("FINAL_ERROR_DETAIL", result.stderr)
        self.assertLess(len(result.stderr), 1000)

    def test_process_timeout_kills_its_term_ignoring_child(self):
        pid_file = self.directory / "owned-child.pid"
        keep = self.directory / "exchange.img"
        keep.write_bytes(b"KEEP_EXISTING_IMAGE")
        script = (
            "import os, signal, pathlib, time; "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "pathlib.Path(os.environ['WK_TEST_PID_FILE']).write_text(str(os.getpid())); "
            "time.sleep(10)"
        )
        environment = dict(os.environ, WK_TEST_PID_FILE=str(pid_file))
        started = time.monotonic()
        result = subprocess.run([str(self.binary), "process", "0.5", sys.executable, "-c", script],
                                env=environment, capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("超时", result.stderr)
        self.assertLess(time.monotonic() - started, 3)
        self.assertTrue(pid_file.exists(), "child must install its SIGTERM handler before timeout")
        pid = int(pid_file.read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        self.assertEqual(keep.read_bytes(), b"KEEP_EXISTING_IMAGE")

    def test_attachment_selects_exact_image_root_device(self):
        image = self.directory / "exchange.img"
        entries = {"images": [
            {"image-path": str(self.directory / "unrelated.img"),
             "system-entities": [{"dev-entry": "/dev/disk0"}]},
            {"image-path": str(image), "system-entities": [
                {"dev-entry": "/dev/disk8"},
                {"dev-entry": "/dev/disk8s1", "mount-point": "/Volumes/WIREDKVM"}]},
        ]}
        self.assertEqual(self.attachment(entries, image),
                         {"device": "/dev/disk8", "mount": "/Volumes/WIREDKVM"})
        self.assertEqual(self.attachment(entries, self.directory / "missing.img"),
                         {"device": "", "mount": ""})

    def test_attachment_rejects_ambiguous_or_invalid_devices(self):
        image = self.directory / "exchange.img"
        entry = {"image-path": str(image), "system-entities": [{"dev-entry": "/dev/disk8"}]}
        self.attachment({"images": [entry, entry]}, image, success=False)
        for device in ("/dev/disk8s1", "/dev/rdisk8", "/dev/disk0;anything", "/tmp/disk8"):
            with self.subTest(device=device):
                self.attachment({"images": [{"image-path": str(image),
                                 "system-entities": [{"dev-entry": device}]}]}, image, success=False)
        self.attachment({"unexpected": []}, image, success=False)

    def test_new_image_receipt_requires_one_unmounted_whole_device(self):
        path = self.directory / "attach.plist"
        path.write_bytes(plistlib.dumps({"system-entities": [{"dev-entry": "/dev/disk8"}]}))
        self.assertEqual(self.run_helper("new-device", path).stdout.strip(), "/dev/disk8")
        for entities in (
            [],
            [{"dev-entry": "/dev/disk8s1"}],
            [{"dev-entry": "/dev/disk8", "mount-point": "/Volumes/USER_DATA"}],
            [{"dev-entry": "/dev/disk8"}, {"dev-entry": "/dev/disk9"}],
        ):
            with self.subTest(entities=entities):
                path.write_bytes(plistlib.dumps({"system-entities": entities}))
                self.run_helper("new-device", path, success=False)

    def test_existing_image_is_never_reformatted(self):
        image = self.write_image()
        before = (image.stat().st_ino, image.stat().st_size, image.stat().st_mtime_ns)
        self.run_helper("ensure", self.directory)
        after = (image.stat().st_ino, image.stat().st_size, image.stat().st_mtime_ns)
        self.assertEqual(before, after)
        with image.open("rb") as file:
            marker = b"OWNED-EXISTING-IMAGE-SENTINEL"
            self.assertEqual(file.read(len(marker)), marker)

    def test_wrong_size_image_is_preserved(self):
        image = self.write_image(1024)
        original = image.read_bytes()
        self.run_helper("ensure", self.directory, success=False)
        self.assertEqual(image.read_bytes(), original)

    def test_image_symlink_and_directory_symlink_are_refused(self):
        target = self.directory / "keep.txt"
        target.write_text("USER DATA MUST SURVIVE")
        (self.directory / "exchange.img").symlink_to(target)
        self.run_helper("ensure", self.directory, success=False)
        self.assertEqual(target.read_text(), "USER DATA MUST SURVIVE")
        real = self.directory / "real"
        real.mkdir()
        alias = self.directory / "alias"
        alias.symlink_to(real, target_is_directory=True)
        self.run_helper("ensure", alias, success=False)
        self.assertEqual(list(real.iterdir()), [])

    def test_missing_remote_image_is_not_recreated(self):
        marker = self.directory / "exchange.img.remote_dirty"
        marker.write_text("remote data ownership")
        self.run_helper("ensure", self.directory, success=False)
        self.assertEqual(sorted(p.name for p in self.directory.iterdir()), [marker.name])

    def test_fragmented_ipc_reply_and_detail(self):
        with FakeController(self.sock, [b"OK EJE", b"CTED 268435456 clean", b"\n"], delay=0.01) as server:
            result = self.run_helper("request", self.sock, "STATUS")
            self.assertEqual(result.stdout.strip(), "EJECTED|268435456|clean")
            self.assertEqual(server.commands, [b"STATUS\n"])
            self.assertEqual(server.errors, [])

    def test_ipc_errors_close_and_oversize_are_rejected(self):
        for chunks in ([b"ERR REMOTE_DIRTY\n"], [b"NOPE\n"], [b"OK LOCAL"], [b"X" * 2500]):
            with self.subTest(chunks_length=sum(map(len, chunks))):
                with FakeController(self.sock, chunks):
                    self.run_helper("request", self.sock, "LOCAL", success=False)

    def test_ipc_timeout_is_bounded_and_unknown_command_not_sent(self):
        with FakeController(self.sock, [], close=False) as server:
            self.run_helper("request", self.sock, "DELETE", success=False)
            self.assertEqual(server.commands, [])
            started = time.monotonic()
            self.run_helper("request", self.sock, "STATUS", success=False, timeout=4)
            self.assertLess(time.monotonic() - started, 3)
            self.assertEqual(server.commands, [b"STATUS\n"])

    def test_remote_owner_rejection_cannot_create_or_mount_image(self):
        with FakeController(self.sock, [b"ERR REMOTE_DIRTY\n"]):
            self.run_helper("open", self.directory, self.sock, success=False)
        self.assertEqual(list(self.directory.iterdir()), [])

    @unittest.skipUnless(os.environ.get("WK_EXCHANGE_LOCAL_DISK_TEST") == "1",
                         "opt-in local disk-image integration, no USB")
    def test_local_image_roundtrip_and_busy_publish(self):
        image = self.directory / "exchange.img"
        mount = self.directory / "Book"

        def attachment():
            info = plistlib.loads(subprocess.check_output(["/usr/bin/hdiutil", "info", "-plist"]))
            owned = [i for i in info.get("images", []) if Path(i.get("image-path", "")).resolve() == image.resolve()]
            self.assertLessEqual(len(owned), 1)
            return owned[0] if owned else None

        def clean_detach():
            current = attachment()
            if current:
                devices = [e["dev-entry"] for e in current["system-entities"] if e.get("dev-entry")]
                self.assertEqual(len(devices), 1)
                subprocess.run(["/usr/bin/hdiutil", "detach", devices[0]], check=True,
                               capture_output=True, timeout=15)

        try:
            with FakeController(self.sock, [b"OK LOCAL 268435456\n"]):
                opened = self.run_helper("open", self.directory, self.sock, timeout=30)
            self.assertEqual(Path(opened.stdout.strip()), mount)
            self.assertEqual(image.stat().st_size, CAPACITY)
            sample = mount / "中文文件.bin"
            data = bytes(range(256)) * 1024
            sample.write_bytes(data)
            expected = hashlib.sha256(data).hexdigest()
            with sample.open("rb"), FakeController(self.sock, [b"OK REMOTE 268435456\n"]) as server:
                self.run_helper("publish", self.directory, self.sock, success=False, timeout=15)
                self.assertEqual(server.commands, [], "busy local disk must not publish")
                self.assertIsNotNone(attachment())
            with FakeController(self.sock, [b"OK REMOTE 268435456\n"]) as server:
                self.run_helper("publish", self.directory, self.sock, timeout=15)
                self.assertEqual(server.commands, [b"PUBLISH\n"])
                self.assertIsNone(attachment())
            with FakeController(self.sock, [b"OK LOCAL 268435456\n"]):
                self.run_helper("open", self.directory, self.sock, timeout=15)
            self.assertEqual(hashlib.sha256(sample.read_bytes()).hexdigest(), expected)
        finally:
            clean_detach()


if __name__ == "__main__":
    unittest.main()
