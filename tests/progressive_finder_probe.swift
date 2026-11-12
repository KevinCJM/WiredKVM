// Explicit Book-only native Finder experiment. Uses generated content, one
// loopback portal and its own temporary mount. No USB, target or installation.
import AppKit
import Foundation
import CryptoKit
import Darwin

private final class NativeReadObservations: @unchecked Sendable {
    let root: URL
    private let lock=NSLock()
    private var entries=[[String:Any]]()
    init(_ root:URL){self.root=root}
    func record(_ offset:UInt64,_ count:Int,_ verified:Bool){
        lock.lock();defer{lock.unlock()};guard entries.count<160 else{return}
        entries.append(["offset":offset,"bytes":count,"wholeFileVerified":verified,"timeUnix":Date().timeIntervalSince1970])
        if let data=try? JSONSerialization.data(withJSONObject:entries,options:[.prettyPrinted,.sortedKeys]){try? data.write(to:root.appendingPathComponent("reads.json"),options:.atomic)}
    }
}

@main @MainActor final class ProgressiveFinderProbe: NSObject, NSApplicationDelegate {
    private let portal = WKFilePortal()
    private var timer: Timer?, reader: WKReceivingFile?
    private var fd: Int32 = -1, written = 0, began: Date?, failed = false, finished = false
    private let content = Data((0..<(4*1024*1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    private let root: URL
    private let failure: Bool
    init(root: URL, failure: Bool) { self.root=root;self.failure=failure;super.init() }
    static func main() {
        let args=Array(CommandLine.arguments.dropFirst())
        guard args.count==2,["slow","fail"].contains(args[0]),args[1].hasPrefix("/"),
              FileManager.default.fileExists(atPath:args[1]) else { fputs("usage: slow|fail EXISTING_TEST_DIRECTORY\n",stderr);exit(2) }
        let app=NSApplication.shared, delegate=ProgressiveFinderProbe(root:URL(fileURLWithPath:args[1]),failure:args[0]=="fail")
        app.delegate=delegate;app.setActivationPolicy(.accessory);app.run();withExtendedLifetime(delegate){}
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        portal.start { [weak self] result in
            guard let self else{return}
            do { try result.get();try self.prepare() }
            catch {self.record(["state":"error","code":"portal-start-or-fixture"]);NSApplication.shared.terminate(nil)}
        }
    }
    private func record(_ values:[String:Any]) {
        var data=values;data["timeUnix"]=Date().timeIntervalSince1970
        if let bytes=try? JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]){try? bytes.write(to:root.appendingPathComponent("status.json"),options:.atomic)}
    }
    private func prepare() throws {
        let url=root.appendingPathComponent("unlinked-receiver")
        fd=Darwin.open(url.path,O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0,unlink(url.path)==0 else{throw WKStreamError.system(errno)}
        let incoming=try WKReceivingFile(fd:fd,size:UInt64(content.count));reader=incoming
        let observations=NativeReadObservations(root);incoming.onRead={observations.record($0,$1,$2)}
        let offer=WKStreamOffer(id:UUID().uuidString.lowercased(),name:failure ? "WiredKVM-native-failure.bin":"WiredKVM-native-slow.bin",nonce:"901",size:UInt64(content.count))
        let remote=try portal.offerStream(offer);try portal.beginReceiving(id:offer.id,file:incoming)
        let board=NSPasteboard.general;board.clearContents()
        guard board.writeObjects([remote as NSURL]) else{throw WKFilePortalError.failed}
        let plan:[String:Any]=["state":"ready","filename":offer.name,"bytes":content.count,"sha256":SHA256.hash(data:content).map{String(format:"%02x",$0)}.joined(),"mode":failure ? "fail":"slow","clipboardReplacedWithGeneratedFile":true,"physicalUSB":false,"targetAccess":false,"installed":false]
        try JSONSerialization.data(withJSONObject:plan,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("fixture.json"))
        record(["state":"ready","bytes":content.count])
        timer=Timer.scheduledTimer(withTimeInterval:4,repeats:true){[weak self] _ in MainActor.assumeIsolated{self?.tick()}}
    }
    private func tick() {
        if FileManager.default.fileExists(atPath:root.appendingPathComponent("stop").path){stop();return}
        guard !finished,!failed,let reader else{return}
        if began==nil {
            guard (portal.diagnosticCounts?[2] ?? 0)>0 else{return}
            began=Date()
        }
        if failure&&written>=131072 {failed=true;reader.fail();record(["state":"intentionally-failed","written":written,"total":content.count]);return}
        let count=min(65536,content.count-written)
        let n=content.withUnsafeBytes{pwrite(fd,$0.baseAddress!.advanced(by:written),count,off_t(written))}
        guard n==count else{failed=true;reader.fail();record(["state":"error","code":"fixture-write"]);return}
        written+=count;reader.advance(to:UInt64(written))
        if written==content.count {
            var observed=Data(count:content.count)
            let n=observed.withUnsafeMutableBytes{pread(fd,$0.baseAddress!,$0.count,0)}
            guard n==content.count,SHA256.hash(data:observed)==SHA256.hash(data:content) else{failed=true;reader.fail();record(["state":"error","code":"fixture-integrity"]);return}
            do{try reader.finishVerified();finished=true;record(["state":"verified","written":written,"seconds":Date().timeIntervalSince(began!)])}
            catch{failed=true;reader.fail();record(["state":"error","code":"fixture-final-state"])}
        } else {record(["state":"receiving","written":written,"total":content.count,"seconds":Date().timeIntervalSince(began!)])}
    }
    private func stop() {
        timer?.invalidate();timer=nil;reader?.fail()
        portal.stop {NSApplication.shared.terminate(nil)}
    }
    func applicationWillTerminate(_ notification: Notification) {timer?.invalidate();reader?.fail();if fd>=0{Darwin.close(fd);fd = -1}}
}
