#!/usr/bin/env python3
"""Book-only, five-point absolute-pointer probe. Default is entirely offline.

--execute opens only the board's host control CDC and sends exactly five WK1 A
frames. Never sends buttons, keys, release, wheel, or text. The OS cursor is
restored in finally. Hardware execution remains a separate, explicit action.
"""
import argparse
import ctypes as C
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import secrets
import select
import signal
import subprocess
import sys
import termios
import time

SERIAL = "CH32V407-DoNotShip"  # Shared role marker, not a unique board identity.
PROBE_SERIAL = "A47C8F062A1A"
FIRMWARE_SHA = "be9df7f1e72e48ec9fc2c8de0b2a287ebb3c3870f83ed962641667b5f57b7c68"
DESCRIPTOR_SHA = "dcf3d83be3ce7ca199ef30b372190b866d559ae2e5ddd21fec40ae79eaf6d6c9"
POINTS = ((.25, .25), (.75, .25), (.75, .75), (.25, .75), (.5, .5))
TOLERANCE = 4.0  # Screen points, not backing pixels.


def walk(nodes):
    for n in nodes:
        yield n
        yield from walk(n.get("IORegistryEntryChildren", []))


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def crc8(data):
    crc = 0
    for value in data:
        crc ^= value
        for _ in range(8):
            crc = ((crc << 1) ^ (7 if crc & 128 else 0)) & 255
    return crc


def frame(seq, x, y):
    require(0 <= seq <= 65535 and 0 <= x <= 32767 and 0 <= y <= 32767,
            "Out-of-range absolute frame")
    body = f"WK1,{seq},A,{x},{y}".encode("ascii")
    return body + f",{crc8(body):02X}\n".encode("ascii")


def unique_interface(device, number):
    nodes = [n for n in walk([device]) if n.get("IOObjectClass") == "IOUSBHostInterface"
             and n.get("bInterfaceNumber") == number]
    require(len(nodes) == 1, f"Ambiguous interface {number}")
    return nodes[0]


def load_flash_proof(path):
    """Local flash evidence plus physical confirmation, not USB authentication."""
    raw = path.read_bytes(); data = json.loads(raw)
    expected = {"flashed": True, "readback_verified": True, "reset_run": True,
                "probe_serial": PROBE_SERIAL, "chip_id": "0x46740011",
                "uid": "ad21ad506c54c6c6", "firmware_sha256": FIRMWARE_SHA, "bytes": 71704}
    require(all(data.get(key) == value and type(data.get(key)) is type(value)
                for key, value in expected.items()), "Flash proof identity or verified firmware differs")
    age = time.time() - path.stat().st_mtime
    require(-60 <= age <= 6 * 3600, "Flash proof is stale or has a future modification time")
    return {"path": str(path.resolve()), "sha256": hashlib.sha256(raw).hexdigest(),
            "firmware_sha256": FIRMWARE_SHA, "probe_serial": PROBE_SERIAL,
            "uid": expected["uid"], "age_seconds_at_load": round(age, 3),
            "physical_association": "user-confirmed same board after verified DBG flash; not a unique USB identity"}


def select_pair(registry, flash_proof=None):
    devices = [n for n in walk(registry) if n.get("IOObjectClass") == "IOUSBHostDevice"]
    role_devices = [n for n in devices if n.get("USB Serial Number") == SERIAL]
    hosts = [n for n in role_devices if (n.get("idVendor"), n.get("idProduct")) == (0x1a86, 0x4070)]
    targets = [n for n in role_devices if (n.get("idVendor"), n.get("idProduct")) == (0x05ac, 0x0265)]
    require(len(role_devices) == 2 and len(hosts) == len(targets) == 1,
            "Exactly one host and one target must both enumerate on Book")
    host, target = hosts[0], targets[0]
    require(host.get("bcdDevice") == 0x0200 and target.get("bcdDevice") == 0x026a,
            "Unexpected firmware version; this probe only accepts NoPreferred 026a")
    # The USB role serial is not unique. A recently verified flash proof permits
    # leaving DBG empty only after the user confirms the same physical board.
    # This is a procedural association, not cryptographic USB identification.
    probes = [n for n in devices if (n.get("idVendor"), n.get("idProduct")) == (0x1a86, 0x8010)]
    if probes:
        require(len(probes) == 1 and probes[0].get("USB Serial Number") == PROBE_SERIAL,
                "Unexpected or multiple DBG probes; flash proof cannot override this")
    else:
        require(flash_proof is not None, "DBG absent; explicit recent --flash-proof is required")
    require(host.get("locationID") != target.get("locationID"), "Duplicate USB location")
    itf = unique_interface(target, 1)
    nodes = list(walk([itf]))
    require(not any("MultiAxisPointer" in n for n in nodes),
            "MultiAxisPointer is present; no pointer injection permitted")
    drivers = [n for n in nodes if n.get("IOUserClass") == "AppleUserHIDEventDriver"
               and isinstance(n.get("AbsolutePointer"), dict)]
    require(len(drivers) == 1, "Actual generic AbsolutePointer driver is required")
    driver = drivers[0]
    require(driver.get("PrimaryUsagePage") == 1 and driver.get("PrimaryUsage") == 1,
            "Unexpected pointer Application Usage")
    elements = driver["AbsolutePointer"].get("Elements", [])
    for usage in (48, 49):
        axes = [e for e in elements if e.get("UsagePage") == 1 and e.get("Usage") == usage]
        require(len(axes) == 1, "Missing or ambiguous absolute axis")
        e = axes[0]
        require(e.get("ReportID") == 3 and e.get("Min") == 0 and e.get("Max") == 32767
                and e.get("ReportSize") == 16 and e.get("IsRelative") is False,
                "Absolute axis format differs from the audited candidate")
    descriptors = [n[k] for n in nodes for k in ("ReportDescriptor", "HIDReportDescriptor")
                   if isinstance(n.get(k), bytes)]
    require(descriptors and all(hashlib.sha256(b).hexdigest() == DESCRIPTOR_SHA for b in descriptors),
            "Actual absolute report descriptor does not match the audited candidate")
    control = unique_interface(host, 1)
    ports = {n["IOCalloutDevice"] for n in walk([control]) if "IOCalloutDevice" in n}
    require(len(ports) == 1, "Ambiguous host control CDC path")
    port = ports.pop()
    require(port.startswith("/dev/cu.usbmodem"), "Unexpected serial path")
    return {"port": port, "host_registry_id": host.get("IORegistryEntryID"),
            "target_registry_id": target.get("IORegistryEntryID"),
            "host_location": host.get("locationID"), "target_location": target.get("locationID"),
            "target_bcd": target["bcdDevice"], "probe_serial": PROBE_SERIAL,
            "dbg_present": bool(probes), "flash_proof": flash_proof,
            "absolute_descriptor_sha256": DESCRIPTOR_SHA}


def live_pair(flash_proof=None):
    raw = subprocess.check_output(["/usr/sbin/ioreg", "-r", "-c", "IOUSBHostDevice", "-l", "-w", "0", "-a"], timeout=10)
    return select_pair(plistlib.loads(raw), flash_proof)


def no_controller():
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,comm="], text=True, timeout=5)
    forbidden = {"wiredkvm-native", "macos-capture", "wiredkvm-companion",
                 "WiredKVM", "WiredKVM Companion"}
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and Path(fields[1]).name in forbidden:
            raise RuntimeError("Controller/capture/companion is running: " + line.strip())


class Point(C.Structure):
    _fields_ = [("x", C.c_double), ("y", C.c_double)]


class Size(C.Structure):
    _fields_ = [("width", C.c_double), ("height", C.c_double)]


class Rect(C.Structure):
    _fields_ = [("origin", Point), ("size", Size)]


class Cursor:
    def __init__(self):
        self.cg = C.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        self.cf = C.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        for name, args, result in [
            ("CGGetActiveDisplayList", [C.c_uint32, C.POINTER(C.c_uint32), C.POINTER(C.c_uint32)], C.c_int32),
            ("CGMainDisplayID", [], C.c_uint32), ("CGDisplayBounds", [C.c_uint32], Rect),
            ("CGDisplayIsBuiltin", [C.c_uint32], C.c_uint32),
            ("CGEventCreate", [C.c_void_p], C.c_void_p),
            ("CGEventGetLocation", [C.c_void_p], Point),
            ("CGWarpMouseCursorPosition", [Point], C.c_int32),
            ("CGEventSourceButtonState", [C.c_int32, C.c_uint32], C.c_bool)]:
            fn = getattr(self.cg, name); fn.argtypes = args; fn.restype = result
        self.cf.CFRelease.argtypes = [C.c_void_p]; self.cf.CFRelease.restype = None

    def layout(self):
        ids = (C.c_uint32 * 16)(); count = C.c_uint32()
        require(self.cg.CGGetActiveDisplayList(16, ids, C.byref(count)) == 0, "Cannot read displays")
        require(count.value == 1 and ids[0] == self.cg.CGMainDisplayID()
                and self.cg.CGDisplayIsBuiltin(ids[0]), "Requires only Book's built-in display")
        bounds = self.cg.CGDisplayBounds(ids[0])
        x, y, w, h = bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height
        require(x == y == 0 and 640 <= w <= 10000 and 400 <= h <= 10000,
                "Unexpected display bounds")
        return {"display_id": int(ids[0]), "x": x, "y": y, "width": w, "height": h}

    def position(self):
        event = self.cg.CGEventCreate(None)
        require(bool(event), "CGEventCreate failed")
        try:
            p = self.cg.CGEventGetLocation(event)
            require(math.isfinite(p.x) and math.isfinite(p.y), "Invalid cursor location")
            return [p.x, p.y]
        finally:
            self.cf.CFRelease(event)

    def buttons_up(self):
        require(not any(self.cg.CGEventSourceButtonState(0, i) for i in range(32)),
                "A mouse button is pressed; stop the probe")

    def restore(self, position):
        require(self.cg.CGWarpMouseCursorPosition(Point(*position)) == 0, "Cursor restore failed")


def read_ack(fd, seq, timeout=.8):
    pending = bytearray(); deadline = time.monotonic() + timeout; lines = []
    while time.monotonic() < deadline and len(pending) < 4096:
        ready, _, _ = select.select([fd], [], [], min(.05, max(0, deadline - time.monotonic())))
        if not ready:
            continue
        data = os.read(fd, 512)
        require(data, "Control serial disconnected while waiting for ACK")
        pending.extend(data)
        while b"\n" in pending:
            raw, _, tail = pending.partition(b"\n"); pending = bytearray(tail)
            line = raw.rstrip(b"\r").decode("ascii", errors="strict"); lines.append(line)
            if line == f"ACK,{seq}":
                return lines
            require(line != f"WAIT,{seq}", "Target rejected the pointer report")
    raise RuntimeError(f"No matching ACK for sequence {seq}: {lines!r}")


def execute(result, flash_proof=None):
    require(sys.platform == "darwin", "Book-only probe requires macOS")
    no_controller(); identity = live_pair(flash_proof); result["identity"] = identity
    held = subprocess.run(["/usr/sbin/lsof", "-t", identity["port"]], capture_output=True, text=True, timeout=5)
    require(held.returncode in (0, 1) and not held.stdout.strip() and not held.stderr.strip(),
            "Serial port is busy or its ownership cannot be established")
    cursor = Cursor(); layout = cursor.layout(); result["layout"] = layout
    cursor.buttons_up(); before = cursor.position(); result["cursor_before"] = before
    fd = None; attempted = False
    try:
        fd = os.open(identity["port"], os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        fcntl.ioctl(fd, termios.TIOCEXCL)
        a = termios.tcgetattr(fd); a[0] = a[1] = a[3] = 0
        a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        a[4] = a[5] = termios.B115200; a[6][termios.VMIN] = a[6][termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSANOW, a)
        # No command traffic for > firmware's 2500 ms held-input watchdog.
        time.sleep(3)
        no_controller(); require(live_pair(flash_proof) == identity, "Device re-enumerated during preflight")
        require(cursor.layout() == layout, "Display layout changed")
        cursor.buttons_up()
        seq = secrets.randbelow(65530)
        for index, (fx, fy) in enumerate(POINTS):
            no_controller(); require(live_pair(flash_proof) == identity, "Device identity changed")
            require(cursor.layout() == layout, "Display layout changed")
            cursor.buttons_up()
            x, y = round(fx * 32767), round(fy * 32767)
            packet = frame(seq + index, x, y)
            item = {"sequence": seq + index, "normalized": [x, y],
                    "expected": [x / 32767 * (layout["width"] - 1), y / 32767 * (layout["height"] - 1)]}
            result["points"].append(item)
            attempted = True
            require(os.write(fd, packet) == len(packet), "Short write; stop without retry")
            item["ack_lines"] = read_ack(fd, seq + index)
            time.sleep(.2); cursor.buttons_up()
            item["observed"] = cursor.position()
            item["max_error_points"] = max(abs(a - b) for a, b in zip(item["expected"], item["observed"]))
            item["passed"] = item["max_error_points"] <= TOLERANCE
            require(item["passed"], "Absolute coordinates did not match; stop further injection")
        require(live_pair(flash_proof) == identity, "Device disappeared at end of probe")
        result["status"] = "five_absolute_points_passed"
    finally:
        if fd is not None:
            os.close(fd)
        if attempted:
            time.sleep(.2)
            cursor.restore(before)
            result["cursor_restored"] = cursor.position()
            require(max(abs(a-b) for a,b in zip(before, result["cursor_restored"])) <= TOLERANCE,
                    "Cursor restore position could not be confirmed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--execute", action="store_true")
    group.add_argument("--dry-run", action="store_true", help="Default: no device access, no events")
    parser.add_argument("--out", type=Path, required=True, help="New JSON file; never overwritten")
    parser.add_argument("--flash-proof", type=Path,
                        help="Recent verified flash-result JSON. Allows DBG absent only after user confirms the same board")
    args = parser.parse_args()
    result = {"mode": "execute" if args.execute else "dry_run", "status": "not_started", "points": [],
              "scope": "Book-only absolute movement; no clicks, text, wheel, or mini control",
              "limitations": ["Does not validate edge return, drag, gestures, or throughput",
                              "DBG absent needs recent verified flash proof and user-confirmed same physical board; USB role serial is not unique"]}
    # Reserve the evidence path before considering any input operation.
    with args.out.open("x") as output:
        try:
            proof = load_flash_proof(args.flash_proof) if args.flash_proof else None
            result["flash_proof"] = proof
            if args.execute:
                def stop(signum, _frame):
                    raise KeyboardInterrupt(f"Signal {signum}")
                signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGHUP, stop)
                execute(result, proof)
            else:
                result["plan"] = [{"normalized": [round(x*32767), round(y*32767)],
                                   "frame": frame(i, round(x*32767), round(y*32767)).decode("ascii").rstrip()}
                                  for i, (x, y) in enumerate(POINTS)]
                result["status"] = "offline_plan_only"
        except (Exception, KeyboardInterrupt) as error:
            result["status"] = "failed"; result["error"] = f"{type(error).__name__}: {error}"
        finally:
            json.dump(result, output, ensure_ascii=False, indent=2); output.write("\n")
    print(json.dumps({"status": result["status"], "output": str(args.out), "error": result.get("error")}, ensure_ascii=False))
    return 2 if result["status"] == "failed" else 0


if __name__ == "__main__":
    sys.exit(main())
