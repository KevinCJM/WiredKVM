#!/usr/bin/env python3
"""Archive checked software evidence; explicitly excludes physical USB claims."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build/ch32v407'
OUT = ROOT / 'results/ch32v407-software-20261031'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    gates = {
        'all-tests.log':'CH32_ALL_TESTS_PASS',
        'firmware-build.log':'BUILD_OK: CH32V407',
        'host-build.log':'BUILD_OK: CH32 Mac host launcher',
        'core-test.log':'CORE_PASS',
        'stream-large.log':'CH32_STREAM_STRESS_PASS',
        'stream-pipeline.log':'CH32_PIPELINE_PASS',
        'stream-http.log':'CH32_FILE_BACKED_HTTP_PASS',
        'portal-test.log':'PORTAL_SELFTEST_PASS',
        'companion-selftest.log':'WKCLIP_SELF_TEST PASS',
        'test_native_absolute.py.log':'\nOK\n',
        'test_clipboard_native.py.log':'\nOK\n',
    }
    for name, marker in gates.items():
        assert marker in (BUILD/name).read_text(), f'Missing successful check: {name}'
    large = json.loads((BUILD/'stream-large.json').read_text())
    firmware = json.loads((BUILD/'firmware-verified.json').read_text())
    assert large['hidFailures']==0 and large['bytesAtoB']>2**32 and large['bytesBtoA']>2**32
    assert large['physicalUSB'] is False and firmware['physicalUSB'] is False
    assert firmware['firmwareSHA256']==digest(BUILD/'wiredkvm-ch32v407.bin')
    OUT.mkdir(parents=True,exist_ok=True)
    for name in [*gates,'stream-large.json','stream-http.json','firmware-verified.json','firmware-verify.log','test-build.log']:
        shutil.copy2(BUILD/name,OUT/name)
    additional = BUILD/'native-under-file-load.log'
    if additional.exists() and '\nOK\n' in additional.read_text(): shutil.copy2(additional,OUT/additional.name)
    source_paths = [*ROOT.glob('firmware/ch32v407/*'), *ROOT.glob('scripts/*ch32v407*'), *ROOT.glob('tests/ch32v407*'),
        *ROOT.glob('host/clipboard/*.swift'),ROOT/'host/ch32v407_host.swift',ROOT/'host/gui/WiredKVMClipboard.swift',
        ROOT/'host/macos_capture.swift',ROOT/'native/wiredkvm.cpp',ROOT/'native/desktop_pointer.hpp',
        ROOT/'native/wk_protocol.hpp',ROOT/'native/clipboard_channel.hpp',ROOT/'firmware/main/wire_protocol.c',
        ROOT/'firmware/main/wire_protocol.h',ROOT/'scripts/build.sh']
    artifacts = [BUILD/'wiredkvm-ch32v407.elf',BUILD/'wiredkvm-ch32v407.bin',BUILD/'wiredkvm-ch32v407.map',
        BUILD/'macos/wiredkvm-ch32-host',BUILD/'macos/wiredkvm-native',BUILD/'macos/macos-capture',
        BUILD/'macos/wiredkvm-companion',BUILD/'tests/core-test',BUILD/'tests/stream-test']
    manifest = {'recordedUTC':datetime.now(timezone.utc).isoformat(),'physicalUSB':False,
        'productionInstalled':False,'hardwareFlashed':False,'pcbDesigned':False,
        'sdkCommit':firmware['sdkCommit'],
        'sources':{str(p.relative_to(ROOT)):digest(p) for p in sorted(set(source_paths)) if p.is_file()},
        'artifacts':{str(p.relative_to(ROOT)):digest(p) for p in artifacts},
        'results':{p.name:digest(p) for p in sorted(OUT.iterdir()) if p.is_file() and p.name!='manifest.json'}}
    (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
    print(f'EVIDENCE_ARCHIVED {OUT}')


if __name__=='__main__': main()
