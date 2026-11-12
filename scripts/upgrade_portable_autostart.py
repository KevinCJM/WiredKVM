#!/usr/bin/env python3
"""Prepare/upgrade the existing Book LaunchAgent with rollback. Never touch mini.

Prepare is read-only outside the project. Preflight stages only the dormant
supervisor binary and runs its no-USB check under a temporary Aqua job. Install
requires that exact fresh preflight before replacing config/manifest/LaunchAgent
and handing off input. Capture/native/touch stay at their authorized paths.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]
LABEL='com.wiredkvm.control-autostart'
BASE=Path.home()/'Library/Application Support/WiredKVM/control-autostart'
PLIST=Path.home()/'Library/LaunchAgents'/(LABEL+'.plist')
FILES=['wiredkvm-control-service','config.txt','manifest.json']
IDENTITY=ROOT/'results/portable-direct-cable-20261110/libidentity.dylib'
KEYS=['native','capture','relay','portable_host','portable_runtime']
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def read(p):return json.loads(Path(p).read_text())
def save(p,v):Path(p).write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n')
def config(path,root):
    d={}
    for line in Path(path).read_text().splitlines():
        if not line or line.startswith('#'):continue
        key,value=line.split('=',1)
        if key in d:raise ValueError('duplicate config key')
        d[key]=value
    if set(d)!=set(KEYS+[k+'_sha256' for k in KEYS]+['state_dir']):raise ValueError('explicit portable config required')
    for key in KEYS:
        p=Path(d[key])
        if not p.is_absolute() or not p.resolve().is_relative_to(root) or p.is_symlink() or sha(p)!=d[key+'_sha256']:raise ValueError('runtime pin mismatch: '+key)
    runtime=read(d['portable_runtime'])
    if runtime.get('diagnosticOnly'):raise ValueError('a diagnostic runtime must not become the login default')
    if any(runtime[k]!=d[v] for k,v in [('native','native'),('capture','capture'),('companion','relay')]):raise ValueError('coordinator and supervisor runtime disagree')
    for key in ['native','capture','companion','touch','loader','asset']:
        p=Path(runtime[key])
        if not p.resolve().is_relative_to(root) or p.is_symlink() or sha(p)!=runtime['hashes'].get(str(p)):raise ValueError('portable asset pin mismatch: '+key)
    return d,runtime
def prepare(stage,source,service,active,*,root=ROOT,base=BASE,plist=PLIST,state_name='state-portable'):
    root=root.resolve();stage=stage.resolve();service=service.resolve()
    if not stage.is_relative_to(root/'build') or stage.exists():raise ValueError('fresh project build stage required')
    if not service.is_relative_to(root/'build') or service.name!='wiredkvm-control-service':raise ValueError('project-built supervisor required')
    d,runtime=config(source,root);a=read(active)
    active_service=Path(a['executable'])
    if a['identity'][3]!=str(active_service) or a['pid']!=a['identity'][0] or active_service.name!='wiredkvm-control-service' or active_service.is_symlink() or not active_service.resolve().is_relative_to(root/'build'):raise ValueError('active supervisor identity record mismatch')
    launch=plistlib.loads(plist.read_bytes())
    if launch.get('Label')!=LABEL or launch.get('ProgramArguments')!=[str(base/FILES[0]),'run',str(base/'config.txt')] or not launch.get('RunAtLoad') or not launch.get('KeepAlive'):raise ValueError('unexpected existing LaunchAgent')
    if re.fullmatch(r'state-portable(?:-[a-z0-9-]{1,64})?',state_name) is None:raise ValueError('invalid portable state name')
    state=base/state_name
    if state.exists():raise ValueError('portable state already exists; inspect before replacing')
    old={str(p):sha(p) for p in [plist,*[base/n for n in FILES]]}
    if any(Path(p).is_symlink() for p in old):raise ValueError('refusing symlink destination')
    d['state_dir']=str(state)
    launch['EnvironmentVariables']={'WK_RAW_TOUCH_PROTOCOL':'2','WK_RAW_TOUCH_HELPER':runtime['touch']}
    stage.mkdir(parents=True);backup=stage/'backup';backup.mkdir()
    for p in old:(backup/Path(p).name).write_bytes(Path(p).read_bytes())
    (stage/FILES[0]).write_bytes(service.read_bytes());(stage/FILES[0]).chmod(0o755)
    (stage/'config.txt').write_text(''.join(k+'='+v+'\n' for k,v in d.items()));(stage/'config.txt').chmod(0o600)
    (stage/plist.name).write_bytes(plistlib.dumps(launch))
    save(stage/'manifest.json',{'portable':True,'targetInstalled':False,'capturePathPreserved':runtime['capture'],'runtimePins':d})
    plan={'base':str(base),'plist':str(plist),'oldFiles':old,'newFiles':{n:sha(stage/n) for n in [*FILES,plist.name]},
          'sourceConfig':str(source.resolve()),'sourceSHA256':sha(source),'service':str(service),'serviceSHA256':sha(service),
          'activeRecord':str(active.resolve()),'activeRecordSHA256':sha(active),'active':a,'activeService':str(active_service),'activeServiceSHA256':sha(active_service),'stateDir':str(state),'root':str(root),'installed':False}
    save(stage/'plan.json',plan);return plan
def verify(stage,plan):
    if plan['base']!=str(BASE) or plan['plist']!=str(PLIST) or plan['root']!=str(ROOT):raise ValueError('installation scope mismatch')
    if set(plan['oldFiles'])!={str(PLIST),*[str(BASE/n) for n in FILES]} or set(plan['newFiles'])!=set([*FILES,PLIST.name]):raise ValueError('installation file scope mismatch')
    staged=stage/'binary-staged.json'
    binary_staged=staged.exists() and read(staged).get('planSHA256')==sha(stage/'plan.json')
    for p,h in plan['oldFiles'].items():
        current=plan['newFiles'][FILES[0]] if binary_staged and Path(p)==BASE/FILES[0] else h
        if Path(p).is_symlink() or sha(p)!=current:raise ValueError('existing installation changed: '+Path(p).name)
        if sha(stage/'backup'/Path(p).name)!=h:raise ValueError('backup changed')
    for n,h in plan['newFiles'].items():
        if Path(n).name!=n or sha(stage/n)!=h:raise ValueError('stage changed')
    for key,pkey in [('sourceSHA256','sourceConfig'),('serviceSHA256','service'),('activeRecordSHA256','activeRecord')]:
        if sha(plan[pkey])!=plan[key]:raise ValueError('prepared input changed')
    config(Path(plan['sourceConfig']),ROOT)
    if sha(plan['activeService'])!=plan['activeServiceSHA256']:raise ValueError('previous active supervisor binary changed')
    state=Path(plan['stateDir'])
    if state.parent!=BASE or re.fullmatch(r'state-portable(?:-[a-z0-9-]{1,64})?',state.name) is None or state.is_symlink():raise ValueError('portable state scope mismatch')
def identity_reader():
    lib=ctypes.CDLL(str(IDENTITY));lib.wk_process.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_int,ctypes.POINTER(ctypes.c_uint64),ctypes.POINTER(ctypes.c_uint64),ctypes.POINTER(ctypes.c_int)]
    def identity(pid):
        path=ctypes.create_string_buffer(4096);sec=ctypes.c_uint64();usec=ctypes.c_uint64();parent=ctypes.c_int()
        if not lib.wk_process(pid,path,len(path),ctypes.byref(sec),ctypes.byref(usec),ctypes.byref(parent)):return None
        return [pid,sec.value,usec.value,path.value.decode()]
    return identity
def replace(path,data,executable=False):
    temp=path.with_name(path.name+'.wiredkvm-upgrade')
    with temp.open('xb') as f:f.write(data);f.flush();os.fsync(f.fileno())
    temp.chmod(0o755 if executable else 0o600);os.replace(temp,path)
def check_preflight(stage,plan):
    p=stage/'preflight.json'
    if not p.exists():raise ValueError('successful launchd preflight required before handoff')
    result=read(p)
    if not result.get('ready') or not result.get('temporaryJobRemoved') or result.get('program')!=str(BASE/FILES[0]) or result.get('programSHA256')!=plan['newFiles'][FILES[0]] or result.get('configSHA256')!=plan['newFiles']['config.txt'] or result.get('planSHA256')!=sha(stage/'plan.json') or not 0<=time.time()-result.get('timeUnix',0)<=900:raise ValueError('launchd preflight is failed, stale or for another candidate')
def preflight(stage):
    plan=read(stage/'plan.json');verify(stage,plan);identity=identity_reader()
    if identity(plan['active']['pid'])!=plan['active']['identity']:raise ValueError('active supervisor changed; current runtime retained')
    domain=f'gui/{os.getuid()}';normal=domain+'/'+LABEL
    probe=subprocess.run(['/bin/launchctl','print',normal],capture_output=True,text=True)
    if probe.returncode==0 or 'Could not find service' not in probe.stderr:raise ValueError('existing login job must be inactive before staging')
    if not (stage/'binary-staged.json').exists():
        replace(BASE/FILES[0],(stage/FILES[0]).read_bytes(),True)
        save(stage/'binary-staged.json',{'planSHA256':sha(stage/'plan.json'),'programSHA256':plan['newFiles'][FILES[0]],'inputHandoff':False})
    verify(stage,plan)
    work=Path(tempfile.mkdtemp(prefix='wiredkvm-login-check-',dir='/private/tmp'));state=work/'state';state.mkdir(mode=0o700)
    cfg=work/'config.txt';cfg.write_text('\n'.join('state_dir='+str(state) if line.startswith('state_dir=') else line for line in (stage/'config.txt').read_text().splitlines())+'\n');cfg.chmod(0o600)
    label=LABEL+'-preflight-'+sha(stage/'plan.json')[:12];target=domain+'/'+label
    absent=subprocess.run(['/bin/launchctl','print',target],capture_output=True,text=True)
    if absent.returncode==0 or 'Could not find service' not in absent.stderr:raise ValueError('temporary preflight label occupied')
    program=str(BASE/FILES[0]);log=work/'check.log';plist=work/'check.plist'
    plist.write_bytes(plistlib.dumps({'Label':label,'ProgramArguments':[program,'check',str(cfg)],'RunAtLoad':True,'KeepAlive':False,'LimitLoadToSessionType':'Aqua','ProcessType':'Interactive','StandardOutPath':str(log),'StandardErrorPath':str(log)}));plist.chmod(0o600)
    started=False;result=None
    try:
        subprocess.run(['/bin/launchctl','bootstrap',domain,str(plist)],check=True,capture_output=True,timeout=12);started=True;deadline=time.monotonic()+35;info=''
        while time.monotonic()<deadline:
            p=subprocess.run(['/bin/launchctl','print',target],capture_output=True,text=True,timeout=5);info=p.stdout+p.stderr
            if 'last exit code =' in info and 'state = not running' in info:break
            time.sleep(.1)
        text=log.read_text() if log.exists() else ''
        (stage/'preflight.log').write_text(text);(stage/'preflight-launchctl.txt').write_text(info)
        ready='PREFLIGHT_READY' in text and re.search(r'last exit code = 0\b',info) is not None and 'state = not running' in info
        result={'ready':ready,'program':program,'programSHA256':sha(program),'configSHA256':sha(stage/'config.txt'),'planSHA256':sha(stage/'plan.json'),'timeUnix':time.time(),'USBAccess':False,'inputHandoff':False,'temporaryJobRemoved':False}
    finally:
        if started:
            current=subprocess.run(['/bin/launchctl','print',target],capture_output=True,text=True)
            if program not in current.stdout or str(cfg) not in current.stdout:raise ValueError('preflight job identity changed; refusing removal')
            subprocess.run(['/bin/launchctl','bootout',target],check=True,capture_output=True,timeout=12)
            if result is not None:result['temporaryJobRemoved']=True
        if result is not None:save(stage/'preflight.json',result)
    print(json.dumps(result))
def install(stage):
    plan=read(stage/'plan.json');verify(stage,plan);check_preflight(stage,plan);identity=identity_reader();old=plan['active']['identity']
    if identity(old[0])!=old:raise ValueError('active supervisor changed')
    domain=f'gui/{os.getuid()}';service_name=domain+'/'+LABEL
    check=subprocess.run(['/bin/launchctl','print',service_name],capture_output=True,text=True)
    if check.returncode==0 or 'Could not find service' not in check.stderr:raise ValueError('existing launchd state must be reviewed')
    stopped=False;started=False
    try:
        for name in FILES:
            if name==FILES[0] and sha(BASE/name)==plan['newFiles'][name]:continue
            replace(BASE/name,(stage/name).read_bytes(),name==FILES[0])
        replace(PLIST,(stage/PLIST.name).read_bytes())
        state=Path(plan['stateDir']);state.mkdir(mode=0o700)
        if identity(old[0])!=old:raise ValueError('supervisor changed before handoff')
        os.kill(old[0],signal.SIGTERM);stopped=True
        deadline=time.monotonic()+12
        while identity(old[0])==old and time.monotonic()<deadline:time.sleep(.05)
        if identity(old[0])==old:raise RuntimeError('old supervisor did not exit; no force kill')
        subprocess.run(['/bin/launchctl','enable',service_name],check=True)
        subprocess.run(['/bin/launchctl','bootstrap',domain,str(PLIST)],check=True);started=True
        deadline=time.monotonic()+30
        while time.monotonic()<deadline:
            status=state/'status.txt';log=state/'control.log'
            if status.exists() and 'status=running' in status.read_text() and log.exists() and 'CH32_INPUT_READY' in log.read_text():
                info=subprocess.check_output(['/bin/launchctl','print',service_name],text=True)
                match=re.search(r'^\s*pid = (\d+)',info,re.M)
                if not match:raise RuntimeError('new launchd PID unavailable')
                current=identity(int(match.group(1)))
                if not current or current[3]!=str(BASE/FILES[0]):raise RuntimeError('launchd process identity mismatch')
                result={'installed':True,'identity':current,'config':str(BASE/'config.txt'),'state':str(state),'inputReady':True,
                        'physicalRebootTested':False,'sleepWakeTested':False,'firmwareChanged':False,'targetInstallation':False}
                save(stage/'installed.json',result);print(json.dumps(result));return
            time.sleep(.1)
        raise RuntimeError('login service did not report input readiness')
    except BaseException:
        if started:subprocess.run(['/bin/launchctl','bootout',service_name],capture_output=True)
        for p in plan['oldFiles']:replace(Path(p),(stage/'backup'/Path(p).name).read_bytes(),Path(p).name==FILES[0])
        # Installed bytes are old again; neither a staged-binary receipt nor a
        # previous permission result may authorize another input handoff.
        for name in ['binary-staged.json','preflight.json']:
            p=stage/name
            if p.exists():p.unlink()
        if stopped and identity(old[0])!=old:
            log=(stage/'fallback.log').open('ab')
            child=subprocess.Popen([plan['activeService'],'run',plan['sourceConfig']],stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True);log.close()
            time.sleep(.15);current=identity(child.pid)
            save(stage/'fallback.json',{'pid':child.pid,'identity':current,'config':plan['sourceConfig'],'installed':False})
            if current:
                a=plan['active'];a.update(pid=child.pid,identity=current,startedUnix=time.time());save(plan['activeRecord'],a)
        raise
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('action',choices=['prepare','preflight','install']);parser.add_argument('stage',type=Path)
    parser.add_argument('--source-config',type=Path);parser.add_argument('--supervisor',type=Path);parser.add_argument('--active-record',type=Path)
    parser.add_argument('--state-name',default='state-portable')
    args=parser.parse_args()
    if args.action=='prepare':
        if not all([args.source_config,args.supervisor,args.active_record]):parser.error('prepare requires source config, supervisor and active record')
        prepare(args.stage,args.source_config,args.supervisor,args.active_record,state_name=args.state_name);print('PREPARED no_runtime_changes=true no_target_access=true')
    elif args.action=='preflight':preflight(args.stage.resolve())
    else:install(args.stage.resolve())
if __name__=='__main__':main()
