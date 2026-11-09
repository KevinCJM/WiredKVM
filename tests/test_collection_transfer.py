#!/usr/bin/env python3
"""Build/run isolated collection Bulk tests. Never open USB or a real clipboard."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    out = (args.output or ROOT / 'build' / ('tree-test-' + uuid.uuid4().hex)).resolve()
    if not any(out.is_relative_to(ROOT / p) for p in ['build', 'results']):
        raise ValueError('output must be new and inside project build/results')
    out.mkdir(parents=True, exist_ok=False)
    commands = []
    def run(argv, log, timeout=180):
        argv = list(map(str, argv)); commands.append(argv)
        (out / 'commands.json').write_text(json.dumps(commands, indent=2)+'\n')
        with (out / log).open('w') as stream:
            result = subprocess.run(argv, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
        if result.returncode:
            raise RuntimeError(f'{result.returncode}: see {out / log}')

    crate = ROOT / 'native/transfer-tree'
    rust_target = out/'rust-target'
    run(['cargo', 'test', '--manifest-path', crate/'Cargo.toml', '--offline', '--locked', '--target-dir', rust_target], 'rust-tests.log')
    run(['cargo', 'build', '--manifest-path', crate/'Cargo.toml', '--offline', '--locked', '--release', '--target-dir', rust_target], 'rust-build.log')
    objects=[]
    for name, src in [('bridge','firmware/ch32v407/bridge.c'),('wire','firmware/main/wire_protocol.c'),('sim','tests/ch32v407_sim.c')]:
        obj=out/(name+'.o');objects.append(obj)
        run(['/usr/bin/clang','-std=c11','-O2','-Wall','-Wextra','-Werror','-Ifirmware/ch32v407','-Ifirmware/main','-c',src,'-o',obj],name+'.log')
    names=['WKClipboardProtocol','WKOnboarding','WKFnKey','WKScrollRelay','WKGestureRelay','WKInputRelay',
           'WKClipboardContent','WKClipboardTransport','WKFilePortal','WKStreamFiles','WKTransferTree',
           'WKFilePipelineSelfTest','WKFilePortalSelfTest','WKOnDemandClipboard','WiredKVMCompanion']
    sources=[ROOT/'host/clipboard'/(name+'.swift') for name in names]
    sources += [ROOT/'tests/ch32v407_stream_test.swift',ROOT/'tests/collection_transfer_selftest.swift']
    binary=out/'collection-test'
    run(['/usr/bin/swiftc','-D','WK_PORTABLE','-D','WK_CH32_TEST','-D','WK_TREE','-O','-parse-as-library',
         '-module-cache-path',out/'swift-cache','-I',crate/'include','-framework','AppKit','-framework','IOKit',
         '-lcompression','-import-objc-header','tests/ch32v407_sim.h',*sources,*objects,
         rust_target/'release/libwiredkvm_transfer_tree.a','-o',binary],'swift-build.log')
    run([binary,'--collections','--json',out/'collections.json'],'collections.log')
    run([binary,'--json',out/'single-file.json'],'single-file.log')
    run([binary,'--cancel'],'cancellation.log')
    run([binary,'--images'],'images.log')
    run([binary,'--pipeline'],'clipboard-pipeline.log')
    run([binary,'--collection-pipeline'],'collection-pipeline.log')
    inputs=sources+list((crate/'src').glob('*'))+list((crate/'include').glob('*'))+[crate/'build.rs',crate/'Cargo.toml',crate/'Cargo.lock']
    manifest={'physicalUSB':False,'generalClipboardAccess':False,'firmwareChanged':False,
              'binary':str(binary),'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
              'sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}}
    (out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    print(out)

if __name__=='__main__':
    main()
