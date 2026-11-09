#!/usr/bin/env python3
"""Bounded Book-only stationary-contact probe. No target program or clipboard.

Requires both data roles on Book, the service stopped, a matching fresh flash
proof, and an explicitly supplied Rust observer/finite vector emitter.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import select
import subprocess
import termios
import time
import fcntl

def walk(n):
    if isinstance(n,dict):
        yield n
        for v in n.values():
            if isinstance(v,(dict,list)):yield from walk(v)
    elif isinstance(n,list):
        for v in n:yield from walk(v)

def one_json(text):
    rows=[json.loads(line) for line in text.splitlines() if line.startswith('{')]
    if len(rows)!=1:raise RuntimeError('Expected one diagnostic JSON line')
    return rows[0]

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['output','observer','emitter','flash-proof','firmware']:p.add_argument('--'+name,type=Path,required=True)
    args=p.parse_args();out=args.output.resolve();assert not out.exists();out.mkdir()
    proof=json.loads(args.flash_proof.read_text());image=args.firmware.read_bytes()
    assert proof['readback_verified'] and proof['firmware_sha256']==hashlib.sha256(image).hexdigest()
    assert proof['uid']=='ad21ad506c54c6c6' and proof['probe_serial']=='A47C8F062A1A'
    active=subprocess.run(['/bin/launchctl','print','gui/501/com.wiredkvm.control-autostart'],capture_output=True)
    assert active.returncode!=0,'Stop the Book controller before a same-Book loopback probe'
    tree=subprocess.check_output(['/usr/sbin/ioreg','-a','-l','-p','IOUSB']);(out/'ioreg.plist').write_bytes(tree)
    devices=[n for n in walk(plistlib.loads(tree)) if n.get('IOObjectClass')=='IOUSBHostDevice']
    host=[n for n in devices if (n.get('idVendor'),n.get('idProduct'))==(0x1a86,0x4070)]
    target=[n for n in devices if (n.get('idVendor'),n.get('idProduct'))==(0x05ac,0x0265) and n.get('USB Serial Number')=='CH32V407-DoNotShip']
    assert len(host)==len(target)==1 and not any((n.get('idVendor'),n.get('idProduct'))==(0x1a86,0x8010) for n in devices)
    assert host[0]['USB Product Name']=='WiredKVM Petros V467 Host' and host[0]['USB Serial Number']=='CH32V407-DoNotShip'
    assert host[0]['IORegistryEntryID']!=target[0]['IORegistryEntryID']
    interfaces=[n for n in walk(host[0]) if n.get('IOObjectClass')=='IOUSBHostInterface' and n.get('bInterfaceNumber')==1]
    assert len(interfaces)==1
    ports={n['IOCalloutDevice'] for n in walk(interfaces[0]) if 'IOCalloutDevice' in n};assert len(ports)==1
    port=ports.pop();held=subprocess.run(['/usr/sbin/lsof','-t',port],capture_output=True,text=True);assert not held.stdout.strip()
    version=subprocess.check_output([str(args.observer),'--protocol'],text=True,timeout=3).strip();assert version=='2'
    inspected=subprocess.check_output([str(args.observer),'--inspect'],text=True,timeout=6);(out/'inspect.txt').write_text(inspected)
    roles=[d for d in one_json(inspected)['devices'] if d['usb_target'] and not d['built_in']];assert len(roles)==1
    rid=roles[0]['registry_id']
    # Rust emits fixed stationary positions only. Check the bounded fixture
    # again before any USB write; it cannot contain keys, buttons or movement.
    fixture=subprocess.check_output([str(args.emitter)],text=True,timeout=3);(out/'fixture.txt').write_text(fixture)
    rows=[];positions={}
    for row in fixture.splitlines():
        delay,text=row.split(' ',1);delay=int(delay);assert 0<=delay<=16
        fields=text.split(',');assert fields[0] in ['MT2B','MT2D','MT2E'] and fields[1] in ['102','104']
        if fields[0]=='MT2D':
            b=bytes.fromhex(fields[2]);assert len(b) in [12,30,48] and b[0]==2 and b[1:7]==bytes(6) and b[8]==0x31 and b[9]&7==4
            for i in range(12,len(b),9):
                contact=b[i:i+9];assert contact[3]>>5 in [0,3,4,7] and 1<=(contact[3]>>2)&7<=5 and 1<=contact[8]&15<=15
                key=(fields[1],contact[8]&15);xy=contact[:3]+bytes([contact[3]&3]);assert positions.setdefault(key,xy)==xy
        else:assert len(fields)==2
        rows.append((delay,text+'\n'))
    assert len(rows)<=80
    fd=os.open(port,os.O_RDWR|os.O_NOCTTY|os.O_NONBLOCK);observer=None
    def write(data):
        data=data.encode();deadline=time.monotonic()+0.5
        while data:
            if time.monotonic()>deadline:raise TimeoutError('CDC write deadline')
            if select.select([], [fd], [], .05)[1]:
                try:n=os.write(fd,data);data=data[n:]
                except BlockingIOError:pass
    try:
        fcntl.ioctl(fd,termios.TIOCEXCL)
        attrs=termios.tcgetattr(fd);attrs[0]=attrs[1]=attrs[3]=0;attrs[2]=termios.CS8|termios.CREAD|termios.CLOCAL;attrs[4]=attrs[5]=termios.B115200;attrs[6][termios.VMIN]=attrs[6][termios.VTIME]=0;termios.tcsetattr(fd,termios.TCSANOW,attrs)
        write('MT2?\n');response=b'';deadline=time.monotonic()+2
        while time.monotonic()<deadline and not response.endswith(b'\n'):
            if select.select([fd],[],[],.05)[0]:response+=os.read(fd,512)
        (out/'capability.txt').write_bytes(response);assert b'MT2,version=2,enabled=1,' in response
        observer=subprocess.Popen([str(args.observer),'--observe-usb-target','--seconds','6','--registry-id',str(rid)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        # Observer emits readiness only after MTDeviceStart succeeds. No blind
        # sleep can substitute for that ownership/lifecycle acknowledgement.
        ready=b'';deadline=time.monotonic()+3
        while time.monotonic()<deadline:
            if select.select([observer.stderr],[],[],.1)[0]:
                chunk=os.read(observer.stderr.fileno(),4096);ready+=chunk
                if f'USB_TARGET_OBSERVER_READY {rid}'.encode() in ready:break
                if not chunk:raise RuntimeError('Observer stopped before ready')
        else:raise TimeoutError('Observer did not become ready')
        (out/'observer-ready.txt').write_bytes(ready)
        for delay,row in rows:time.sleep(delay/1000);write(row)
        stdout,stderr=observer.communicate(timeout=8);(out/'observer.txt').write_bytes(stdout);(out/'observer-stderr.txt').write_bytes(stderr)
        stdout=stdout.decode('utf8',errors='replace')
        assert observer.returncode==0
        measured=one_json(stdout)
        result=dict(status='PASS_BOOK_NATIVE_DECODE' if measured['frames']>0 and measured['max_touching']>=4 else 'FAIL_NATIVE_DECODE',stationary_only=True,keyboard_mouse_buttons_sent=False,clipboard_access=False,target_machine_access=False,usb_target_registry_id=rid,observed=measured,firmware_sha256=proof['firmware_sha256'])
        (out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
        if result['status']!='PASS_BOOK_NATIVE_DECODE':raise SystemExit(2)
    finally:
        for epoch in [102,104]:
            try:write(f'MT2E,{epoch}\n')
            except Exception:pass
        os.close(fd)
        if observer and observer.poll() is None:observer.terminate();observer.communicate(timeout=3)

if __name__=='__main__':main()
