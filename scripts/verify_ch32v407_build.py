#!/usr/bin/env python3
"""Inspect the built ELF/bin, not a second handwritten set of descriptors."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build/ch32v407'
DEFAULT = Path.home() / '.local/share/esp32-agent/idf-tools/tools/riscv32-esp-elf/esp-15.2.0_20251204/riscv32-esp-elf/bin/riscv32-esp-elf-'
PREFIX = os.environ.get('WK_RISCV_PREFIX', str(DEFAULT))


def main():
    elf = BUILD / 'wiredkvm-ch32v407.elf'
    binary = (BUILD / 'wiredkvm-ch32v407.bin').read_bytes()
    output = subprocess.check_output([PREFIX+'nm', '-S', '--defined-only', str(elf)], text=True)
    symbols = {}
    for row in output.splitlines():
        parts = row.split()
        if len(parts) == 4: symbols[parts[3]] = (int(parts[0],16),int(parts[1],16))
        elif len(parts) == 3: symbols[parts[2]] = (int(parts[0],16),0)
    summaries = {}
    for name in ['host_hs','host_fs','target_hs','target_fs']:
        addr,length = symbols[name]; data = binary[addr:addr+length]
        assert len(data) == length and int.from_bytes(data[2:4],'little') == length
        pos = 0; interfaces = []; endpoints = []; counts = {}; current = None; classes = []
        while pos < length:
            n,kind = data[pos:pos+2]; assert n >= 2 and pos+n <= length
            d = data[pos:pos+n]
            if kind == 4:
                current = d[2]; interfaces.append(current); counts[current] = [d[4],0]; classes.append(d[5])
            if kind == 5:
                ep,typ,mps = d[2], d[3]&3, int.from_bytes(d[4:6],'little')
                assert current is not None and (ep&15) in range(1,8) and ep not in endpoints
                endpoints.append(ep); counts[current][1] += 1
                assert mps == (512 if name.endswith('hs') else 64) if typ == 2 else mps <= 64
                if typ == 3: assert d[6] > 0
            pos += n
        assert len(interfaces)==data[4] and set(interfaces)==set(range(data[4]))
        assert all(expected==actual for expected,actual in counts.values())
        assert classes.count(8) == 1 and classes[-1] == 8  # local read-only onboarding LUN
        assert data[4] == (5 if name.startswith('host') else 6)
        summaries[name]={'bytes':length,'interfaces':interfaces,'endpoints':[hex(e) for e in endpoints]}
    start = symbols['_sbss'][0]; end = symbols['_ebss'][0]
    stack = symbols['__stack_size'][0]
    assert stack == 8192 and end <= symbols['_eusrstack'][0]-stack
    assert len(binary) < 576*1024 and end-0x20000400+stack < 135*1024
    assert '__getreent' in symbols
    report = {'physicalUSB':False,'sdkCommit':'de8b9431e2c2f862d067a77d44859aee9e12e1d3',
        'firmwareBytes':len(binary),'firmwareSHA256':hashlib.sha256(binary).hexdigest(),
        'bssBytes':end-start,'staticRAMPlusStackBytes':end-0x20000400+stack,'stackBytes':stack,
        'ramLinkRegionBytes':135*1024,'descriptors':summaries}
    (BUILD/'firmware-verified.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__': main()
