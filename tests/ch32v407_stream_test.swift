import Foundation
import AppKit
import CryptoKit
import Darwin

private struct Failure: Error, CustomStringConvertible { let description: String }
private func check(_ value: @autoclosure () throws -> Bool, _ reason: String) throws { if try !value() { throw Failure(description: reason) } }

final class FirmwarePipe {
    let lock = NSLock()
    let core = wk407_sim_create()!
    var stalled = [false, false], corrupt = false, connected = true
    var readLimit = 65536, writeLimit = 65536
    var probes = 0, failures = 0
    var trace = false
    var txBuffer = [Data(),Data()], rxBuffer = [Data(),Data()]
    var txBodies: [[String: UInt64]] = [[:],[:]], rxBodies: [[String: UInt64]] = [[:],[:]]
    func record(_ data: Data, port: Int, tx: Bool) {
        guard trace else { return }
        var bytes = (tx ? txBuffer[port] : rxBuffer[port]); bytes.append(data)
        while bytes.count >= 512 {
            let d = Data(bytes.prefix(512)); bytes = Data(bytes.dropFirst(512))
            if let f = try? WKStreamEngine.Frame.decode(d), f.kind == 1 {
                if tx { txBodies[port][f.id, default: 0] += UInt64(f.body.count) }
                else { rxBodies[port][f.id, default: 0] += UInt64(f.body.count) }
            }
        }
        if tx { txBuffer[port] = bytes } else { rxBuffer[port] = bytes }
    }
    deinit { wk407_sim_destroy(core) }
    func probe(_ n: UInt32) { lock.lock(); defer { lock.unlock() }; probes += 1; if wk407_sim_hid_probe(core, n) != 1 { failures += 1 } }
}
final class FirmwareIO: WKStreamIO {
    let shared: FirmwarePipe
    let port: UInt8
    var closed = false
    init(_ shared: FirmwarePipe, _ port: UInt8) { self.shared = shared; self.port = port }
    func forwardControl(_ data: Data) -> Bool {
        shared.lock.lock(); defer { shared.lock.unlock() }
        return data.withUnsafeBytes { wk407_sim_control(shared.core, UInt32(port), $0.baseAddress) != 0 }
    }
    func close() { closed = true }
    func read(maximum: Int) throws -> Data {
        shared.lock.lock(); defer { shared.lock.unlock() }
        if closed || !shared.connected { throw WKStreamError.disconnected }
        if shared.stalled[Int(port)] { return Data() }
        var data = Data(count: min(maximum, shared.readLimit))
        let n = data.withUnsafeMutableBytes { wk407_sim_read(shared.core, UInt32(port), $0.baseAddress, $0.count) }; data.count = n
        if shared.corrupt && n > 100 { data[100] ^= 1; shared.corrupt = false }
        shared.record(data, port: Int(port), tx: false); return data
    }
    func write(_ data: Data) throws -> Int {
        shared.lock.lock(); defer { shared.lock.unlock() }
        if closed || !shared.connected { throw WKStreamError.disconnected }
        let n = data.withUnsafeBytes { wk407_sim_write(shared.core, UInt32(port), $0.baseAddress, min($0.count, shared.writeLimit)) }
        shared.record(Data(data.prefix(n)), port: Int(port), tx: true); return n
    }
}

@main struct CH32StreamTest {
    static func source(_ root: URL, _ name: String, _ size: UInt64, _ seed: UInt8) throws -> URL {
        let url = root.appendingPathComponent(name)
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        guard fd >= 0 else { throw WKStreamError.system(errno) }; defer { Darwin.close(fd) }
        guard ftruncate(fd, off_t(size)) == 0 else { throw WKStreamError.system(errno) }
        if size > 0 {
            let block = Data((0..<min(4096, Int(size))).map { UInt8(truncatingIfNeeded: $0) ^ seed })
            for offset in Set([UInt64(0), size / 2, size - UInt64(block.count)]) {
                let count = min(block.count, Int(size - offset))
                try check(block.withUnsafeBytes { pwrite(fd, $0.baseAddress!, count, off_t(offset)) } == count, "source write")
            }
        }
        return url
    }
    static func digest(_ url: URL) throws -> String {
        let f = try FileHandle(forReadingFrom: url); defer { try? f.close() }; var h = SHA256()
        while let d = try f.read(upToCount: 65536), !d.isEmpty { h.update(data: d) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func digest(_ file: WKReceivedFile) throws -> String {
        var offset: UInt64 = 0, h = SHA256()
        while offset < file.size { let d = try file.read(offset: offset, maximum: 65536); h.update(data: d); offset += UInt64(d.count) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func pair(_ root: URL) -> (FirmwarePipe, WKStreamEngine, WKStreamEngine) {
        let p = FirmwarePipe(); let a = WKStreamEngine(io: FirmwareIO(p, 0), directory: root, inlineDisk: true), b = WKStreamEngine(io: FirmwareIO(p, 1), directory: root, inlineDisk: true)
        a.onControl = { [weak b] in b?.control($0) }; b.onControl = { [weak a] in a?.control($0) }
        a.setEpoch(12345); b.setEpoch(12345); return (p, a, b)
    }
    static func main() throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wk-ch32-stress-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
#if WK_TREE
        if CommandLine.arguments.contains("--collections") { try WKCollectionTransferSelfTest.run(root); return }
        if CommandLine.arguments.contains("--collection-pipeline") {
            try WKFilePipelineSelfTest.collectionSuite {
                let pipe=FirmwarePipe()
                return (FirmwareIO(pipe,0),FirmwareIO(pipe,1),{paused in pipe.lock.lock();pipe.stalled=[paused,paused];pipe.lock.unlock()})
            }
            return
        }
#endif
        let large = CommandLine.arguments.contains("--large")
        if CommandLine.arguments.contains("--cancel") { try cancellation(root); try blockedDisk(root); return }
        if CommandLine.arguments.contains("--image-bounds") { try WKFilePipelineSelfTest.bulkImageBounds(); return }
        if CommandLine.arguments.contains("--images") {
            try WKFilePipelineSelfTest.bulkImageSuite {
                let pipe = FirmwarePipe()
                return (FirmwareIO(pipe, 0), FirmwareIO(pipe, 1), { paused in pipe.lock.lock(); pipe.stalled = [paused,paused]; pipe.lock.unlock() })
            }
            print("CH32_BULK_IMAGES_PASS"); return
        }
        if CommandLine.arguments.contains("--portal") { try WKFilePortalSelfTest.main(); return }
        if CommandLine.arguments.contains("--pipeline") {
            try WKFilePipelineSelfTest.streamSuite {
                let pipe = FirmwarePipe()
                return (FirmwareIO(pipe, 0), FirmwareIO(pipe, 1), { paused in pipe.lock.lock(); pipe.stalled = [paused,paused]; pipe.lock.unlock() })
            }
            print("CH32_PIPELINE_PASS"); return
        }
        let count: UInt64 = CommandLine.arguments.contains("--gib") ? 1024 * 1024 * 1024 + 123 : large ? 8 * 1024 * 1024 * 1024 + 123 : 32 * 1024 * 1024 + 137
        try faults(root)
        let aURL = try source(root, "a.bin", count, 0xa3), bURL = try source(root, "b.bin", count + 17, 0x51)
        let asrc = try WKStreamSource(url: aURL, nonce: "100"), bsrc = try WKStreamSource(url: bURL, nonce: "101")
        let (pipe, a, b) = pair(root)
        var received: [String: WKReceivedFile] = [:], finished = Set<String>(), errors: [String] = []
        a.onFile = { received[$0] = $1 }; b.onFile = a.onFile
        a.onComplete = { finished.insert($0) }; b.onComplete = a.onComplete
        a.onFailure = { errors.append($0) }; b.onFailure = a.onFailure
        a.onFault = { errors.append(String(describing: $0)) }; b.onFault = a.onFault
        try a.add(asrc, now: 0); try b.expect(asrc.offer, now: 0)
        try b.add(bsrc, now: 0); try a.expect(bsrc.offer, now: 0)
        let started = Date()
        // Both peers stop reading for 300 steps. Then use odd-sized reads and
        // writes briefly before draining at normal simulator speed.
        pipe.stalled = [true, true]
        var iterations = 0
        while finished.count != 2 && iterations < 4_000_000 && errors.isEmpty {
            if iterations == 300 { pipe.stalled = [false, false]; pipe.readLimit = 509; pipe.writeLimit = 997 }
            if iterations == 450 { pipe.readLimit = 65536; pipe.writeLimit = 65536 }
            let now = Double(iterations) * 0.0001
            a.step(now: now); pipe.probe(UInt32(iterations)); b.step(now: now)
            iterations += 1
        }
        try check(errors.isEmpty, "stream failed \(errors)")
        try check(finished.count == 2 && received.count == 2, "large stream incomplete")
        try check(pipe.failures == 0 && pipe.probes == iterations, "file pressure blocked HID")
        for (source, url) in [(asrc,aURL),(bsrc,bURL)] {
            let file = received[source.offer.id]!
            try check(file.size == source.offer.size && file.sha256 == digest(url), "source hash mismatch")
            try check(file.sha256 == digest(file), "received disk hash mismatch")
        }
        try check(a.maxBuffered <= WKStreamEngine.queueLimit * 4 && b.maxBuffered <= WKStreamEngine.queueLimit * 4, "memory unbounded")
        // Verify the real Finder portal store reads bounded pieces from the
        // verified backing file, including an offset beyond the 32-bit boundary.
        let store = WKPortalStore(), file = received[asrc.offer.id]!
        _ = try store.offer(id: asrc.offer.id, name: asrc.offer.name, size: Int(file.size), sha256: String(repeating: "0", count: 64), streaming: true)
        try store.fulfill(id: asrc.offer.id, file: file)
        let payload = try store.waitPayload(id: asrc.offer.id, timeout: 1, cancelled: { false })
        let offset = Int(file.size) - 500
        try check(payload.read(offset: offset, maximum: 500) == file.read(offset: UInt64(offset), maximum: 500), "64-bit portal range")
        if CommandLine.arguments.contains("--http") {
            let server = WKPortalHTTPServer(store: store, proxyCheck: { _ in true }); try server.start(); defer { server.stop() }
            let url = server.url.appendingPathComponent(asrc.offer.id).appendingPathComponent(asrc.offer.name)
            let reply = try WKFilePortalSelfTest.request(url, headers: ["Range":"bytes=65530-196605"])
            let first = try file.read(offset: 65530, maximum: 65536), second = try file.read(offset: 131066, maximum: 65536)
            try check(reply.status == 206 && reply.body == first + second + file.read(offset: 196602, maximum: 4), "file-backed HTTP multi-chunk range")
            print("CH32_FILE_BACKED_HTTP_PASS")
        }
        let report: [String: Any] = ["test":"CH32V407 simulated dual USB + real Swift file engines", "physicalUSB":false,
            "bytesAtoB":asrc.offer.size, "bytesBtoA":bsrc.offer.size, "hidProbes":pipe.probes, "hidFailures":pipe.failures,
            "sha256A":file.sha256, "sha256B":received[bsrc.offer.id]!.sha256, "bridgeBytes":wk407_sim_size(),
            "bulkQueuePeak":wk407_sim_peak(pipe.core), "hostBufferPeakA":a.maxBuffered, "hostBufferPeakB":b.maxBuffered,
            "wallSeconds":Date().timeIntervalSince(started), "faultsPassed":true]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
        if let index = CommandLine.arguments.firstIndex(of: "--result"), index + 1 < CommandLine.arguments.count { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index+1])) }
        print(String(decoding: data, as: UTF8.self)); a.stop(); b.stop(); print("CH32_STREAM_STRESS_PASS")
    }
    static func cancellation(_ root: URL) throws {
        let oldURL = try source(root, "cancel-old.bin", 2*1024*1024+123, 71)
        let nextURL = try source(root, "cancel-next.bin", 65536, 19)
        let independentURL = try source(root, "independent.bin", 3*1024*1024, 42)
        var trials = 0, maximumResidual: UInt64 = 0, maximumFirst: Double = 0, maximumAccept: Double = 0
        for direction in 0..<2 { for phase in [0,1,50,99,100,101,102] { for _ in 0..<20 {
            let (pipe,a,b) = pair(root); defer { a.stop(); b.stop() }; pipe.trace = true
            let sender = direction == 0 ? a : b, receiver = direction == 0 ? b : a
            let old = try WKStreamSource(url: oldURL, nonce: "1")
            let independent = try WKStreamSource(url: independentURL, nonce: "3")
            let next = try WKStreamSource(url: nextURL, nonce: "2")
            var files: [String: WKReceivedFile] = [:], failed = Set<String>(), now = 0.0
            a.onFile = { files[$0] = $1 }; b.onFile = a.onFile
            a.onFailure = { failed.insert($0) }; b.onFailure = a.onFailure
            try sender.add(old, now: now); try receiver.expect(old.offer, now: now)
            try sender.add(independent, now: now); try receiver.expect(independent.offer, now: now)
            if phase == 102 { pipe.readLimit = 509; pipe.writeLimit = 997 } // cancel with partial cells in both OS streams
            if phase == 101 { pipe.stalled[1-direction] = true } // body stalls; control remains live
            let threshold = UInt64(phase == 101 ? 1 : min(phase,99)) * old.offer.size / 100
            for _ in 0..<10000 {
                if phase == 0 { break }
                a.step(now: now); b.step(now: now); now += 0.001; pipe.probe(UInt32(trials))
                if (pipe.txBodies[direction][old.offer.id] ?? 0) >= threshold { break }
            }
            let before = (pipe.txBodies[direction][old.offer.id] ?? 0) + (pipe.rxBodies[1-direction][old.offer.id] ?? 0)
            let cancelledAt = now
            receiver.cancel(old.offer.id) // one-sided cancellation, never artificially cancel both peers
            let requestedAt = now
            var accepted: Double?, first: Double?
            receiver.onAccepted = { if $0 == next.offer.id { accepted = now } }
            try sender.add(next, now: now); try receiver.expect(next.offer, now: now)
            for i in 0..<10000 {
                a.step(now: now); b.step(now: now); pipe.probe(UInt32(trials+i)); now += 0.001
                if first == nil && (pipe.txBodies[direction][next.offer.id] ?? 0) > 0 { first = now }
                if phase == 101 && i == 30 {
                    // Model 30 seconds of stalled body without sleeping. Source
                    // must be stopped even while the destination cannot read.
                    now += 30; pipe.stalled[1-direction] = false
                }
                if files[next.offer.id] != nil && files[independent.offer.id] != nil { break }
            }
            let residual = (pipe.txBodies[direction][old.offer.id] ?? 0) + (pipe.rxBodies[1-direction][old.offer.id] ?? 0) - before
            maximumResidual = max(maximumResidual, residual)
            try check(residual <= 262144, "cancel residual two-hop budget")
            try check(files[old.offer.id] == nil, "cancelled contents published")
            try check(files[next.offer.id]?.sha256 == digest(nextURL), "new transfer did not bypass cancelled body")
            try check(files[independent.offer.id]?.sha256 == digest(independentURL), "cancel destroyed independent file")
            try check(accepted != nil && accepted! - requestedAt <= 0.3, "new transaction confirmation delayed")
            if phase != 101 {
                try check(first != nil && first! - requestedAt <= 0.5, "new body waited for stale stream")
                maximumFirst = max(maximumFirst, first! - requestedAt)
            }
            maximumAccept = max(maximumAccept, accepted! - requestedAt)
            try check(pipe.failures == 0 && !a.stopped && !b.stopped, "cancel interrupted HID/engine")
            try check(a.activeCount == 0 || now-cancelledAt < 60, "leaked transactions")
            trials += 1
        } } }
        print("CH32_CANCEL_PASS trials=\(trials) bothHopResidualMax=\(maximumResidual) newAcceptModelMaxMs=\(maximumAccept*1000) newFirstModelMaxMs=\(maximumFirst*1000) physicalUSB=false")
    }
    static func blockedDisk(_ root: URL) throws {
        let oldURL = try source(root,"disk-old.bin",2*1024*1024,83), nextURL = try source(root,"disk-next.bin",65536,84)
        for direction in 0..<2 { for slowSource in [true,false] {
            let pipe = FirmwarePipe()
            // Use one shared virtual device, with production asynchronous disk tasks.
            let first = WKStreamEngine(io:FirmwareIO(pipe,0),directory:root), second = WKStreamEngine(io:FirmwareIO(pipe,1),directory:root)
            defer { first.stop(); second.stop() }
            first.onControl = { [weak second] in second?.control($0) }; second.onControl = { [weak first] in first?.control($0) }
            first.setEpoch(4321); second.setEpoch(4321)
            let sender = direction == 0 ? first : second, receiver = direction == 0 ? second : first
            let entered = DispatchSemaphore(value:0), unblock = DispatchSemaphore(value:0)
            let blocked = slowSource ? sender : receiver
            blocked.diskGate = { entered.signal(); unblock.wait() }
            defer { unblock.signal() }
            var files = Set<String>(); receiver.onFile = { id,_ in files.insert(id) }
            let old = try WKStreamSource(url:oldURL,nonce:"91")
            let start = ProcessInfo.processInfo.systemUptime
            try sender.add(old,now:start); try receiver.expect(old.offer,now:start)
            var waiting = false
            while ProcessInfo.processInfo.systemUptime-start < 3 {
                let now = ProcessInfo.processInfo.systemUptime; first.step(now:now); second.step(now:now)
                if entered.wait(timeout:.now()) == .success { waiting = true; break }
                Thread.sleep(forTimeInterval:0.0002)
            }
            try check(waiting,"disk fault did not block a real worker")
            blocked.diskGate = nil; receiver.cancel(old.offer.id)
            let next = try WKStreamSource(url:nextURL,nonce:"92"), request = ProcessInfo.processInfo.systemUptime
            try sender.add(next,now:request); try receiver.expect(next.offer,now:request)
            while !files.contains(next.offer.id) && ProcessInfo.processInfo.systemUptime-request < 2 {
                let now = ProcessInfo.processInfo.systemUptime; first.step(now:now); second.step(now:now); pipe.probe(300)
                Thread.sleep(forTimeInterval:0.0002)
            }
            try check(files.contains(next.offer.id) && !files.contains(old.offer.id),"blocked old disk delayed or overwrote new transaction")
            try check(pipe.failures == 0,"blocked disk affected input")
            unblock.signal()
            for _ in 0..<50 { let now = ProcessInfo.processInfo.systemUptime; first.step(now:now); second.step(now:now); Thread.sleep(forTimeInterval:0.0002) }
            try check(!files.contains(old.offer.id),"late disk completion resurrected cancellation")
        } }
        print("CH32_BLOCKED_DISK_PASS source-and-destination both-directions late-completion-discarded physicalUSB=false")
    }
    static func faults(_ root: URL) throws {
        // Model nonblocking CDC short reads: drain ready bytes in one turn,
        // stop at EAGAIN/empty, and never spin without a strict syscall limit.
        do {
            final class ShortReadIO: WKStreamIO {
                let port: UInt8 = 0
                var calls = 0, remaining = 12000, chunk = 512, oversized = false
                func forwardControl(_ data: Data) -> Bool { true }
                func close() { }
                func write(_ data: Data) throws -> Int { data.count }
                func read(maximum: Int) throws -> Data {
                    calls += 1
                    if oversized { return Data(count: maximum + 1) }
                    let n = min(remaining, chunk, maximum)
                    remaining -= n; return Data(repeating: 0x73, count: n)
                }
            }
            let io = ShortReadIO()
            try check(WKStreamEngine.readAvailable(io) == Data(repeating: 0x73, count: 12000), "short CDC read lost ready bytes")
            try check(io.calls == 25, "empty CDC read did not end draining")
            io.remaining = 100; io.chunk = 1; io.calls = 0
            try check(WKStreamEngine.readAvailable(io).count == 32 && io.calls == 32, "CDC syscall budget was not bounded")
            io.remaining = 100000; io.chunk = 32768; io.calls = 0
            try check(WKStreamEngine.readAvailable(io).count == 32768 && io.calls == 1, "CDC byte budget was not bounded")
            io.oversized = true
            do { _ = try WKStreamEngine.readAvailable(io); throw Failure(description: "oversized CDC read admitted") } catch WKStreamError.invalid { }
            print("CH32_CDC_DRAIN_PASS ready_short_reads=true calls_bounded=32 bytes_bounded=32768")
        }
        // Admission limits fail before receiving file bytes or allocating a body.
        do {
            let (pipe,a,b) = pair(root); defer { a.stop(); b.stop(); _ = pipe }
            let bad = WKStreamOffer(id: UUID().uuidString.lowercased(), name: "../escape", nonce: "1", size: 1)
            do { try b.expect(bad, now: 0); throw Failure(description: "unsafe filename admitted") } catch is WKStreamError { }
            let huge = WKStreamOffer(id: UUID().uuidString.lowercased(), name: "huge", nonce: "1", size: WKStreamOffer.maximumSize)
            do { try b.expect(huge, now: 0); throw Failure(description: "disk reserve ignored") } catch WKStreamError.capacity { }
        }
        for scenario in ["empty","corrupt","disconnect","timeout","source-changed","content-changed-mtime-restored","metadata-changed","cancel","old-epoch"] {
            let url = try source(root, scenario + ".bin", scenario == "empty" ? 0 : 1048576, 0x18)
            let source = try WKStreamSource(url: url, nonce: "200")
            let (p,a,b) = pair(root); var complete = false, published = false, diagnostics: [String] = []
            a.onDiagnostic = { diagnostics.append($0) }; b.onDiagnostic = a.onDiagnostic
            a.onComplete = { _ in complete = true }; b.onFile = { _,_ in published = true }
            try a.add(source, now: 0); try b.expect(source.offer, now: 0)
            if scenario == "corrupt" { p.corrupt = true }
            if scenario == "timeout" { p.stalled = [true,true]; a.timeout = 0.01; b.timeout = 0.01 }
            if scenario == "old-epoch" { b.setEpoch(999) }
            for i in 0..<3000 {
                if i == 3 {
                    if scenario == "disconnect" { p.connected = false }
                    if scenario == "source-changed" {
                        let f = try FileHandle(forWritingTo: url); try f.seek(toOffset: 100000); try f.write(contentsOf: Data([3,4,5])); try f.close()
                    }
                    if scenario == "metadata-changed" {
                        let value = Data([7])
                        let n = value.withUnsafeBytes { setxattr(url.path, "com.wiredkvm.fixture", $0.baseAddress, $0.count, 0, 0) }
                        try check(n == 0, "fixture metadata change failed")
                    }
                    if scenario == "content-changed-mtime-restored" {
                        var before = stat(); try check(stat(url.path, &before) == 0, "fixture stat failed")
                        let fd = Darwin.open(url.path, O_WRONLY | O_CLOEXEC); try check(fd >= 0, "fixture open failed")
                        let bytes = Data([3,4,5]); let n = bytes.withUnsafeBytes { pwrite(fd,$0.baseAddress!,3,0) }
                        var times = [before.st_atimespec,before.st_mtimespec]
                        let restored = futimens(fd,&times); Darwin.close(fd)
                        try check(n == 3 && restored == 0, "fixture content change/mtime restore failed")
                    }
                    if scenario == "cancel" { a.cancel(source.offer.id); b.cancel(source.offer.id) }
                }
                a.step(now: Double(i) * 0.001); b.step(now: Double(i) * 0.001)
            }
            if ["empty", "metadata-changed"].contains(scenario) { try check(complete && published,"\(scenario) did not complete with verified content") }
            else { try check(!complete && !published, "\(scenario) incorrectly succeeded") }
            if scenario == "metadata-changed" {
                try check(!diagnostics.contains(where: { $0.contains("event=ERROR") }), "metadata-only revalidation incorrectly rejected content")
            }
            if scenario == "content-changed-mtime-restored" {
                try check(diagnostics.contains(where: { $0.contains("code=stream-source-changed") }), "same-size content mutation with restored mtime escaped revalidation")
            }
            a.stop(); b.stop()
        }
        print("CH32_STREAM_FAULTS_PASS empty corruption disconnect timeout source-change metadata-rehash restored-mtime-content-rejected cancellation retired-epoch")
    }
}
