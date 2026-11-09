#!/usr/bin/env python3
"""Offline capacity experiment. Not an installer, flash tool, or device image.

Keep all current Mac GUI/installer resources plus the CH32 runtime. Build a
compressed resource archive, reconstruct it from a simulated 4 MiB NOR, mount
only the new test image read-only, and compare every payload file and signature.
The future small bootstrap has an explicit reservation; it is not implemented
or claimed to be tested by this capacity experiment.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
MIB = 1024 * 1024


def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True,
                          timeout=kwargs.pop('timeout', 120), **kwargs)


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(65536), b''):
            h.update(block)
    return h.hexdigest()


def inventory(root):
    result = {}
    for p in sorted(root.rglob('*')):
        info = p.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise ValueError(f'Unexpected symlink in audited build: {p}')
        if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
            raise ValueError(f'Unexpected payload type: {p}')
        row = {'mode': stat.S_IMODE(info.st_mode), 'directory': p.is_dir()}
        if p.is_file():
            row.update(bytes=info.st_size, sha256=sha(p))
        result[str(p.relative_to(root))] = row
    return result


def signatures(root):
    checked = []
    for app in sorted(root.rglob('*.app')):
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
        checked.append(str(app.relative_to(root)))
    for p in sorted((root / 'CH32-runtime').iterdir()):
        if p.is_file():
            run('/usr/bin/codesign', '--verify', '--strict', p)
            arch = run('/usr/bin/lipo', '-archs', p).stdout.decode().split()
            if set(arch) != {'arm64', 'x86_64'}:
                raise ValueError(f'Missing Mac architecture: {p}: {arch}')
            checked.append(str(p.relative_to(root)))
    return checked


def mount_verify(image, work, archive_hash, expected):
    mount = work / 'mounted'
    mount.mkdir()
    device = None
    before = sha(image)
    result = {}
    try:
        attached = plistlib.loads(run('/usr/bin/hdiutil', 'attach', '-readonly',
            '-nobrowse', '-noautoopen', '-mountpoint', mount, '-plist', image,
            timeout=45).stdout)
        entities = attached['system-entities']
        whole = [e['dev-entry'] for e in entities
                 if re.fullmatch(r'/dev/disk[0-9]+', e.get('dev-entry', ''))]
        own = [e for e in entities if e.get('mount-point') == str(mount)]
        if len(whole) == 1:
            device = whole[0]
        elif len(own) == 1:
            match = re.fullmatch(r'(/dev/disk[0-9]+)(?:s[0-9]+)*', own[0].get('dev-entry', ''))
            if match:
                device = match.group(1)
        if not device or len(own) != 1:
            raise ValueError(f'Unexpected attachment identity: {entities}')
        info = plistlib.loads(run('/usr/sbin/diskutil', 'info', '-plist', own[0]['dev-entry']).stdout)
        if info.get('WritableVolume', True):
            raise ValueError('Test image is not read-only')
        archive = mount / 'WiredKVM-complete-mac.tar.xz'
        if sha(archive) != archive_hash:
            raise ValueError('Archive changed through filesystem/flash readback')
        recovered = work / 'extracted'
        recovered.mkdir()
        began = time.monotonic()
        run('/usr/bin/tar', '-xf', archive, '-C', recovered)
        result['extract_seconds_local_ssd_not_usb'] = round(time.monotonic() - began, 3)
        actual = inventory(recovered / 'payload')
        if actual != expected:
            changed = sorted(k for k in expected.keys() | actual.keys() if expected.get(k) != actual.get(k))
            raise ValueError(f'File/mode/hash mismatch: {changed}')
        result['signature_checks'] = signatures(recovered / 'payload')
        # This entry point uses private test pasteboards and simulated transport.
        tested = run(recovered / 'payload/CH32-runtime/wiredkvm-companion', '--self-test', timeout=120)
        (work / 'extracted-companion-selftest.log').write_bytes(tested.stdout + tested.stderr)
        result.update(readonly_mount=True, every_file_and_mode_equal=True,
                      companion_private_selftest_pass=True, gui_application_launched=False,
                      selftest_executable_started=True)
    finally:
        if device:
            run('/usr/bin/hdiutil', 'detach', device, timeout=45)
        # Never recursively remove a mount directory or force-unmount anything.
        if not os.path.ismount(mount):
            mount.rmdir()
    if sha(image) != before:
        raise ValueError('Read-only verification changed image')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build, runtime, out = args.build.resolve(), args.runtime.resolve(), args.output.resolve()
    if not out.is_relative_to(ROOT / 'build'):
        parser.error('output must be a fresh directory under this project build/')
    out.mkdir(exist_ok=False)
    payload = out / 'payload'
    payload.mkdir()
    for name in ['WiredKVM.app', '安装 WiredKVM Companion.app', 'WiredKVM Companion.app']:
        source = build / name
        if not source.is_dir():
            raise ValueError(f'Missing complete application: {source}')
        run('/usr/bin/ditto', source, payload / name)
    run('/usr/bin/ditto', runtime, payload / 'CH32-runtime')
    expected = inventory(payload)
    original_checks = signatures(payload)
    manifest = out / 'payload-manifest.json'
    manifest.write_text(json.dumps(expected, ensure_ascii=False, indent=2) + '\n')
    archive = out / 'WiredKVM-complete-mac.tar.xz'
    began = time.monotonic()
    run('/usr/bin/tar', '-cJf', archive, '--options', 'xz:compression-level=9', '-C', out, 'payload')
    compression_seconds = round(time.monotonic() - began, 3)
    media = out / 'media'
    media.mkdir()
    shutil.copy2(archive, media / archive.name)
    shutil.copy2(manifest, media / manifest.name)
    (media / 'CAPACITY-AUDIT-ONLY.txt').write_text(
        'Capacity verification only. This is NOT a shipping installer.\n'
        'Complete current Mac app bundles and both-architecture CH32 tools are archived.\n'
        'A small bootstrap, CH32 MSC/SPI integration and physical USB tests are pending.\n')
    image = out / 'capacity.img'
    run('/usr/bin/hdiutil', 'makehybrid', '-hfs', '-hfs-volume-name', 'WK Capacity Audit',
        '-o', image, media)
    if not image.exists() and image.with_suffix('.img.dmg').exists():
        image.with_suffix('.img.dmg').rename(image)
    image_bytes = image.stat().st_size
    if image_bytes % 512:
        raise ValueError('Raw image not sector aligned')
    # These reservations are deliberate budgets, not completed updater code.
    reservations = dict(metadata_and_settings=128 * 1024, firmware_update=256 * 1024,
                        compact_bootstrap=512 * 1024, future_growth=512 * 1024)
    image_start = sum(v for k, v in reservations.items() if k != 'future_growth')
    bank_bytes = ((4 * MIB - image_start) // (2 * 4096)) * 4096
    if image_bytes + reservations['future_growth'] // 2 > bank_bytes:
        raise ValueError('Two resource banks plus per-bank growth allowance do not fit')
    used_budget = image_start + 2 * image_bytes + reservations['future_growth']
    if used_budget > 4 * MIB:
        raise ValueError(f'4 MiB budget exceeded: {used_budget}')
    fixture = out / 'capacity-only-DO-NOT-FLASH.bin'
    with fixture.open('xb') as f:
        f.write(b'\xff' * (4 * MIB))
        f.seek(0)
        f.write(b'WKCAPACITY-AUDIT-NOT-FIRMWARE\0')
        f.seek(image_start)
        f.write(image.read_bytes())
        f.seek(image_start + bank_bytes)
        f.write(image.read_bytes())
    readback = out / 'readback.img'
    # Model an uncompressed, bounded sector read from NOR. The MCU does NOT
    # decode XZ; the receiving Mac does that after it has read the archive.
    with fixture.open('rb') as source, readback.open('xb') as destination:
        for offset in range(0, image_bytes, 512):
            source.seek(image_start + offset)
            destination.write(source.read(512))
    if sha(readback) != sha(image):
        raise ValueError('Simulated NOR image differs')
    bank_b = out / 'readback-bank-b.img'
    with fixture.open('rb') as source, bank_b.open('xb') as destination:
        for offset in range(0, image_bytes, 512):
            source.seek(image_start + bank_bytes + offset)
            destination.write(source.read(512))
    if sha(bank_b) != sha(image):
        raise ValueError('Second resource bank differs')
    damaged = bytearray(fixture.read_bytes())
    damaged[image_start + 1024] ^= 1
    if hashlib.sha256(damaged[image_start:image_start + image_bytes]).hexdigest() == sha(image):
        raise ValueError('Corruption fixture did not change bank A')
    start_b = image_start + bank_bytes
    if hashlib.sha256(damaged[start_b:start_b + image_bytes]).hexdigest() != sha(image):
        raise ValueError('Corruption in bank A damaged bank B')
    checked = mount_verify(readback, out, sha(archive), expected)
    result = dict(scope='Mac arm64+x86_64 capacity audit, not shipping installer',
        full_raw_payload_bytes=sum(v.get('bytes', 0) for v in expected.values()),
        original_target_setup_image_bytes=(build / 'setup/setup.img').stat().st_size,
        compressed_archive_bytes=archive.stat().st_size,
        archive_sha256=sha(archive), hfs_image_bytes=image_bytes,
        raw_image_sha256=sha(image), external_flash_bytes=4 * MIB,
        reservations_bytes=reservations, total_with_reservations=used_budget,
        spare_after_all_reservations=4 * MIB - used_budget,
        resource_banks=2, resource_bank_bytes=bank_bytes,
        per_bank_unused_bytes=bank_bytes-image_bytes,
        both_resource_banks_readback_equal=True, simulated_corrupt_bank_a_keeps_b=True,
        atomic_updater_implemented=False,
        raw_sector_readback_equal=True, file_count=sum(not v['directory'] for v in expected.values()),
        compression_seconds_local_only=compression_seconds,
        source_signature_checks=original_checks,
        firmware_internal_flash_binary_bytes=(ROOT / 'build/ch32v407/wiredkvm-ch32v407.bin').stat().st_size,
        bootstrap_implemented=False, ch32_spi_msc_implemented=False,
        physical_usb_validated=False, runtime_sources_changed=False,
        windows_installer_included=False, **checked)
    (out / 'capacity-result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
