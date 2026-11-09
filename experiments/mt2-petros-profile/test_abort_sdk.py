#!/usr/bin/env python3
"""Exercise cancellation against the pinned real WCH USB driver core.

Only the register boundary is simulated. No device access or SDK modifications.
Artifacts are retained in a new directory; no cleanup or overwrite.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
VENDOR = "EVT/EXAM/USBHS/Dual_device/cdc_transfer/usb_driver"
CORE_SHA = "a6e72568ba8703656d43a6168d92051927aa1f98ef8f80a7107bf00982bf5f7a"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--endpoint",type=int,choices=(2,7),default=2)
    args = parser.parse_args()
    live=args.endpoint==7
    abort_file=HERE/("live_abort.c" if live else "single_port_abort.c")
    sdk = args.sdk.resolve(strict=True)
    driver = sdk / VENDOR
    core = driver / "src/usbd_driver_core.c"
    if hashlib.sha256(core.read_bytes()).hexdigest() != CORE_SHA:
        raise SystemExit("Unreviewed SDK core; refuse substitution")
    registers = sdk / "EVT/EXAM/SRC/Peripheral/inc/ch32v4x7_usb.h"
    definitions = registers.read_text()
    values = {"USBHS_UDIF_BUS_RST": 1, "USBHS_UDMS_SIE_FREE": 8,
              "USBHS_UEP_T_DONE": 128, "USBHS_UEP_T_NAK_ACT": 64,
              "USBHS_UEP_T_RES_MASK": 3, "USBHS_UEP_T_RES_NAK": 0}
    for name, expected in values.items():
        match = re.search(r"^#define\s+" + name + r"\s+(0x[0-9A-Fa-f]+)\b", definitions, re.M)
        if not match or int(match[1], 16) != expected:
            raise SystemExit("Unreviewed register definition: " + name)
    work = Path(tempfile.mkdtemp(prefix="sdk-abort-test-", dir=HERE))
    model_header='''#pragma once
#include <stdint.h>
typedef struct {uint8_t INT_FG,MIS_ST;} model_registers;
extern model_registers model;
#define USBHS2D (&model)
uint8_t model_ctrl_read(void);
void model_ctrl_write(uint8_t);
#define WKAP_EP82_CTRL_READ() model_ctrl_read()
#define WKAP_EP82_CTRL_WRITE(v) model_ctrl_write(v)
'''
    if live:model_header=model_header.replace('WKAP_EP82','WKMT2_EP87')
    (work/"ch32v4x7.h").write_text(model_header)
    (work / "ch32v4x7_usb.h").write_text("#pragma once\n" + "\n".join(
        f"#define {key} {value}" for key, value in values.items()) + "\n")
    source = work / "sdk_abort.c"
    harness=(HERE / "test_abort_sdk.c").read_text()
    if live:
        harness=harness.replace('#include "single_port_abort.h"','#include <stdbool.h>\nbool wkmt2_live_abort_usb(usbd_handle_t *);')
        harness=harness.replace('wkap_abort_ep82','wkmt2_live_abort_usb').replace('0x82','0x87')
        for old,new in [('ctrl[2]','ctrl[7]'),('dma[2]','dma[7]'),('length[2]','length[7]'),('[USB_DIR_IN][2]','[USB_DIR_IN][7]'),('complete(2)','complete(7)')]:harness=harness.replace(old,new)
    source.write_text(harness)
    command = ["clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
               "-Wno-unused-parameter", "-Wno-error=switch", "-I", str(work), "-I", str(HERE),
               "-I", str(driver / "include"), str(source), str(core),
               str(abort_file), "-o", str(work / "sdk_abort")]
    compiled = subprocess.run(command, text=True, capture_output=True)
    (work / "compile.log").write_text(compiled.stdout + compiled.stderr)
    if compiled.returncode:
        raise SystemExit("Compile failed; see " + str(work / "compile.log"))
    run = subprocess.run([command[-1]], text=True, capture_output=True, timeout=10)
    (work / "run.log").write_text(run.stdout + run.stderr)
    if run.returncode:
        raise SystemExit("Regression failed; see " + str(work / "run.log"))
    if "REAL_WCH_CORE_ABORT_PASS cycles=1000" not in run.stdout:
        raise SystemExit("Missing semantic pass marker")
    # A plain RMW can compile and appear correct without the racing completion.
    # Require the same real-core scenario to reject that broken implementation.
    mutant = work / "stale_zero_abort.c"
    text = abort_file.read_text()
    marker = " | USBHS_UEP_T_DONE | USBHS_UEP_T_NAK_ACT"
    if text.count(marker) != 1:
        raise SystemExit("Unrecognized cancellation implementation for mutation")
    mutant.write_text(text.replace(marker, ""))
    changed = [str(mutant) if x == str(abort_file) else x for x in command]
    changed[-1] = str(work / "sdk_abort_mutant")
    built = subprocess.run(changed, text=True, capture_output=True)
    if built.returncode:
        raise SystemExit("Mutation must compile before testing its behavior")
    failed = subprocess.run([changed[-1]], text=True, capture_output=True, timeout=10)
    (work / "mutation.log").write_text(failed.stdout + failed.stderr)
    if failed.returncode == 0:
        raise SystemExit("Real-core regression failed to reject stale-zero mutation")
    result = dict(status="PASS_OFFLINE_REAL_CORE_NOT_PHYSICAL", device_access=False,
                  sdk_core_sha256=CORE_SHA, endpoint=args.endpoint, cycles=1000, mutation_rejected=True, command=command,
                  inputs={str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in [core, registers, abort_file,
                                    HERE / "single_port_abort.h", HERE / "test_abort_sdk.c",
                                    HERE / "test_abort_sdk.py"]}, output=run.stdout)
    (work / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(work / "result.json")


if __name__ == "__main__":
    main()
