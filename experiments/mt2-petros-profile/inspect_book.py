#!/usr/bin/env python3
"""Read only the experimental board's IORegistry subtree and MT2 diagnostics.

Does not claim input devices, install a driver, open target HID, or post events.
--query opens only the host control CDC, after checking no controller runs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import select
import subprocess
import termios
import time

SERIAL = "CH32V407-DoNotShip"  # role marker, NOT a unique board identity
ROOT = Path(__file__).resolve().parents[2]

def walk(nodes):
    for node in nodes:
        yield node
        yield from walk(node.get("IORegistryEntryChildren", []))

def compact(node, interface=None):
    # Driver personalities may publish bInterfaceNumber="*". Only the actual
    # USB interface establishes ancestry; a matching rule cannot replace it.
    if node.get("IOObjectClass") == "IOUSBHostInterface":
        interface = node.get("bInterfaceNumber", interface)
    keys = ["IORegistryEntryName", "IOObjectClass", "IORegistryEntryID",
            "idVendor", "idProduct", "USB Product Name", "USB Serial Number",
            "locationID", "bcdDevice", "bConfigurationValue", "Device Speed",
            "bInterfaceNumber", "bInterfaceClass", "bInterfaceSubClass",
            "bInterfaceProtocol", "VendorID", "ProductID", "DeviceUsagePairs",
            "PrimaryUsagePage", "PrimaryUsage", "MTEventSource", "TrackpadEmbedded",
            "SupportsGestureScrolling", "TrackpadFourFingerGestures", "IOCalloutDevice"]
    result = {k: node[k] for k in keys if k in node}
    result["parent_interface"] = interface
    for key in ["ReportDescriptor", "HIDReportDescriptor"]:
        value = node.get(key)
        if isinstance(value, bytes):
            result[key] = {"length": len(value), "sha256": hashlib.sha256(value).hexdigest()}
    result["children"] = [compact(child, interface) for child in node.get("IORegistryEntryChildren", [])]
    return result

def query(host):
    processes = subprocess.check_output(["/bin/ps", "-axo", "pid=,command="], text=True)
    for line in processes.splitlines():
        if str(ROOT) in line and any(x in line for x in ["/wiredkvm-native ", "/macos-capture"]):
            raise RuntimeError("Controller/capture still running; no serial access: " + line)
    interfaces = [n for n in walk([host]) if n.get("IOObjectClass") == "IOUSBHostInterface" and n.get("bInterfaceNumber") == 1]
    if len(interfaces) != 1:
        raise RuntimeError("Host control interface is ambiguous")
    ports = [n["IOCalloutDevice"] for n in walk(interfaces) if "IOCalloutDevice" in n]
    if len(ports) != 1:
        raise RuntimeError("Host control port is ambiguous: " + repr(ports))
    port = ports[0]
    # TIOCEXCL rejects later opens. Refuse an already-open client as well.
    held = subprocess.run(["/usr/sbin/lsof", "-t", port], capture_output=True, text=True)
    if held.stdout.strip():
        raise RuntimeError("Control port already open; no query")
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        import fcntl
        fcntl.ioctl(fd, termios.TIOCEXCL)
        attributes = termios.tcgetattr(fd)
        attributes[0] = 0; attributes[1] = 0
        attributes[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        attributes[3] = 0; attributes[4] = attributes[5] = termios.B115200
        attributes[6][termios.VMIN] = 0; attributes[6][termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSANOW, attributes)
        os.write(fd, b"MT2?\n")
        received = bytearray(); deadline = time.monotonic() + 3
        while time.monotonic() < deadline and len(received) < 4096:
            ready, _, _ = select.select([fd], [], [], .1)
            if ready:
                received.extend(os.read(fd, 512))
                if b"MT2," in received and received.endswith(b"\n"):
                    break
        lines = received.decode("ascii", errors="replace").splitlines()
        return {"port": port, "responses": lines, "has_mt2_reply": any(s.startswith("MT2,") for s in lines)}
    finally:
        os.close(fd)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--query", action="store_true")
    args = parser.parse_args()
    if args.out.exists():
        raise SystemExit("Refusing to overwrite evidence")
    registry = plistlib.loads(subprocess.check_output(["/usr/sbin/ioreg", "-r", "-c", "IOUSBHostDevice", "-l", "-w", "0", "-a"]))
    devices = [n for n in walk(registry) if n.get("IOObjectClass") == "IOUSBHostDevice"
               and n.get("USB Serial Number") == SERIAL
               and (n.get("idVendor"), n.get("idProduct")) in [(0x1a86, 0x4070), (0x05ac, 0x0265)]]
    result = {"devices": [compact(n) for n in devices], "diagnostics": None}
    if args.query:
        hosts = [n for n in devices if n.get("idVendor") == 0x1a86]
        try:
            if len(hosts) != 1:
                raise RuntimeError("Expected one already-identified board host")
            result["diagnostics"] = query(hosts[0])
        except (OSError, RuntimeError) as error:
            # Preserve enumeration evidence even when the control port is
            # missing. A failed query must not be mistaken for success.
            result["diagnostics"] = {"error": str(error), "has_mt2_reply": False}
    with args.out.open("x") as output:
        json.dump(result, output, ensure_ascii=False, indent=2)
        output.write("\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if args.query and not result["diagnostics"].get("has_mt2_reply"):
        raise SystemExit(2)

if __name__ == "__main__":
    main()
