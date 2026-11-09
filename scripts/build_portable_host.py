#!/usr/bin/env python3
"""Build an isolated Book coordinator. Never launch it or replace autostart.

Reuse explicitly supplied, already accepted capture/touch binaries in place.
The new coordinator starts input first, uploads the source disk on the separate
file CDC function, then starts clipboard. Loader errors retain input and retry.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess

from build_portable_companion import SOURCES, ROOT


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['output','companion-build','media-build','capture','touch','loader']:
        parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args();out=args.output.resolve()
    if not out.is_relative_to(ROOT/'build'):
        raise ValueError('output must be a fresh project build directory')
    companion=json.loads((args.companion_build/'manifest.json').read_text())
    media=json.loads((args.media_build/'manifest.json').read_text())
    asset=(args.media_build/'cable-program.bin').resolve()
    if sha(asset)!=media['assetSHA256'] or not media['mountedReadOnlyVerified']:
        raise ValueError('program disk was not verified')
    binary=Path(companion['binary'])
    if sha(binary)!=companion['sha256']:
        raise ValueError('companion hash mismatch')
    if not any(p.endswith('/Contents/MacOS/WiredKVMPortable') and row['sha256']==companion['sha256']
               for p,row in media['files'].items()):
        raise ValueError('program disk contains a different companion build')
    for p,digest in companion['sources'].items():
        if sha(ROOT/p)!=digest:raise ValueError('companion source changed: '+p)
    out.mkdir(parents=True,exist_ok=False);commands=[]
    def run(argv):
        argv=list(map(str,argv));commands.append(argv)
        r=subprocess.run(argv,cwd=ROOT,capture_output=True,timeout=180)
        with (out/'build.log').open('ab') as f:f.write((json.dumps(argv)+'\n').encode()+r.stdout+r.stderr)
        if r.returncode:raise RuntimeError('build failed; see '+str(out/'build.log'))
    native=out/'wiredkvm-native';relay=out/'wiredkvm-companion';loader=out/'wiredkvm-cable-loader'
    shutil.copy2(binary,relay);shutil.copy2(args.loader,loader)
    run(['/usr/bin/clang++','-std=c++17','-O2','-Wall','-Wextra','-Wpedantic','-Werror','-mmacosx-version-min=13.0',ROOT/'native/wiredkvm.cpp','-o',native])
    crate=ROOT/'native/transfer-tree'
    arch={'arm64':'aarch64-apple-darwin','x86_64':'x86_64-apple-darwin'}[platform.machine()]
    archive=args.companion_build/'rust-target'/arch/'release/libwiredkvm_transfer_tree.a'
    sources=[ROOT/'host/clipboard'/(p+'.swift') for p in SOURCES]+[ROOT/'host/gui/WiredKVMClipboard.swift',ROOT/'host/ch32v407_host.swift']
    host=out/'wiredkvm-ch32-host'
    run(['/usr/bin/swiftc','-D','WK_PORTABLE','-D','WK_TREE','-D','WK_CH32_TEST','-O','-parse-as-library',
         '-target',platform.machine()+'-apple-macosx13.0',
         '-module-cache-path',out/'swift-cache','-I',crate/'include','-framework','AppKit','-framework','IOKit','-lcompression',
         *sources,archive,'-o',host])
    run(['/usr/bin/codesign','--force','--sign','-','--identifier','com.wiredkvm.ch32.portable-host',host])
    config={'native':str(native),'companion':str(relay),'capture':str(args.capture.resolve()),
            'touch':str(args.touch.resolve()),'loader':str(loader),'asset':str(asset)}
    config['hashes']={p:sha(Path(p)) for p in config.values()}
    (out/'runtime.json').write_text(json.dumps(config,ensure_ascii=False,indent=2)+'\n')
    manifest={'host':str(host),'hostSHA256':sha(host),'runtime':config,'launched':False,'autostartChanged':False,
              'inputFirst':True,'programUploadUsesSeparateCDC':True,
              'sources':{str(p.relative_to(ROOT)):sha(p) for p in sources+[ROOT/'native/wiredkvm.cpp']}}
    (out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    (out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n')
    print(json.dumps({'host':str(host),'launched':False,'autostartChanged':False}))


if __name__=='__main__':main()
