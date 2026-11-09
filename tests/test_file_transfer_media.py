"""Production Swift staging/FAT observer tests; no devices, mounts or clipboard."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def finder_info(flags=0, file_type=b"\0" * 4):
    result = bytearray(32)
    result[:4] = file_type
    struct.pack_into(">H", result, 24, flags)
    return bytes(result)


def apple_double(info=None, attributes=False, attribute_padding=0):
    """Current macOS v2 FinderInfo/resource entries, including empty resource fork."""
    info = finder_info() if info is None else info
    finder_offset = 50
    payload = info
    if attributes:
        name = b"com.wiredkvm.test\0"
        entry_size = (11 + len(name) + 3) & ~3
        data_start = finder_offset + 34 + 36 + entry_size
        value = b"safe"
        header = struct.pack(">IIIIIIIIHH", 0x41545452, 0, data_start + len(value) + attribute_padding,
                             data_start, len(value), 0, 0, 0, 0, 1)
        entry = struct.pack(">IIHB", data_start, len(value), 0, len(name)) + name
        payload += b"\0\0" + header + entry.ljust(entry_size, b"\0") + value + b"\0" * attribute_padding
    resource_offset = finder_offset + len(payload)
    return (struct.pack(">II16sH", 0x00051607, 0x00020000, b"Mac OS X        ", 2)
            + struct.pack(">III", 9, finder_offset, len(payload))
            + struct.pack(">III", 2, resource_offset, 0) + payload)


HARNESS = r'''
import Foundation
import Darwin
@main struct MediaHarness {
    static func main() {
        do {
            let a = Array(CommandLine.arguments.dropFirst())
            switch a[0] {
            case "job":
                let job = try WKTransferMedia.makeJob(root: URL(fileURLWithPath: a[1]), id: a[2],
                    outbound: a.count > 3 ? URL(fileURLWithPath: a[3]) : nil)
                print(job.directory.path)
            case "stage":
                let file = try WKTransferMedia.stageSingleFile(from: URL(fileURLWithPath: a[1]),
                                            toDirectory: URL(fileURLWithPath: a[2]))
                print("\(file.byteCount)|\(file.sha256)|\(file.name)")
            case "inspect":
                let file = try WKTransferMedia.inspectFile(at: URL(fileURLWithPath: a[1]))
                print("\(file.byteCount)|\(file.sha256)|\(file.name)")
            case "validate":
                print(try WKTransferMedia.validateSingleFile(at: URL(fileURLWithPath: a[1])).lastPathComponent)
            case "fat":
                let view = try WKFAT16View(image: URL(fileURLWithPath: a[1]))
                print(try view.exists(directoryComponents: Array(a.dropFirst(2))) ? "YES" : "NO")
            case "local-disk":
                let directory = URL(fileURLWithPath: a[1]).resolvingSymlinksInPath()
                let temporaryRoot = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
                guard directory.deletingLastPathComponent().path == temporaryRoot.path,
                      directory.lastPathComponent.hasPrefix("wk-media-disk-"),
                      try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
                    throw WKTransferMediaError(message: "Integration requires a new private temporary directory")
                }
                let disk = WKExchangeDisk(directory: directory)
                try disk.ensureImage() // Production format/device identity guards.
                func attach() throws {
                    guard try WKExchangeDisk.currentAttachment(disk.imageURL) == nil else {
                        throw WKTransferMediaError(message: "Test image was already attached")
                    }
                    try FileManager.default.createDirectory(at: disk.mountURL, withIntermediateDirectories: true)
                    _ = try WKExchangeDisk.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-plist", "-imagekey",
                        "diskimage-class=CRawDiskImage", "-mountpoint", disk.mountURL.path, disk.imageURL.path])
                    guard let attachment = try WKExchangeDisk.currentAttachment(disk.imageURL),
                          attachment.mount?.resolvingSymlinksInPath() == disk.mountURL.resolvingSymlinksInPath() else {
                        throw WKTransferMediaError(message: "Mounted-image identity mismatch")
                    }
                }
                func detach() throws {
                    guard let attachment = try WKExchangeDisk.currentAttachment(disk.imageURL) else { return }
                    guard attachment.mount?.resolvingSymlinksInPath() == disk.mountURL.resolvingSymlinksInPath() else {
                        throw WKTransferMediaError(message: "Refusing to detach an unexpected mount")
                    }
                    _ = try WKExchangeDisk.run("/usr/bin/hdiutil", ["detach", attachment.device])
                    guard try WKExchangeDisk.currentAttachment(disk.imageURL) == nil else {
                        throw WKTransferMediaError(message: "Test image remained attached")
                    }
                }
                var phase = "attach"
                do {
                    try attach()
                    let source = directory.appendingPathComponent("中文文件.bin")
                    try Data((0..<65536).map { UInt8($0 % 251) }).write(to: source, options: .withoutOverwriting)
                    phase = "inspect local source"
                    let expected = try WKTransferMedia.inspectFile(at: source)
                    phase = "stage FAT payload"
                    let job = try WKTransferMedia.makeJob(root: disk.mountURL, id: "ABCDEF01", outbound: source)
                    guard let staged = job.source, staged.sha256 == expected.sha256 else {
                        throw WKTransferMediaError(message: "FAT staging hash mismatch")
                    }
                    func setAttribute(_ name: String, _ value: Data) throws {
                        let fd = open(staged.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                        guard fd >= 0 else { throw WKTransferMediaError(message: "Cannot open owned FAT fixture") }
                        defer { close(fd) }
                        guard value.withUnsafeBytes({ fsetxattr(fd, name, $0.baseAddress, $0.count, 0, 0) }) == 0 else {
                            throw WKTransferMediaError(message: "Cannot set owned FAT fixture metadata")
                        }
                    }
                    var finderInfo = Data(count: 32)
                    finderInfo[25] = 0x80
                    phase = "set busy FinderInfo"
                    try setAttribute("com.apple.FinderInfo", finderInfo)
                    var busyRejected = false
                    do { _ = try WKTransferMedia.validateSingleFile(at: job.payload) }
                    catch { busyRejected = true }
                    guard busyRejected else { throw WKTransferMediaError(message: "FAT busy flag was accepted") }
                    finderInfo[25] = 0; finderInfo[24] = 1 // Legitimate custom badge flag.
                    phase = "set valid FinderInfo and extended attribute"
                    try setAttribute("com.apple.FinderInfo", finderInfo)
                    try setAttribute("com.wiredkvm.test", Data("safe".utf8))
                    phase = "validate FAT metadata"
                    _ = try WKTransferMedia.validateSingleFile(at: job.payload)
                    var collisionRejected = false
                    do { _ = try WKTransferMedia.stageSingleFile(from: source, toDirectory: job.payload) }
                    catch { collisionRejected = true }
                    guard collisionRejected else { throw WKTransferMediaError(message: "Existing target overwritten") }
                    try FileManager.default.createDirectory(at: job.ready, withIntermediateDirectories: false)
                    phase = "detach and observe marker"
                    try detach()
                    let observer = try WKFAT16View(image: disk.imageURL)
                    guard try observer.exists(directoryComponents: ["WKJOB", "ABCDEF01", "READY"]),
                          try !observer.exists(directoryComponents: ["WKJOB", "ABCDEF01", "MISSING"]) else {
                        throw WKTransferMediaError(message: "Real FAT marker observation mismatch")
                    }
                    phase = "remount and validate metadata"
                    try attach()
                    let received = try WKTransferMedia.validateSingleFile(at: job.payload)
                    let readback = try WKTransferMedia.inspectFile(at: received)
                    guard readback.sha256 == expected.sha256, readback.name == "中文文件.bin" else {
                        throw WKTransferMediaError(message: "Remounted FAT hash/name mismatch")
                    }
                    try detach()
                    let result: [String: Any] = ["exclusiveRename": true, "unicodeName": readback.name,
                        "sha256": readback.sha256, "bytes": readback.byteCount,
                        "busyRejected": busyRejected, "metadataRoundTrip": true,
                        "markerAfterDetach": true, "detached": true]
                    print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
                } catch {
                    // Bounded diagnostics for this newly created fixture only.
                    let payload = disk.mountURL.appendingPathComponent("WKJOB/ABCDEF01/OUT/PAYLOAD")
                    if let bytes = try? Data(contentsOf: payload.appendingPathComponent("._中文文件.bin")) {
                        fputs("OWNED_APPLEDOUBLE bytes=\(bytes.count) prefix=\(bytes.prefix(192).map { String(format: "%02x", $0) }.joined())\n", stderr)
                    }
                    try? detach() // Only the verified, newly created test image.
                    throw WKTransferMediaError(message: "Local FAT \(phase): \(error.localizedDescription)")
                }
            default: throw WKTransferMediaError(message: "Unknown harness operation")
            }
        } catch {
            fputs("MEDIA_ERROR: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
'''


class FATFixture:
    total = 40000
    fat_sectors = 32
    data_sector = 97
    cluster_sectors = 8

    def __init__(self, path):
        self.path = path
        boot = bytearray(512)
        boot[:3] = b"\xeb\x3c\x90"
        struct.pack_into("<HBHBHHBHHHII", boot, 11, 512, 8, 1, 2, 512,
                         self.total, 0xF8, self.fat_sectors, 32, 64, 0, 0)
        boot[510:] = b"\x55\xaa"
        fat = bytearray(self.fat_sectors * 512)
        for index, value in enumerate([0xFFF8, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF]):
            struct.pack_into("<H", fat, index * 2, value)
        with path.open("wb") as stream:
            stream.truncate(self.total * 512)
            stream.write(boot)
            for sector in [1, 1 + self.fat_sectors]:
                stream.seek(sector * 512)
                stream.write(fat)
            stream.seek((1 + 2 * self.fat_sectors) * 512)
            stream.write(self.entry("WKJOB", 2))
            stream.seek(self.cluster_offset(2))
            stream.write(self.entry("ABCDEF01", 3))
            stream.seek(self.cluster_offset(3))
            stream.write(self.entry("READY", 4))

    def cluster_offset(self, cluster):
        return (self.data_sector + (cluster - 2) * self.cluster_sectors) * 512

    @staticmethod
    def entry(name, cluster):
        data = bytearray(32)
        data[:11] = name.encode().ljust(11)
        data[11] = 0x10
        struct.pack_into("<H", data, 26, cluster)
        return data

    def patch(self, offset, data):
        with self.path.open("r+b") as stream:
            stream.seek(offset)
            stream.write(data)

    def chain(self, cluster, value, both=True):
        for sector in ([1, 1 + self.fat_sectors] if both else [1]):
            self.patch(sector * 512 + cluster * 2, struct.pack("<H", value))


class TransferMediaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="wk-media-build-")
        harness = Path(cls.build.name) / "harness.swift"
        harness.write_text(HARNESS)
        cls.binary = Path(cls.build.name) / "media-test"
        result = subprocess.run(["/usr/bin/swiftc", "-O", "-parse-as-library",
                        "-module-cache-path", str(ROOT / "build/file-transfer-media-module-cache"),
                        str(ROOT / "host/gui/WiredKVMTransferMedia.swift"),
                        str(ROOT / "host/gui/WiredKVMExchange.swift"), str(harness),
                        "-o", str(cls.binary)], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wk-media-case-")
        self.directory = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def run_media(self, *args, okay=True):
        result = subprocess.run([str(self.binary), *map(str, args)],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode == 0, okay, result.stderr)
        return result.stdout.strip()

    def test_unicode_file_staged_verified_without_overwrite(self):
        source = self.directory / "测试文件.bin"
        data = bytes(range(256)) * 256
        source.write_bytes(data)
        output = self.directory / "out"
        output.mkdir()
        self.assertEqual(self.run_media("stage", source, output),
                         f"65536|{hashlib.sha256(data).hexdigest()}|测试文件.bin")
        self.run_media("stage", source, output, okay=False)
        self.assertEqual((output / source.name).read_bytes(), data)
        self.assertEqual(list(output.iterdir()), [output / source.name])

    def test_job_exclusive_paths_and_no_forged_ready(self):
        self.run_media("job", self.directory, "ABCDEF01")
        job = self.directory / "WKJOB/ABCDEF01"
        self.assertTrue((job / "IN").is_dir())
        self.assertTrue((job / "OUT/PAYLOAD").is_dir())
        self.assertFalse((job / "READY").exists())
        self.run_media("job", self.directory, "ABCDEF01", okay=False)
        self.run_media("job", self.directory, "../ABCDE", okay=False)

    def test_symlinks_directories_fifo_and_large_sources_rejected(self):
        target = self.directory / "file"
        target.write_bytes(b"hello")
        link = self.directory / "link"
        link.symlink_to(target)
        fifo = self.directory / "pipe"
        os.mkfifo(fifo)
        large = self.directory / "large"
        large.write_bytes(b"x" * 65537)
        for path in [link, self.directory, fifo, large]:
            self.run_media("inspect", path, okay=False)
        base = self.directory / "WKJOB"
        base.symlink_to(self.directory, target_is_directory=True)
        self.run_media("job", self.directory, "01234567", okay=False)

    def test_single_payload_empty_and_multiple_validation(self):
        self.run_media("validate", self.directory, okay=False)
        a = self.directory / "one.txt"
        a.write_bytes(b"hello")
        self.assertEqual(self.run_media("validate", self.directory), "one.txt")
        (self.directory / "two.txt").write_bytes(b"other")
        self.run_media("validate", self.directory, okay=False)

    def test_legitimate_dotfile_is_not_silently_filtered(self):
        (self.directory / ".env").write_bytes(b"sample")
        self.assertEqual(self.run_media("validate", self.directory), ".env")
        (self.directory / "file").write_bytes(b"x")
        self.run_media("validate", self.directory, okay=False)

    def test_known_partial_file_is_not_committed(self):
        (self.directory / "file.download").write_bytes(b"unfinished")
        self.run_media("validate", self.directory, okay=False)

    def test_metadata_requires_signature_and_matching_payload(self):
        (self.directory / "file").write_bytes(b"data")
        sidecar = self.directory / "._file"
        sidecar.write_bytes(b"bad")
        self.run_media("validate", self.directory, okay=False)
        sidecar.write_bytes(b"\x00\x05\x16\x07" + b"\0" * 22)
        self.run_media("validate", self.directory, okay=False)
        sidecar.write_bytes(apple_double())
        self.assertEqual(self.run_media("validate", self.directory), "file")
        (self.directory / ".DS_Store").write_bytes(b"bad")
        self.run_media("validate", self.directory, okay=False)
        (self.directory / ".DS_Store").write_bytes(b"\0\0\0\1Bud1")
        self.assertEqual(self.run_media("validate", self.directory), "file")

    def test_mounted_finder_busy_metadata_rejected_before_inspect_or_stage(self):
        incoming = self.directory / "incoming"
        incoming.mkdir()
        source = incoming / "file"
        source.write_bytes(b"payload")
        output = self.directory / "out"
        output.mkdir()
        for info in [finder_info(0x0080), finder_info(0x8000), finder_info(file_type=b"bzy "),
                     finder_info(file_type=b"bzy?")]:
            with self.subTest(info=info.hex()):
                subprocess.run(["/usr/bin/xattr", "-wx", "com.apple.FinderInfo", info.hex(), str(source)], check=True)
                self.run_media("inspect", source, okay=False)
                self.run_media("validate", incoming, okay=False)
                self.run_media("stage", source, output, okay=False)
                self.assertEqual(list(output.iterdir()), [])
        subprocess.run(["/usr/bin/xattr", "-wx", "com.apple.FinderInfo", finder_info(0x0100).hex(), str(source)], check=True)
        self.assertEqual(self.run_media("validate", incoming), "file")
        # A clear flag grants only structural validation, not copy completion.
        subprocess.run(["/usr/bin/xattr", "-d", "com.apple.FinderInfo", str(source)], check=True)
        self.assertEqual(self.run_media("validate", incoming), "file")

    def test_appledouble_busy_and_attribute_metadata(self):
        (self.directory / "file").write_bytes(b"payload")
        sidecar = self.directory / "._file"
        for attributes in [False, True]:
            sidecar.write_bytes(apple_double(finder_info(0x0100), attributes=attributes))
            self.assertEqual(self.run_media("validate", self.directory), "file")
            for info in [finder_info(0x0080), finder_info(0x8000), finder_info(file_type=b"bzy!")]:
                sidecar.write_bytes(apple_double(info, attributes=attributes))
                self.run_media("validate", self.directory, okay=False)
        sidecar.write_bytes(apple_double(finder_info(0x0100), attributes=True, attribute_padding=128))
        self.assertEqual(self.run_media("validate", self.directory), "file")

    def test_appledouble_malformed_entries_are_not_silently_filtered(self):
        (self.directory / "file").write_bytes(b"payload")
        sidecar = self.directory / "._file"
        valid = apple_double()
        mutations = [valid[:25], valid[:40], valid[:-1]]
        for offset, value in [(4, 0x10000), (26, 1), (30, 26), (34, 31),
                              (30, 0xFFFFFFFF), (34, 0xFFFFFFFF), (38, 9)]:
            damaged = bytearray(valid)
            struct.pack_into(">I", damaged, offset, value)
            mutations.append(damaged)
        overlap = bytearray(valid)
        struct.pack_into(">II", overlap, 42, 50, 1)
        mutations.append(overlap)
        no_finder = bytearray(valid)
        struct.pack_into(">I", no_finder, 26, 2)
        mutations.append(no_finder)
        for value in mutations:
            with self.subTest(value=bytes(value).hex()):
                sidecar.write_bytes(value)
                self.run_media("validate", self.directory, okay=False)

    def test_appledouble_attribute_bounds_names_and_lengths_are_checked(self):
        (self.directory / "file").write_bytes(b"payload")
        sidecar = self.directory / "._file"
        valid = apple_double(attributes=True)
        header, entry = 84, 120
        # Header bounds, payload overlap with the header, impossible lengths,
        # unsupported extension, and an unterminated attribute name.
        mutations = []
        for offset, value in [(header, 0), (header + 8, 0xFFFFFFFF),
                              (header + 12, 100), (header + 16, 0xFFFFFFFF),
                              (entry, 100), (entry + 4, 0xFFFFFFFF)]:
            damaged = bytearray(valid)
            struct.pack_into(">I", damaged, offset, value)
            mutations.append(damaged)
        damaged = bytearray(valid)
        damaged[entry + 10] = 255
        mutations.append(damaged)
        # Reserved free space is legal, but must never be treated as used data.
        damaged = bytearray(apple_double(attributes=True, attribute_padding=128))
        struct.pack_into(">I", damaged, entry, len(valid))
        mutations.append(damaged)
        damaged = bytearray(valid)
        damaged[entry + 11 + damaged[entry + 10] - 1] = 65
        mutations.append(damaged)
        for value in mutations:
            with self.subTest(value=bytes(value).hex()):
                sidecar.write_bytes(value)
                self.run_media("validate", self.directory, okay=False)

    def test_orphan_or_ordinary_dot_underscore_file_is_not_metadata(self):
        sidecar = self.directory / "._ordinary"
        sidecar.write_bytes(b"user file")
        self.run_media("validate", self.directory, okay=False)
        (self.directory / "file").write_bytes(b"payload")
        self.run_media("validate", self.directory, okay=False)
        sidecar.write_bytes(apple_double())
        self.run_media("validate", self.directory, okay=False)

    def test_empty_regular_file_is_valid(self):
        (self.directory / "empty").touch()
        self.assertEqual(self.run_media("validate", self.directory), "empty")

    def fixture(self):
        return FATFixture(self.directory / "disk.img")

    def observe(self, fixture, okay=True):
        return self.run_media("fat", fixture.path, "WKJOB", "ABCDEF01", "READY", okay=okay)

    def test_fat_marker_present_missing_and_unchanged_bytes(self):
        fixture = self.fixture()
        before = hashlib.sha256(fixture.path.read_bytes()).digest()
        self.assertEqual(self.observe(fixture), "YES")
        self.assertEqual(before, hashlib.sha256(fixture.path.read_bytes()).digest())
        fixture.patch(fixture.cluster_offset(3), b"\0")
        self.assertEqual(self.observe(fixture), "NO")

    def test_fat_copies_must_agree(self):
        fixture = self.fixture()
        fixture.chain(4, 0, both=False)
        self.observe(fixture, okay=False)

    def test_fat_final_marker_chain_cannot_be_free_or_cyclic(self):
        fixture = self.fixture()
        fixture.chain(4, 4)
        self.observe(fixture, okay=False)
        fixture.chain(4, 0)
        self.observe(fixture, okay=False)

    def test_fat_invalid_geometry_bounds_and_paths(self):
        fixture = self.fixture()
        self.run_media("fat", fixture.path, "..", okay=False)
        fixture.patch(13, b"\x03")
        self.observe(fixture, okay=False)
        fixture.patch(13, b"\x08")
        fixture.path.write_bytes(fixture.path.read_bytes()[:512])
        self.observe(fixture, okay=False)

    def test_fat_lfn_or_duplicate_marker_not_accepted(self):
        fixture = self.fixture()
        fixture.patch(fixture.cluster_offset(3) + 11, b"\x0f")
        self.assertEqual(self.observe(fixture), "NO")
        fixture.patch(fixture.cluster_offset(3), FATFixture.entry("READY", 4) * 2)
        self.observe(fixture, okay=False)

    @unittest.skipUnless(os.environ.get("WK_FILE_TRANSFER_DISK_TEST") == "1",
                         "opt-in newly-created local FAT16 image; no serial/target")
    def test_real_fat_staging_unicode_roundtrip_and_marker(self):
        # Keep this separate from ordinary tests, and preserve files if a normal
        # detach fails. Never unlink a live image or use a forced detach.
        work = Path(tempfile.mkdtemp(prefix="wk-media-disk-", dir="/private/tmp"))
        image = work / "exchange.img"
        try:
            result = subprocess.run([str(self.binary), "local-disk", str(work)],
                                    capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stderr)
            details = json.loads(result.stdout)
            self.assertTrue(details["exclusiveRename"])
            self.assertTrue(details["markerAfterDetach"])
            self.assertTrue(details["busyRejected"])
            self.assertTrue(details["metadataRoundTrip"])
            self.assertTrue(details["detached"])
            self.assertEqual(details["unicodeName"], "中文文件.bin")
            self.assertEqual(details["bytes"], 65536)
            expected = bytes(i % 251 for i in range(65536))
            self.assertEqual(details["sha256"], hashlib.sha256(expected).hexdigest())
        finally:
            # The production ensureImage helper may retain its own temporary
            # creating-* image on a failed format. Match only this fresh root.
            info = plistlib.loads(subprocess.check_output(["/usr/bin/hdiutil", "info", "-plist"], timeout=15))
            for item in info.get("images", []):
                path = Path(item.get("image-path", "")).resolve()
                if path.parent != work.resolve():
                    continue
                devices = [part["dev-entry"] for part in item.get("system-entities", [])
                           if part.get("dev-entry", "").startswith("/dev/disk")]
                self.assertEqual(len(devices), 1, "Unexpected test-only image device layout; retained image")
                subprocess.run(["/usr/bin/hdiutil", "detach", devices[0]],
                               check=True, capture_output=True, timeout=30)
            # Recheck all images before removing the private tree.
            info = plistlib.loads(subprocess.check_output(["/usr/bin/hdiutil", "info", "-plist"], timeout=15))
            self.assertFalse(any(Path(item.get("image-path", "")).resolve().parent == work.resolve()
                                 for item in info.get("images", [])), "Mounted test image retained")
            import shutil
            shutil.rmtree(work)


if __name__ == "__main__":
    unittest.main()
