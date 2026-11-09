"""Prepare or explicitly install Book-only input autostart. Never touches the target.

The existing, user-verified capture binary stays at its authorized path.
Prepare is project-local; --install writes exactly one user LaunchAgent and its
Application Support directory, then adopts an input-only runtime if present.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LABEL = "com.wiredkvm.control-autostart"
BASE = Path.home() / "Library/Application Support/WiredKVM/control-autostart"
PLIST = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
NATIVE = ROOT / "build/input-relay-20261105/runtime/wiredkvm-native"
RELAY = ROOT / "build/input-relay-20261105/runtime/wiredkvm-companion"
CAPTURE = ROOT / "build/scroll-short-20261105/macos-capture"
EXPECTED = {
    NATIVE: "6400669f6dc9fafa921bbfe5a843289d1661657e63fb325955003240ccbc1506",
    RELAY: "dcf5d6ce2ac3e1173622fcdae801ba4b20ac05760b772df3283fa155429e07b9",
    CAPTURE: "0ea227a12e1d5895175d707248b0ad9e29fd20569e9369a104922ff1062e1836",
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(stage):
    stage.mkdir(parents=True, exist_ok=False)
    for path, expected in EXPECTED.items():
        assert sha(path) == expected, f"Verified runtime changed: {path}"
    binary = ROOT / "native/control-service/target/release/wiredkvm-control-service"
    shutil.copy2(binary, stage / binary.name)
    config = "\n".join([
        f"native={NATIVE}", f"relay={RELAY}", f"capture={CAPTURE}",
        f"state_dir={BASE / 'state'}", f"native_sha256={EXPECTED[NATIVE]}",
        f"relay_sha256={EXPECTED[RELAY]}", f"capture_sha256={EXPECTED[CAPTURE]}", "",
    ])
    (stage / "config.txt").write_text(config)
    launch = {
        "Label": LABEL,
        "ProgramArguments": [str(BASE / binary.name), "run", str(BASE / "config.txt")],
        "RunAtLoad": True,
        "KeepAlive": True,
        # Preserve the capture process if only the supervisor crashes. On the
        # next launch, PID + birth time + executable checks adopt that session.
        # A normal stop is handled by Rust and restores the local pointer first.
        "AbandonProcessGroup": True,
        "ThrottleInterval": 10,
        "ExitTimeOut": 12,
        "LimitLoadToSessionType": "Aqua",
        "ProcessType": "Interactive",
        "Umask": 0o077,
        "StandardOutPath": str(BASE / "service.log"),
        "StandardErrorPath": str(BASE / "service.log"),
    }
    (stage / PLIST.name).write_bytes(plistlib.dumps(launch))
    subprocess.run(["/usr/bin/plutil", "-lint", str(stage / PLIST.name)], check=True)
    manifest = {"label": LABEL, "destination": str(BASE), "launch_agent": str(PLIST),
                "files": {p.name: sha(p) for p in stage.iterdir() if p.is_file()},
                "runtime": {str(p): v for p, v in EXPECTED.items()},
                "clipboard": False, "target_programs": False, "firmware_changed": False}
    (stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


def install(stage):
    manifest = json.loads((stage / "manifest.json").read_text())
    assert manifest["destination"] == str(BASE) and manifest["launch_agent"] == str(PLIST)
    for name, digest in manifest["files"].items():
        assert Path(name).name == name and sha(stage / name) == digest
    for p, digest in EXPECTED.items():
        assert sha(p) == digest
    assert not PLIST.exists(), "Existing LaunchAgent must be reviewed before replacement"
    assert not BASE.exists(), "Existing autostart installation must be reviewed before replacement"
    # Refuse to alter another active or differently configured control session.
    procs = subprocess.check_output(["/bin/ps", "-axo", "pid=,comm="], text=True)
    found = {}
    for line in procs.splitlines():
        row = line.strip().split(None, 1)
        if len(row) != 2:
            continue
        p = Path(row[1])
        if p.name in {NATIVE.name, RELAY.name, CAPTURE.name}:
            assert p in EXPECTED and p not in found, "Unknown or duplicate input controller"
            found[p] = int(row[0])
    assert not found or len(found) == 3, "Incomplete existing runtime; inspect before adoption"
    if found:
        native_args = subprocess.check_output(["/bin/ps", "-p", str(found[NATIVE]), "-o", "command="], text=True)
        relay_args = subprocess.check_output(["/bin/ps", "-p", str(found[RELAY]), "-o", "command="], text=True)
        assert "--input-socket " in native_args and "--clipboard-socket" not in native_args
        assert "--input-only" in relay_args and "--headless" in relay_args
    BASE.mkdir(parents=True, mode=0o700)
    os.chmod(BASE, 0o700)
    for name in ["wiredkvm-control-service", "config.txt", "manifest.json"]:
        shutil.copy2(stage / name, BASE / name)
        os.chmod(BASE / name, 0o755 if name == "wiredkvm-control-service" else 0o600)
    if found:
        subprocess.run([str(BASE / "wiredkvm-control-service"), "seed", str(BASE / "config.txt"),
                        str(found[NATIVE]), str(found[RELAY]), str(found[CAPTURE])], check=True)
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    with PLIST.open("xb") as target:
        target.write((stage / PLIST.name).read_bytes())
    os.chmod(PLIST, 0o600)
    domain = f"gui/{os.getuid()}"
    subprocess.run(["/bin/launchctl", "enable", domain + "/" + LABEL], check=True)
    subprocess.run(["/bin/launchctl", "bootstrap", domain, str(PLIST)], check=True)
    print(json.dumps({"installed": str(PLIST), "adopted_pids": list(found.values())}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "install"])
    parser.add_argument("stage", type=Path)
    args = parser.parse_args()
    (prepare if args.action == "prepare" else install)(args.stage.resolve())
