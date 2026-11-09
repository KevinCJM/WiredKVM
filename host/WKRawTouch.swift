import Foundation
import Darwin

// Book only. The helper observes physical contacts, never opens USB. Capture
// remains the single stdout producer; native remains the single serial writer.
final class WKRawTouch {
    private var child: Process?
    private var control: FileHandle?
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var rows: [String] = []
    private var buffer = Data()
    private var failed = false
    private var helperReady = false
    private var hardwareReady = false
    private var remote = false
    private var epoch: UInt32 = UInt32(truncatingIfNeeded: UInt64(ProcessInfo.processInfo.systemUptime * 1000))
    private var current: UInt32 = 0
    private let output: (String) -> Void
    var enabled: Bool { remote && hardwareReady && helperReady && current != 0 }
    init(output: @escaping (String) -> Void) { self.output = output }
    func start(path: String) throws {
        guard path.hasPrefix("/"), child == nil else { throw NSError(domain:"WKRawTouch",code:1) }
        let p=Process(), incoming=Pipe(), outgoing=Pipe()
        p.executableURL=URL(fileURLWithPath:path); p.arguments=["--stream"]
        p.standardInput=incoming; p.standardOutput=outgoing; p.standardError=FileHandle.standardError
        // No USB or target identity is passed to the raw collector.
        try p.run(); child=p; control=incoming.fileHandleForWriting
        let fd=incoming.fileHandleForWriting.fileDescriptor
        _=fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK)
        outgoing.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data=handle.availableData
            guard let self else { return }
            self.lock.lock(); defer {self.lock.unlock()}
            if data.isEmpty {self.failed=true;return}
            if self.buffer.count+data.count>16_384 {self.failed=true;self.buffer.removeAll();return}
            self.buffer.append(data)
            while let n=self.buffer.firstIndex(of:10) {
                let row=String(data:self.buffer.prefix(upTo:n),encoding:.utf8) ?? ""
                self.buffer.removeSubrange(...n)
                if self.rows.count>=64 {self.failed=true;self.rows.removeAll();break}
                if row.hasPrefix("H ") && row.utf8.count<=160 {self.rows.append(row)}
            }
        }
        let t=DispatchSource.makeTimerSource(queue:.main);timer=t
        t.schedule(deadline:.now(),repeating:.milliseconds(4))
        t.setEventHandler { [weak self] in self?.drain() };t.resume()
    }
    private func command(_ text:String)->Bool {
        guard let control else{return false}
        let data=Array((text+"\n").utf8)
        let n=data.withUnsafeBytes {Darwin.write(control.fileDescriptor,$0.baseAddress,data.count)}
        return n==data.count
    }
    private func leave() {
        if current != 0 {output("H E \(current)");current=0}
        _=command("OFF")
    }
    func setRemote(_ active:Bool) { if remote != active {leave();remote=active;arm()} }
    func setHardware(_ ready:Bool) { if hardwareReady != ready {leave();hardwareReady=ready;arm()} }
    private func arm() {
        guard remote,hardwareReady,helperReady,current==0 else{return}
        epoch &+= 1;if epoch==0 {epoch=1};current=epoch
        if !command("ON \(current)") {fault()}
    }
    private func fault() {leave();helperReady=false;hardwareReady=false}
    private func drain() {
        lock.lock();let pending=rows;rows.removeAll(keepingCapacity:true);let bad=failed;failed=false;lock.unlock()
        if bad {fault();return}
        for row in pending {
            if row=="H READY" {helperReady=true;arm();continue}
            if row=="H FAULT" {leave();arm();continue}
            if row=="H STOPPED" {fault();continue}
            let pieces=row.split(separator:" ")
            guard enabled, pieces.count>=3, UInt32(pieces[2])==current else{continue}
            if pieces[1]=="B" && pieces.count==3 || pieces[1]=="D" && pieces.count==4 {output(row)}
            // Helper's E is a lease failure or shutdown, never keep suppressing
            // normal scroll after it has stopped forwarding this session.
            if pieces[1]=="E" && pieces.count==3 {leave();arm()}
        }
    }
    func stop() {leave();timer?.cancel();timer=nil;try? control?.close();control=nil;child?.terminate();child=nil}
    deinit {stop()}
}
