#!/usr/bin/env python3
"""Operator rollback admission tests. USB/DBG subprocesses are all mocks."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('flash_candidate',ROOT/'scripts/flash_portable_candidate.py')
flash=importlib.util.module_from_spec(spec);spec.loader.exec_module(flash)

def digest(b):return hashlib.sha256(b).hexdigest()

class FlashAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix='wk-flash-model-')
        self.root=Path(self.temporary.name).resolve()
        self.old=b'KNOWN_WORKING_FIRMWARE'*8;self.current=b'CURRENT_DIAGNOSTIC_FIRMWARE'*8
        self.pins={}
        for label,data in [('old',self.old),('current',self.current)]:
            folder=self.root/'experiments/mt2-petros-profile'/label;folder.mkdir(parents=True)
            (folder/'wiredkvm-mt2-stage1.bin').write_bytes(data)
            self.pins[label]=(label,digest(data))
        self.source=self.root/'source.c';self.source.write_text('new source\n')
        self.profile=self.root/'profile.json';self.profile.write_text(json.dumps({
            'ram_setup':True,'binary':{'path':str(self.root/'experiments/mt2-petros-profile/old/wiredkvm-mt2-stage1.bin'),'sha256':digest(self.old)},
            'inputs':{},'production_inputs':{'source.c':digest(b'previous source\n')}}))
        self.tool=self.root/'mock-tool';self.tool.write_bytes(b'NOT_EXECUTABLE_NOT_A_DEVICE_TOOL')
        self.memory=bytearray(self.current+b'\xa7'*(flash.BACKUP_BYTES-len(self.current)))
        self.original=bytes(self.memory);self.calls=[];self.corrupt_readback=False;self.bad_probe=False

    def tearDown(self):self.temporary.cleanup()

    def inventory(self,argv):
        self.calls.append(('inventory',list(argv)))
        return plistlib.dumps([{'IOObjectClass':'IOUSBHostDevice','idVendor':0x1a86,'idProduct':0x8010,
                              'USB Serial Number':'WRONG' if self.bad_probe else flash.PROBE}])

    def operation(self,argv,**kwargs):
        argv=list(map(str,argv));self.calls.append(('operation',argv))
        if 'status' in argv:output=flash.CHIP+' '+flash.UID
        elif 'dump' in argv:
            at=argv.index('dump');n=int(argv[at+2]);out=Path(argv[argv.index('--out')+1]);data=bytes(self.memory[:n])
            if self.corrupt_readback and out.name=='readback.bin':data=bytes([data[0]^1])+data[1:]
            out.write_bytes(data);output='mock dump'
        elif 'flash' in argv:
            data=Path(argv[-1]).read_bytes();self.memory[:len(data)]=data;output='mock flash'
        elif 'reset' in argv:output='mock resume'
        else:raise AssertionError('Unexpected subprocess')
        return subprocess.CompletedProcess(argv,0,stdout=output.encode(),stderr=b'')

    def invoke(self,args):
        argv=['flash.py',*args,'--wlink',str(self.tool)]
        with patch.object(flash,'ROOT',self.root),patch.object(flash,'ACCEPTED',self.pins),\
             patch.object(flash,'TOOL_SHA',digest(self.tool.read_bytes())),patch.object(sys,'argv',argv),\
             patch.object(flash.subprocess,'check_output',side_effect=self.inventory),\
             patch.object(flash.subprocess,'run',side_effect=self.operation),contextlib.redirect_stdout(io.StringIO()) as out:
            flash.main()
        return json.loads(out.getvalue())

    def target(self):return self.root/'experiments/mt2-petros-profile/old/wiredkvm-mt2-stage1.bin'
    def output(self):return self.root/'results/one-trial'
    def flash_args(self):return ['--flash','--known','old','--expected-current','current','--output',str(self.output())]

    def test_describe_known_is_filesystem_only_despite_later_source_edits(self):
        r=self.invoke(['--describe','--known','old'])
        self.assertFalse(r['deviceAccess']);self.assertFalse(r['currentSourcesChecked'])
        self.assertEqual(r['candidateSHA256'],digest(self.old));self.assertEqual(self.calls,[])

    def test_new_profile_rejects_changed_production_header_before_any_device_access(self):
        with self.assertRaisesRegex(ValueError,'build input changed'):
            self.invoke(['--describe','--profile',str(self.profile)])
        self.assertEqual(self.calls,[])

    def test_new_profile_with_current_inputs_still_describes_without_usb(self):
        data=json.loads(self.profile.read_text())
        data['production_inputs']['source.c']=digest(self.source.read_bytes())
        self.profile.write_text(json.dumps(data))
        r=self.invoke(['--describe','--profile',str(self.profile)])
        self.assertTrue(r['currentSourcesChecked']);self.assertIsNone(r['knownArtifact'])
        self.assertEqual(self.calls,[])

    def test_conflicting_manifest_hashes_cannot_override_one_another(self):
        data=json.loads(self.profile.read_text())
        data['production_inputs']['source.c']=digest(self.source.read_bytes())
        data['inputs'][str(self.source)]=digest(b'previous source\n')
        self.profile.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError,'build input changed'):
            self.invoke(['--describe','--profile',str(self.profile)])
        self.assertEqual(self.calls,[])

    def test_known_artifact_and_arbitrary_profile_are_mutually_exclusive(self):
        with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):
            self.invoke(['--describe','--known','old','--profile',str(self.profile)])
        self.assertEqual(self.calls,[])

    def test_tampered_pinned_target_rejected_before_inventory(self):
        self.target().write_bytes(b'UNREVIEWED')
        with self.assertRaisesRegex(ValueError,'pinned target firmware'):
            self.invoke(self.flash_args())
        self.assertEqual(self.calls,[])

    def test_known_rollback_still_requires_explicit_current_pin(self):
        with self.assertRaisesRegex(ValueError,'expected-current'):
            self.invoke(['--flash','--known','old','--output',str(self.output())])
        self.assertEqual(self.calls,[])

    def test_wrong_probe_rejected_before_dbg_attach(self):
        self.bad_probe=True
        with self.assertRaisesRegex(ValueError,'exact sole DBG'):
            self.invoke(self.flash_args())
        self.assertEqual(len(self.calls),1);self.assertEqual(bytes(self.memory),self.original)

    def test_wrong_running_prefix_stops_without_flash(self):
        self.memory[0]^=1;before=bytes(self.memory)
        with self.assertRaisesRegex(ValueError,'baseline'):
            self.invoke(self.flash_args())
        self.assertFalse(any('flash' in argv for kind,argv in self.calls if kind=='operation'))
        self.assertEqual(bytes(self.memory),before)

    def test_known_rollback_backs_up_full_current_and_verifies_target(self):
        r=self.invoke(self.flash_args())
        self.assertTrue(r['readbackVerified']);self.assertFalse(r['runtimeAccepted'])
        self.assertFalse(r['currentSourcesChecked']);self.assertEqual(r['knownArtifact'],'old')
        self.assertEqual((self.output()/'before-full.bin').read_bytes(),self.original)
        self.assertEqual((self.output()/'readback.bin').read_bytes(),self.old)

    def test_bad_readback_restores_entire_original_and_verifies_it(self):
        self.corrupt_readback=True
        with self.assertRaisesRegex(ValueError,'readback mismatch'):
            self.invoke(self.flash_args())
        self.assertEqual(bytes(self.memory),self.original)
        self.assertEqual((self.output()/'restored.bin').read_bytes(),self.original)

if __name__=='__main__':unittest.main(verbosity=2)
