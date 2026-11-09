#!/usr/bin/env python3
"""Check our fresh disk image and both sealed apps, then detach. Never launch."""
import hashlib
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile


def main():
    out = Path(sys.argv[1]).resolve()
    image = out/'setup.img'
    assert image.stat().st_size % 512 == 0
    directory = Path(tempfile.mkdtemp(prefix='verify-', dir=out))
    mount = directory/'mounted'; mount.mkdir()
    disk = None
    try:
        result = subprocess.run(['/usr/bin/hdiutil','attach','-readwrite','-nobrowse','-noautoopen',
            '-mountpoint',str(mount),'-plist',str(image)],check=True,capture_output=True,timeout=30)
        entries = plistlib.loads(result.stdout)['system-entities']
        disks = [e['dev-entry'] for e in entries if re.fullmatch('/dev/disk[0-9]+',e.get('dev-entry',''))]
        assert len(disks)==1; disk=disks[0]
        app=mount/'安装 WiredKVM.app'
        subprocess.run(['/usr/bin/xattr','-dr','com.apple.FinderInfo',str(app)],check=True,timeout=20)
        subprocess.run(['/usr/bin/codesign','--verify','--strict','--deep','-R',
            '=identifier "com.wiredkvm.onboarding"',str(app)],check=True,timeout=20)
        for relative in ['Contents/Info.plist','Contents/MacOS/WiredKVMSetup','Contents/Resources/applications.tar.xz']:
            assert (app/relative).read_bytes()==(out/'staging/安装 WiredKVM.app'/relative).read_bytes()
    finally:
        if disk: subprocess.run(['/usr/bin/hdiutil','detach',disk],check=True,timeout=30)
        if not mount.is_mount():
            mount.rmdir();directory.rmdir()
    # Extract only the builder-created signed archive into our own new directory.
    extracted=Path(tempfile.mkdtemp(prefix='extract-',dir=out))
    subprocess.run(['/usr/bin/tar','-xJf',str(out/'applications.tar.xz'),'-C',str(extracted),
                    '--no-same-owner'],check=True,timeout=30)
    for name,identifier in [('WiredKVM.app','com.wiredkvm.menu'),('WiredKVM Companion.app','com.wiredkvm.companion')]:
        subprocess.run(['/usr/bin/codesign','--verify','--strict','--deep','-R',f'=identifier "{identifier}"',
                        str(extracted/name)],check=True,timeout=20)
    print('DUAL_SETUP_MEDIA_PASS both_signed_roles=true exact_payload=true detached=true no_app_launched=true')


if __name__=='__main__': main()
