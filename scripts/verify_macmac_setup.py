#!/usr/bin/env python3
"""Verify only the newly built setup image; never run its application."""
import hashlib
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUILD = Path(os.environ.get("WK_BUILD_DIR", ROOT / "build/macmac-clipboard")).resolve()
IMAGE = BUILD / "setup/setup.img"
APP = BUILD / "安装 WiredKVM Companion.app"
PAYLOAD = BUILD / "WiredKVM Companion.app"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def finder_info():
    # HFS+ Finder open-folder metadata belongs to the volume, not the app.
    # Our makehybrid image has an Apple partition map in 512-byte entries.
    with IMAGE.open("rb") as stream:
        for index in range(1, 64):
            stream.seek(index * 512)
            entry = stream.read(512)
            if entry[:2] != b"PM":
                break
            if entry[48:80].split(b"\0", 1)[0] == b"Apple_HFS":
                start = int.from_bytes(entry[8:12], "big") * 512
                length = int.from_bytes(entry[12:16], "big") * 512
                values = []
                for offset in (start + 1024, start + length - 1024):
                    stream.seek(offset)
                    header = stream.read(112)
                    assert header[:2] == b"H+"
                    values.append(header[80:112])
                return values
    raise AssertionError("new setup image has no HFS+ partition")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prepare", action="store_true",
                        help="Remove makehybrid's empty app FinderInfo in this NEW build image only")
    prepare = parser.parse_args().prepare
    assert IMAGE.is_file() and not IMAGE.is_symlink()
    original = digest(IMAGE)
    open_folder = finder_info()
    # Never use recursive TemporaryDirectory cleanup around a mount point: a
    # failed detach must leave a recoverable mount, not delete its contents.
    directory = Path(tempfile.mkdtemp(prefix="setup-check-", dir=BUILD))
    mount = directory / "mounted"
    device = None
    try:
        mount.mkdir()
        attached = subprocess.run([
            "/usr/bin/hdiutil", "attach", "-readwrite" if prepare else "-readonly", "-nobrowse", "-noautoopen",
            "-mountpoint", str(mount), "-plist", str(IMAGE),
        ], capture_output=True, check=True, timeout=30)
        entities = plistlib.loads(attached.stdout)["system-entities"]
        # The service does not guarantee entity order. Select the whole disk
        # explicitly, instead of assuming entities[0] is the parent device.
        roots = [e["dev-entry"] for e in entities
                 if re.fullmatch(r"/dev/disk[0-9]+", e.get("dev-entry", ""))]
        if len(roots) == 1:
            device = roots[0]
        else:
            own = [e for e in entities if e.get("mount-point") == str(mount)]
            if len(own) == 1:
                match = re.fullmatch(r"(/dev/disk[0-9]+)(?:s[0-9]+)*", own[0].get("dev-entry", ""))
                if match:
                    device = match.group(1)
        try:
            assert device, entities
            assert any(e.get("mount-point") == str(mount) for e in entities), entities
            copied = mount / APP.name
            if prepare:
                # DiscRecording creates empty FinderInfo attributes on signed
                # bundle entries. Clear only those synthesized app attributes,
                # preserving the volume's Finder auto-open metadata.
                subprocess.run(["/usr/bin/xattr", "-dr", "com.apple.FinderInfo", str(copied)],
                               check=True, timeout=20)
            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict",
                            "-R", '=identifier "com.wiredkvm.setup"', str(copied)],
                           check=True, timeout=20)
            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict",
                            "-R", '=identifier "com.wiredkvm.companion"',
                            str(copied / "Contents/Resources/WiredKVM Companion.app")],
                           check=True, timeout=20)
            for relative in ["Contents/MacOS/WiredKVMCompanion", "Contents/Info.plist"]:
                assert digest(copied / relative) == digest(APP / relative)
                assert digest(copied / "Contents/Resources/WiredKVM Companion.app" / relative) == digest(PAYLOAD / relative)
            if not prepare:
                probe = mount / "wiredkvm-readonly-probe"
                try:
                    probe.write_bytes(b"must not be writable")
                except OSError as error:
                    assert error.errno == 30, error  # EROFS
                else:
                    probe.unlink()
                    raise AssertionError("setup mounted writable")
            print(f"SETUP_MEDIA_PASS readonly={not prepare} signature=true exact_app=true app_not_run=true")
        finally:
            if device:
                subprocess.run(["/usr/bin/hdiutil", "detach", device], check=True, timeout=30)
    finally:
        # Empty-directory removal cannot walk into a still-mounted filesystem.
        if not os.path.ismount(mount):
            try:
                mount.rmdir()
                directory.rmdir()
            except OSError:
                pass
    assert finder_info() == open_folder, "Finder auto-open metadata changed"
    if prepare:
        print("SETUP_IMAGE_PREPARED open_folder_preserved=true")
    else:
        assert digest(IMAGE) == original
        print("SETUP_IMAGE_UNCHANGED sha256=" + original)


if __name__ == "__main__":
    main()
