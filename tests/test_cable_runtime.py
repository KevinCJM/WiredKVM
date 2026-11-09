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
    command=['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','-DWK_RAM_MODEL',
        '-Itests/psram_model','-Ifirmware/ch32v467_petros','-Ifirmware/ch32v407',
        'tests/setup_ram_test.c','firmware/ch32v467_petros/setup_ram.c','-o',str(out/'psram-model')]
    commands.append(command);subprocess.run(command,cwd=ROOT,check=True)
    with (out/'psram-model.log').open('w') as log:subprocess.run([str(out/'psram-model')],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=20)
    for name,crate,features in [('image','native/cable-image',[]),('loader','native/cable-loader',[]),
                                ('touch','experiments/mt2-usb',['--features','c-abi,native-mt2,ram-setup'])]:
        command=['cargo','test','--offline','--locked','--manifest-path',str(ROOT/crate/'Cargo.toml'),
                 '--target-dir',str(out/'rust-target'),*features];commands.append(command)
        with (out/(name+'.log')).open('w') as log:
            result=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=120)
        if result.returncode:raise RuntimeError('test failed; see '+str(out/(name+'.log')))
    (out/'manifest.json').write_text(json.dumps({'physicalUSB':False,'OSInput':False,'generalClipboard':False,
        'passed':['psram-adapter-model','image','loader','touch'],'commands':commands},indent=2)+'\n')
    print(out)

if __name__=='__main__':main()
