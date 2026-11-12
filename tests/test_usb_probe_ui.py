#!/usr/bin/env python3
"""Real hidden AppKit window/child-process exit checks. No USB or clipboard."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

def aqua_run(binary, mode, logbase):
    label='com.wiredkvm.probe-ui-test.'+logbase.parent.name+'.'+logbase.name
    domain='gui/'+str(os.getuid());target=domain+'/'+label
    plist=logbase.with_suffix('.plist');log=logbase.with_suffix('.log')
    plist.write_bytes(plistlib.dumps({'Label':label,'ProgramArguments':[str(binary),mode],
        'RunAtLoad':True,'KeepAlive':False,'LimitLoadToSessionType':'Aqua',
        'ProcessType':'Interactive','StandardOutPath':str(log),'StandardErrorPath':str(log)}))
    def ctl(*args):return subprocess.run(['/bin/launchctl',*args],capture_output=True,text=True,timeout=10)
    if ctl('print',target).returncode==0:raise RuntimeError('test label occupied')
    ctl('bootstrap',domain,str(plist)).check_returncode()
    try:
        deadline=time.monotonic()+10;info=''
        while time.monotonic()<deadline:
            info=ctl('print',target).stdout
            if 'state = not running' in info and 'last exit code =' in info:break
            time.sleep(.05)
        logbase.with_suffix('.launchd.txt').write_text(info)
        text=log.read_text() if log.exists() else ''
        ok='state = not running' in info and re.search(r'last exit code = 0\b',info) is not None
        if not ok:
            match=re.search(r'^\s*pid = (\d+)',info,re.M)
            if match and str(binary) in info:
                subprocess.run(['/usr/bin/sample',match.group(1),'1','10','-file',str(logbase.with_suffix('.sample.txt'))],capture_output=True,timeout=8)
        return 0 if ok else 1,text
    finally:
        info=ctl('print',target).stdout
        if str(binary) not in info or mode not in info:raise RuntimeError('test job identity changed')
        ctl('bootout',target).check_returncode()

def main():
    source = ROOT / 'experiments/usb-throughput-probe/ProbeApp.swift'
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    out = Path(tempfile.mkdtemp(prefix='probe-ui-lifecycle-', dir=ROOT/'build'))
    binary = out/'ui-test'
    command = ['/usr/bin/swiftc', '-O', '-parse-as-library', '-D', 'WK_PROBE_UI_TEST',
               '-module-cache-path', str(ROOT/'build/shared-swift-cache-20261110'),
               '-framework', 'AppKit', str(source), '-o', str(binary)]
    compile_result = subprocess.run(command, capture_output=True, text=True, timeout=90)
    (out/'compile.log').write_text(compile_result.stdout+compile_result.stderr)
    compile_result.check_returncode()
    # The standalone fixture never needs Desktop access. Run its executable
    # and launchd logs from an owned temp directory instead of requesting a
    # new app's broad Desktop permission merely for a hidden-window check.
    execution=Path(tempfile.mkdtemp(prefix='wiredkvm-probe-ui-',dir='/private/tmp'))
    executable=execution/'ui-test';shutil.copy2(binary,executable)
    runs=[]
    for mode in ['--self-test-lifecycle', '--self-test-close']:
        for index in range(3):
            name=mode[2:]+'-'+str(index)
            code,text = aqua_run(executable,mode,execution/name)
            for item in execution.glob(name+'.*'):
                shutil.copy2(item,out/item.name)
            if code != 0 or 'PROBE_UI_LIFECYCLE_PASS' not in text:
                raise RuntimeError('UI lifecycle failed: '+str(out))
            runs.append({'mode':mode,'index':index,'exit':code})
    if hashlib.sha256(source.read_bytes()).hexdigest()!=before:
        raise RuntimeError('source changed during test')
    (out/'result.json').write_text(json.dumps({'passed':True,'sourceSHA256':before,
        'runs':runs,'deviceAccess':False,'clipboardAccess':False,'targetAccess':False},indent=2)+'\n')
    print(out)

if __name__ == '__main__':
    main()
