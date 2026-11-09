#!/usr/bin/env python3
"""Fetch a pinned WCH SDK subset; verify every Git blob before using it.

Only downloads source. Does not install software, flash, or touch a USB device.
WCH source retains its upstream copyright and WCH-MCU-only license notices.
"""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess

COMMIT = "de8b9431e2c2f862d067a77d44859aee9e12e1d3"
REPO = "openwch/ch32v407_ch32v467"
ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "build/ch32v407/sdk"
EXAMPLE = "EVT/EXAM/USBHS/Dual_device/cdc_transfer/"


def curl(url):
    return subprocess.check_output(["curl", "-sS", "--fail", "-L", "--retry", "2", "--max-time", "90", url])


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    cache = DEST / "tree.json"
    if not cache.exists():
        cache.write_bytes(curl(f"https://api.github.com/repos/{REPO}/git/trees/{COMMIT}?recursive=1"))
    tree = json.loads(cache.read_bytes())
    assert tree["sha"] == COMMIT and not tree.get("truncated")
    files = [x for x in tree["tree"] if x["type"] == "blob" and (
        x["path"].startswith("EVT/EXAM/SRC/") or
        x["path"].startswith(EXAMPLE)) and (Path(x["path"]).suffix in (".c", ".h", ".S", ".ld") or Path(x["path"]).name == ".cproject")]

    def fetch(item):
        path = DEST / item["path"]
        data = path.read_bytes() if path.exists() else curl(f"https://raw.githubusercontent.com/{REPO}/{COMMIT}/{item['path']}")
        digest = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        if digest != item["sha"]:
            raise RuntimeError(f"SDK blob mismatch: {item['path']}")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return {"path": item["path"], "git_blob": digest, "sha256": hashlib.sha256(data).hexdigest()}

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        manifest = list(pool.map(fetch, files))
    (DEST / "manifest.json").write_text(json.dumps({"repository": REPO, "commit": COMMIT, "files": manifest}, indent=2) + "\n")
    print(f"SDK verified: {len(manifest)} files at {COMMIT}")


if __name__ == "__main__":
    main()
