import AppKit
import Foundation

private struct WKPipelineTestFailure: Error, CustomStringConvertible { let description: String }
private func wkPipelineExpect(_ value: @autoclosure () throws -> Bool, _ reason: String) throws {
    if try !value() { throw WKPipelineTestFailure(description: reason) }
}

private final class WKPipelineMemoryTransport: WKTransport {
    var onReport: (Data) -> Void = { _ in }
    var onConnection: (Bool) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    var reports: [Data] = []
    func start() {}
    func tick(_ time: Double) {}
    func send(_ bytes: Data) -> Bool { reports.append(bytes); return true }
    func stop() {}
}

// No listener or mount. Publishing a URL does not create/read its file.
private final class WKPipelineMockPortal: WKFilePortalServing {
    struct Entry { let name: String; let size: Int; let hash: String; let url: URL }
    let root: URL
    var offers: [String: Entry] = [:]
    var fulfilled: [String: Data] = [:]
    var streamFulfilled: [String: WKReceivedFile] = [:]
    var failed = Set<String>()
    var retired = Set<String>()
    var fulfillCalls = 0
    var started = false
    var startError: Error?
    var isAvailable: Bool { started }
    var diagnosticCounts: [UInt32]?
#if WK_TREE
    var trees: [String: WKTreeManifest] = [:]
    var onTree: (() -> Void)?
    func offerTree(_ offer: WKStreamOffer, manifest: WKTreeManifest) throws -> [URL] {
        _ = try self.offer(id: offer.id, name: offer.name, size: Int(offer.size), sha256: offer.manifestSHA256!)
        trees[offer.id] = manifest; onTree?()
        return manifest.roots.map { root.appendingPathComponent(offer.id).appendingPathComponent($0.path, isDirectory: $0.directory) }
    }
#endif
    init(root: URL) { self.root = root }
    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        if let startError { started = false; completion(.failure(startError)) }
        else { started = true; completion(.success(())) }
    }
    func stop() { started = false }
    func offer(id: String, name: String, size: Int, sha256: String) throws -> URL {
        guard started, offers[id] == nil else { throw WKPipelineTestFailure(description: "mock portal duplicate/unavailable") }
        let url = root.appendingPathComponent(id, isDirectory: true).appendingPathComponent(name)
        offers[id] = Entry(name: name, size: size, hash: sha256, url: url)
        return url
    }
    func fulfill(id: String, data: Data) throws {
        fulfillCalls += 1
        guard let entry = offers[id], !failed.contains(id), data.count == entry.size,
              WKMessage.digest(data) == entry.hash else { throw WKPipelineTestFailure(description: "mock portal integrity") }
        fulfilled[id] = data
    }
    func offerStream(_ offer: WKStreamOffer) throws -> URL {
        try self.offer(id: offer.id, name: offer.name, size: Int(offer.size), sha256: String(repeating: "0", count: 64))
    }
    func fulfill(id: String, file: WKReceivedFile) throws {
        guard let entry = offers[id], !failed.contains(id), file.size == UInt64(entry.size) else { throw WKPipelineTestFailure(description: "stream portal mismatch") }
        streamFulfilled[id] = file
    }
#if WK_TREE
    // Model a user's completed Finder copy only inside this fixture directory.
    // The production portal remains a read-only source, not a write destination.
    func materializeTrees() throws {
        for (id, file) in streamFulfilled {
            guard let manifest = trees[id] else { continue }
            let directory = root.appendingPathComponent(id, isDirectory:true)
            for entry in manifest.entries {
                let url = directory.appendingPathComponent(entry.path, isDirectory:entry.directory)
                try wkPipelineExpect(url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/"), "fixture path escaped")
                if entry.directory { try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);continue }
                try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
                var body=Data(), offset:UInt64=0
                while offset < entry.size {
                    let bytes=try file.read(offset:entry.offset+offset,maximum:Int(min(65_536,entry.size-offset)))
                    body.append(bytes);offset += UInt64(bytes.count)
                }
                try body.write(to:url,options:.withoutOverwriting)
            }
        }
    }
#endif
    func fail(id: String) { if fulfilled[id] == nil { failed.insert(id) } }
    func retire(id: String) { retired.insert(id) }
}

private final class WKTestClock { var now: Double = 100 }

private final class WKPipelineCountedIO: WKStreamIO {
    let base: WKStreamIO
    private let lock=NSLock()
    private var bytes: UInt64=0
    init(_ base: WKStreamIO) {self.base=base}
    var port: UInt8 {base.port}
    var writeDescriptor: Int32? {base.writeDescriptor}
    var written: UInt64 {lock.lock();defer{lock.unlock()};return bytes}
    func forwardControl(_ data:Data)->Bool {base.forwardControl(data)}
    func read(maximum:Int)throws->Data {try base.read(maximum:maximum)}
    func close() {base.close()}
    func write(_ data:Data)throws->Int {
        let count=try base.write(data);lock.lock();bytes += UInt64(count);lock.unlock();return count
    }
    func write(_ data:Data,offset:Int)throws->Int {
        let count=try base.write(data,offset:offset);lock.lock();bytes += UInt64(count);lock.unlock();return count
    }
}

private final class WKPipelineFixture {
    let time = WKTestClock()
    var dataReports = 0
    var wireMessageKinds = Set<String>()
    private var wirePackets: [String: [UInt32: Data]] = [:]
    var usbRateReports = [0,0]
    var portalRateReports = [0,0]
    let root: URL
    let aBoard: NSPasteboard
    let bBoard: NSPasteboard
    let at = WKPipelineMemoryTransport()
    let bt = WKPipelineMemoryTransport()
    let aPortal: WKPipelineMockPortal
    let bPortal: WKPipelineMockPortal
    let a: WKCompanion
    let b: WKCompanion
    var replies: [String] = []
    var logs: [String] = []
    var holdBulk = false
    var held: [(Bool, Data)] = []
    var dropReport: ((Bool, Data) -> Bool)?
    var initialMiniMetadata: [Data] = []
    var holdTargetReadiness = false
    var heldReadiness: [(message: WKMessage, packets: [Data])] = []
    private var readinessPackets: [UInt32: [UInt32: Data]] = [:]
    var readinessCaptureFailed = false
    private let streams: (WKStreamFiles, WKStreamFiles)?
    private var inputSequence: UInt64 = 0
    private var focusEpoch: UInt64 = 1
    private var pasteSequence: UInt64 = 0
    private var pasteCommands: [String: String] = [:]
    

    init(legacyTarget: Bool = false, denyPortal: Bool = false, streams: (WKStreamFiles, WKStreamFiles)? = nil,
         usbRates: (WKUSBDiscovery.Rate, WKUSBDiscovery.Rate)? = nil,
         holdInitialMiniMetadata: Bool = false) throws {
        self.streams = streams
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wk-private-file-pipeline-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        aBoard = NSPasteboard.withUniqueName(); bBoard = NSPasteboard.withUniqueName()
        aBoard.clearContents(); bBoard.clearContents()
        guard aBoard.setString("fixture A initial", forType: .string), bBoard.setString("fixture B initial", forType: .string) else {
            throw WKPipelineTestFailure(description: "private pasteboard service unavailable")
        }
        aPortal = WKPipelineMockPortal(root: root.appendingPathComponent("a-portal"))
        bPortal = WKPipelineMockPortal(root: root.appendingPathComponent("b-portal"))
        if denyPortal {
            aPortal.startError = WKFilePortalError.accessDenied
            bPortal.startError = WKFilePortalError.accessDenied
        }
        a = WKCompanion(role: "host", clipboard: WKClipboard(board: aBoard, receiveRoot: root.appendingPathComponent("a-received")),
                        transport: at, portal: aPortal, stream: streams?.0, clock: { [time] in time.now })
        b = WKCompanion(role: "target", clipboard: WKClipboard(board: bBoard, receiveRoot: root.appendingPathComponent("b-received")),
                        transport: bt, portal: legacyTarget ? nil : bPortal, stream: legacyTarget ? nil : streams?.1, clock: { [time] in time.now })
        a.reply = { [weak self] in self?.replies.append($0) }
        a.log = { [weak self] in self?.logs.append($0) }
        b.log = { [weak self] in self?.logs.append($0) }; b.reply = { _ in }
        if let usbRates {
            a.usbLinkRateProvider = { usbRates.0 }; b.usbLinkRateProvider = { usbRates.1 }
        }
        if holdInitialMiniMetadata {
            dropReport = { [weak self] fromA,bytes in
                guard !fromA,let report=WKReport(bytes,wireMagic:WKCompanion.magic),report.kind == .pong,
                      report.flags==0x42,report.payload.prefix(4)==Data("WKCV".utf8) else{return false}
                self?.initialMiniMetadata.append(bytes);return true
            }
        }
        // Do not start either companion: start() touches host stdin/signal handlers.
        // These explicit injected operations exercise only the isolated objects.
        a.startPortal(); b.startPortal()
        streams?.0.start(); streams?.1.start()
        at.onConnection(true); bt.onConnection(true)
        drive(20)
        try wkPipelineExpect(a.link.ready && b.link.ready, "pipeline primary handshake")
        if legacyTarget || denyPortal { try wkPipelineExpect(!a.bulkLink.ready && !b.bulkLink.ready, "unavailable portal advertised bulk") }
        else { try wkPipelineExpect(a.bulkLink.ready && b.bulkLink.ready, "pipeline bulk handshake") }
    }

    deinit {
        streams?.0.stop(); streams?.1.stop()
        aBoard.releaseGlobally(); bBoard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    func drive(_ count: Int) {
        for _ in 0..<count {
            if streams != nil { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001)) }
            time.now += 0.01
            a.tick(time.now); b.tick(time.now)
            for _ in 0..<8 {
                let aReports = at.reports; at.reports.removeAll()
                let bReports = bt.reports; bt.reports.removeAll()
                if aReports.isEmpty && bReports.isEmpty { break }
                for bytes in aReports { deliver(true, bytes) }
                for bytes in bReports { deliver(false, bytes) }
            }
        }
    }

    private func deliver(_ fromA: Bool, _ bytes: Data) {
        if WKReport(bytes, wireMagic: WKCompanion.magic)?.kind == .data { dataReports += 1 }
        for magic in [WKCompanion.magic,WKCompanion.fileMagic] {
            guard let report=WKReport(bytes,wireMagic:magic),report.kind == .data else{continue}
            let key="\(fromA)-\(String(decoding:magic,as:UTF8.self))-\(report.transfer)"
            wirePackets[key,default:[:]][report.sequence]=report.payload
            if report.flags & 2 != 0,let packets=wirePackets.removeValue(forKey:key) {
                let body=packets.keys.sorted().reduce(into:Data()){$0.append(packets[$1]!)}
                if let message=try? WKMessage.decode(body) {wireMessageKinds.insert(message.kind)}
            }
        }
        if let report = WKReport(bytes, wireMagic: WKCompanion.magic), report.kind == .pong, report.flags == 0x40 {
            usbRateReports[fromA ? 0 : 1] += 1
        }
        if let report = WKReport(bytes, wireMagic: WKCompanion.magic), report.kind == .pong, report.flags == 0x41 {
            portalRateReports[fromA ? 0 : 1] += 1
        }
        if dropReport?(fromA, bytes) == true { return }
        if holdTargetReadiness,!fromA,let report=WKReport(bytes,wireMagic:WKCompanion.magic),report.kind == .data {
            // An application-delivery queue: acknowledge complete transport
            // packets so both validated ready messages can be queued, then
            // exercise the real Book application callback in either order.
            // This does not claim that old wire transfer IDs may be replayed.
            readinessPackets[report.transfer,default:[:]][report.sequence]=bytes
            bt.onReport(WKReport(kind:.ack,session:report.session,sequence:report.sequence,
                                transfer:report.transfer).encode(wireMagic:WKCompanion.magic))
            if report.flags & 2 != 0,let packets=readinessPackets.removeValue(forKey:report.transfer) {
                let ordered=packets.keys.sorted().compactMap{packets[$0]}
                let body=ordered.reduce(into:Data()){$0.append(WKReport($1,wireMagic:WKCompanion.magic)!.payload)}
                if let message=try? WKMessage.decode(body) {
                    if message.kind=="stream-ready" {heldReadiness.append((message,ordered))}
                    else {for packet in ordered{at.onReport(packet)}}
                } else {readinessCaptureFailed=true}
            }
            return
        }
        if holdBulk, WKReport(bytes, wireMagic: WKCompanion.fileMagic)?.kind == .data {
            held.append((fromA, bytes)); return
        }
        // Exercise the coordinator's actual magic-based transport dispatch.
        (fromA ? bt : at).onReport(bytes)
    }

    func resumeBulk() {
        holdBulk = false
        let reports = held; held.removeAll()
        for (fromA, bytes) in reports { deliver(fromA, bytes) }
        drive(300)
    }
    @discardableResult func releaseTargetReadiness(reversed: Bool = false) -> [Bool] {
        holdTargetReadiness=false
        let messages=reversed ? Array(heldReadiness.reversed()):heldReadiness
        heldReadiness.removeAll()
        return deliverApplicationReadiness(messages.map(\.message))
    }
    func deliverApplicationReadiness(_ messages: [WKMessage]) -> [Bool] {
        // Readiness is already assembled and checksum-validated from the
        // target's real control traffic. Reorder application delivery only;
        // WKLink's independent wire/session replay protection stays enabled.
        messages.map { message in
            guard message.kind=="stream-ready",let data=try? message.encoded() else {
                readinessCaptureFailed=true;return false
            }
            return a.link.receiveMessage(data)
        }
    }

    func source(_ direction: String) -> String {
        guard let line = replies.last(where: { $0.hasPrefix("WKCLIP_ROUTE ") }) else { return "0" }
        let fields = line.dropFirst("WKCLIP_ROUTE ".count).split(separator: ",")
        guard fields.count == 9 else { return "0" }
        return String(fields[direction == "OUT" ? 3 : 4])
    }
    func selectedSide() -> String {
        guard let line=replies.last(where:{$0.hasPrefix("WKCLIP_ROUTE ")}) else{return "2"}
        let fields=line.dropFirst("WKCLIP_ROUTE ".count).split(separator:",")
        return fields.count==9 ? String(fields[2]):"2"
    }
    func ready(_ token: String) -> Bool { readyCount(token) > 0 }
    func readyCount(_ token: String) -> Int {
        replies.filter { $0.hasPrefix("WKCLIP_RESULT " + token + " ready ") }.count
    }
    func blocked(_ token: String) -> Bool {
        replies.contains("WKCLIP_RESULT " + token + " blocked") ||
            replies.contains("WKCLIP_RESULT " + token + " cancelled")
    }
    func context(side: Int) {
        inputSequence += 1; focusEpoch += 1
        a.command("CONTEXT \(inputSequence) \(side) \(focusEpoch)")
    }
    func select(_ direction: String, cut: Bool = false) {
        let sourceSide = direction == "OUT" ? 0 : 1
        context(side:sourceSide)
        inputSequence += 1
        a.command("SELECT \(inputSequence) \(sourceSide) \(cut ? "cut" : "copy") \(source(direction)) \(focusEpoch)")
    }
    @discardableResult func paste(_ direction: String, id: String = "9001") -> String {
        let sourceSide = direction == "OUT" ? 0 : 1, destinationSide = 1 - sourceSide
        select(direction)
        context(side:destinationSide)
        return pasteCurrent(destinationSide:destinationSide,id:id)
    }
    @discardableResult func pasteCurrent(destinationSide: Int, id: String = "9001") -> String {
        pasteSequence = max(pasteSequence + 1, UInt64(id) ?? 1)
        let token = String(pasteSequence)
        let revision = destinationSide == 0 ? aBoard.changeCount : 0
        let command = "PASTE \(token) \(destinationSide) \(inputSequence) \(revision) \(focusEpoch)"
        pasteCommands[token] = command; a.command(command)
        return token
    }
    func repeatPaste(_ token: String) {
        guard let command = pasteCommands[token] else { preconditionFailure("missing paste fixture") }
        a.command(command)
    }
    func publishText(_ direction: String, _ value: String) {
        let board = direction == "OUT" ? aBoard : bBoard
        board.clearContents(); board.setString(value, forType: .string); drive(25)
    }
    func publishFile(direction: String, nonce: String, body: Data, arm: Bool = true) throws {
        let file = root.appendingPathComponent("fixture-\(nonce).bin")
        try body.write(to: file, options: .withoutOverwriting)
        let board = direction == "OUT" ? aBoard : bBoard
        board.clearContents()
        try wkPipelineExpect(board.writeObjects([file as NSURL]), "private file URL publication")
        drive(30)
    }
}

enum WKFilePipelineSelfTest {
#if WK_TREE
    static func collectionSuite(make: () -> (WKStreamIO, WKStreamIO, (Bool) -> Void)) throws {
        try mixedBundleRoundtrip(make:make)
        for direction in ["OUT", "IN"] {
            let (ioA,ioB,stall)=make(), f=try WKPipelineFixture(streams:(WKStreamFiles { ioA },WKStreamFiles { ioB }))
            let source=direction == "OUT" ? f.aBoard : f.bBoard, board=direction == "OUT" ? f.bBoard : f.aBoard
            let portal=direction == "OUT" ? f.bPortal : f.aPortal
            let folder=f.root.appendingPathComponent("照片 & 文件"), empty=folder.appendingPathComponent("空目录")
            try FileManager.default.createDirectory(at:empty,withIntermediateDirectories:true)
            let file=try CH32StreamTest.source(folder,"binary.bin",32*1024*1024+7,0x41), extra=f.root.appendingPathComponent("second.txt")
            try Data("second selection".utf8).write(to:extra,options:.withoutOverwriting)
            source.clearContents(); try wkPipelineExpect(source.writeObjects([folder as NSURL,extra as NSURL]),"collection publication")
            f.drive(40); let revision=source.changeCount, reports=f.dataReports
            try wkPipelineExpect(portal.offers.isEmpty,"local copy started collection transmission")
            // Pause body delivery when verified metadata reaches the destination.
            portal.onTree={stall(true)}
            let token=f.paste(direction,id:"9601")
            for _ in 0..<50 {f.drive(40);if f.ready(token){break}}
            if !f.ready(token){print(f.logs.suffix(30).joined(separator:"\n"));print(f.replies.suffix(12))}
            try wkPipelineExpect(f.ready(token),"collection did not enable native paste")
            try wkPipelineExpect(portal.trees.count==1 && portal.streamFulfilled.isEmpty,"collection waited for full body")
            let urls=(board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true])as?[URL]) ?? []
            try wkPipelineExpect(Set(urls.map(\.lastPathComponent))==Set([folder.lastPathComponent,extra.lastPathComponent]),"multiple clipboard roots lost")
            try wkPipelineExpect(source.changeCount==revision,"source local clipboard changed")
            board.clearContents();board.setString("new destination copy",forType:.string);f.drive(30)
            portal.onTree=nil;stall(false)
            for _ in 0..<100 {f.drive(60);if !portal.streamFulfilled.isEmpty{break}}
            guard let (id,received)=portal.streamFulfilled.first,let manifest=portal.trees[id]else{throw WKPipelineTestFailure(description:"collection body did not finish")}
            for entry in manifest.entries where !entry.directory {
                let original=entry.path.hasSuffix("binary.bin") ? file : extra
                try wkPipelineExpect(WKCollectionTransferSelfTest.digest(received,entry)==CH32StreamTest.digest(original),"collection pipeline integrity")
            }
            try wkPipelineExpect(board.string(forType:.string)=="new destination copy","late collection overwrote local copy")
            try wkPipelineExpect(f.dataReports-reports<180,"collection body leaked into HID metadata")
            // Cancellation before the manifest arrives preserves local contents.
            source.clearContents();source.writeObjects([folder as NSURL,extra as NSURL]);f.drive(30);stall(true)
            let old=f.paste(direction,id:"9602");f.drive(50);f.a.command("CANCEL "+old)
            f.publishText(direction,"new paste wins");stall(false)
            let next=f.paste(direction,id:"9603");f.drive(200)
            try wkPipelineExpect(f.ready(next) && board.string(forType:.string)=="new paste wins","cancelled collection blocked new paste")
            try wkPipelineExpect(!f.ready(old),"cancelled collection committed")
            // Empty folders can finish before the ready-message round trip.
            source.clearContents();source.writeObjects([empty as NSURL]);f.drive(30)
            let last=f.paste(direction,id:"9604")
            for _ in 0..<30{f.drive(30);if f.ready(last){break}}
            try wkPipelineExpect(f.ready(last),"empty directory ready race")
        }
        wkLog("WKCLIP_TEST collection-bidirectional-multiple-roots-early-paste-local-copy-cancel-empty PASS")
    }
    private static func mixedBundleRoundtrip(make: () -> (WKStreamIO, WKStreamIO, (Bool) -> Void)) throws {
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:16,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
            bytesPerRow:64,bitsPerPixel:32),let pixels=bitmap.bitmapData else {throw WKPipelineTestFailure(description:"mixed image fixture")}
        memset(pixels,173,bitmap.bytesPerRow*bitmap.pixelsHigh)
        let png=bitmap.representation(using:.png,properties:[:])!,text="mixed standard clipboard",
            html=Data("<b>mixed standard clipboard</b>".utf8),rtf=Data("{\\rtf1\\ansi mixed standard clipboard}".utf8)
        for reverse in [false,true] {
            let(ioA,ioB,_)=make(),f=try WKPipelineFixture(streams:(WKStreamFiles{ioA},WKStreamFiles{ioB}))
            let folder=f.root.appendingPathComponent("mixed-folder",isDirectory:true)
            try FileManager.default.createDirectory(at:folder.appendingPathComponent("empty",isDirectory:true),withIntermediateDirectories:true)
            let body=Data((0..<8192).map{UInt8(truncatingIfNeeded:$0 &* 17 &+ 3)})
            try body.write(to:folder.appendingPathComponent("data.bin"),options:.withoutOverwriting)
            func publish() throws {
                let file=NSPasteboardItem(),standard=NSPasteboardItem()
                try wkPipelineExpect(file.setString(folder.absoluteString,forType:.fileURL) && file.setString("folder caption",forType:.string) &&
                    standard.setString(text,forType:.string) && standard.setData(html,forType:.html) &&
                    standard.setData(rtf,forType:.rtf) && standard.setData(png,forType:.png),"mixed fixture representation")
                f.aBoard.clearContents();try wkPipelineExpect(f.aBoard.writeObjects([file,standard]),"mixed fixture publication");f.drive(25)
            }
            func verify(_ board:NSPasteboard,_ portal:WKPipelineMockPortal) throws {
                guard let items=board.pasteboardItems,items.count==2,let path=items[0].string(forType:.fileURL),let url=URL(string:path) else {
                    throw WKPipelineTestFailure(description:"mixed bundle item order or file URL lost")
                }
                try wkPipelineExpect(items[0].string(forType:.string)=="folder caption" && items[1].string(forType:.string)==text &&
                    items[1].data(forType:.html)==html && items[1].data(forType:.rtf)==rtf && items[1].data(forType:.png)==png &&
                    items[1].data(forType:.tiff) != nil,"mixed bundle standard representations lost")
                try portal.materializeTrees()
                try wkPipelineExpect(try Data(contentsOf:url.appendingPathComponent("data.bin"))==body &&
                    FileManager.default.fileExists(atPath:url.appendingPathComponent("empty").path),"mixed bundle file tree/hash missing")
            }
            try publish();f.holdTargetReadiness=true
            let outgoing=f.paste("OUT",id:"9901")
            for _ in 0..<80 {f.drive(25);if f.heldReadiness.count>=2{break}}
            try wkPipelineExpect(!f.readinessCaptureFailed && f.heldReadiness.count==2 &&
                f.heldReadiness.allSatisfy{$0.message.nonce==outgoing} && !f.ready(outgoing),"mixed transfer did not wait for both distinct ready messages")
            let saved=f.heldReadiness
            let accepted=f.releaseTargetReadiness(reversed:reverse)
            try wkPipelineExpect(accepted==[true,true],"same-turn/reversed application ready delivery rejected a current transaction")
            for _ in 0..<80 {f.drive(25);if f.ready(outgoing) && f.bPortal.streamFulfilled.count==1{break}}
            try wkPipelineExpect(f.readyCount(outgoing)==1,"same-turn/reversed mixed readiness did not commit once")
            try verify(f.bBoard,f.bPortal)
            // Force an actual return transfer, rather than same-origin native V.
            f.publishText("OUT","new Book destination before mixed return")
            let incoming=f.paste("IN",id:"9902")
            for _ in 0..<80 {f.drive(25);if f.ready(incoming) && f.aPortal.streamFulfilled.count==1{break}}
            try wkPipelineExpect(f.readyCount(incoming)==1,"mixed bundle return did not finish once")
            try verify(f.aBoard,f.aPortal)
            // Replaying old ready callbacks after a cancelled prepared bundle
            // must not overwrite a newer plain-text paste or revive its lease.
            try publish();f.holdTargetReadiness=true
            let obsolete=f.paste("OUT",id:"9903")
            for _ in 0..<80 {f.drive(25);if f.heldReadiness.count>=2{break}}
            try wkPipelineExpect(f.heldReadiness.count==2 && !f.ready(obsolete),"cancel fixture never reached prepared bundle")
            f.a.command("CANCEL "+obsolete);f.drive(10)
            f.publishText("OUT","new text outranks cancelled mixed bundle")
            let fresh=f.paste("OUT",id:"9904")
            for _ in 0..<50 {f.drive(10);if f.ready(fresh){break}}
            try wkPipelineExpect(f.ready(fresh),"cancelled prepared bundle blocked fresh text")
            let rejected=f.releaseTargetReadiness(reversed:true)
            let replayed=f.deliverApplicationReadiness(saved.map(\.message))
            try wkPipelineExpect(rejected==[false,false] && replayed==[false,false],
                "application callback accepted obsolete or cancelled readiness")
            f.drive(100)
            try wkPipelineExpect(!f.ready(obsolete) && f.readyCount(fresh)==1 &&
                f.bBoard.string(forType:.string)=="new text outranks cancelled mixed bundle","late mixed readiness changed the new clipboard")
            wkLog("WKCLIP_TEST state-v2-mixed-file-text-html-rtf-PNG-roundtrip-application-ready-\(reverse ? "reverse":"same-turn")-cancel-late-callback PASS")
        }
    }
#endif
    // Injected USB stream endpoints exercise the real coordinator, private
    // pasteboards and background workers. No general pasteboard or mounts.
    private static func repeatedStreamPastes(make: () -> (WKStreamIO, WKStreamIO, (Bool) -> Void)) throws {
        for direction in ["OUT", "IN"] {
            let (ioA, ioB, stall) = make()
            let countedA=WKPipelineCountedIO(ioA),countedB=WKPipelineCountedIO(ioB)
            let f = try WKPipelineFixture(streams: (WKStreamFiles { countedA }, WKStreamFiles { countedB }))
            let target = direction == "OUT" ? f.bPortal : f.aPortal
            let sourceBoard = direction == "OUT" ? f.aBoard : f.bBoard
            let targetBoard = direction == "OUT" ? f.bBoard : f.aBoard
            let body = Data(repeating: 0x69, count: 2 * 1024 * 1024)
            try f.publishFile(direction: direction, nonce: "repeat", body: body)
            guard let sourceURL = sourceBoard.string(forType: .fileURL), let url = URL(string: sourceURL) else {
                throw WKPipelineTestFailure(description: "private source URL absent")
            }
            stall(true)
            let first = f.paste(direction, id: "8201"); f.drive(150)
            try wkPipelineExpect(f.ready(first) && target.offers.count == 1,
                                 "first file URL did not become ready before body")
            let firstIDs = Set(target.offers.keys)
            let firstURL=targetBoard.string(forType:.fileURL),firstBytes=countedA.written+countedB.written
            let second = f.paste(direction, id: "8202"); f.drive(150)
            try wkPipelineExpect(f.ready(second) && target.offers.count == 1 &&
                targetBoard.string(forType:.fileURL)==firstURL && countedA.written+countedB.written==firstBytes,
                                 "same-version second V must reuse the native URL without a new offer or Bulk body")
            sourceBoard.clearContents()
            try wkPipelineExpect(sourceBoard.writeObjects([url as NSURL]), "private same-file recopy")
            f.drive(30)
            let third = f.paste(direction, id: "8203"); f.drive(150)
            try wkPipelineExpect(f.ready(third) && target.offers.count == 2,
                                 "same-file recopy lost its independent URL")
            let latestURL = targetBoard.string(forType: .fileURL)
            try wkPipelineExpect(target.streamFulfilled.isEmpty && target.failed.isEmpty,
                                 "new paste failed a previously published URL")
            try wkPipelineExpect(firstIDs.isSubset(of: target.retired), "old published URL was not retired")
            stall(false)
            for _ in 0..<50 { if target.streamFulfilled.count == 2 { break }; f.drive(100) }
            try wkPipelineExpect(target.streamFulfilled.count == 2 && target.failed.isEmpty,
                                 "overlapping paste snapshots did not all finish")
            for file in target.streamFulfilled.values {
                try wkPipelineExpect(file.size == UInt64(body.count) && file.sha256 == WKMessage.digest(body),
                                     "overlapping file snapshot integrity")
            }
            try wkPipelineExpect(targetBoard.string(forType: .fileURL) == latestURL,
                                 "late file completion overwrote the latest paste")
            // Losing a file portal must not take down the independent text
            // protocol or either local clipboard after failed Finder work.
            target.started = false; f.drive(10)
            f.publishText(direction, "fresh text after files")
            let text = f.paste(direction, id: "8204"); f.drive(100)
            try wkPipelineExpect(f.ready(text) &&
                targetBoard.string(forType: .string) == "fresh text after files", "file portal failure blocked text")
        }
        wkLog("WKCLIP_TEST CH32-repeat-V-recopy-pending-file-snapshots-local-clipboard PASS")
    }

    static func streamSuite(make: () -> (WKStreamIO, WKStreamIO, (Bool) -> Void)) throws {
        try repeatedStreamPastes(make: make)
        do {
            let (ioA,ioB,_) = make(), streams = (WKStreamFiles { ioA }, WKStreamFiles { ioB })
            let f = try WKPipelineFixture(streams: streams, usbRates: (.high,.full))
            f.drive(400)
            try wkPipelineExpect(f.logs.contains("WKCLIP_DIAG role=host event=TRANSPORT phase=RESULT usbMbps=480"), "host negotiated speed missing")
            try wkPipelineExpect(f.logs.contains("WKCLIP_DIAG role=target event=TRANSPORT phase=RESULT usbMbps=12"), "target negotiated speed did not cross the cable")
            try wkPipelineExpect(f.usbRateReports == [3,3], "USB speed diagnostic was not bounded")
            let count = f.logs.count
            for (session,flags,sequence,payload) in [
                (f.b.link.session &+ 1,UInt8(0x40),UInt32(0),Data([0x57,0x4b,0x55,0x53,1,2])),
                (f.b.link.session,UInt8(0),UInt32(0),Data([0x57,0x4b,0x55,0x53,1,2])),
                (f.b.link.session,UInt8(0x40),UInt32(1),Data([0x57,0x4b,0x55,0x53,1,2])),
                (f.b.link.session,UInt8(0x40),UInt32(0),Data([0x57,0x4b,0x55,0x53,2,2])),
                (f.b.link.session,UInt8(0x40),UInt32(0),Data([0x57,0x4b,0x55,0x53,1,3]))] {
                f.at.onReport(WKReport(kind:.pong,flags:flags,session:session,sequence:sequence,payload:payload).encode(wireMagic:WKCompanion.magic))
            }
            try wkPipelineExpect(f.logs.count == count && f.a.link.ready && f.b.link.ready, "invalid USB diagnostic changed state or entered logs")
            try wkPipelineExpect(WKMetadata.line(role:"target",event:"TRANSPORT",fields:["usbMbps":"625"]) == nil,"arbitrary speed admitted")
            var ioFields=Dictionary(uniqueKeysWithValues:"steps elapsedUs gapMaxUs pendingMax inFlightMax readWaitSteps windowFullSteps readCalls readBytes readZero readMax writeCalls writeWanted writeBytes writeZero writePartial writeMax".split(separator:" ").map { (String($0),"1") })
            ioFields["phase"]="RESULT"
            try wkPipelineExpect(WKMetadata.line(role:"host",event:"STREAM_IO",fields:ioFields) != nil,"numeric IO profile rejected")
            for (key,value) in [("writeMax","/Users/private/file"),("writeMax","-1"),("writeMax","4294967296"),("payload","PRIVATE_CONTENT"),("phase","PRIVATE_CONTENT")] {
                var invalid=ioFields;invalid[key]=value
                try wkPipelineExpect(WKMetadata.line(role:"host",event:"STREAM_IO",fields:invalid) == nil,"invalid IO diagnostics admitted")
            }
            ioFields.removeValue(forKey:"steps")
            try wkPipelineExpect(WKMetadata.line(role:"host",event:"STREAM_IO",fields:ioFields) == nil,"incomplete IO diagnostic admitted")
            wkLog("WKCLIP_TEST bounded-peer-usb-negotiated-rate PASS")
            streams.1.onDiagnostic("stream-source-ctime-changed"); f.drive(100)
            try wkPipelineExpect(f.logs.contains("WKCLIP_DIAG role=target event=ERROR code=stream-source-ctime-changed"), "peer failure reason did not cross the control channel")
            for code in ["/Users/private/file.png", "stream-clipboard-content", String(repeating: "x", count: 100)] {
                do {
                    _ = try WKMessage(kind: "stream-diagnostic", nonce: "1", body: Data(code.utf8)).encoded()
                    throw WKPipelineTestFailure(description: "private or arbitrary diagnostic admitted")
                } catch is WKStreamError { }
            }
            wkLog("WKCLIP_TEST bounded-peer-stream-diagnostic PASS")
        }
        do {
            let (ioA,ioB,_) = make()
            let f = try WKPipelineFixture(streams: (WKStreamFiles { ioA }, WKStreamFiles { ioB }))
            f.bPortal.diagnosticCounts = [3,2,1,1,0,0,0,0]; f.drive(110)
            try wkPipelineExpect(f.logs.contains(where: { $0.contains("role=target event=PORTAL") && $0.contains("davMissing=2") }), "target portal counters missing")
            let before = f.logs.filter { $0.contains("event=PORTAL") }.count
            var valid = Data([0x57,0x4b,0x50,0x53,1]); (0..<8).forEach { valid.appendLE(UInt32($0)) }
            for report in [
                WKReport(kind: .pong, flags: 0x41, session: f.b.link.session &+ 1, payload: valid),
                WKReport(kind: .pong, flags: 0x40, session: f.b.link.session, payload: valid),
                WKReport(kind: .pong, flags: 0x41, session: f.b.link.session, sequence: 1, payload: valid),
                WKReport(kind: .pong, flags: 0x41, session: f.b.link.session, transfer: 1, payload: valid),
                WKReport(kind: .pong, flags: 0x41, session: f.b.link.session, payload: valid.dropLast()),
                WKReport(kind: .pong, flags: 0x41, session: f.b.link.session, payload: Data([0x57,0x4b,0x50,0x53,2]) + valid.dropFirst(5))
            ] { f.at.onReport(report.encode(wireMagic: WKCompanion.magic)) }
            try wkPipelineExpect(f.logs.filter { $0.contains("event=PORTAL") }.count == before, "malformed portal diagnostic admitted")
            for n in 0..<70 { f.bPortal.diagnosticCounts = [UInt32(n),0,0,0,0,0,0,0]; f.drive(110) }
            try wkPipelineExpect(f.portalRateReports == [0,64], "portal report limit not enforced")
            f.publishText("OUT", "text with exhausted diagnostics")
            let token = f.paste("OUT", id: "8205"); f.drive(100)
            try wkPipelineExpect(f.ready(token) &&
                f.bBoard.string(forType: .string) == "text with exhausted diagnostics", "diagnostics blocked text")
            try wkPipelineExpect(WKMetadata.line(role: "target", event: "PORTAL", fields: ["davMissing":"/private/file"]) == nil &&
                WKMetadata.line(role: "target", event: "PORTAL", fields: ["davMissing":"4294967296"]) == nil, "unsafe portal log field admitted")
            wkLog("WKCLIP_TEST bounded-peer-portal-counters-malformed-limit-text PASS")
        }
        for direction in ["OUT", "IN"] {
            let (ioA, ioB, stall) = make()
            let streams = (WKStreamFiles { ioA }, WKStreamFiles { ioB })
            let f = try WKPipelineFixture(streams: streams)
            f.publishText("OUT", "local Book"); f.publishText("IN", "local mini")
            try wkPipelineExpect(f.aBoard.string(forType: .string) == "local Book" && f.bBoard.string(forType: .string) == "local mini", "CH32 local copy isolation")
            f.publishText(direction, "CH32 wired text " + direction)
            let textToken = f.paste(direction, id: "8001"); f.drive(100)
            try wkPipelineExpect(f.ready(textToken), "CH32 text paste")
            let body = Data((0..<2_097_153).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 23) })
            try f.publishFile(direction: direction, nonce: "8002", body: body)
            let target = direction == "OUT" ? f.bPortal : f.aPortal
            let board = direction == "OUT" ? f.bBoard : f.aBoard
            try wkPipelineExpect(target.offers.isEmpty, "CH32 copy sent file contents before cross paste")
            stall(true)
            let token = f.paste(direction, id: "8003"); f.drive(300)
            try wkPipelineExpect(f.ready(token), "CH32 early native paste blocked")
            try wkPipelineExpect(target.offers.count == 1 && target.streamFulfilled.isEmpty, "CH32 file bytes required before native progress")
            board.clearContents(); board.setString("fresh destination local copy", forType: .string); f.drive(30)
            stall(false)
            for _ in 0..<30 { if !target.streamFulfilled.isEmpty { break }; f.drive(100) }
            try wkPipelineExpect(target.streamFulfilled.count == 1, "CH32 streamed file did not complete")
            let received = target.streamFulfilled.values.first!
            try wkPipelineExpect(received.sha256 == WKMessage.digest(body), "CH32 pipeline file hash")
            try wkPipelineExpect(board.string(forType: .string) == "fresh destination local copy", "CH32 late file completion replaced local clipboard")
            // Destination copy between keypress and metadata must cancel paste.
            f.publishText(direction, "stale remote contents")
            let cancelled = f.paste(direction, id: "8004")
            board.clearContents(); board.setString("local wins race", forType: .string); f.drive(150)
            try wkPipelineExpect(board.string(forType: .string) == "local wins race" && !f.ready(cancelled), "CH32 stale commit race")
        }
        wkLog("WKCLIP_TEST CH32-bidirectional-text-file-early-paste-local-copy-wins PASS")
    }
    static func bulkImageBounds() throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:32,pixelsHigh:32,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
            bytesPerRow:128,bitsPerPixel:32), let pixels = bitmap.bitmapData else { throw WKPipelineTestFailure(description:"boundary bitmap") }
        memset(pixels,127,bitmap.bytesPerRow*bitmap.pixelsHigh)
        let original = bitmap.representation(using:.png,properties:[:])!
        // A legal unknown ancillary PNG chunk provides exact-size boundary
        // fixtures. These are NOT performance samples or substitute for entropy.
        func padded(_ size: Int) -> Data {
            var payload = Data("wkVM".utf8); payload.append(Data(repeating:0x61,count:size-original.count-12))
            var d = Data(original.dropLast(12)); var length = UInt32(payload.count-4).bigEndian
            withUnsafeBytes(of:&length) { d.append(contentsOf:$0) }; d.append(payload)
            var crc = WKBulkControl.crc(payload).bigEndian; withUnsafeBytes(of:&crc) { d.append(contentsOf:$0) }
            d.append(original.suffix(12)); return d
        }
        for n in [1_048_576,1_048_577,8*1024*1024,32*1024*1024,64*1024*1024] {
            let image = padded(n), ready = try WKBulkImage.prepare(image)
            try wkPipelineExpect(ready.png == image && ready.tiff.count > 0,"image boundary \(n)")
            try WKStreamOffer(id:UUID().uuidString.lowercased(),name:"image.png",nonce:"1",size:UInt64(n),kind:"png").validate()
        }
        do { _ = try WKBulkImage.prepare(padded(64*1024*1024+1)); throw WKPipelineTestFailure(description:"64MiB+1 admitted") } catch is WKStreamError { }
        do { try WKStreamOffer(id:UUID().uuidString.lowercased(),name:"image.png",nonce:"1",size:64*1024*1024+1,kind:"png").validate(); throw WKPipelineTestFailure(description:"oversize offer admitted") } catch is WKStreamError { }
        do { _ = try WKBulkImage.prepare(Data([137,80,78,71,13,10,26,10])); throw WKPipelineTestFailure(description:"corrupt PNG admitted") } catch is WKClipboardError { }
        wkLog("WKCLIP_TEST CH32-image-boundaries-1MiB-8MiB-32MiB-64MiB-oversize-corrupt PASS boundary-fixtures-not-speed-evidence")
    }
    static func bulkImageSuite(make: () -> (WKStreamIO, WKStreamIO, (Bool) -> Void)) throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:768,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
            bytesPerRow:4096,bitsPerPixel:32), let pixels = bitmap.bitmapData else { throw WKPipelineTestFailure(description:"image fixture") }
        var random: UInt32 = 19
        for i in 0..<bitmap.bytesPerRow*bitmap.pixelsHigh { random ^= random << 13; random ^= random >> 17; random ^= random << 5; pixels[i] = UInt8(truncatingIfNeeded:random) }
        let png = bitmap.representation(using:.png,properties:[:])!
        let tiff = bitmap.representation(using:.tiff,properties:[.compressionMethod:NSNumber(value:NSBitmapImageRep.TIFFCompression.none.rawValue)])!
        try wkPipelineExpect(png.count > 1_048_576, "real high-entropy image must exceed old 1 MiB limit")
        for direction in ["OUT","IN"] {
            let (ioA,ioB,stall) = make(); let f = try WKPipelineFixture(streams:(WKStreamFiles { ioA },WKStreamFiles { ioB }))
            let source = direction == "OUT" ? f.aBoard : f.bBoard, target = direction == "OUT" ? f.bBoard : f.aBoard
            func publish(_ data: Data, _ type: NSPasteboard.PasteboardType) {
                source.clearContents(); source.setData(data,forType:type); f.drive(25)
            }
            publish(png,.png)
            let before = f.dataReports, originalRevision = source.changeCount
            f.drive(40); try wkPipelineExpect(f.dataReports == before,"image body left on local copy")
            let token = f.paste(direction,id:"8501")
            f.repeatPaste(token) // identical V must not restart
            for _ in 0..<100 { f.drive(50); if f.ready(token) { break } }
            if !f.ready(token) { print(f.logs.suffix(40).joined(separator:"\n")); print(f.replies.suffix(12)) }
            try wkPipelineExpect(f.readyCount(token) == 1,"bulk image one V completion " + direction)
            try wkPipelineExpect(target.data(forType:.png) == png,"PNG bytes changed " + direction)
            try wkPipelineExpect(target.data(forType:.tiff) != nil,"TIFF representation absent")
            try wkPipelineExpect(source.changeCount == originalRevision,"image source clipboard overwritten")
            try wkPipelineExpect(f.dataReports-before < 150,"image body leaked into HID JSON/Base64")
            // Pause only body reads, then cancel and issue a new text paste at
            // once. No artificial two-sided cancellation and no queue draining.
            publish(png,.png); stall(true)
            let old = f.paste(direction,id:"8502"); f.drive(80)
            f.a.command("CANCEL " + old)
            f.publishText(direction,"new text bypassed old image")
            let fresh = f.paste(direction,id:"8503"); f.drive(80)
            try wkPipelineExpect(f.ready(fresh),"cancel/new text blocked by body stall")
            try wkPipelineExpect(!f.ready(old),"cancelled image committed")
            stall(false); f.drive(100)
            try wkPipelineExpect(target.string(forType:.string) == "new text bypassed old image","late old image replaced new content")
            // A local copy at the destination wins even during image transfer.
            publish(tiff,.tiff); stall(true)
            let race = f.paste(direction,id:"8504"); f.drive(80)
            target.clearContents(); target.setString("destination local wins",forType:.string); f.drive(25)
            stall(false); f.drive(100)
            try wkPipelineExpect(target.string(forType:.string) == "destination local wins" && !f.ready(race),"local image-copy race")
            // Fresh TIFF conversion still works after cancellation.
            publish(tiff,.tiff); let converted = f.paste(direction,id:"8505")
            for _ in 0..<100 { f.drive(50); if f.ready(converted) { break } }
            try wkPipelineExpect(f.ready(converted) && target.data(forType:.png) != nil,"TIFF bulk conversion failed")
            let oversized = Data(repeating:0,count:WKStreamOffer.maximumImage+1)
            publish(oversized,.png); let rejected = f.paste(direction,id:"8506")
            for _ in 0..<50 { f.drive(20); if f.blocked(rejected) { break } }
            try wkPipelineExpect(f.blocked(rejected),"oversize image did not fail promptly")
            try wkPipelineExpect(source.data(forType:.png) == oversized,"oversize source clipboard was changed")
            wkLog("WKCLIP_TEST CH32-Bulk-image-\(direction)-PNG-\(png.count)-TIFF-local-isolation-cancel-retry PASS")
        }
    }
    static func run() throws {
        try nativeIsolation()
        try unchangedSourceSelection()
        try reconnectExistingClipboard()
        try lateInitialMiniMetadata()
        try rawAdvertisementCannotReplacePinnedDestination()
        try repeatedOwnCommitMetadataBeforeAck()
        try cutSameOriginProtection()
        try menuDepartureBarrier()
        for direction in ["OUT", "IN"] {
            try textPaste(direction)
            try imagePaste(direction)
            try earlyFile(direction)
            try noPortalFile(direction)
            try destinationWins(direction)
        }
        try stagedCancellation()
        try staleDestination()
        try unsolicitedAndLegacy()
        try lostCommitAck()
        try disconnect()
        wkLog("WKCLIP_TEST on-demand-native-isolation-bidirectional-stage-commit-local-wins-file-integrity-legacy-rejection PASS")
    }
    private static func nativeIsolation() throws {
        let f = try WKPipelineFixture()
        try wkPipelineExpect(f.a.receivedCount == 0 && f.b.receivedCount == 0, "startup must not copy existing data")
        let baseline = f.dataReports
        f.publishText("OUT", "Book local copy")
        f.publishText("IN", "mini menu copy")
        f.drive(100)
        try wkPipelineExpect(f.dataReports == baseline, "copy emitted clipboard content before paste")
        try wkPipelineExpect(f.aBoard.string(forType: .string) == "Book local copy", "Book native clipboard overwritten")
        try wkPipelineExpect(f.bBoard.string(forType: .string) == "mini menu copy", "mini native clipboard overwritten")
        f.a.command("COPY IN 999")
        f.drive(10)
        try wkPipelineExpect(!f.replies.contains { $0.hasPrefix("WKCLIP_COPY") }, "remote copy depended on an arm or replay")
    }
    private static func textPaste(_ direction: String) throws {
        let f = try WKPipelineFixture()
        let text = "private on-demand " + direction + " 你好"
        f.publishText(direction, text)
        let token = f.paste(direction); f.drive(60)
        let destination = direction == "OUT" ? f.bBoard : f.aBoard
        try wkPipelineExpect(destination.string(forType: .string) == text, "text did not arrive: " + direction)
        try wkPipelineExpect(f.readyCount(token) == 1, "paste did not execute exactly once: " + direction)
        let count = f.dataReports; f.drive(60)
        try wkPipelineExpect(count == f.dataReports, "applied text echoed back")
        let all = f.logs.joined(); try wkPipelineExpect(!all.contains(text), "clipboard leaked to diagnostic log")
    }
    private static func unchangedSourceSelection() throws {
        let f = try WKPipelineFixture()
        let bookVersion = f.source("OUT"), miniVersion = f.source("IN")
        let bookRevision = f.aBoard.changeCount, miniRevision = f.bBoard.changeCount
        try wkPipelineExpect(bookVersion != "0" && miniVersion != "0", "initial clipboard versions unavailable")
        f.select("OUT"); f.select("IN"); f.select("OUT"); f.drive(20)
        try wkPipelineExpect(f.source("OUT") == bookVersion && f.source("IN") == miniVersion &&
            f.aBoard.changeCount == bookRevision && f.bBoard.changeCount == miniRevision,
            "A-B-A source selection changed OS content/version")
        let token = f.paste("OUT"); f.drive(100)
        try wkPipelineExpect(f.ready(token) && f.bBoard.string(forType:.string) == "fixture A initial",
            "unchanged initial clipboard failed after A-B-A selection")
        wkLog("WKCLIP_TEST state-v2-initial-A-B-A-unchanged-source PASS")
    }
    private static func reconnectExistingClipboard() throws {
        let f = try WKPipelineFixture()
        let before = f.bBoard.changeCount
        f.at.onConnection(false); f.bt.onConnection(false); f.drive(10)
        f.at.onConnection(true); f.bt.onConnection(true); f.drive(50)
        try wkPipelineExpect(f.a.link.ready && f.b.link.ready && f.source("IN") != "0", "reconnect did not refresh existing metadata")
        try wkPipelineExpect(f.bBoard.changeCount == before, "reconnect touched private source clipboard")
        let token = f.paste("IN"); f.drive(100)
        try wkPipelineExpect(f.ready(token) && f.aBoard.string(forType:.string) == "fixture B initial",
            "reconnect required a new OS clipboard revision")
        wkLog("WKCLIP_TEST state-v2-reconnect-existing-clipboard PASS")
    }
    private static func lateInitialMiniMetadata() throws {
        let f=try WKPipelineFixture(holdInitialMiniMetadata:true)
        try wkPipelineExpect(!f.initialMiniMetadata.isEmpty && f.source("IN")=="0", "initial mini snapshot delay not injected")
        f.select("OUT");f.context(side:1)
        let version=f.source("OUT")
        f.dropReport=nil
        for packet in f.initialMiniMetadata {f.at.onReport(packet)}
        f.drive(25)
        try wkPipelineExpect(f.source("IN") != "0" && f.selectedSide()=="0" && f.source("OUT")==version,
            "initial mini snapshot replaced the explicit Book source after screen entry")
        wkLog("WKCLIP_TEST state-v2-late-initial-mini-metadata-keeps-Book-selection PASS")
    }
    private static func repeatedOwnCommitMetadataBeforeAck() throws {
        let f=try WKPipelineFixture(), text="private ACK delay text"
        f.publishText("OUT",text)
        var acks:[Data]=[], snapshots:[Data]=[]
        f.dropReport={fromA,bytes in
            guard !fromA,f.bBoard.string(forType:.string)==text,
                  let report=WKReport(bytes,wireMagic:WKCompanion.magic) else{return false}
            if report.kind == .ack {acks.append(bytes);return true}
            if report.kind == .pong,report.flags==0x42,report.payload.prefix(4)==Data("WKCV".utf8) {
                snapshots.append(bytes)
            }
            return false
        }
        let token=f.paste("OUT",id:"9801")
        for _ in 0..<60 {f.drive(5);if snapshots.count>=2{break}}
        try wkPipelineExpect(!acks.isEmpty && snapshots.count>=2,"commit ACK/WKCV delay fixture did not reach both events")
        try wkPipelineExpect(!f.ready(token) && !f.blocked(token),"repeated own-commit metadata cancelled or prematurely completed the pending paste")
        let revision=f.bBoard.changeCount
        f.dropReport=nil;f.at.onReport(acks.last!);f.drive(60)
        for packet in snapshots {f.at.onReport(packet)}
        f.drive(20)
        try wkPipelineExpect(f.readyCount(token)==1 && f.bBoard.changeCount==revision &&
            f.bBoard.string(forType:.string)==text,"commit replay or duplicate metadata authorized more than one paste")
        wkLog("WKCLIP_TEST state-v2-own-commit-metadata-twice-before-ACK-ready-once PASS")
    }
    private static func rawAdvertisementCannotReplacePinnedDestination() throws {
        let f=try WKPipelineFixture()
        f.publishText("OUT","Book selected source with a pinned peer version")
        let pinned=f.source("IN")
        try wkPipelineExpect(pinned != "0","pinned destination fixture lacks a confirmed mini snapshot")
        var advertisements=0,withheldSnapshots=0
        f.dropReport={fromA,bytes in
            guard !fromA,let report=WKReport(bytes,wireMagic:WKCompanion.magic) else{return false}
            if report.kind == .pong,report.flags==0x42,report.payload.prefix(4)==Data("WKCV".utf8) {
                withheldSnapshots += 1;return true
            }
            if report.kind == .ping,report.payload.prefix(4)==Data("WKOD".utf8) {advertisements += 1}
            return false
        }
        let local="new mini local clipboard must not be overwritten"
        f.bBoard.clearContents();f.bBoard.setString(local,forType:.string)
        let destinationRevision=f.bBoard.changeCount
        f.drive(60)
        try wkPipelineExpect(advertisements>0 && withheldSnapshots>0 && f.source("IN")==pinned,
            "binding fixture failed to separate raw WKOD from the pinned WKCV snapshot")
        // No mini SELECT is generated: only the Book source and destination
        // context are selected. Target prepare must use the pinned model stamp,
        // not the newer, unconfirmed raw advertisement.
        let token=f.paste("OUT",id:"9851");f.drive(120)
        try wkPipelineExpect(f.blocked(token) && !f.ready(token) &&
            f.bBoard.changeCount==destinationRevision && f.bBoard.string(forType:.string)==local,
            "raw peer advertisement bypassed the pinned destination version")
        f.dropReport=nil
        wkLog("WKCLIP_TEST state-v2-WKOD-cannot-replace-pinned-WKCV-destination PASS")
    }
    private static func cutSameOriginProtection() throws {
        for direction in ["OUT","IN"] {
            let f=try WKPipelineFixture(),destinationSide=direction=="OUT" ? 1:0
            let source=direction=="OUT" ? f.aBoard:f.bBoard,destination=direction=="OUT" ? f.bBoard:f.aBoard
            let previous="same-origin content before Cut"
            f.publishText(direction,previous)
            let first=f.paste(direction);f.drive(100)
            try wkPipelineExpect(f.ready(first) && destination.string(forType:.string)==previous,"same-origin Cut fixture not committed")
            let revision=source.changeCount
            f.select(direction,cut:true);f.context(side:destinationSide)
            guard let line=f.replies.last(where:{$0.hasPrefix("WKCLIP_ROUTE ")}) else {throw WKPipelineTestFailure(description:"Cut projection missing")}
            let fields=line.dropFirst("WKCLIP_ROUTE ".count).split(separator:",").compactMap{UInt64($0)}
            try wkPipelineExpect(fields.count==9 && fields[7]==1 && fields[8] & (1 << destinationSide)==0,
                "unconfirmed Cut advertised same-origin native Paste on the other computer")
            let blocked=f.pasteCurrent(destinationSide:destinationSide);f.drive(110)
            try wkPipelineExpect(f.blocked(blocked) && !f.ready(blocked) && source.changeCount==revision &&
                destination.string(forType:.string)==previous,"unchanged Cut pasted the old clipboard")
            f.publishText(direction,"new native Cut revision")
            let confirmed=f.pasteCurrent(destinationSide:destinationSide);f.drive(100)
            try wkPipelineExpect(f.readyCount(confirmed)==1 && destination.string(forType:.string)=="new native Cut revision",
                "new OS revision did not unblock the existing Cut intent")
        }
        wkLog("WKCLIP_TEST state-v2-cut-same-origin-native-mask-guard-bidirectional PASS")
    }
    private static func menuDepartureBarrier() throws {
        for bookWins in [false,true] {
            let f=try WKPipelineFixture()
            f.publishText("OUT","Book source before menu")
            f.select("OUT");f.context(side:1);f.drive(25)
            // Menu Copy does not emit SELECT. Return before mini's next poll,
            // then wait for the explicit departure snapshot acknowledgement.
            f.bBoard.clearContents();f.bBoard.setString("mini menu selection",forType:.string)
            f.context(side:0)
            if bookWins {f.aBoard.clearContents();f.aBoard.setString("new Book menu selection",forType:.string)}
            f.drive(100)
            try wkPipelineExpect(!f.replies.contains{$0.hasPrefix("WKCLIP_RESULT ")},
                "metadata departure acknowledgement replayed a Paste without a user V")
            try wkPipelineExpect(f.selectedSide()==(bookWins ? "0":"1"),
                "menu departure snapshot ignored the newest eligible native source")
            let token=f.pasteCurrent(destinationSide:0);f.drive(120)
            try wkPipelineExpect(f.readyCount(token)==1 && f.aBoard.string(forType:.string) ==
                (bookWins ? "new Book menu selection":"mini menu selection"),
                "explicit V after the departure barrier selected the wrong clipboard")
        }
        wkLog("WKCLIP_TEST state-v2-menu-departure-barrier-native-Book-copy-wins-no-implicit-replay PASS")
    }
    private static func imagePaste(_ direction: String) throws {
        let f=try WKPipelineFixture(),source=direction=="OUT" ? f.aBoard:f.bBoard,
            destination=direction=="OUT" ? f.bBoard:f.aBoard
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:768,pixelsHigh:512,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
            bytesPerRow:768*4,bitsPerPixel:32),let pixels=bitmap.bitmapData else {
            throw WKPipelineTestFailure(description:"image pipeline fixture")
        }
        memset(pixels,127,bitmap.bytesPerRow*bitmap.pixelsHigh)
        let tiff=bitmap.representation(using:.tiff,properties:[.compressionMethod:NSNumber(value:NSBitmapImageRep.TIFFCompression.none.rawValue)])!
        try wkPipelineExpect(tiff.count>WKMessage.maximumContent,"TIFF fixture must exceed old wire limit")
        source.clearContents();source.setData(tiff,forType:.tiff);f.drive(25)
        let sourceRevision=source.changeCount,destinationRevision=destination.changeCount,before=f.dataReports
        f.drive(20);try wkPipelineExpect(f.dataReports==before,"image left during native local copy")
        let token=f.paste(direction);f.drive(200)
        try wkPipelineExpect(f.blocked(token) && !f.ready(token),"image without Bulk must fail closed")
        try wkPipelineExpect(source.changeCount==sourceRevision && source.data(forType:.tiff)==tiff &&
            destination.changeCount==destinationRevision && destination.string(forType:.string)==(direction=="OUT" ? "fixture B initial":"fixture A initial"),
            "rejected image changed a local clipboard")
        try wkPipelineExpect(f.wireMessageKinds.isDisjoint(with:["png","file","file-offer","stream-offer"]),
            "image body or fallback offer entered the control-only transport")
        wkLog("WKCLIP_TEST no-stream-image-\(direction)-blocked-local-clipboards-preserved-no-binary-fallback PASS")
    }
    private static func earlyFile(_ direction: String) throws {
        try fileWithoutStream(direction,denyPortal:false)
    }
    private static func noPortalFile(_ direction: String) throws {
        try fileWithoutStream(direction,denyPortal:true)
    }
    private static func fileWithoutStream(_ direction: String,denyPortal:Bool) throws {
        let f=try WKPipelineFixture(denyPortal:denyPortal)
        let body=Data((0..<65_536).map{UInt8(truncatingIfNeeded:$0 &* 31 &+ 17)})
        try f.publishFile(direction:direction,nonce:"91",body:body)
        let source=direction=="OUT" ? f.aBoard:f.bBoard,destination=direction=="OUT" ? f.bBoard:f.aBoard,
            portal=direction=="OUT" ? f.bPortal:f.aPortal
        let sourceRevision=source.changeCount,destinationRevision=destination.changeCount,
            sourceURL=source.string(forType:.fileURL)
        try wkPipelineExpect(portal.offers.isEmpty,"native Copy offered a file")
        let token=f.paste(direction);f.drive(120)
        try wkPipelineExpect(f.blocked(token) && !f.ready(token) && portal.offers.isEmpty &&
            portal.fulfilled.isEmpty && portal.streamFulfilled.isEmpty,"file without Bulk created a fallback transfer")
        try wkPipelineExpect(source.changeCount==sourceRevision && source.string(forType:.fileURL)==sourceURL &&
            destination.changeCount==destinationRevision && destination.string(forType:.string)==(direction=="OUT" ? "fixture B initial":"fixture A initial"),
            "rejected file changed a local clipboard")
        try wkPipelineExpect(f.wireMessageKinds.isDisjoint(with:["png","file","file-offer","stream-offer"]),
            "file body or offer entered the control-only transport")
        f.publishText(direction,"plain text after rejected file")
        let text=f.paste(direction);f.drive(100)
        try wkPipelineExpect(f.ready(text) && destination.string(forType:.string)=="plain text after rejected file",
            "rejected file blocked a new plain-text paste")
        wkLog("WKCLIP_TEST no-stream-file-\(direction)-portal-\(denyPortal ? "denied":"available")-blocked-no-fallback-text-recovers PASS")
    }
    private static func destinationWins(_ direction: String) throws {
        let f = try WKPipelineFixture()
        f.publishText(direction, String(repeating: "large source", count: 2000))
        let token = f.paste(direction)
        // A new menu/context copy arrives after V but before delivery.
        let board = direction == "OUT" ? f.bBoard : f.aBoard
        board.clearContents(); board.setString("destination wins", forType: .string)
        f.drive(100)
        try wkPipelineExpect(board.string(forType: .string) == "destination wins", "in-flight transfer replaced newer local copy")
        try wkPipelineExpect(!f.ready(token), "stale paste was authorized")
    }
    private static func stagedCancellation() throws {
        let f = try WKPipelineFixture()
        f.publishText("OUT", "must stay staged")
        f.dropReport = { fromA, bytes in
            fromA && f.b.receivedCount > 0 && WKReport(bytes, wireMagic: WKCompanion.magic)?.kind == .data
        }
        let token = f.paste("OUT"); f.drive(20)
        try wkPipelineExpect(f.b.receivedCount == 1, "stage fixture did not receive data")
        try wkPipelineExpect(f.bBoard.string(forType: .string) == "fixture B initial", "receive wrote clipboard before commit")
        f.a.command("CANCEL " + token); f.dropReport = nil; f.drive(100)
        try wkPipelineExpect(f.bBoard.string(forType: .string) == "fixture B initial", "cancelled staged content applied later")
        try wkPipelineExpect(!f.ready(token), "cancelled paste replayed")
    }
    private static func staleDestination() throws {
        let f = try WKPipelineFixture(); f.publishText("OUT", "outgoing")
        f.bBoard.clearContents(); f.bBoard.setString("unobserved menu copy", forType: .string)
        let token = f.paste("OUT"); f.drive(60)
        try wkPipelineExpect(!f.ready(token), "unobserved destination change bypassed prepare")
        try wkPipelineExpect(f.bBoard.string(forType: .string) == "unobserved menu copy", "destination overwritten")
    }
    private static func unsolicitedAndLegacy() throws {
        let f = try WKPipelineFixture()
        for nonce in ["0", "123"] {
            _ = f.b.link.send(try WKMessage(kind: "text", nonce: nonce, body: Data("unrequested".utf8)).encoded())
            f.drive(40)
        }
        try wkPipelineExpect(f.aBoard.string(forType: .string) == "fixture A initial", "unsolicited data overwrote clipboard")
        let old = WKLink(nonce: { 700 })
        var packets: [Data] = []; old.sendReport = { packets.append($0); return true }
        old.connected(true, at: 0)
        for packet in packets { f.at.onReport(packet) }
        f.drive(30)
        try wkPipelineExpect(!old.ready && f.a.link.ready, "legacy protocol replaced current session")
    }
    private static func lostCommitAck() throws {
        let f = try WKPipelineFixture(); f.publishText("OUT", "commit then local copy")
        var dropped = false
        f.dropReport = { fromA, bytes in
            if !fromA && f.bBoard.string(forType: .string) == "commit then local copy",
               WKReport(bytes, wireMagic: WKCompanion.magic)?.kind == .ack { dropped = true; return true }
            return false
        }
        let token = f.paste("OUT"); f.drive(10)
        try wkPipelineExpect(dropped, "commit ACK fixture did not drop")
        f.bBoard.clearContents(); f.bBoard.setString("new local after commit", forType: .string)
        f.dropReport = nil; f.drive(100)
        try wkPipelineExpect(!f.ready(token), "cached ACK authorized a stale commit")
        try wkPipelineExpect(f.bBoard.string(forType: .string) == "new local after commit", "commit replay replaced local data")
    }
    private static func disconnect() throws {
        let f=try WKPipelineFixture()
        f.publishText("OUT","text interrupted before commit")
        f.dropReport={fromA,bytes in
            fromA && f.b.receivedCount>0 && WKReport(bytes,wireMagic:WKCompanion.magic)?.kind == .data
        }
        let token=f.paste("OUT");f.drive(20)
        try wkPipelineExpect(f.b.receivedCount==1 && !f.ready(token),"disconnect fixture did not retain staged text")
        f.at.onConnection(false);f.bt.onConnection(false);f.dropReport=nil;f.drive(10)
        try wkPipelineExpect(!f.ready(token) && f.bBoard.string(forType:.string)=="fixture B initial",
            "disconnected staged text changed destination clipboard")
        f.aBoard.clearContents();f.aBoard.setString("offline local",forType:.string);f.drive(10)
        try wkPipelineExpect(f.aBoard.string(forType:.string)=="offline local","offline native clipboard damaged")
    }

}

