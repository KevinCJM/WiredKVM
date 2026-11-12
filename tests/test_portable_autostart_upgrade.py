"""Fixture-only upgrade admission. Never launch launchd or touch real user files."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import time
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPT=Path(__file__).resolve().parents[1]/'scripts/upgrade_portable_autostart.py'
spec=importlib.util.spec_from_file_location('upgrade',SCRIPT);upgrade=importlib.util.module_from_spec(spec);spec.loader.exec_module(upgrade)

class UpgradeAdmission(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name).resolve()
        self.base=self.root/'support';self.base.mkdir();self.plist=self.root/'agent.plist';self.build=self.root/'build';self.build.mkdir()
        self.runtime={}
        for key in ['native','capture','companion','touch','loader','asset']:
            p=self.build/key;p.write_text(key);self.runtime[key]=str(p)
        self.runtime['hashes']={p:upgrade.sha(p) for p in self.runtime.values()}
        self.rp=self.build/'runtime.json';upgrade.save(self.rp,self.runtime)
        self.host=self.build/'host';self.host.write_text('coordinator')
        self.service=self.build/'wiredkvm-control-service';self.service.write_text('new service')
        d={'native':self.runtime['native'],'capture':self.runtime['capture'],'relay':self.runtime['companion'],'portable_host':str(self.host),'portable_runtime':str(self.rp),'state_dir':str(self.root/'trial')}
        d.update({k+'_sha256':upgrade.sha(d[k]) for k in upgrade.KEYS})
        self.source=self.build/'config.txt';self.source.write_text(''.join(k+'='+v+'\n' for k,v in d.items()))
        self.active=self.build/'active.json';upgrade.save(self.active,{'pid':123,'identity':[123,1,2,str(self.service)],'executable':str(self.service),'config':str(self.source)})
        for n in upgrade.FILES:(self.base/n).write_text('old '+n)
        self.launch={'Label':upgrade.LABEL,'ProgramArguments':[str(self.base/upgrade.FILES[0]),'run',str(self.base/'config.txt')],'RunAtLoad':True,'KeepAlive':True}
        self.plist.write_bytes(plistlib.dumps(self.launch));self.stage=self.build/'stage'
    def prepare(self):return upgrade.prepare(self.stage,self.source,self.service,self.active,root=self.root,base=self.base,plist=self.plist)
    def test_preserves_capture_paths_and_pins_old_destination(self):
        before={str(p):p.read_bytes() for p in [self.plist,*self.base.iterdir()]};plan=self.prepare()
        self.assertEqual(before,{p:Path(p).read_bytes() for p in before})
        d,r=upgrade.config(self.stage/'config.txt',self.root)
        self.assertEqual(d['capture'],self.runtime['capture']);self.assertEqual(r['touch'],self.runtime['touch'])
        self.assertEqual(d['state_dir'],str(self.base/'state-portable'));self.assertFalse(plan['installed'])
    def test_changed_binary_is_rejected(self):
        Path(self.runtime['native']).write_text('modified')
        with self.assertRaisesRegex(ValueError,'pin mismatch'):self.prepare()
        self.assertFalse(self.stage.exists())
    def test_diagnostic_runtime_cannot_be_login_default(self):
        self.runtime['diagnosticOnly']=True;upgrade.save(self.rp,self.runtime)
        text=self.source.read_text();old=next(l for l in text.splitlines() if l.startswith('portable_runtime_sha256='))
        self.source.write_text(text.replace(old,'portable_runtime_sha256='+upgrade.sha(self.rp)))
        with self.assertRaisesRegex(ValueError,'diagnostic runtime'):self.prepare()
    def test_foreign_launch_agent_is_rejected(self):
        self.launch['Label']='unrelated.service';self.plist.write_bytes(plistlib.dumps(self.launch))
        with self.assertRaisesRegex(ValueError,'unexpected existing'):self.prepare()
    def test_changed_destination_or_stage_is_rejected(self):
        plan=self.prepare()
        with patch.object(upgrade,'ROOT',self.root),patch.object(upgrade,'BASE',self.base),patch.object(upgrade,'PLIST',self.plist):
            upgrade.verify(self.stage,plan)
            (self.base/'config.txt').write_text('concurrent change')
            with self.assertRaisesRegex(ValueError,'installation changed'):upgrade.verify(self.stage,plan)
    def test_duplicate_keys_are_rejected(self):
        with self.source.open('a') as f:f.write('native=other\n')
        with self.assertRaisesRegex(ValueError,'duplicate'):self.prepare()
    def test_new_supervisor_can_preserve_previous_executable_for_rollback(self):
        previous=self.build/'previous/wiredkvm-control-service';previous.parent.mkdir();previous.write_text('previous supervisor')
        upgrade.save(self.active,{'pid':123,'identity':[123,1,2,str(previous)],'executable':str(previous),'config':str(self.source)})
        plan=self.prepare();self.assertEqual(plan['activeService'],str(previous));self.assertEqual(plan['activeServiceSHA256'],upgrade.sha(previous))
    def test_named_state_keeps_failed_upgrade_state_untouched(self):
        old=self.base/'state-portable';old.mkdir();(old/'probe.log').write_text('previous evidence')
        plan=upgrade.prepare(self.stage,self.source,self.service,self.active,root=self.root,base=self.base,plist=self.plist,state_name='state-portable-next')
        self.assertEqual(plan['stateDir'],str(self.base/'state-portable-next'));self.assertEqual((old/'probe.log').read_text(),'previous evidence')
    def test_state_name_cannot_escape_destination(self):
        with self.assertRaisesRegex(ValueError,'state name'):
            upgrade.prepare(self.stage,self.source,self.service,self.active,root=self.root,base=self.base,plist=self.plist,state_name='../other')
        self.assertFalse(self.stage.exists())
    def test_staged_binary_is_the_only_allowed_installation_change(self):
        plan=self.prepare();(self.base/upgrade.FILES[0]).write_bytes((self.stage/upgrade.FILES[0]).read_bytes())
        upgrade.save(self.stage/'binary-staged.json',{'planSHA256':upgrade.sha(self.stage/'plan.json')})
        with patch.object(upgrade,'ROOT',self.root),patch.object(upgrade,'BASE',self.base),patch.object(upgrade,'PLIST',self.plist):
            upgrade.verify(self.stage,plan)
            (self.base/'config.txt').write_text('unexpected replacement')
            with self.assertRaisesRegex(ValueError,'installation changed'):upgrade.verify(self.stage,plan)
    def test_handoff_requires_fresh_preflight_for_exact_candidate(self):
        plan=self.prepare()
        with patch.object(upgrade,'ROOT',self.root),patch.object(upgrade,'BASE',self.base),patch.object(upgrade,'PLIST',self.plist),patch.object(upgrade,'identity_reader',side_effect=AssertionError('must not hand off')):
            with self.assertRaisesRegex(ValueError,'preflight required'):upgrade.install(self.stage)
            result={'ready':True,'temporaryJobRemoved':True,'program':str(self.base/upgrade.FILES[0]),'programSHA256':plan['newFiles'][upgrade.FILES[0]],'configSHA256':plan['newFiles']['config.txt'],'planSHA256':upgrade.sha(self.stage/'plan.json'),'timeUnix':time.time()}
            upgrade.save(self.stage/'preflight.json',result);upgrade.check_preflight(self.stage,plan)
            for key,value in [('ready',False),('programSHA256','0'*64),('timeUnix',time.time()-901)]:
                broken=dict(result);broken[key]=value;upgrade.save(self.stage/'preflight.json',broken)
                with self.assertRaisesRegex(ValueError,'preflight is failed'):upgrade.check_preflight(self.stage,plan)
    def test_failed_launch_restores_files_and_previous_supervisor_not_candidate(self):
        previous=self.build/'previous/wiredkvm-control-service';previous.parent.mkdir();previous.write_text('previous supervisor')
        old_id=[123,1,2,str(previous)]
        upgrade.save(self.active,{'pid':123,'identity':old_id,'executable':str(previous),'config':str(self.source)})
        plan=self.prepare();before={p:Path(p).read_bytes() for p in plan['oldFiles']}
        (self.base/upgrade.FILES[0]).write_bytes((self.stage/upgrade.FILES[0]).read_bytes())
        upgrade.save(self.stage/'binary-staged.json',{'planSHA256':upgrade.sha(self.stage/'plan.json')})
        upgrade.save(self.stage/'preflight.json',{'ready':True,'temporaryJobRemoved':True,'program':str(self.base/upgrade.FILES[0]),'programSHA256':plan['newFiles'][upgrade.FILES[0]],'configSHA256':plan['newFiles']['config.txt'],'planSHA256':upgrade.sha(self.stage/'plan.json'),'timeUnix':time.time()})
        alive={123:old_id};fallback=[]
        def run(argv,**kwargs):
            self.assertEqual(argv[0],'/bin/launchctl')
            if argv[1]=='bootstrap':raise RuntimeError('fixture bootstrap failure')
            return subprocess.CompletedProcess(argv,1 if argv[1]=='print' else 0,stdout='',stderr='Could not find service' if argv[1]=='print' else '')
        def stop(pid,sig):self.assertEqual(pid,123);alive.pop(pid)
        def start(argv,**kwargs):
            fallback.append(argv);alive[124]=[124,3,4,str(previous)];return SimpleNamespace(pid=124)
        with patch.object(upgrade,'ROOT',self.root),patch.object(upgrade,'BASE',self.base),patch.object(upgrade,'PLIST',self.plist),patch.object(upgrade,'identity_reader',return_value=lambda pid:alive.get(pid)),patch.object(upgrade.os,'kill',side_effect=stop),patch.object(upgrade.subprocess,'run',side_effect=run),patch.object(upgrade.subprocess,'Popen',side_effect=start),patch.object(upgrade.time,'sleep'):
            with self.assertRaisesRegex(RuntimeError,'fixture bootstrap failure'):upgrade.install(self.stage)
        self.assertEqual(before,{p:Path(p).read_bytes() for p in before})
        self.assertEqual(fallback,[[str(previous),'run',str(self.source)]])
        self.assertFalse((self.stage/'binary-staged.json').exists());self.assertFalse((self.stage/'preflight.json').exists())
        self.assertEqual(upgrade.read(self.active)['identity'],[124,3,4,str(previous)])

if __name__=='__main__':unittest.main(verbosity=2)
