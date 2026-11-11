#!/usr/bin/env python3
"""Check continuous one-packet OUT against pinned real WCH core, offline only."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
VENDOR = "EVT/EXAM/USBHS/Dual_device/cdc_transfer/usb_driver"
CORE_SHA = "a6e72568ba8703656d43a6168d92051927aa1f98ef8f80a7107bf00982bf5f7a"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    args = parser.parse_args()
    sdk = args.sdk.resolve(strict=True)
    driver = sdk / VENDOR
    core = driver / "src/usbd_driver_core.c"
    if hashlib.sha256(core.read_bytes()).hexdigest() != CORE_SHA:
        raise SystemExit("Unreviewed SDK core; refuse substitution")
    work = Path(tempfile.mkdtemp(prefix="sdk-bulk-rx-test-", dir=HERE))
    command = ["clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
               "-Wno-unused-parameter", "-Wno-error=switch", "-I", str(driver / "include"),
               str(HERE / "test_bulk_rx_sdk.c"), str(core), "-o", str(work / "test")]
    compiled = subprocess.run(command, text=True, capture_output=True, timeout=60)
    (work / "compile.log").write_text(compiled.stdout + compiled.stderr)
    if compiled.returncode:
        raise SystemExit("Compile failed: " + str(work / "compile.log"))
    run = subprocess.run([command[-1]], text=True, capture_output=True, timeout=10)
    (work / "run.log").write_text(run.stdout + run.stderr)
    if run.returncode or "REAL_WCH_CORE_RX_PASS cycles=4000" not in run.stdout:
        raise SystemExit("Regression failed: " + str(work / "run.log"))
    # Remove returned-ACK continuation in the real core, not in a model. The
    # harness must reject that mutation; otherwise it is not testing this path.
    text = core.read_text()
    marker = "_set_endp_response(h, ep, resp);"
    if text.count(marker) != 2:
        raise SystemExit("Unreviewed core response sites")
    mutant = work / "mutated_core.c"
    target = "param->xfer_offset = 0;\n        _set_endp_response(h, ep, resp);"
    if text.count(target) != 1:
        raise SystemExit("Unreviewed transfer completion")
    mutant.write_text(text.replace(target, "param->xfer_offset = 0;\n        (void)resp;\n        _set_endp_response(h, ep, ENDP_RESP_NAK);"))
    changed = [str(mutant) if x == str(core) else x for x in command]
    changed[-1] = str(work / "mutant")
    built = subprocess.run(changed, text=True, capture_output=True, timeout=60)
    (work / "mutation-compile.log").write_text(built.stdout + built.stderr)
    if built.returncode:
        raise SystemExit("Mutation must compile: " + str(work / "mutation-compile.log"))
    failed = subprocess.run([changed[-1]], text=True, capture_output=True, timeout=10)
    (work / "mutation.log").write_text(failed.stdout + failed.stderr)
    if failed.returncode == 0:
        raise SystemExit("Harness accepted broken ACK continuation")
    result = dict(status="PASS_OFFLINE_REAL_CORE_NOT_PHYSICAL", device_access=False,
                  sdk_core_sha256=CORE_SHA, mutation_rejected=True, command=command,
                  inputs={str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in [core, HERE / "test_bulk_rx_sdk.c", Path(__file__)]},
                  output=run.stdout)
    (work / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(work / "result.json")


if __name__ == "__main__":
    main()
