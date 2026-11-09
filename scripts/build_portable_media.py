#!/usr/bin/env python3
"""Package an unpacked portable app as a readonly cable image. Never launch it.

The source volume must remain mounted while its program runs. No installer,
archive extraction, self-copy, login service, real USB or general clipboard.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess

from pack_dual_setup import pack, FLASH_BYTES

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(root):
    result = {}
    for p in sorted(root.rglob('*')):
        mode = p.lstat().st_mode
        if stat.S_ISLNK(mode) or not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise ValueError('unsupported payload entry')
        if p.is_file():
            result[str(p.relative_to(root))] = {'sha256': digest(p), 'executable': bool(mode & 0o111)}
    return result


def build(build_dir, out):
    build_dir, out = build_dir.resolve(), out.resolve()
    if not out.is_relative_to(ROOT / 'build'):
        raise ValueError('output must be a fresh directory under project/build')
    source = json.loads((build_dir / 'manifest.json').read_text())
    binary = Path(source['binary'])
    if not all(source.get(k) for k in ['collections', 'binaryBulk']) or source.get('legacyInputRelay') is not False:
        raise ValueError('portable tree/Bulk/native-input build required')
    if digest(binary) != source['sha256'] or not binary.is_relative_to(build_dir):
        raise ValueError('binary does not match the portable manifest')
    for name, expected in source['sources'].items():
        if digest(ROOT / name) != expected:
            raise ValueError('portable input changed: ' + name)
    out.mkdir(parents=True, exist_ok=False)
    commands = []

    def run(argv):
        argv = list(map(str, argv)); commands.append(argv)
        result = subprocess.run(argv, cwd=ROOT, capture_output=True, timeout=90)
        with (out / 'build.log').open('ab') as log:
            log.write((json.dumps(argv, ensure_ascii=False) + '\n').encode() + result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError('command failed; see ' + str(out / 'build.log'))
        return result.stdout

    app = binary.parents[2]
    run(['/usr/bin/codesign', '--verify', '--strict', '--deep', app])
    staging = out / 'staging'; staging.mkdir()
    shutil.copytree(app, staging / app.name, symlinks=False)
    (staging / '开始使用.txt').write_text(
        '先用主控电脑的鼠标进入被控电脑，再双击“WiredKVM 临时连接”。\n'
        '程序直接从本盘运行；不安装到应用程序，不注册后台服务或登录启动。\n'
        '运行期间请保留本盘，勿推出。图片和文件正文走独立 USB Bulk 通道。\n'
        '本机复制粘贴保持原生；退出菜单中的临时会话后停止跨机传输。\n'
        '本开发版仅有临时签名，首次启动或文件入口可能需要正常系统确认。\n', encoding='utf-8')
    expected = inventory(staging)
    generated = out / 'portable.dmg'
    run(['/usr/bin/hdiutil', 'makehybrid', '-hfs', '-hfs-volume-name', 'WiredKVM',
         '-hfs-openfolder', staging, '-o', generated, staging])
    image = out / 'portable.img'; generated.rename(image)
    mount = out / 'verify-mounted'; mount.mkdir()
    # makehybrid can synthesize empty FinderInfo attributes in HFS+. Even empty
    # attributes make strict codesign reject the app. Remove only this metadata
    # from our new image, then verify again on a fresh readonly attachment.
    run(['/usr/bin/hdiutil', 'attach', '-readwrite', '-nobrowse', '-noautoopen',
         '-mountpoint', mount, image])
    try:
        mounted_app = mount / app.name
        for p in [mounted_app, *mounted_app.rglob('*')]:
            probe = subprocess.run(['/usr/bin/xattr', '-p', 'com.apple.FinderInfo', str(p)], capture_output=True)
            if probe.returncode == 0:
                run(['/usr/bin/xattr', '-d', 'com.apple.FinderInfo', p])
        if inventory(mount) != expected:
            raise ValueError('metadata cleanup changed payload bytes or executable permission')
        run(['/usr/bin/codesign', '--verify', '--strict', '--deep', mounted_app])
    finally:
        run(['/usr/bin/hdiutil', 'detach', mount])
    asset = pack(image.read_bytes())  # Reject oversize; never silently discard an architecture.
    (out / 'cable-program.bin').write_bytes(asset)
    attached = False
    try:
        value = plistlib.loads(run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
                                  '-mountpoint', mount, '-plist', image]))
        attached = any(e.get('mount-point') == str(mount) for e in value['system-entities'])
        if not attached or inventory(mount) != expected:
            raise ValueError('mounted image content or executable permission differs')
        run(['/usr/bin/codesign', '--verify', '--strict', '--deep', mount / app.name])
    finally:
        if attached:
            run(['/usr/bin/hdiutil', 'detach', mount])
    manifest = {'format': 'WKDUAL01', 'mode': 'direct-from-cable', 'appBytes': binary.stat().st_size,
                'imageBytes': image.stat().st_size, 'assetBytes': len(asset), 'flashCapacity': FLASH_BYTES,
                'freeBytes': FLASH_BYTES - len(asset), 'imageSHA256': digest(image),
                'assetSHA256': hashlib.sha256(asset).hexdigest(), 'files': expected,
                'architectures': source['architectures'], 'mountedReadOnlyVerified': True,
                'launched': False, 'installed': False, 'deviceAccess': False, 'notarized': False}
    (out / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
    (out / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: manifest[k] for k in ['mode', 'assetBytes', 'freeBytes', 'mountedReadOnlyVerified', 'launched']}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build(args.build, args.output)
