"""Production v2 capture tests; OS replay, focus and clipboard use fake sinks.

No EventTap, real input, USB or general clipboard access is used.
"""
from __future__ import annotations
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def replace_function(source, name, body):
    start = source.index('private func ' + name + '(')
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[:opening + 1] + '\n' + body + '\n' + source[end - 1:]


@unittest.skipUnless(sys.platform == 'darwin', 'macOS capture only')
class WiredClipboardCaptureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='wk-wired-routing-v2-')
        cls.addClassCleanup(cls.temp.cleanup)
        path = Path(cls.temp.name)
        source = (ROOT/'host/macos_capture.swift').read_text()
        source = replace_function(source,'replayClipboardShortcut',' fixtureReplays.append(key)')
        source = replace_function(source,'clipboardPID',' return fixturePID')
        source = replace_function(source,'clipboardIntent',' fixtureIntents.append(line)')
        source = source.replace('private var activeClient = false',
            'private var fixtureRevision = 0\nprivate var fixtureReplays: [Int] = []\n'
            'private var fixtureIntents: [String] = []\nprivate var fixturePID: pid_t = 71\n'
            'private var activeClient = false',1)
        source = source.replace('NSPasteboard.general.changeCount','fixtureRevision')
        harness = r'''
if CommandLine.arguments.contains("--fixture-routing") {
    precondition(wiredClipboardEnabled)
    receiveClipboardControl("STATE",token:"1")
    let proxy=CGEventTapProxy(bitPattern:1)!
    let eventSource=CGEventSource(stateID:.privateState)
    let scenario=CommandLine.arguments.last!
    func sample(_ key:Int,_ type:CGEventType = .keyDown,_ flags:CGEventFlags = [.maskCommand],repeatKey:Bool=false)->CGEvent {
        let e=CGEvent(keyboardEventSource:eventSource,virtualKey:CGKeyCode(key),keyDown:type != .keyUp)!
        e.type=type;e.flags=flags;e.setIntegerValueField(.keyboardEventAutorepeat,value:repeatKey ? 1:0);return e
    }
    func route(_ event:CGEvent)->Bool {
        let passed=eventTapCallback(proxy:proxy,type:event.type,event:event,refcon:nil) != nil
        if passed && event.type == .keyDown && event.flags.contains(.maskCommand) && event.getIntegerValueField(.keyboardEventAutorepeat)==0 {
            let key=Int(event.getIntegerValueField(.keyboardEventKeycode));if key==8 || key==9 {fixtureReplays.append(key)}
        };return passed
    }
    func projection(_ side:UInt64,generation:UInt64=1,applied:UInt64?=nil,mask:UInt64=0,book:UInt64=121,mini:UInt64=242) {
        receiveClipboardControl("ROUTE",token:"\(generation),\(applied ?? clipboardIntents.inputSequence),\(side),\(book),\(mini),0,0,0,\(mask)")
    }
    func crossPaste(source:UInt64=1)->ClipboardShortcut {
        projection(source);activeClient=source==0;_ = route(sample(9));return clipboardIntents.paste!
    }
    func result(_ p:ClipboardShortcut,_ status:String="ready") {
        receiveClipboardControl("RESULT",token:p.token+"."+status+(status=="ready" ? ".\(fixtureRevision)":""))
    }
    switch scenario {
    case "copy-local-native","copy-remote-native":
        activeClient=scenario=="copy-remote-native"
        precondition(route(sample(8)) == !activeClient && route(sample(8,.keyUp)) == !activeClient)
        precondition(fixtureIntents.filter{$0.hasPrefix("SELECT ")}.count==1)
        precondition(fixtureReplays == (activeClient ? []:[8]))
    case "copy-repeat":
        _ = route(sample(8));_ = route(sample(8,repeatKey:true))
        precondition(fixtureIntents.filter{$0.hasPrefix("SELECT ")}.count==1 && fixtureReplays == [8])
    case "native-copy-before-projection","native-cut-before-projection":
        projection(1);let before=clipboardIntents.inputSequence
        _ = route(sample(scenario.contains("cut") ? 7:8));projection(1,generation:2,applied:before)
        precondition(route(sample(9)) && clipboardIntents.paste==nil,"unacknowledged native input must outrank delayed route")
    case "same-revision-book","same-revision-mini":
        let remote=scenario.hasSuffix("mini");activeClient=remote;projection(remote ? 1:0)
        for _ in 0..<100 {_ = route(sample(8));_ = route(sample(8,.keyUp))}
        precondition(clipboardIntents.stamps == [121,242],"Copy cannot create or clear content versions")
        precondition(route(sample(9)) == !remote,"same-side paste must remain native")
        activeClient = !remote;_ = route(sample(9));precondition(clipboardIntents.paste != nil)
        precondition(fixtureIntents.last!.hasPrefix("PASTE "))
    case "return-to-old-side":
        projection(0);_ = route(sample(8));activeClient=true;_ = route(sample(8));projection(1,generation:2)
        activeClient=false;_ = route(sample(8));precondition(clipboardIntents.stamps == [121,242])
        activeClient=true;_ = route(sample(9));precondition(clipboardIntents.paste != nil,"A-B-A unchanged copy must select the old side")
    case "unknown-source-native":
        projection(2,book:0,mini:0);precondition(route(sample(9)) && clipboardIntents.paste==nil)
    case "unknown-version-refresh":
        projection(2,book:0,mini:0);_ = route(sample(8));activeClient=true;_ = route(sample(9))
        precondition(clipboardIntents.paste != nil && clipboardIntents.stamps == [0,0],"engine must resolve the explicit source without invented versions")
    case "cut-cross-guard":
        projection(0);_ = route(sample(7));activeClient=true;_ = route(sample(9));let p=clipboardIntents.paste!
        result(p,"blocked");precondition(clipboardIntents.paste==nil && fixtureReplays.isEmpty,"only engine may confirm fresh Cut data")
    case "paste-cancel","paste-focus","paste-expired","paste-epoch":
        let p=crossPaste()
        if scenario=="paste-cancel" {_ = route(sample(0,.keyDown,[]))}
        if scenario=="paste-focus" {fixturePID=72}
        if scenario=="paste-expired" {clipboardIntents.paste=ClipboardShortcut(token:p.token,remote:p.remote,pid:p.pid,at:ProcessInfo.processInfo.systemUptime-181,epoch:p.epoch)}
        if scenario=="paste-epoch" {clipboardIntents.focusEpoch += 1}
        result(p);precondition(!fixtureReplays.contains(9),"late or wrong-focus result cannot replay")
    case "paste-token":
        let p=crossPaste();receiveClipboardControl("RESULT",token:"999999.ready.0");precondition(fixtureReplays.isEmpty)
        result(p);result(p);precondition(fixtureReplays == [9])
    case "paste-local-revision":
        let p=crossPaste();fixtureRevision += 1
        receiveClipboardControl("RESULT",token:p.token+".ready.0")
        precondition(fixtureReplays.isEmpty && fixtureIntents.last=="CANCEL "+p.token,
                     "new local ownership between engine commit and replay must win")
    case "menu-local-wins":
        projection(1);fixtureRevision += 1;precondition(route(sample(9)))
        precondition(clipboardIntents.paste==nil && fixtureReplays == [9])
    case "offline-native":
        projection(1);receiveClipboardControl("STATE",token:"0");precondition(route(sample(8)) && route(sample(9)))
        precondition(fixtureReplays == [8,9])
    case "same-side-native":
        projection(0);precondition(route(sample(9)));activeClient=true;projection(1,generation:2)
        precondition(!route(sample(9)) && clipboardIntents.paste==nil)
    case "native-mask":
        projection(0,mask:2);activeClient=true;precondition(!route(sample(9)) && clipboardIntents.paste==nil)
        precondition(fixtureIntents.allSatisfy{!$0.hasPrefix("PASTE ")})
    case "repeat-after-ready":
        let p=crossPaste();result(p);precondition(route(sample(9)) && clipboardIntents.paste==nil)
        precondition(fixtureReplays == [9,9])
    case "route-stale":
        projection(0,generation:5);projection(1,generation:4);precondition(clipboardIntents.selectedSide==0)
        receiveClipboardControl("ROUTE",token:"6,\(clipboardIntents.inputSequence+1),1,121,242,0,0,0,0");precondition(clipboardIntents.selectedSide==0)
    case "context-bounded":
        let count=fixtureIntents.count;for _ in 0..<100 {receiveClipboardControl("STATE",token:"1")}
        precondition(fixtureIntents.count==count,"heartbeat cannot flood context commands")
        clipboardContext();precondition(fixtureIntents.count==count+1 && fixtureIntents.last!.hasPrefix("CONTEXT "))
    default:fatalError("unknown scenario")
    }
    print("WIRED_CLIPBOARD_ROUTING_PASS "+scenario);exit(0)
}
'''
        source=source.replace('// Safe regression paths below',harness+'\n// Safe regression paths below',1)
        fixture=path/'capture.swift';fixture.write_text(source);cls.binary=path/'capture'
        result=subprocess.run(['/usr/bin/swiftc','-O','-target',f'{platform.machine()}-apple-macosx13.0',
            '-module-cache-path',str(path/'modules'),'-framework','ApplicationServices','-framework','Cocoa',
            str(fixture),'-o',str(cls.binary)],capture_output=True,text=True,timeout=100)
        if result.returncode:raise AssertionError(result.stderr)

    def run_scenario(self,scenario):
        env=dict(os.environ,WK_TARGET_ABSOLUTE='1',WK_WIRED_CLIPBOARD='1')
        for key in ('WK_TARGET_IPHONE','WK_FILE_TRANSFER','WK_CLIPBOARD_SYNC'):env.pop(key,None)
        result=subprocess.run([str(self.binary),'--fixture-routing',scenario],env=env,capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('WIRED_CLIPBOARD_ROUTING_PASS '+scenario,result.stdout)


SCENARIOS=['copy-local-native','copy-remote-native','copy-repeat','native-copy-before-projection',
 'native-cut-before-projection','same-revision-book','same-revision-mini','return-to-old-side',
 'unknown-source-native','unknown-version-refresh','cut-cross-guard','paste-cancel','paste-focus',
 'paste-expired','paste-epoch','paste-token','paste-local-revision','menu-local-wins','offline-native','same-side-native',
 'native-mask','repeat-after-ready','route-stale','context-bounded']
for scenario in SCENARIOS:
    setattr(WiredClipboardCaptureTests,'test_'+scenario.replace('-','_'),lambda self,s=scenario:self.run_scenario(s))

if __name__=='__main__':unittest.main()
