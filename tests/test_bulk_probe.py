#!/usr/bin/env python3
"""Memory-only diagnostic core and generated input regression. No USB access."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--large-in', action='store_true')
    args = parser.parse_args()
    out = (args.output or ROOT/'build'/('bulk-probe-test-'+uuid.uuid4().hex)).resolve()
    if not any(out.is_relative_to(ROOT/p) for p in ['build', 'results']):
        raise ValueError('output must be a new project build/results directory')
    out.mkdir(parents=True, exist_ok=False)
    paths = ['experiments/mt2-petros-profile/'+n for n in ['bulk_probe.h','bulk_rx.h','bulk_batch.h','build_profile.py','test_bulk_probe.c','test_live_touch.py','test_live_touch_main.c']]
    paths += ['firmware/ch32v407/'+n for n in ['bridge.c','bridge.h','main.c','descriptors.c']]
    paths += ['firmware/main/'+n for n in ['wire_protocol.c','wire_protocol.h']]
    paths += [str(p.relative_to(ROOT)) for p in (ROOT/'experiments/mt2-usb/src').glob('*.rs')]
    before = {p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths}
    commands=[]
    def run(argv, name):
        commands.append(list(map(str,argv)))
        with (out/name).open('w') as log:
            subprocess.run(argv,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
    run(['clang','-std=c11','-O2','-Wall','-Wextra','-Werror','-Ifirmware/ch32v407','-Ifirmware/main','-Iexperiments/mt2-petros-profile',
         *(['-DWK_PROBE_SLOTS=12','-DWK_PROBE_DMA_BYTES=6144'] if args.large_in else []),
         'experiments/mt2-petros-profile/test_bulk_probe.c','firmware/ch32v407/bridge.c','firmware/main/wire_protocol.c','-o',str(out/'core-test')],'compile.log')
    run([str(out/'core-test')],'core.log')
    run(['python3','experiments/mt2-petros-profile/test_live_touch.py','--native-format','--ram-setup','--bulk-batch','--bulk-profile','--bulk-continuous-out','--bulk-probe',*(['--bulk-probe-large-in'] if args.large_in else [])],'retained-input.log')
    if before != {p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths}:
        raise RuntimeError('inputs changed during test; evidence invalid')
    (out/'result.json').write_text(json.dumps({'passed':True,'physicalUSB':False,'sources':before,'commands':commands},indent=2)+'\n')
    print(out)

if __name__=='__main__': main()
