#!/usr/bin/env python3
"""Build an isolated, non-installing macOS companion. Never launch or deploy.

Outputs must be new and inside this project. Installer and self-install sources
are intentionally excluded, and WK_PORTABLE removes login registration paths.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ["WKClipboardProtocol", "WKOnboarding", "WKFnKey", "WKScrollRelay",
           "WKGestureRelay", "WKInputRelay", "WKClipboardContent",
           "WKClipboardTransport", "WKFilePortal", "WKStreamFiles", "WKTransferTree",
           "WKOnDemandClipboard", "WiredKVMCompanion"]


def build(out: Path, arches: list[str]) -> dict:
    out = out.resolve()
    if not out.is_relative_to(ROOT / "build"):
        raise ValueError("output must be a new directory under project/build")
    out.mkdir(parents=True, exist_ok=False)
    sources = [ROOT / "host/clipboard" / (s + ".swift") for s in SOURCES]
    crate = ROOT / "native/transfer-tree"
    inputs = sources + [ROOT/"host/gui/Companion-Info.plist"] + [crate / p for p in ["Cargo.toml", "Cargo.lock", "build.rs", "src/lib.rs", "src/dir_list.c",
                                           "include/transfer_tree.h", "include/module.modulemap"]]
    before={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    commands = []

    def run(argv):
        argv = list(map(str, argv)); commands.append(argv)
        env = dict(os.environ, TMPDIR=str(out), MACOSX_DEPLOYMENT_TARGET="13.0")
        for key in ["CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "LIBRARY_PATH", "DYLD_INSERT_LIBRARIES"]:
            env.pop(key, None)
        p = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True, timeout=180)
        with (out / "build.log").open("a") as f:
            f.write(json.dumps(argv) + "\n" + p.stdout + p.stderr)
        if p.returncode:
            raise RuntimeError(f"command failed ({p.returncode}); see {out / 'build.log'}")
        return p.stdout

    app = out / "WiredKVM 临时连接.app"
    exe = app / "Contents/MacOS/WiredKVMPortable"
    exe.parent.mkdir(parents=True)
    rust_targets = {"arm64": "aarch64-apple-darwin", "x86_64": "x86_64-apple-darwin"}
    for arch in arches:
        target = rust_targets[arch]
        # Keep candidate builds separate from every currently running helper.
        run(["cargo", "build", "--offline", "--locked", "--release", "--manifest-path", crate / "Cargo.toml",
             "--target", target, "--target-dir", out / "rust-target"])
        archive = out / "rust-target" / target / "release/libwiredkvm_transfer_tree.a"
        run(["/usr/bin/swiftc", "-D", "WK_PORTABLE", "-D", "WK_TREE", "-O", "-parse-as-library",
             "-target", f"{arch}-apple-macosx13.0", "-module-cache-path", out / "swift-cache",
             "-I", crate / "include", "-Xlinker", "-dead_strip",
             "-framework", "AppKit", "-framework", "IOKit", "-lcompression",
             *sources, archive, "-o", out / ("portable-" + arch)])
    run(["/usr/bin/lipo", "-create", *[out / ("portable-" + a) for a in arches], "-output", exe])
    info = plistlib.loads((ROOT / "host/gui/Companion-Info.plist").read_bytes())
    info.update(CFBundleIdentifier="com.wiredkvm.portable", CFBundleExecutable="WiredKVMPortable",
                CFBundleName="WiredKVM 临时连接", CFBundleDisplayName="WiredKVM 临时连接")
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "com.wiredkvm.portable", app])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", '=identifier "com.wiredkvm.portable"', app])
    symbols = run(["/usr/bin/nm", exe])
    for forbidden in ["WKCompanionInstall", "WKLoginItem", "WKFirstRunWindow", "SMAppService"]:
        if forbidden in symbols:
            raise RuntimeError("portable binary contains installed-only symbol: " + forbidden)
    if before!={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}:
        raise RuntimeError("build inputs changed during compilation; candidate is not publishable")
    manifest = dict(mode="portable", architectures=arches, collections=True, binaryBulk=True,
                    legacyInputRelay=False, launched=False, installed=False,
                    deviceAccess=False, clipboardAccess=False, firmwareChanged=False,
                    binary=str(exe), bytes=exe.stat().st_size,
                    sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),
                    sources=before,
                    limitations=["physical input and clipboard acceptance pending",
                                 "macOS may require normal execution and network-volume access permission",
                                 "temporary transfer data and OS-managed caches are not an installation",
                                 "physical USB delivery and file integrity require separate acceptance"])
    (out / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--arch", choices=["arm64", "x86_64"], action="append")
    args = parser.parse_args()
    result = build(args.output, args.arch or ["arm64", "x86_64"])
    print(json.dumps({k: result[k] for k in ["mode", "architectures", "binary", "bytes", "sha256", "launched"]}, ensure_ascii=False))
