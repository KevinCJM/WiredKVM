"""Native owner + fake capture/USB peer. Never accesses real USB or OS input."""
import socket
import time
import unittest
from tests.test_native_absolute import FakeSession, wait_until

class TouchSession(FakeSession):
    def __init__(self,events=(),ready=True,version=1):
        super().__init__(events,extra=("--raw-touch","/private/tmp/fixture-unused-touch-helper"))
        self.touch=[];self.ready=ready;self.version=version
    def peer(self):
        try:
            while not self.stop.is_set():
                try: channel,_=self.server.accept();break
                except socket.timeout: continue
            else:return
            with channel,channel.makefile("rb") as stream:
                for wire in stream:
                    text=wire.decode().strip()
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
