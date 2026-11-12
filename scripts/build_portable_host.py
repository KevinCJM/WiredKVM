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

from build_portable_companion import SOURCES, ROOT, RUST_LIBRARIES, rust_input_paths


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['output','companion-build','media-build','capture','touch','loader']:
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--media-companion-build',type=Path,
        help='explicit older target artifact, when only the Book companion is updated')
    parser.add_argument('--probe-media',action='store_true',help='temporary memory-only benchmark image; retain input and release file CDC after upload')
    parser.add_argument('--module-cache',type=Path,help='explicit shared Swift cache below project/build')
    args=parser.parse_args();out=args.output.resolve()
    if not out.is_relative_to(ROOT/'build'):
        raise ValueError('output must be a fresh project build directory')
    cache=args.module_cache.resolve() if args.module_cache else out/'swift-cache'
    if not cache.is_relative_to(ROOT/'build') or cache==ROOT/'build':raise ValueError('module cache must be below project/build')
    companion=json.loads((args.companion_build/'manifest.json').read_text())
    target_build=args.media_companion_build or args.companion_build
    target=json.loads((target_build/'manifest.json').read_text())
    media=json.loads((args.media_build/'manifest.json').read_text())
    asset=(args.media_build/'cable-program.bin').resolve()
    if sha(asset)!=media['assetSHA256'] or not media['mountedReadOnlyVerified']:
        raise ValueError('program disk was not verified')
    binary=Path(companion['binary'])
    if sha(binary)!=companion['sha256']:
        raise ValueError('companion hash mismatch')
    target_binary=Path(target['binary'])
    if args.probe_media:
        if media.get('mode')!='memory-usb-diagnostic' or media.get('installed') is not False:raise ValueError('explicit diagnostic media required')
        target_binary=Path(media['binary']);target={'sha256':media['binarySHA256']}
        for p,digest in media['sources'].items():
            if sha(ROOT/p)!=digest:raise ValueError('probe source changed: '+p)
    if sha(target_binary)!=target['sha256']:
        raise ValueError('target artifact hash mismatch')
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(target_binary.parents[2])],check=True)
    suffix='/Contents/MacOS/WiredKVMUSBProbe' if args.probe_media else '/Contents/MacOS/WiredKVMPortable'
    if not any(p.endswith(suffix) and row['sha256']==target['sha256']
               for p,row in media['files'].items()):
        raise ValueError('program disk contains a different companion build')
    for p,digest in companion['sources'].items():
        if sha(ROOT/p)!=digest:raise ValueError('companion source changed: '+p)
    sources=[ROOT/'host/clipboard'/(p+'.swift') for p in SOURCES]+[ROOT/'host/gui/WiredKVMClipboard.swift',ROOT/'host/ch32v407_host.swift']
    tracked=sources+sorted((ROOT/'native').glob('*.hpp'))+[ROOT/'native/wiredkvm.cpp']+rust_input_paths()
    source_hashes={str(p.relative_to(ROOT)):sha(p) for p in tracked}
    out.mkdir(parents=True,exist_ok=False);commands=[]
    def run(argv):
        argv=list(map(str,argv));commands.append(argv)
        r=subprocess.run(argv,cwd=ROOT,capture_output=True,timeout=180)
        with (out/'build.log').open('ab') as f:f.write((json.dumps(argv)+'\n').encode()+r.stdout+r.stderr)
        if r.returncode:raise RuntimeError('build failed; see '+str(out/'build.log'))
    native=out/'wiredkvm-native';relay=out/'wiredkvm-companion';loader=out/'wiredkvm-cable-loader'
    shutil.copy2(binary,relay);shutil.copy2(args.loader,loader)
    run(['/usr/bin/clang++','-std=c++17','-O2','-Wall','-Wextra','-Wpedantic','-Werror','-mmacosx-version-min=13.0',ROOT/'native/wiredkvm.cpp','-o',native])
    arch={'arm64':'aarch64-apple-darwin','x86_64':'x86_64-apple-darwin'}[platform.machine()]
    archives=[];includes=[]
    for directory,library in RUST_LIBRARIES:
        archive=(args.companion_build/'rust-target'/arch/('release/lib'+library+'.a')).resolve()
        if companion.get('staticLibraries',{}).get(str(archive))!=sha(archive):
            raise ValueError('companion static library hash mismatch: '+library)
        archives.append(archive);includes+=['-I',ROOT/'native'/directory/'include']
    host=out/'wiredkvm-ch32-host'
    run(['/usr/bin/swiftc','-D','WK_PORTABLE','-D','WK_TREE','-D','WK_CH32_TEST','-O','-parse-as-library',
         '-target',platform.machine()+'-apple-macosx13.0',
         '-module-cache-path',cache,*includes,'-framework','AppKit','-framework','IOKit','-lcompression',
         *sources,*archives,'-o',host])
    run(['/usr/bin/codesign','--force','--sign','-','--identifier','com.wiredkvm.ch32.portable-host',host])
    config={'native':str(native),'companion':str(relay),'capture':str(args.capture.resolve()),
            'touch':str(args.touch.resolve()),'loader':str(loader),'asset':str(asset)}
    config['hashes']={p:sha(Path(p)) for p in config.values()}
    if args.probe_media:config['diagnosticOnly']=True
    (out/'runtime.json').write_text(json.dumps(config,ensure_ascii=False,indent=2)+'\n')
    for path,digest in source_hashes.items():
        if sha(ROOT/path)!=digest:raise ValueError('source changed during build: '+path)
    manifest={'host':str(host),'hostSHA256':sha(host),'runtime':config,'launched':False,'autostartChanged':False,
              'inputFirst':True,'programUploadUsesSeparateCDC':True,'moduleCache':str(cache),'streamProfile':companion.get('streamProfile',False),
              'targetArtifact':str(target_binary),'targetArtifactSHA256':target['sha256'],
              'targetSourceHashesCheckedAgainstCurrentTree':args.media_companion_build is None,
              'diagnosticOnly':args.probe_media,
              'sources':source_hashes}
    (out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    (out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n')
    print(json.dumps({'host':str(host),'launched':False,'autostartChanged':False}))


if __name__=='__main__':main()
