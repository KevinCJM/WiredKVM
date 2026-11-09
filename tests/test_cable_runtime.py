#!/usr/bin/env python3
"""Isolated Rust RAM-image, loader and retained-touch tests. No real USB/input."""
import json
from pathlib import Path
import subprocess
import uuid

ROOT=Path(__file__).resolve().parents[1]

def main():
    out=ROOT/'build'/('cable-runtime-test-'+uuid.uuid4().hex);out.mkdir(parents=True,exist_ok=False)
    commands=[]
    for name,crate,features in [('image','native/cable-image',[]),('loader','native/cable-loader',[]),
                                ('touch','experiments/mt2-usb',['--features','c-abi,native-mt2,ram-setup'])]:
        command=['cargo','test','--offline','--locked','--manifest-path',str(ROOT/crate/'Cargo.toml'),
                 '--target-dir',str(out/'rust-target'),*features];commands.append(command)
        with (out/(name+'.log')).open('w') as log:
            result=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=120)
        if result.returncode:raise RuntimeError('test failed; see '+str(out/(name+'.log')))
    (out/'manifest.json').write_text(json.dumps({'physicalUSB':False,'OSInput':False,'generalClipboard':False,
        'passed':['image','loader','touch'],'commands':commands},indent=2)+'\n')
    print(out)

if __name__=='__main__':main()
