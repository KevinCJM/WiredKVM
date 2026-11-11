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
    parser.add_argument('--stream-profile', action='store_true')
    parser.add_argument('--module-cache', type=Path)
    args = parser.parse_args()
    out = (args.output or ROOT / 'build' / ('tree-test-' + uuid.uuid4().hex)).resolve()
    if not any(out.is_relative_to(ROOT / p) for p in ['build', 'results']):
        raise ValueError('output must be new and inside project build/results')
    cache=args.module_cache.resolve() if args.module_cache else out/'swift-cache'
    if args.module_cache and (not cache.is_relative_to(ROOT/'build') or cache==ROOT/'build'):
        raise ValueError('shared module cache must be below project/build')
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
    names=['WKClipboardProtocol','WKOnboarding','WKFnKey','WKScrollRelay','WKGestureRelay','WKInputRelay',
           'WKClipboardContent','WKClipboardTransport','WKFilePortal','WKStreamFiles','WKTransferTree',
           'WKFilePipelineSelfTest','WKFilePortalSelfTest','WKOnDemandClipboard','WiredKVMCompanion']
    sources=[ROOT/'host/clipboard'/(name+'.swift') for name in names]
    sources += [ROOT/'tests/ch32v407_stream_test.swift',ROOT/'tests/collection_transfer_selftest.swift']
    inputs=sources+list((crate/'src').glob('*'))+list((crate/'include').glob('*'))+[crate/'build.rs',crate/'Cargo.toml',crate/'Cargo.lock']
    inputs += [ROOT/p for p in ['firmware/ch32v407/bridge.c','firmware/ch32v407/bridge.h','firmware/main/wire_protocol.c','firmware/main/wire_protocol.h','tests/ch32v407_sim.c','tests/ch32v407_sim.h']]
    before={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    (out/'source-hashes-before.json').write_text(json.dumps(before,indent=2)+'\n')
    rust_target = out/'rust-target'
    run(['cargo', 'test', '--manifest-path', crate/'Cargo.toml', '--offline', '--locked', '--target-dir', rust_target], 'rust-tests.log')
    run(['cargo', 'build', '--manifest-path', crate/'Cargo.toml', '--offline', '--locked', '--release', '--target-dir', rust_target], 'rust-build.log')
    objects=[]
    for name, src in [('bridge','firmware/ch32v407/bridge.c'),('wire','firmware/main/wire_protocol.c'),('sim','tests/ch32v407_sim.c')]:
        obj=out/(name+'.o');objects.append(obj)
        run(['/usr/bin/clang','-std=c11','-O2','-Wall','-Wextra','-Werror','-Ifirmware/ch32v407','-Ifirmware/main','-c',src,'-o',obj],name+'.log')
    binary=out/'collection-test'
    run(['/usr/bin/swiftc','-D','WK_PORTABLE','-D','WK_CH32_TEST','-D','WK_TREE',*(['-D','WK_STREAM_PROFILE'] if args.stream_profile else []),'-O','-parse-as-library',
         '-module-cache-path',cache,'-I',crate/'include','-framework','AppKit','-framework','IOKit',
         '-lcompression','-import-objc-header','tests/ch32v407_sim.h',*sources,*objects,
         rust_target/'release/libwiredkvm_transfer_tree.a','-o',binary],'swift-build.log')
    run([binary,'--collections','--json',out/'collections.json'],'collections.log')
    run([binary,'--result',out/'single-file.json'],'single-file.log')
    run([binary,'--io-benchmark','--io-benchmark-result',out/'short-write-benchmark.json'],'short-write-benchmark.log')
    run([binary,'--cancel'],'cancellation.log')
    run([binary,'--images'],'images.log')
    run([binary,'--pipeline'],'clipboard-pipeline.log')
    run([binary,'--collection-pipeline'],'collection-pipeline.log')
    if before!={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}:
        raise RuntimeError('test inputs changed after compilation; passing output is not acceptance')
    manifest={'physicalUSB':False,'generalClipboardAccess':False,'firmwareChanged':False,'streamProfile':args.stream_profile,'moduleCache':str(cache),
              'binary':str(binary),'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
              'sources':before}
    (out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    print(out)

if __name__=='__main__':
    main()
