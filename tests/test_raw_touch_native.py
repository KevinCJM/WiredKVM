"""Native owner + fake capture/USB peer. Never accesses real USB or OS input."""
import socket
import tempfile
import time
import unittest
import zlib
from tests.test_native_absolute import FakeSession, wait_until

class TouchSession(FakeSession):
    def __init__(self,events=(),ready=True,version=1,clipboard=False):
        super().__init__(events,extra=("--raw-touch","/private/tmp/fixture-unused-touch-helper"))
        self.touch=[];self.ready=ready;self.version=version
        self.clipboard=clipboard;self.reports=[]
    def __enter__(self):
        if self.clipboard:
            self.clip_temp=tempfile.TemporaryDirectory(prefix="wk-touch-clipboard-")
            self.ipc=self.clip_temp.name+"/clipboard.sock"
            self.extra += ("--clipboard-socket",self.ipc)
        return super().__enter__()
    def __exit__(self,*args):
        try:super().__exit__(*args)
        finally:
            if self.clipboard:self.clip_temp.cleanup()
    def peer(self):
        try:
            while not self.stop.is_set():
                try: channel,_=self.server.accept();break
                except socket.timeout: continue
            else:return
            with channel,channel.makefile("rb") as stream:
                for wire in stream:
                    text=wire.decode().strip()
                    if text.startswith("C1,"):
                        _,raw,checksum=text.split(",")
                        data=bytes.fromhex(raw)
                        if len(data)!=64 or zlib.crc32(data)!=int(checksum,16):return
                        self.reports.append(data);channel.sendall(wire);continue
                    if text=="MT2?":channel.sendall(f"MT2,version={self.version},enabled={int(self.ready)},faults=0,resets=1\n".encode());continue
                    if text.startswith("MT2"):
                        self.touch.append((time.monotonic(),text));continue
                    fields=text.split(",")
                    if len(fields)!=6:return
                    _,seq,kind,a,b,_=fields
                    self.frames.append(dict(kind=kind,a=int(a),b=int(b),at=time.monotonic()))
                    self.counts[kind]+=1
                    channel.sendall(f"ACK,{seq}\n".encode())
        except OSError:pass

class RawTouchNativeTests(unittest.TestCase):
    def test_suspended_capture_releases_held_keys_buttons_and_native_contacts(self):
        raw="020000000000000031000088"
        events=[(0,"E 5000 0"),(0,"H B 31"),(0,"H D 31 "+raw),
                (0.01,"T 4 1"),(0,"B 1 0"),(0.01,"R 0 0"),
                (0,"H D 31 "+raw)]
        with TouchSession(events) as s:
            self.assertTrue(wait_until(lambda:any(row=="MT2E,31" for _,row in s.touch)))
            self.assertEqual([row for _,row in s.touch],
                             ["MT2B,31","MT2D,31,"+raw,"MT2E,31"])
            self.assertTrue(wait_until(lambda:s.counts['R']>=1))
            # R is the existing firmware all-release command, including held
            # keys/buttons. No explicit key-up can arrive after capture loss.
            downs=[f for f in s.frames if f['kind']=='T' and f['b']==1]
            self.assertEqual(len(downs),1)
            self.assertTrue(any(f['kind']=='R' and f['at']>downs[0]['at'] for f in s.frames))
            self.assertIsNone(s.proc.poll())

    def test_clipboard_traffic_keeps_native_touch_keys_and_automatic_edge_return(self):
        raw="020000000000000031000088"
        events=[(0.05,"E 5000 0"),(0,"H B 19"),(0,"H D 19 "+raw),
                (0.02,"T 4 1"),(0,"T 4 0"),(0.02,"M 20 0"),
                (0.04,"M -127 0"),(0.14,"M -127 0")]
        with TouchSession(events,clipboard=True) as s:
            self.assertTrue(wait_until(lambda:(s.work/'started').exists()))
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(2);client.connect(s.ipc)
                payload=bytes(range(64))*256;client.sendall(payload)
                received=b""
                while len(received)<len(payload):received+=client.recv(len(payload)-len(received))
                self.assertEqual(received,payload)
                self.assertTrue(wait_until(lambda:s.counts['T']==2))
                self.assertTrue(wait_until(lambda:len(s.returns())>0))
                self.assertTrue(wait_until(lambda:any(row=='MT2E,19' for _,row in s.touch)))
                self.assertIn("MT2D,19,"+raw,[row for _,row in s.touch])
                self.assertEqual(len(s.reports),256)
                self.assertIsNone(s.proc.poll())

    def test_local_stale_and_returned_contacts_cannot_leak_while_keyboard_still_works(self):
        raw="020000000000000031000088"
        events=[(0,"H B 10"),(0,"H D 10 "+raw), # still Book
                (0,"E 5000 0"),(0,"H B 11"),(0,"H D 11 "+raw),
                (0.01,"T 4 1"),(0,"T 4 0"),(0.01,"R 0 0"),
                (0,"H D 11 "+raw),(0,"H B 12"),(0,"H D 12 "+raw)]
        with TouchSession(events) as s:
            self.assertTrue(wait_until(lambda:s.counts['T']==2))
            self.assertTrue(wait_until(lambda:any(row=='MT2E,11' for _,row in s.touch)))
            rows=[r for _,r in s.touch]
            self.assertEqual(rows,["MT2B,11","MT2D,11,"+raw,"MT2E,11"])
            self.assertTrue(any(r=="TOUCH_READY 1" for _,r in s.commands()))
    def test_native_v2_requires_explicit_matching_local_protocol(self):
        import os
        from unittest.mock import patch
        raw="020000000000000031040000"
        with patch.dict(os.environ,{"WK_RAW_TOUCH_PROTOCOL":"2"}):
            with TouchSession([(0,"E 5000 0"),(0,"H B 9"),(0,"H D 9 "+raw)],version=2) as s:
                self.assertTrue(wait_until(lambda:any(row=="MT2D,9,"+raw for _,row in s.touch)))
                self.assertIsNone(s.proc.poll())
    def test_disabled_target_feature_keeps_keyboard_mouse_capture_available(self):
        with TouchSession([(0,"E 5000 0"),(0,"T 4 1"),(0,"T 4 0")],ready=False) as s:
            self.assertTrue(wait_until(lambda:(s.work/'started').exists()))
            self.assertTrue(wait_until(lambda:s.counts['T']==2))
            self.assertIsNone(s.proc.poll())
            self.assertEqual(s.touch,[])

if __name__=='__main__':unittest.main()
