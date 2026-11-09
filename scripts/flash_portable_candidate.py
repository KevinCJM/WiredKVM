#!/usr/bin/env python3
"""Explicit DBG-only prototype update with identity, full backup and readback.

--describe is read-only filesystem inspection. --flash pauses/restarts the
verified MCU; use only after the user connects DBG alone. It never changes
Book autostart, starts target programs, or uploads an image to RAM.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

ROOT=Path(__file__).resolve().parents[1]
PROBE='A47C8F062A1A'
UID='ad-21-ad-50-6c-54-c6-c6'
CHIP='0x46740011'
TOOL_SHA='4f116e0f31a434320c18affecba894028a5873f8fe331382c4448a62feff2c61'
ACCEPTED={
    'native-v2':('candidate-native-v2-final-20261109','9322b86a3e70b272e71716d1051ec641783afdd33b8d0fc40452608f33d0866b'),
    'ram-setup-v1':('candidate-ram-setup-20261109-final','dde0403eccbade5d6a032dab4659170d8e468393a84d392cc7596c33bffed9e4'),
    'ram-diag-v2':('candidate-ram-setup-20261109-diag-v2','0d3a5fff3d92a3530de7919a070f3cef05e191cc6dd97c724c54b0dcef2c11fd'),
}
BACKUP_BYTES=576*1024

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser(description=__doc__)
    action=p.add_mutually_exclusive_group(required=True);action.add_argument('--describe',action='store_true');action.add_argument('--flash',action='store_true')
    p.add_argument('--profile',type=Path,required=True);p.add_argument('--wlink',type=Path,required=True);p.add_argument('--output',type=Path)
    p.add_argument('--expected-current',choices=ACCEPTED,help='explicit pinned running firmware to back up before writing')
    a=p.parse_args();profile=json.loads(a.profile.read_text());image=Path(profile['binary']['path'])
    if not profile.get('ram_setup') or sha(image)!=profile['binary']['sha256'] or sha(a.wlink)!=TOOL_SHA:raise ValueError('candidate or tool hash mismatch')
    for name,digest in profile['inputs'].items():
        if sha(Path(name))!=digest:raise ValueError('build input changed: '+name)
    if a.describe:
        print(json.dumps({'candidateSHA256':sha(image),'bytes':image.stat().st_size,'probe':PROBE,'chip':CHIP,'uid':UID,'deviceAccess':False}));return
    if not a.expected_current:raise ValueError('--flash requires --expected-current; never guess the active firmware')
    folder,digest=ACCEPTED[a.expected_current]
    baseline=ROOT/'experiments/mt2-petros-profile'/folder/'wiredkvm-mt2-stage1.bin'
    if sha(baseline)!=digest:raise ValueError('known input firmware backup missing or changed')
    if not a.output:raise ValueError('--flash requires a fresh results directory')
    out=a.output.resolve()
    if not out.is_relative_to(ROOT/'results'):raise ValueError('output must be under project results')
    out.mkdir(parents=True,exist_ok=False)
    def run(name,argv):
        r=subprocess.run(list(map(str,argv)),capture_output=True,timeout=90)
        (out/name).write_bytes(r.stdout+r.stderr)
        if r.returncode:raise RuntimeError('operation failed; see '+str(out/name))
        return (r.stdout+r.stderr).decode(errors='replace')
    raw=subprocess.check_output(['/usr/sbin/ioreg','-a','-l','-p','IOUSB']);(out/'inventory.plist').write_bytes(raw);found=[]
    def walk(n):
        if isinstance(n,dict):
            if n.get('IOObjectClass')=='IOUSBHostDevice' and (n.get('idVendor'),n.get('idProduct')) in [(0x1a86,0x8010),(0x1a86,0x4070),(0x05ac,0x0265)]:found.append(n)
            for v in n.values():
                if isinstance(v,(dict,list)):walk(v)
        elif isinstance(n,list):
            for v in n:walk(v)
    walk(plistlib.loads(raw))
    if len(found)!=1 or (found[0].get('idVendor'),found[0].get('idProduct'),found[0].get('USB Serial Number'))!=(0x1a86,0x8010,PROBE):
        raise ValueError('exact sole DBG required; no device operation performed')
    base=[a.wlink,'--device','0','--chip','CH32V4X7','--no-detach']
    status=run('identity.log',base+['status'])
    if CHIP not in status or UID not in status.lower():raise ValueError('chip identity mismatch; no flash performed')
    backup=out/'before-full.bin';readback=out/'readback.bin';written=False
    try:
        run('backup.log',base+['dump','0x08000000',str(BACKUP_BYTES),'--out',backup])
        data=backup.read_bytes()
        if len(data)!=BACKUP_BYTES or not data.startswith(baseline.read_bytes()):raise ValueError('running firmware is not the accepted baseline; no flash performed')
        written=True;run('flash.log',base+['flash','--no-run',image])
        run('readback.log',base+['dump','0x08000000',str(image.stat().st_size),'--out',readback])
        if readback.read_bytes()!=image.read_bytes():raise ValueError('independent firmware readback mismatch')
    except Exception:
        if written:
            run('rollback.log',base+['flash','--no-run',backup]);restored=out/'restored.bin'
            run('rollback-readback.log',base+['dump','0x08000000',str(BACKUP_BYTES),'--out',restored])
            if restored.read_bytes()!=backup.read_bytes():raise RuntimeError('rollback readback mismatch; leave DBG attached')
        run('abort-resume.log',[a.wlink,'--device','0','--chip','CH32V4X7','reset','quit'])
        raise
    run('resume.log',[a.wlink,'--device','0','--chip','CH32V4X7','reset','quit'])
    result={'firmwareSHA256':sha(image),'bytes':image.stat().st_size,'backupSHA256':sha(backup),'backupBytes':BACKUP_BYTES,
            'readbackVerified':True,'probe':PROBE,'uid':UID,'chip':CHIP,'runtimeAccepted':False,'clipboardAccepted':False,'autostartChanged':False}
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))

if __name__=='__main__':main()
