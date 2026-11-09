#!/usr/bin/env python3
"""Generate/build a new MT2 probe directory. Never flash, delete, or edit inputs.

Only main.c/descriptors.c overlays are generated. All other production objects
compile from existing paths. SDK is read-only and must retain recovered fixes.
Python is build orchestration; new protocol state lives in the no_std Rust crate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CORE = ROOT / "experiments/mt2-usb"
PROBE_CORE = HERE / "single-port-core"
FLAGS = ["-march=rv32imac_zicsr_zifencei", "-mabi=ilp32", "-mcmodel=medany",
         "-msmall-data-limit=0", "-Os", "-g3", "-ffunction-sections", "-fdata-sections",
         "-fno-common", "-fno-strict-aliasing", "-mstrict-align"]
VENDOR = "EVT/EXAM/USBHS/Dual_device/cdc_transfer"

def once(text, before, after):
    if text.count(before) != 1:
        raise ValueError(f"Unrecognized source context, refusing patch: {before!r}")
    return text.replace(before, after, 1)

def overlays(main, descriptors, pointer_collections=False, absolute_no_preferred=False, absolute_mouse_logical=False, single_port_probe=False):
    if single_port_probe and not absolute_mouse_logical:
        raise ValueError("single-port-probe requires absolute-mouse-logical")
    if absolute_no_preferred and not pointer_collections:
        raise ValueError("absolute-no-preferred requires pointer-collections")
    if absolute_mouse_logical and not pointer_collections:
        raise ValueError("absolute-mouse-logical requires pointer-collections")
    if absolute_mouse_logical and absolute_no_preferred:
        raise ValueError("absolute-mouse-logical and absolute-no-preferred are mutually exclusive")
    main = once(main, '#include "setup_flash.h"', '#include "setup_flash.h"\n#include "mt2_glue.h"')
    if main.count("[2][7]") != 7:
        raise ValueError("unexpected endpoint array count")
    main = main.replace("[2][7]", "[2][8]")
    main = once(main, "reset_pending[p]=true;", "if(p==0)wkmt2_profile_host_reset();else wkmt2_profile_reset();\n    reset_pending[p]=true;")
    main = once(main, "(void)parameter;unsigned p=wk407_port(h);", "(void)parameter;unsigned p=wk407_port(h);\n    if(p==0)wkmt2_profile_host_reset();else wkmt2_profile_reset();")
    main = once(main, "usbd_endp_open(h,0x86,0,packet);usbd_endp_open(h,6,0,packet);", "usbd_endp_open(h,0x86,0,packet);usbd_endp_open(h,6,0,packet);\n        usbd_endp_open(h,0x87,0,64);")
    main = once(main, "static endp_resp_e data_cb", "static void forward_control(void *context,const uint8_t *bytes,size_t n,uint32_t now) {\n    wk407_control((wk407_bridge *)context,bytes,n,now);\n}\nstatic endp_resp_e data_cb")
    main = once(main, "unsigned p=wk407_port(h),e=ep&127;", "unsigned p=wk407_port(h),e=ep&127;\n    if(e>=8)return ENDP_RESP_STALL;")
    main = once(main, "if(p==0&&e==2)wk407_control(&bridge,buf,size,wk407_now_ms());", "if(p==0&&e==2)wkmt2_profile_control(&bridge,forward_control,buf,size,wk407_now_ms());")
    main = once(main, "unsigned p=wk407_port(h),i=r->wIndex;*size=0;", "unsigned p=wk407_port(h),i=r->wIndex;*size=0;\n    if(p==1&&i==WKMT2_INTERFACE)return wkmt2_profile_setup(r,buf,size);")
    main = once(main, "static usb_rst_e interface_data(usbd_handle_t *h,const usb_req_t *r,void *buf,size_t size) {", "static usb_rst_e interface_data(usbd_handle_t *h,const usb_req_t *r,void *buf,size_t size) {\n    if(wk407_port(h)==1&&r->wIndex==WKMT2_INTERFACE)return wkmt2_profile_data(r,buf,size);")
    main = once(main, "if(kind==5)wk407_urgent_done(&bridge,p);", "if(kind==5)wk407_urgent_done(&bridge,p);\n        if(kind==7)wkmt2_profile_diagnostic_done();\n        if(kind==8)wkmt2_profile_input_done();")
    main = once(main, "if(online!=bridge.online[p]) {", "if(online!=bridge.online[p]) {\n            if(!online){if(p==0)wkmt2_profile_host_reset();else wkmt2_profile_reset();}")
    main = once(main, "if(c)send(0,2,3,c->bytes,c->size);", "size_t diagnostic_size=0;const uint8_t *diagnostic=wkmt2_profile_diagnostic(&diagnostic_size);\n        if(c)send(0,2,3,c->bytes,c->size);\n        else if(diagnostic)send(0,2,7,diagnostic,(unsigned)diagnostic_size);")
    main = once(main, "    /* At most one 512-byte operation per file direction per pass. */", "    /* Probe is subordinate to keyboard/mouse/ACK; at most one empty frame. */\n    if(bridge.online[1]&&!busy[1][WKMT2_ENDPOINT]) {\n        size_t n=0;const uint8_t *frame=wkmt2_profile_input(&n);\n        if(frame)send(1,WKMT2_ENDPOINT,8,frame,(unsigned)n);\n    }\n    /* At most one 512-byte operation per file direction per pass. */")
    main = once(main, "wk407_init(&bridge);wk_setup_flash_init();", "wk407_init(&bridge);wkmt2_profile_reset();wkmt2_profile_host_reset();wk_setup_flash_init();")
    main = once(main, "i<(p?6:5)", "i<(p?7:5)")
    main = once(main, "ep<=6;ep++", "ep<=(p?7:6);ep++")
    descriptors = once(descriptors, '#include "descriptors.h"', '#include "descriptors.h"\n#include "wkmt2.h"')
    descriptors = once(descriptors, "#define TARGET(packet,interval) 9,2,180,0,6,1,0,0x80,50,HID(0,1,sizeof(relative),interval),HID(1,2,sizeof(absolute),interval),CLIP(interval),CDC(3,4,5,packet,5),MSC(5,6,packet)", "#define TARGET(packet,interval) 9,2,205,0,7,1,0,0x80,50,HID(0,1,sizeof(relative),interval),HID(1,2,sizeof(absolute),interval),CLIP(interval),CDC(3,4,5,packet,5),MSC(5,6,packet),HID(6,7,WKMT2_REPORT_DESCRIPTOR_SIZE,interval)")
    descriptors = once(descriptors, 'sizeof(target_hs)==180', 'sizeof(target_hs)==205')
    descriptors = once(descriptors, "0x86,0x1a,0x71,0x40,0,2,1,2,3,1", "0xac,0x05,0x65,0x02,0x68,2,1,2,3,1")
    descriptors = once(descriptors, "other[2][180]", "other[2][205]")
    if pointer_collections:
        # Experimental driver-binding isolation: preserve every report field,
        # changing only the old Mouse Application usage to generic Pointer.
        # The new MT2 descriptor lives in Rust and is intentionally untouched.
        for report_id in (2,3):
            descriptors=once(descriptors,
                f"0x05,1,0x09,2,0xa1,1,0x85,{report_id}",
                f"0x05,1,0x09,1,0xa1,1,0x85,{report_id}")
        descriptors=once(descriptors,"0xac,0x05,0x65,0x02,0x68,2,1,2,3,1", "0xac,0x05,0x65,0x02,0x69,2,1,2,3,1")
    if absolute_no_preferred:
        # Preserve Absolute/Variable/Data. Set only No Preferred State on XY;
        # generic macOS driver classification must still be verified physically.
        descriptors=once(descriptors,"0x75,16,0x95,2,0x81,2,0x09,0x38", "0x75,16,0x95,2,0x81,0x22,0x09,0x38")
        descriptors=once(descriptors,"0xac,0x05,0x65,0x02,0x69,2,1,2,3,1", "0xac,0x05,0x65,0x02,0x6a,2,1,2,3,1")
    if absolute_mouse_logical:
        # Keep Pointer Application for matching; Mouse Logical gives XY a
        # Mouse ancestor without adding a Mouse Application/Physical usage.
        # This models older public Apple parsing, not current driver proof.
        descriptors=once(descriptors,
            "0x05,1,0x09,1,0xa1,1,0x85,3,0x09,1,0xa1,0",
            "0x05,1,0x09,1,0xa1,1,0x85,3,0x09,2,0xa1,2")
        descriptors=once(descriptors,"0xac,0x05,0x65,0x02,0x69,2,1,2,3,1", "0xac,0x05,0x65,0x02,0x6b,2,1,2,3,1")
    if single_port_probe:
        main,descriptors=probe_overlays(main,descriptors)
    return main, descriptors

def probe_overlays(main,descriptors):
    """Opt-in USB2-only actuator. EP0 stages; only service submits a fixed point."""
    main=once(main,'#include "mt2_glue.h"','#include "mt2_glue.h"\n#include "single_port_probe.h"\n#include "single_port_abort.h"')
    main=once(main,"static uint8_t setup_lun;","static uint8_t setup_lun;\nstatic uint32_t probe_tx_epoch,probe_tx_seq;\nstatic bool probe_abort_pending;")
    main=once(main,"void wk407_reset_begin(unsigned p){","void wk407_reset_begin(unsigned p){\n    wkap_profile_reset();")
    main=once(main,"(void)parameter;unsigned p=wk407_port(h);","(void)parameter;unsigned p=wk407_port(h);\n    wkap_profile_reset();")
    main=once(main,"else if(tx_kind[p][e]==4)wk407_clipboard_done(&bridge,p);","else if(tx_kind[p][e]==4)wk407_clipboard_done(&bridge,p);\n            else if(p==1&&e==WKAP_ENDPOINT&&tx_kind[p][e]==WKAP_TX_KIND)wkap_profile_done(probe_tx_epoch,probe_tx_seq);")
    main=once(main,"unsigned p=wk407_port(h),i=r->wIndex;*size=0;","unsigned p=wk407_port(h),i=r->wIndex;*size=0;\n    if(p==1)wkap_profile_cancel_setup();\n    if(p==1&&i==WKAP_INTERFACE&&(r->wValue>>8)==3)return wkap_profile_setup(r,buf,size,wk407_now_ms());")
    main=once(main,"static usb_rst_e interface_data(usbd_handle_t *h,const usb_req_t *r,void *buf,size_t size) {","static usb_rst_e interface_data(usbd_handle_t *h,const usb_req_t *r,void *buf,size_t size) {\n    if(wk407_port(h)==1&&r->wIndex==WKAP_INTERFACE&&(r->wValue>>8)==3)return wkap_profile_data(r,buf,size);")
    main=once(main,"if(online!=bridge.online[p]) {","if(online!=bridge.online[p]) {\n            wkap_profile_reset();")
    main=once(main,"    if(bridge.online[1]) {\n        const wk407_hid_packet *v=",'''    /* Revoke only this probe's EP2 transfer before servicing normal HID.
     * Raw USB1 enumeration also blocks while that host is suspended. */
    wkap_profile_quiescing(probe_abort_pending);
    unsigned probe_guards=wkap_profile_guards(&bridge,usbd_is_enum(handles[0])||reset_pending[0],bridge.online[1],
        probe_abort_pending||busy[1][1]||(busy[1][2]&&tx_kind[1][2]!=WKAP_TX_KIND));
    if(wkap_profile_poll(now,probe_guards))probe_abort_pending=true;
    if(probe_abort_pending) {
        if(!busy[1][2]||tx_kind[1][2]!=WKAP_TX_KIND)probe_abort_pending=false;
        else if(!reset_pending[1]&&wkap_abort_ep82(handles[1])) {
            busy[1][2]=false;tx_kind[1][2]=0;probe_abort_pending=false;
        }
    }
    wkap_profile_quiescing(probe_abort_pending);
    if(bridge.online[1]) {
        const wk407_hid_packet *v=''')
    main=once(main,"    /* Probe is subordinate to keyboard/mouse/ACK; at most one empty frame. */",'''    /* Single-port diagnostic is subordinate to ordinary HID, never queued
     * through wk407_control (which would inherit buttons and create ACKs). */
    if(!busy[1][1]&&!busy[1][2]) {
        size_t n=0;const uint8_t *frame=wkap_profile_input(&n);
        if(frame) {
            send(1,WKAP_ENDPOINT,WKAP_TX_KIND,frame,(unsigned)n);
            if(busy[1][WKAP_ENDPOINT]&&tx_kind[1][WKAP_ENDPOINT]==WKAP_TX_KIND)
                (void)wkap_profile_submitted(&probe_tx_epoch,&probe_tx_seq);
        }
    }
    /* Probe is subordinate to keyboard/mouse/ACK; at most one empty frame. */''')
    main=once(main,"wk407_init(&bridge);wkmt2_profile_reset();","wk407_init(&bridge);wkap_profile_reset();wkmt2_profile_reset();")
    descriptors=once(descriptors,"0x95,64,0x09,0x63,0x91,2,0xc0","0x95,64,0x09,0x63,0x91,2,0x95,64,0x09,0x64,0xb1,2,0xc0")
    descriptors=once(descriptors,"0xac,0x05,0x65,0x02,0x6b,2,1,2,3,1","0xac,0x05,0x65,0x02,0x6c,2,1,2,3,1")
    return main,descriptors

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def audit_rust_archive(path):
    """GCC ld needs native RV32 objects, not Rust's standalone LTO bitcode."""
    data=path.read_bytes()
    if data[:8]!=b"!<arch>\n":raise ValueError("Rust staticlib is not an ar archive")
    offset=8;count=0
    while offset<len(data):
        header=data[offset:offset+60]
        if len(header)!=60 or header[58:60]!=b"`\n":raise ValueError("bad ar member header")
        length=int(header[48:58]);member=data[offset+60:offset+60+length]
        name=header[:16].decode("ascii").strip()
        if len(member)!=length:raise ValueError("truncated ar member")
        if name not in ("/","//","/SYM64/"):
            if member[:6]!=b"\x7fELF\x01\x01" or member[16:20]!=b"\x01\x00\xf3\x00":
                raise ValueError(f"Rust ar member {name} is not ELF32 little-endian RISC-V relocatable; magic={member[:8].hex()}; disable LTO bitcode for GNU linking")
            count+=1
        offset+=60+length+(length%2)
    if offset!=len(data) or count==0:raise ValueError("invalid/empty Rust staticlib")
    return {"native_rv32_members":count,"lto_bitcode_members":0}

def run(args, out, log):
    env=dict(os.environ, TMPDIR=str(out))
    for key in ["CPATH","C_INCLUDE_PATH","CPLUS_INCLUDE_PATH","OBJC_INCLUDE_PATH","GCC_EXEC_PREFIX","COMPILER_PATH","LIBRARY_PATH","GCC_SPECS","DEPENDENCIES_OUTPUT","SUNPRO_DEPENDENCIES","RUSTFLAGS","CARGO_ENCODED_RUSTFLAGS"]:
        env.pop(key,None)
    result=subprocess.run([str(a) for a in args],cwd=out,env=env,text=True,capture_output=True)
    with log.open("a") as f:f.write(json.dumps([str(a) for a in args])+"\n"+result.stdout+result.stderr)
    if result.returncode:raise RuntimeError(f"Build failed; retained {log}: {result.stderr[-2000:]}")
    return result.stdout

def live_overlays(main,descriptors):
    main=once(main,'#include "mt2_glue.h"','#include "mt2_glue.h"\n#include "wkmt2.h"\nextern bool wkmt2_live_abort_usb(usbd_handle_t *);')
    main=once(main,'static uint8_t setup_lun;','static uint8_t setup_lun;\nstatic uint32_t touch_at;')
    main=once(main,"        busy[p][e]=false;\n    } else {","        if(p==1&&e==7&&busy[p][e]&&tx_kind[p][e]==8)wkmt2_live_done();\n        busy[p][e]=false;\n    } else {")
    start=main.index('    /* Probe is subordinate to keyboard/mouse/ACK; at most one empty frame. */')
    end=main.index('    /* At most one 512-byte operation per file direction per pass. */',start)
    main=main[:start]+'''    /* Touch never owns the existing mouse/key endpoints or Bulk queues. */
    wkmt2_live_tick(now,bridge.online[0]&&bridge.online[1]&&wkmt2_enabled());
    if(wkmt2_live_abort_pending()>0) {
        if(!busy[1][7]||(!reset_pending[1]&&wkmt2_live_abort_usb(handles[1]))) {
            busy[1][7]=false;tx_kind[1][7]=0;wkmt2_live_aborted();
        }
    }
    if(bridge.online[1]&&!busy[1][7]&&now-touch_at>=4) {
        uint8_t touch[64] __attribute__((aligned(4)));
        int n=wkmt2_live_input(touch,sizeof(touch));bool live=n>0;
        size_t fallback=0;const uint8_t *frame=live?touch:wkmt2_profile_input(&fallback);
        if(!live)n=(int)fallback;
        if(frame&&n>0) {
            /* Target clock is monotonic at transmission, even after cancel. */
            if(live){uint16_t stamp=(uint16_t)(now*8);touch[9]=(uint8_t)stamp;touch[10]=(uint8_t)(stamp>>8);}
            send(1,7,8,frame,(unsigned)n);
            if(busy[1][7]){touch_at=now;if(live)wkmt2_live_submitted();}
        }
    }
'''+main[end:]
    # Existing authorized supervisor matches the complete USB product identity.
    # Keep its host name; changing only VID/PID is not compatibility.
    descriptors=once(descriptors,'"WiredKVM CH32 Host"','"WiredKVM Petros V467 Host"')
    descriptors=once(descriptors,'0xac,0x05,0x65,0x02,0x6b,2,1,2,3,1','0xac,0x05,0x65,0x02,0x6d,2,1,2,3,1')
    return main,descriptors

def generate(out,pointer_collections=False,absolute_no_preferred=False,absolute_mouse_logical=False,single_port_probe=False,live_touch=False,native_format=False,ram_setup=False):
    main_path=ROOT/"firmware/ch32v407/main.c";descriptor_path=ROOT/"firmware/ch32v407/descriptors.c"
    main,descriptors=overlays(main_path.read_text(),descriptor_path.read_text(),pointer_collections,absolute_no_preferred,absolute_mouse_logical,single_port_probe)
    if live_touch:
        if not absolute_mouse_logical or single_port_probe:raise ValueError("live-touch requires absolute-mouse-logical and no single-port probe")
        main,descriptors=live_overlays(main,descriptors)
    if native_format:
        if not live_touch:raise ValueError("native-format requires live-touch")
        main=once(main,"if(live){uint16_t stamp=(uint16_t)(now*8);touch[9]=(uint8_t)stamp;touch[10]=(uint8_t)(stamp>>8);}","{if(!live){memcpy(touch,frame,(size_t)n);frame=touch;}uint32_t stamp=(now*8)|4u;touch[9]=(uint8_t)stamp;touch[10]=(uint8_t)(stamp>>8);touch[11]=(uint8_t)(stamp>>16);}")
    if ram_setup:
        if not native_format:raise ValueError("RAM setup requires the retained native-v2 input profile")
        main=once(main,'#include "setup_flash.h"','#include "setup_flash.h"\n#include "setup_ram.h"')
        main=once(main,'static wk_setup setup;','static wk_setup setup;\nvoid wk_cable_forward(const uint8_t *b,size_t n){(void)wk407_bulk_accept(&bridge,0,b,n);}')
        main=once(main,'reset_pending[p]=true;','if(p==0)wk_cable_setup_reset();else wk_cable_setup_peer_reset();\n    reset_pending[p]=true;')
        main=once(main,'(void)parameter;unsigned p=wk407_port(h);','(void)parameter;unsigned p=wk407_port(h);\n    if(p==0)wk_cable_setup_reset();else wk_cable_setup_peer_reset();')
        main=once(main,'else (void)wk407_bulk_accept(&bridge,p,buf,size);','else if(p==0&&e==4)wk_cable_setup_input(buf,size);\n        else (void)wk407_bulk_accept(&bridge,p,buf,size);')
        main=once(main,'if(kind==1)wk407_bulk_done(&bridge,p);','if(kind==9)wk_cable_setup_ack_submitted();\n        if(kind==1)wk407_bulk_done(&bridge,p);')
        main=once(main,'if(!online){if(p==0)wkmt2_profile_host_reset();else wkmt2_profile_reset();}',
                  'if(!online){if(p==0){wkmt2_profile_host_reset();wk_cable_setup_reset();}else {wkmt2_profile_reset();wk_cable_setup_peer_reset();}}')
        main=once(main,'        if(wk407_bulk_space(&bridge,p))arm(p,ep,usbd_get_speed(handles[p])==USB_SPEED_HIGH?512:64);',
                  '        if(p==0?(!wk_cable_setup_pending()&&(!wk_cable_setup_size()||!bridge.online[1]||wk407_bulk_space(&bridge,p))):wk407_bulk_space(&bridge,p))arm(p,ep,usbd_get_speed(handles[p])==USB_SPEED_HIGH?512:64);\n'
                  '        if(p==0&&!busy[p][ep]&&wk_cable_setup_pending()){uint8_t ack[512];size_t n=wk_cable_setup_ack(ack,sizeof(ack));if(n)send(0,ep,9,ack,(unsigned)n);}')
        main=once(main,'    wk_setup_tick(&setup,now);','    if(wk_cable_setup_changed())wk_setup_refresh(&setup);\n    wk_setup_tick(&setup,now);')
        descriptors=once(descriptors,'0xac,0x05,0x65,0x02,0x6d,2,1,2,3,1','0xac,0x05,0x65,0x02,0x6e,2,1,2,3,1')
    out.mkdir(exist_ok=False)
    (out/"generated").mkdir();(out/"obj").mkdir()
    (out/"generated/main.c").write_text(main);(out/"generated/descriptors.c").write_text(descriptors)
    manifest={"experiment_only":True,"device_access":False,"target_identity":"05ac:0265 research only; no commercial identity authorization", "host_identity":"1a86:4070 unchanged", "added_interface":6,"added_endpoint":"0x87 interrupt IN 64 bytes 1ms", "retained_interfaces":[0,1,2,3,4,5],"stage":"enumeration and Feature handshake; no live touch ingress", "production_inputs":{str(p.relative_to(ROOT)):sha(p) for p in [main_path,descriptor_path]},"limits":["Apple driver composite-layout binding unverified","Target vendor-HID discovery requires experimental Apple identity support","External NOR absent on Petros: MSC no-medium adapter","No actuator interface in stage 1","No board access or flash performed"]}
    manifest.update(pointer_collections=pointer_collections,absolute_no_preferred=absolute_no_preferred,absolute_mouse_logical=absolute_mouse_logical,target_bcd_device="0x026b" if absolute_mouse_logical else ("0x026a" if absolute_no_preferred else ("0x0269" if pointer_collections else "0x0268")))
    manifest["single_port_probe"]=single_port_probe
    if single_port_probe:
        manifest.update(target_bcd_device="0x026c",stage="USB2-only five-point absolute-pointer probe; no live touch ingress",
            probe=dict(interface=2,feature_report_id=0,feature_bytes=64,lease_ms=5000,point_limit=5,protocol="WKAP/WKAS version 1"),
            deployable=False,readiness="NOT_READY_NOT_FLASHED",
            not_ready_reason="EP82 cancellation now uses NAK + SIE idle + no DONE without reopen. Register-model tests and physical timing review are required; pointer dispatch is unverified and host execution stays disabled.")
        manifest["limits"].remove("No actuator interface in stage 1")
        manifest["limits"].append("Explicit ARM permits five fixed absolute positions only on USB2 with USB1 unconfigured; physical pointer dispatch unverified")
    manifest["live_touch"]=live_touch
    manifest["native_format"]=native_format
    manifest["ram_setup"]=ram_setup
    manifest["wire_protocol_version"]=2 if native_format else 1
    if live_touch:manifest.update(target_bcd_device="0x026d",stage="live touch candidate; NOT physically accepted",deployable=False,readiness="OFFLINE_CANDIDATE_ONLY",limits=["Experimental Apple identity", "Touch geometry and gestures not physically verified", "No target clipboard access or runtime"])
    if ram_setup:manifest.update(target_bcd_device="0x026e",stage="native-v2 input plus volatile readonly program image; NOT physically accepted",limits=["Experimental Apple identity", "PSRAM initialization and physical input under program upload unverified", "Program runs on target CPU only after user opens it; no installation or persistence"])
    (out/"profile.json").write_text(json.dumps(manifest,indent=2)+"\n")
    return manifest

def build(out,sdk,prefix,manifest):
    includes=[out/"generated",HERE,CORE/"include",ROOT/"firmware/ch32v407",ROOT/"firmware/main"]+[sdk/p for p in ["EVT/EXAM/SRC/Core","EVT/EXAM/SRC/Debug","EVT/EXAM/SRC/Peripheral/inc",VENDOR+"/board",VENDOR+"/usb_driver/include",VENDOR+"/usb_driver/port"]]
    linker=sdk/"EVT/EXAM/SRC/Ld/Link.ld"
    for marker in ["__stack_size = 8192;","LENGTH = 576K","LENGTH = 136K-1K"]:
        if marker not in linker.read_text():raise ValueError("unrecognized patched linker")
    for port in [1,2]:
        text=(sdk/(VENDOR+f"/usb_driver/port/usbhs{port}_dcp.c")).read_text()
        for marker in ["extern void wk407_reset_begin(unsigned);","reset_pending","/* polling owner */","Common PLL remains enabled for the other controller."]:
            if marker not in text:raise ValueError("missing recovered USB fix: "+marker)
    config=(sdk/(VENDOR+"/usb_driver/include/usb_config.h")).read_text()
    for level in ["INFO","WARNING","ERROR"]:
        if f"USB_DRIVER_LOG_{level}_EN disabled: no synchronous USB logging" not in config:raise ValueError("blocking USB logging not disabled")
    gcc=Path(str(prefix)+"gcc").resolve(strict=True)
    log=out/"build.log"
    rust_target=out/"rust-target"
    # Cargo's lib + release LTO injects linker-plugin-lto. Disable that too:
    # lto=no alone still left this crate as LLVM bitcode in the GNU archive.
    rust_core=PROBE_CORE if manifest.get("single_port_probe") else CORE
    crate_flags=[] if manifest.get("single_port_probe") else ["--crate-type","staticlib"]
    features="c-abi,native-mt2" if manifest.get("native_format") else "c-abi"
    cargo_config=[]
    if manifest.get("ram_setup"):
        # Cargo must know the top-level crate is a staticlib. Injecting only a
        # rustc --crate-type makes Cargo pass metadata-only externs for the new
        # dependency. A generated wrapper leaves the existing MT2 crate intact.
        rust_core=out/"firmware-core";(rust_core/"src").mkdir(parents=True)
        (rust_core/"Cargo.toml").write_text('[package]\nname="wk-cable-profile"\nversion="0.0.0"\nedition="2021"\n[lib]\ncrate-type=["staticlib"]\n[dependencies]\nwiredkvm-mt2-protocol-draft={path="'+str(CORE)+'",features=["c-abi","native-mt2","ram-setup"]}\n[profile.release]\npanic="abort"\nopt-level="s"\nlto=false\n[workspace]\n')
        (rust_core/"src/lib.rs").write_text('#![no_std]\npub use wiredkvm_mt2_protocol_draft::{ffi::*,ram_setup::*};\n')
        crate_flags=[];features=""
        cargo_config=["--config",'build.rustflags=["-C","target-feature=-unaligned-scalar-mem,-unaligned-vector-mem"]']
    run(["cargo","rustc","--offline",*cargo_config,"--manifest-path",rust_core/"Cargo.toml","--release","--target","riscv32imac-unknown-none-elf","--features",features,"--target-dir",rust_target,"--",*crate_flags,"-C","panic=abort","-C","lto=no","-C","embed-bitcode=no","-C","linker-plugin-lto=no","-C","target-feature=-unaligned-scalar-mem,-unaligned-vector-mem"],out,log)
    archive_pattern="libwk_cable_profile-*.a" if manifest.get("ram_setup") else ("libwiredkvm_single_port_probe-*.a" if manifest.get("single_port_probe") else "libwiredkvm_mt2_protocol_draft-*.a")
    archives=list((rust_target/"riscv32imac-unknown-none-elf/release/deps").glob(archive_pattern))
    if len(archives)!=1:raise ValueError("expected one Rust staticlib, got "+str(archives))
    archive_audit=audit_rust_archive(archives[0])
    (out/"rust-archive-audit.json").write_text(json.dumps(archive_audit,indent=2)+"\n")
    sources=[out/"generated/main.c",out/"generated/descriptors.c",HERE/"mt2_glue.c"]+[ROOT/p for p in ["firmware/ch32v407/bridge.c","firmware/ch32v407/newlib_context.c","firmware/ch32v407/setup_msc.c","firmware/ch32v407/alignment_safe_libc.c","firmware/ch32v467_petros/setup_flash_none.c","firmware/main/wire_protocol.c"]]+[sdk/p for p in ["EVT/EXAM/SRC/Startup/startup_ch32v4x7.S",VENDOR+"/board/system_ch32v4x7.c",VENDOR+"/usb_driver/src/usbd_driver_core.c",VENDOR+"/usb_driver/port/usbhs1_dcp.c",VENDOR+"/usb_driver/port/usbhs2_dcp.c","EVT/EXAM/SRC/Peripheral/src/ch32v4x7_rcc.c"]]
    if manifest.get("single_port_probe"):sources.extend([HERE/"single_port_probe.c",HERE/"single_port_abort.c"])
    if manifest.get("live_touch"):sources.extend([HERE/"live_touch.c",HERE/"live_abort.c"])
    if manifest.get("ram_setup"):
        sources.remove(ROOT/"firmware/ch32v467_petros/setup_flash_none.c")
        sources.extend([ROOT/"firmware/ch32v467_petros/setup_ram.c",sdk/"EVT/EXAM/SRC/Peripheral/src/ch32v4x7_psram.c"])
        includes.append(ROOT/"firmware/ch32v467_petros")
    objects=[]
    for i,source in enumerate(sources):
        obj=out/"obj"/(str(i)+"-"+source.name+".o");args=[gcc,*FLAGS]+(["-DWKMT2_LIVE"] if manifest.get("live_touch") else [])+(["-DWKMT2_NATIVE"] if manifest.get("native_format") else [])
        if source.name=="alignment_safe_libc.c":args +=["-fno-builtin","-fno-tree-loop-distribute-patterns"]
        for include in includes:args +=["-I",include]
        run([*args,"-c",source,"-o",obj],out,log);objects.append(obj)
    elf=out/"wiredkvm-mt2-stage1.elf";binary=out/"wiredkvm-mt2-stage1.bin"
    run([gcc,*FLAGS,"-nostartfiles","--specs=nosys.specs",*objects,*archives,"-Wl,--gc-sections","-Xlinker","-Map","-Xlinker",out/"wiredkvm-mt2-stage1.map","-T",linker,"-o",elf],out,log)
    run([str(prefix)+"objcopy","-O","binary",elf,binary],out,log)
    size=run([str(prefix)+"size",elf],out,log)
    if not 0<binary.stat().st_size<=512*1024:raise ValueError("firmware outside 512KiB ceiling")
    manifest.update(binary={"path":str(binary),"bytes":binary.stat().st_size,"sha256":sha(binary)},size=size,inputs={str(p):sha(p) for p in sources+[linker]},rust_archive_sha256=sha(archives[0]),rust_archive_audit=archive_audit)
    if manifest.get("ram_setup"):
        for p in [ROOT/"firmware/ch32v467_petros/setup_ram.h",ROOT/"native/cable-image/Cargo.toml",ROOT/"native/cable-image/src/lib.rs",CORE/"src/ram_setup.rs"]:manifest["inputs"][str(p)]=sha(p)
    if manifest.get("live_touch"):
        for p in [HERE/"mt2_glue.h",HERE/"build_profile.py",CORE/"Cargo.toml",CORE/"Cargo.lock",CORE/"include/wkmt2.h",*sorted((CORE/"src").rglob("*.rs"))]:manifest["inputs"][str(p)]=sha(p)
        symbols=["wkmt2_live_offer","wkmt2_live_input","wkmt2_live_submitted","wkmt2_live_done","wkmt2_live_abort_usb","wk407_hid_done"]
        map_text=(out/"wiredkvm-mt2-stage1.map").read_text()
        if any(symbol not in map_text for symbol in symbols):raise ValueError("live/retained-input symbols missing from link")
        manifest["map_audit"]={"required_symbols":symbols,"sha256":sha(out/"wiredkvm-mt2-stage1.map")}
    if manifest.get("single_port_probe"):
        rust_inputs=[PROBE_CORE/"Cargo.toml",PROBE_CORE/"Cargo.lock",CORE/"Cargo.toml",CORE/"Cargo.lock"]+sorted((PROBE_CORE/"src").rglob("*.rs"))+sorted((CORE/"src").rglob("*.rs"))
        for p in [HERE/"single_port_probe.h",HERE/"single_port_abort.h",HERE/"mt2_glue.h",HERE/"build_profile.py",CORE/"include/wkmt2.h",*rust_inputs]:
            manifest["inputs"][str(p)]=sha(p)
        map_text=(out/"wiredkvm-mt2-stage1.map").read_text()
        symbols=["wkap_abort_ep82","wkap_core_quiescing","wkap_core_poll","wkap_core_stage","wkap_core_complete","wkap_profile_setup","wkap_profile_data","wkmt2_input","wk407_hid_done"]
        if any(symbol not in map_text for symbol in symbols):raise ValueError("probe/retained-input symbols missing from linked map")
        manifest["map_audit"]={"path":str(out/"wiredkvm-mt2-stage1.map"),"sha256":sha(out/"wiredkvm-mt2-stage1.map"),"required_symbols":symbols}
    (out/"profile.json").write_text(json.dumps(manifest,indent=2)+"\n")

def main():
    parser=argparse.ArgumentParser();parser.add_argument("--output",type=Path,required=True);parser.add_argument("--sdk",type=Path);parser.add_argument("--gcc-prefix",type=Path);parser.add_argument("--build",action="store_true");parser.add_argument("--pointer-collections",action="store_true",help="experimental old Mouse->Pointer usage; MT2 unchanged; bcdDevice 0269");parser.add_argument("--absolute-no-preferred",action="store_true",help="requires Pointer collections; absolute XY NoPreferred flag; bcdDevice 026a")
    parser.add_argument("--absolute-mouse-logical",action="store_true",help="requires Pointer collections; absolute inner Mouse Logical collection; bcdDevice 026b")
    parser.add_argument("--single-port-probe",action="store_true",help="requires absolute-mouse-logical; USB2-only fixed-point diagnostic; bcdDevice 026c")
    parser.add_argument("--live-touch",action="store_true",help="experimental live gesture ingress, bcdDevice 026d")
    parser.add_argument("--ram-setup",action="store_true",help="native-v2 plus volatile program image; PSRAM not persistent storage")
    parser.add_argument("--native-format",action="store_true",help="native three-bit finger/state fields and full clock; protocol v2")
    args=parser.parse_args();out=args.output
    if args.absolute_no_preferred and not args.pointer_collections:parser.error("--absolute-no-preferred requires --pointer-collections")
    if args.absolute_mouse_logical and not args.pointer_collections:parser.error("--absolute-mouse-logical requires --pointer-collections")
    if args.absolute_mouse_logical and args.absolute_no_preferred:parser.error("--absolute-mouse-logical and --absolute-no-preferred are mutually exclusive")
    if args.single_port_probe and not args.absolute_mouse_logical:parser.error("--single-port-probe requires --absolute-mouse-logical")
    # Resolve the parent before containment checks; reject ../ and symlink
    # escapes without touching either production files or SDK directories.
    out=out.parent.resolve(strict=True)/out.name
    if out.exists() or out.is_symlink():raise SystemExit("Output must be new; no overwrite/cleanup")
    if not out.is_relative_to(HERE):raise SystemExit("Output must be inside experiments/mt2-petros-profile")
    manifest=generate(out,args.pointer_collections,args.absolute_no_preferred,args.absolute_mouse_logical,args.single_port_probe,args.live_touch,args.native_format,args.ram_setup)
    if args.build:
        if not args.sdk or not args.gcc_prefix:raise SystemExit("--build needs explicit patched SDK and GCC prefix")
        build(out,args.sdk.resolve(strict=True),args.gcc_prefix,manifest)
    print(out/"profile.json")

if __name__=="__main__":main()
