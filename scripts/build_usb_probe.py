#!/usr/bin/env python3
"""Build a temporary cable-run USB benchmark app and verified readonly image.

No launch, installation, hardware access or active runtime replacement.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
from build_portable_media import inventory
from pack_dual_setup import pack, FLASH_BYTES

ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--module-cache',type=Path,required=True)
    args=parser.parse_args();out=args.output.resolve();cache=args.module_cache.resolve()
    if not out.is_relative_to(ROOT/'build') or not cache.is_relative_to(ROOT/'build'):raise ValueError('project build paths required')
    out.mkdir(parents=True,exist_ok=False)
    crate=ROOT/'experiments/usb-throughput-probe'
    inputs=sorted(p for p in crate.rglob('*') if p.is_file() and 'target' not in p.relative_to(crate).parts)
    inputs += [Path(__file__),ROOT/'scripts/build_portable_media.py',ROOT/'scripts/pack_dual_setup.py']
    hashes={str(p.relative_to(ROOT)):sha(p) for p in inputs};commands=[]
    def run(argv,timeout=180):
        argv=list(map(str,argv));commands.append(argv)
        r=subprocess.run(argv,cwd=ROOT,capture_output=True,timeout=timeout)
        with (out/'build.log').open('ab') as f:f.write((json.dumps(argv)+'\n').encode()+r.stdout+r.stderr)
        if r.returncode:raise RuntimeError('command failed; see '+str(out/'build.log'))
        return r.stdout
    staging=out/'staging';staging.mkdir();app=staging/'WiredKVM USB 测速.app';mac=app/'Contents/MacOS';resources=app/'Contents/Resources'
    mac.mkdir(parents=True);resources.mkdir()
    rusts=[];uis=[]
    for arch,target in [('arm64','aarch64-apple-darwin'),('x86_64','x86_64-apple-darwin')]:
        run(['cargo','build','--offline','--locked','--release','--target',target,'--manifest-path',crate/'Cargo.toml','--target-dir',out/'rust-target'])
        rusts.append(out/'rust-target'/target/'release/wiredkvm-usb-throughput-probe')
        ui=out/('ui-'+arch);uis.append(ui)
        run(['/usr/bin/swiftc','-O','-parse-as-library','-target',arch+'-apple-macosx13.0','-module-cache-path',cache,'-framework','AppKit',crate/'ProbeApp.swift','-o',ui])
    tool=resources/'wiredkvm-usb-throughput-probe';binary=mac/'WiredKVMUSBProbe'
    for parts,dest in [(rusts,tool),(uis,binary)]:
        run(['/usr/bin/lipo','-create',*parts,'-output',dest]);dest.chmod(0o755)
        run(['/usr/bin/codesign','--force','--sign','-',dest])
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.wiredkvm.usb-probe','CFBundleName':'WiredKVM USB 测速','CFBundleExecutable':'WiredKVMUSBProbe','CFBundlePackageType':'APPL','CFBundleVersion':'1','LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True}))
    run(['/usr/bin/codesign','--force','--sign','-',app]);run(['/usr/bin/codesign','--verify','--strict','--deep',app])
    run([tool,'--describe'])
    (staging/'开始使用.txt').write_text('双击“WiredKVM USB 测速”。程序从线内临时运行，不安装。\n测试期间可使用键鼠和手势；请保留本盘。成功后会自动退出；中止时请点“退出测速”。\n更新或拔线前，必须先退出应用，再安全推出程序盘。\n',encoding='utf-8')
    expected=inventory(staging);generated=out/'probe.dmg';image=out/'probe.img';mount=out/'verify-mounted';mount.mkdir()
    run(['/usr/bin/hdiutil','makehybrid','-hfs','-hfs-volume-name','WiredKVM','-hfs-openfolder',staging,'-o',generated,staging]);generated.rename(image)
    run(['/usr/bin/hdiutil','attach','-readwrite','-nobrowse','-noautoopen','-mountpoint',mount,image])
    try:
        mounted=mount/app.name
        for p in [mounted,*mounted.rglob('*')]:
            test=subprocess.run(['/usr/bin/xattr','-p','com.apple.FinderInfo',p],capture_output=True)
            if test.returncode==0:run(['/usr/bin/xattr','-d','com.apple.FinderInfo',p])
        if inventory(mount)!=expected:raise ValueError('media payload changed')
        run(['/usr/bin/codesign','--verify','--strict','--deep',mounted])
    finally:run(['/usr/bin/hdiutil','detach',mount])
    asset=pack(image.read_bytes());(out/'cable-program.bin').write_bytes(asset)
    run(['/usr/bin/hdiutil','attach','-readonly','-nobrowse','-noautoopen','-mountpoint',mount,image])
    try:
        if inventory(mount)!=expected:raise ValueError('readonly payload mismatch')
        run(['/usr/bin/codesign','--verify','--strict','--deep',mount/app.name])
    finally:run(['/usr/bin/hdiutil','detach',mount])
    if hashes!={str(p.relative_to(ROOT)):sha(p) for p in inputs}:raise ValueError('source changed during build')
    manifest={'mode':'memory-usb-diagnostic','binary':str(binary),'binarySHA256':sha(binary),'assetSHA256':sha(out/'cable-program.bin'),'assetBytes':len(asset),'freeBytes':FLASH_BYTES-len(asset),'files':expected,'sources':hashes,'mountedReadOnlyVerified':True,'installed':False,'launched':False,'deviceAccess':False,'architectures':['arm64','x86_64']}
    (out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n');(out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n')
    print(json.dumps({k:manifest[k] for k in ['mode','assetBytes','freeBytes','mountedReadOnlyVerified','installed','launched']}))

if __name__=='__main__':main()
