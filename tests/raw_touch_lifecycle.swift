import Foundation
import CoreFoundation
import Darwin

// Two roles in one fixture executable. No Apple input/USB/clipboard framework.
signal(SIGPIPE,SIG_IGN)
let packet="020000000000000031000088"
if CommandLine.arguments.contains("--stream") {
    print("H READY");fflush(stdout)
    var last="0"
    while let row=readLine(){
        if row.hasPrefix("ON "){last=String(row.dropFirst(3));print("H B \(last)");print("H D \(last) \(packet)");fflush(stdout)}
        else if row=="OFF" {print("H D \(last) \(packet)");print("H E \(last)");fflush(stdout)}
    }
    exit(0)
}
var rows:[String]=[]
let touch=WKRawTouch{rows.append($0)}
func wait(_ seconds:Double){let until=Date().addingTimeInterval(seconds);while Date()<until{CFRunLoopRunInMode(.defaultMode,0.005,true)}}
try touch.start(path:URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.path)
wait(0.1);assert(!touch.enabled&&rows.isEmpty)
touch.setRemote(true);wait(0.03);assert(!touch.enabled&&rows.isEmpty)
touch.setHardware(true);wait(0.1);assert(touch.enabled&&rows.contains(where:{$0.hasPrefix("H D ")}))
let first=rows.first(where:{$0.hasPrefix("H B ")})!.split(separator:" ")[2]
touch.setRemote(false);let n=rows.count;wait(0.1)
assert(!touch.enabled&&rows.count==n) // delayed old-frame/old-end must not escape
assert(rows.last=="H E \(first)")
touch.setRemote(true);wait(0.1);assert(touch.enabled)
let second=rows.last(where:{$0.hasPrefix("H B ")})!.split(separator:" ")[2]
assert(first != second)
touch.setHardware(false);let stopped=rows.count;wait(0.1);assert(!touch.enabled&&rows.count==stopped)
touch.stop();print("RAW_TOUCH_LIFECYCLE_PASS local_gate=true delayed_old_frames_filtered=true new_epoch=true")
