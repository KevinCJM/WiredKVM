#!/usr/bin/env python3
"""Real generated main/C adapter/Rust queue with USB boundary mocks. No device I/O."""
import ast
import argparse
import importlib.util
from pathlib import Path
import subprocess
import tempfile
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('profile',HERE/'build_profile.py')
profile=importlib.util.module_from_spec(spec);spec.loader.exec_module(profile)
spec=importlib.util.spec_from_file_location('old_tests',HERE/'test_profile.py')
old=importlib.util.module_from_spec(spec);spec.loader.exec_module(old)

def run(command,work):
    r=subprocess.run([str(x) for x in command],capture_output=True,text=True,timeout=120)
    with (work/'test.log').open('a') as f:f.write(r.stdout+r.stderr)
    if r.returncode:raise RuntimeError(str(work/'test.log'))
    return r.stdout

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--native-format',action='store_true');parser.add_argument('--ram-setup',action='store_true');parser.add_argument('--bulk-batch',action='store_true');parser.add_argument('--bulk-profile',action='store_true');args=parser.parse_args();native=args.native_format;ram=args.ram_setup;batch=args.bulk_batch
    if ram and not native:raise ValueError('RAM setup requires native format')
    work=Path(tempfile.mkdtemp(prefix='live-main-test-',dir=HERE))
    candidate=work/'candidate';profile.generate(candidate,pointer_collections=True,absolute_mouse_logical=True,live_touch=True,native_format=native,ram_setup=ram,bulk_batch=batch,bulk_profile=args.bulk_profile)
    constants=[n.value for n in ast.walk(ast.parse((HERE/'test_profile.py').read_text())) if isinstance(n,ast.Constant) and isinstance(n.value,str)]
    extension=next(x for x in constants if x.startswith('\ntypedef uint8_t usb_endp_t;'))
    header=old.STUB.replace('typedef struct {int unused;} usbd_handle_t;','typedef struct {bool enumerated;unsigned port;} usbd_handle_t;')+extension
    header+='\n#define USBD_ENDP_FEATURE_BURST 2\n'
    if ram:
        download='(void)h;(void)ep;(void)b;(void)n;return -1;'
        if header.count(download)!=1:raise ValueError('unexpected download mock')
        header=header.replace(download,'(void)h;(void)ep;(void)b;(void)n;return 0;')
    (work/'usb_driver.h').write_text(header)
    chip=next(x for x in constants if 'typedef struct {uint32_t CNT,CTLR,CMP;} mock_systick;' in x)
    chip=chip.replace('mock_ep82','mock_ep87').replace('WKAP_EP82','WKMT2_EP87')
    (work/'ch32v4x7.h').write_text(chip);(work/'ch32v4x7_usb.h').write_text('#pragma once\n')
    for p in (1,2):(work/f'usbhs{p}_dcp.h').write_text(f'#pragma once\n#include "usb_driver.h"\nextern usbd_handle_t usbhs{p}d_handle;\nstatic inline void usbhs{p}_dch_init(void){{}}\nstatic inline void usbhs{p}_dch_interrupt(void){{}}\n')
    rust=work/'rust'
    shim=work/'host-shim';(shim/'src').mkdir(parents=True)
    manifest_text='[package]\nname="wk-live-tests"\nversion="0.0.0"\nedition="2021"\n[lib]\ncrate-type=["staticlib"]\n[dependencies]\nwiredkvm-mt2-protocol-draft={path="'+str(profile.CORE)+'",features=["c-abi"]}\n[profile.release]\npanic="abort"\nlto=false\n[workspace]\n'
    if native:manifest_text=manifest_text.replace('features=["c-abi"]','features=["c-abi","native-mt2"]')
    if ram:manifest_text=manifest_text.replace('features=["c-abi","native-mt2"]','features=["c-abi","native-mt2","ram-setup"]')
    (shim/'Cargo.toml').write_text(manifest_text)
    (shim/'src/lib.rs').write_text('pub use wiredkvm_mt2_protocol_draft::ffi::*;\n')
    run(['cargo','build','--release','--offline','--manifest-path',shim/'Cargo.toml','--target-dir',rust],work)
    archives=[rust/'release/libwk_live_tests.a']
    source=work/'main-test.c'
    source.write_text((HERE/'test_live_touch_main.c').read_text().replace('GENERATED_MAIN',str(candidate/'generated/main.c')))
    extra=[candidate/'generated/descriptors.c',HERE/'mt2_glue.c',HERE/'live_touch.c',HERE/'live_abort.c']+[profile.ROOT/p for p in ['firmware/ch32v407/bridge.c','firmware/ch32v407/setup_msc.c','firmware/ch32v467_petros/setup_flash_none.c','firmware/main/wire_protocol.c']]
    if ram:extra.remove(profile.ROOT/'firmware/ch32v467_petros/setup_flash_none.c')
    run(['clang',*(['-DWKMT2_NATIVE'] if native else []),*(['-DWK_RAM_SETUP'] if ram else []),*(['-DWK_BULK_BATCH_TEST'] if batch else []),*(['-DWK_BULK_PROFILE_TEST'] if args.bulk_profile else []),'-std=c11','-DWKMT2_LIVE','-Wall','-Wextra','-Werror','-Wno-unused-function','-I',work,'-I',HERE,'-I',profile.CORE/'include','-I',profile.ROOT/'firmware/ch32v407','-I',profile.ROOT/'firmware/ch32v467_petros','-I',profile.ROOT/'firmware/main',source,*extra,*archives,'-o',work/'test'],work)
    print(run([work/'test'],work).strip());print('RETAINED',work)
if __name__=='__main__':main()
