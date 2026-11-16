#!/usr/bin/env python3
"""Link real Rust upload/ABI + C PSRAM/MSC/input cores. No USB or device I/O."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    inputs = [
        ROOT / name for name in (
            "tests/psram_recovery_integration.c",
            "firmware/ch32v467_petros/setup_ram.c",
            "firmware/ch32v467_petros/setup_ram.h",
            "firmware/ch32v407/setup_msc.c",
            "firmware/ch32v407/setup_msc.h",
            "firmware/ch32v407/bridge.c",
            "firmware/ch32v407/bridge.h",
            "firmware/main/wire_protocol.c",
            "native/cable-image/src/lib.rs",
            "experiments/mt2-usb/src/ram_setup.rs",
        )
    ]
    inputs += sorted((ROOT / "tests/psram_model").glob("*.h"))
    snapshot = lambda: {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    before = snapshot()
    (ROOT / "build").mkdir(exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix="psram-recovery-integration-", dir=ROOT / "build"))
    shim = out / "shim"
    (shim / "src").mkdir(parents=True)
    (shim / "Cargo.toml").write_text(
        '[package]\nname="wk-psram-recovery-integration"\nversion="0.0.0"\nedition="2021"\n'
        '[lib]\ncrate-type=["staticlib"]\n[dependencies]\n'
        'wiredkvm-mt2-protocol-draft={path=' + json.dumps(str(ROOT / "experiments/mt2-usb"))
        + ',features=["c-abi","native-mt2","ram-setup"]}\n'
        '[profile.release]\npanic="abort"\nlto=false\n[workspace]\n'
    )
    (shim / "src/lib.rs").write_text("pub use wiredkvm_mt2_protocol_draft::ram_setup::*;\n")
    commands = [
        ["cargo", "build", "--release", "--offline", "--manifest-path", str(shim / "Cargo.toml"),
         "--target-dir", str(out / "rust")],
        ["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-DWK_RAM_MODEL",
         "-Itests/psram_model", "-Ifirmware/ch32v467_petros", "-Ifirmware/ch32v407", "-Ifirmware/main",
         "tests/psram_recovery_integration.c", "firmware/ch32v467_petros/setup_ram.c",
         "firmware/ch32v407/setup_msc.c", "firmware/ch32v407/bridge.c", "firmware/main/wire_protocol.c",
         str(out / "rust/release/libwk_psram_recovery_integration.a"), "-o", str(out / "integration")],
    ]
    with (out / "test.log").open("w") as log:
        for command in commands:
            subprocess.run(command, cwd=ROOT, check=True, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        for scenario in ("recover", "exhausted", "physical-crc"):
            completed = subprocess.run([str(out / "integration"), scenario], cwd=ROOT, check=True,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
            log.write(completed.stdout)
            print(completed.stdout.strip())
    if snapshot() != before:
        raise RuntimeError("Test inputs changed during execution; results invalidated")
    (out / "manifest.json").write_text(json.dumps({
        "physicalUSB": False, "physicalPSRAM": False, "OSInput": False,
        "realCores": ["Rust Upload/ram_setup ABI", "C PSRAM adapter", "C MSC CRC", "C input bridge"],
        "inputs": before, "commands": commands, "passed": ["recover", "exhausted", "physical-crc"],
    }, indent=2) + "\n")
    print("RETAINED", out)


if __name__ == "__main__":
    main()
