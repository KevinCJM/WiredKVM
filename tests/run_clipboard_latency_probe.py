#!/usr/bin/env python3
"""Build/run a private-pasteboard diagnostic. No production installation/device I/O.

The production entry point is renamed only in a temporary source copy; the exact
WKCompanion and WKLink implementations are used. The test entry point creates
private NSPasteboards and a memory transport, never the general clipboard/HID.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = root / "host" / "clipboard"
with tempfile.TemporaryDirectory(prefix="wk-latency-build-") as temporary:
    temporary = Path(temporary)
    main = (sources / "WiredKVMCompanion.swift").read_text()
    assert main.count("@main struct WiredKVMCompanionMain") == 1
    isolated = temporary / "IsolatedCompanion.swift"
    isolated.write_text(main.replace("@main struct WiredKVMCompanionMain", "struct WiredKVMCompanionMain"))
    binary = temporary / "latency-probe"
    apple_silicon = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.optional.arm64"], capture_output=True, text=True).stdout.strip() == "1"
    architecture = "arm64" if apple_silicon else "x86_64"
    crate = root / 'native/clipboard-state'
    rust_target = temporary / 'rust-target'
    rust_arch = {'arm64':'aarch64-apple-darwin','x86_64':'x86_64-apple-darwin'}[architecture]
    subprocess.run(['cargo','build','--offline','--locked','--release','--manifest-path',str(crate/'Cargo.toml'),
                    '--target',rust_arch,'--target-dir',str(rust_target)],check=True)
    command = ["/usr/bin/arch", "-" + architecture, "/usr/bin/swiftc", "-target", architecture + "-apple-macosx13.0",
               "-parse-as-library", "-O", "-module-cache-path", "/tmp/wiredkvm-clipboard-module-cache",
               "-I", str(crate/'include'), "-framework", "AppKit", "-framework", "IOKit", "-lcompression"]
    command += [str(path) for path in sorted(sources.glob("*.swift")) if path.name != "WiredKVMCompanion.swift"]
    command += [str(isolated), str(root / "tests" / "clipboard_latency_probe.swift"),
                str(rust_target/rust_arch/'release/libwiredkvm_clipboard_state.a'), "-o", str(binary)]
    subprocess.run(command, check=True)
    subprocess.run([str(binary)], check=True)
