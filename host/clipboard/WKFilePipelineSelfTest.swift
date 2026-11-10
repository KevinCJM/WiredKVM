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
    func fail(id: String) { if fulfilled[id] == nil { failed.insert(id) } }
    func retire(id: String) { retired.insert(id) }
}

private final class WKTestClock { var now: Double = 100 }

private final class WKPipelineFixture {
    let time = WKTestClock()
    var dataReports = 0
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
    private let streams: (WKStreamFiles, WKStreamFiles)?
    

    init(legacyTarget: Bool = false, denyPortal: Bool = false, streams: (WKStreamFiles, WKStreamFiles)? = nil) throws {
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
        if dropReport?(fromA, bytes) == true { return }
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

    func source(_ direction: String) -> String {
        let prefix = "WKCLIP_ORIGIN " + direction + " "
        return replies.last(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) } ?? "0"
    }
    @discardableResult func paste(_ direction: String, id: String = "9001") -> String {
        let token = source(direction) + "." + id
        a.command("PASTE " + direction + " " + token)
        return token
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
            for _ in 0..<50 {f.drive(40);if f.replies.contains("WKCLIP_PASTE READY "+token){break}}
            if !f.replies.contains("WKCLIP_PASTE READY "+token){print(f.logs.suffix(30).joined(separator:"\n"));print(f.replies.suffix(12))}
            try wkPipelineExpect(f.replies.contains("WKCLIP_PASTE READY "+token),"collection did not enable native paste")
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
            try wkPipelineExpect(f.replies.contains("WKCLIP_PASTE READY "+next) && board.string(forType:.string)=="new paste wins","cancelled collection blocked new paste")
            try wkPipelineExpect(!f.replies.contains("WKCLIP_PASTE READY "+old),"cancelled collection committed")
            // Empty folders can finish before the ready-message round trip.
            source.clearContents();source.writeObjects([empty as NSURL]);f.drive(30)
            let last=f.paste(direction,id:"9604")
            for _ in 0..<30{f.drive(30);if f.replies.contains("WKCLIP_PASTE READY "+last){break}}
            try wkPipelineExpect(f.replies.contains("WKCLIP_PASTE READY "+last),"empty directory ready race")
        }
        wkLog("WKCLIP_TEST collection-bidirectional-multiple-roots-early-paste-local-copy-cancel-empty PASS")
    }
#endif
    // Injected USB stream endpoints exercise the real coordinator, private
    // pasteboards and background workers. No general pasteboard or mounts.
    static func streamSuite(make: () -> (WKStreamIO, WKStreamIO, (Bool) -> Void)) throws {
        do {
            let (ioA,ioB,_) = make(), streams = (WKStreamFiles { ioA }, WKStreamFiles { ioB })
            let f = try WKPipelineFixture(streams: streams)
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
        for direction in ["OUT", "IN"] {
            let (ioA, ioB, stall) = make()
            let streams = (WKStreamFiles { ioA }, WKStreamFiles { ioB })
            let f = try WKPipelineFixture(streams: streams)
            f.publishText("OUT", "local Book"); f.publishText("IN", "local mini")
            try wkPipelineExpect(f.aBoard.string(forType: .string) == "local Book" && f.bBoard.string(forType: .string) == "local mini", "CH32 local copy isolation")
            f.publishText(direction, "CH32 wired text " + direction)
            let textToken = f.paste(direction, id: "8001"); f.drive(100)
            try wkPipelineExpect(f.replies.contains("WKCLIP_PASTE READY " + textToken), "CH32 text paste")
            let body = Data((0..<2_097_153).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 23) })
            try f.publishFile(direction: direction, nonce: "8002", body: body)
            let target = direction == "OUT" ? f.bPortal : f.aPortal
            let board = direction == "OUT" ? f.bBoard : f.aBoard
            try wkPipelineExpect(target.offers.isEmpty, "CH32 copy sent file contents before cross paste")
            stall(true)
            let token = f.paste(direction, id: "8003"); f.drive(300)
            try wkPipelineExpect(f.replies.contains("WKCLIP_PASTE READY " + token), "CH32 early native paste blocked")
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
            try wkPipelineExpect(board.string(forType: .string) == "local wins race" && !f.replies.contains("WKCLIP_PASTE READY " + cancelled), "CH32 stale commit race")
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
            f.a.command("PASTE " + direction + " " + token) // identical V must not restart
            for _ in 0..<100 { f.drive(50); if f.replies.contains("WKCLIP_PASTE READY " + token) { break } }
            if !f.replies.contains("WKCLIP_PASTE READY " + token) { print(f.logs.suffix(40).joined(separator:"\n")); print(f.replies.suffix(12)) }
            try wkPipelineExpect(f.replies.filter { $0 == "WKCLIP_PASTE READY " + token }.count == 1,"bulk image one V completion " + direction)
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
            try wkPipelineExpect(f.replies.contains("WKCLIP_PASTE READY " + fresh),"cancel/new text blocked by body stall")
            try wkPipelineExpect(!f.replies.contains("WKCLIP_PASTE READY " + old),"cancelled image committed")
            stall(false); f.drive(100)
            try wkPipelineExpect(target.string(forType:.string) == "new text bypassed old image","late old image replaced new content")
            // A local copy at the destination wins even during image transfer.
            publish(tiff,.tiff); stall(true)
            let race = f.paste(direction,id:"8504"); f.drive(80)
            target.clearContents(); target.setString("destination local wins",forType:.string); f.drive(25)
            stall(false); f.drive(100)
            try wkPipelineExpect(target.string(forType:.string) == "destination local wins" && !f.replies.contains("WKCLIP_PASTE READY " + race),"local image-copy race")
            // Fresh TIFF conversion still works after cancellation.
            publish(tiff,.tiff); let converted = f.paste(direction,id:"8505")
            for _ in 0..<100 { f.drive(50); if f.replies.contains("WKCLIP_PASTE READY " + converted) { break } }
            try wkPipelineExpect(f.replies.contains("WKCLIP_PASTE READY " + converted) && target.data(forType:.png) != nil,"TIFF bulk conversion failed")
            let oversized = Data(repeating:0,count:WKStreamOffer.maximumImage+1)
            publish(oversized,.png); let rejected = f.paste(direction,id:"8506")
            for _ in 0..<50 { f.drive(20); if f.replies.contains("WKCLIP_PASTE BLOCK " + rejected) { break } }
            try wkPipelineExpect(f.replies.contains("WKCLIP_PASTE BLOCK " + rejected),"oversize image did not fail promptly")
            try wkPipelineExpect(source.data(forType:.png) == oversized,"oversize source clipboard was changed")
            wkLog("WKCLIP_TEST CH32-Bulk-image-\(direction)-PNG-\(png.count)-TIFF-local-isolation-cancel-retry PASS")
        }
    }
    static func run() throws {
        try nativeIsolation()
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
        try wkPipelineExpect(f.replies.filter { $0 == "WKCLIP_PASTE READY " + token }.count == 1, "paste did not execute exactly once: " + direction)
        let count = f.dataReports; f.drive(60)
        try wkPipelineExpect(count == f.dataReports, "applied text echoed back")
        let all = f.logs.joined(); try wkPipelineExpect(!all.contains(text), "clipboard leaked to diagnostic log")
    }
    private static func imagePaste(_ direction: String) throws {
        let f = try WKPipelineFixture()
        let source = direction == "OUT" ? f.aBoard : f.bBoard
        let destination = direction == "OUT" ? f.bBoard : f.aBoard
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:768,pixelsHigh:512,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
            bytesPerRow:768*4,bitsPerPixel:32), let pixels = bitmap.bitmapData else {
            throw WKPipelineTestFailure(description:"image pipeline fixture")
        }
        memset(pixels,127,bitmap.bytesPerRow*bitmap.pixelsHigh)
        let tiff=bitmap.representation(using:.tiff,properties:[.compressionMethod:NSNumber(value:NSBitmapImageRep.TIFFCompression.none.rawValue)])!
        try wkPipelineExpect(tiff.count > WKMessage.maximumContent,"TIFF pipeline fixture must exceed wire byte limit")
        source.clearContents(); source.setData(tiff,forType:.tiff); f.drive(25)
        let sourceRevision=source.changeCount
        let before=f.dataReports; f.drive(20)
        try wkPipelineExpect(f.dataReports==before,"image content transferred without cross-machine paste")
        let token=f.paste(direction); f.drive(200)
        try wkPipelineExpect(f.replies.filter { $0=="WKCLIP_PASTE READY "+token }.count==1,"image paste readiness "+direction)
        try wkPipelineExpect(source.changeCount==sourceRevision && source.data(forType:.tiff)==tiff,"image source clipboard changed")
        guard let png=destination.data(forType:.png), let receivedTIFF=destination.data(forType:.tiff),
              let rep=NSBitmapImageRep(data:receivedTIFF) else { throw WKPipelineTestFailure(description:"received image formats missing") }
        try WKClipboard.validateImage(png)
        try wkPipelineExpect(rep.pixelsWide==768 && rep.pixelsHigh==512 && rep.hasAlpha,"received image properties")
        let delivered=f.dataReports; f.drive(60)
        try wkPipelineExpect(f.dataReports==delivered,"received image echoed back")
        wkLog("WKCLIP_TEST on-demand-TIFF-image-\(direction)-stage-commit-dual-format PASS")
    }
    private static func earlyFile(_ direction: String) throws {
        let f = try WKPipelineFixture(); f.holdBulk = true
        let body = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 17) })
        try f.publishFile(direction: direction, nonce: "91", body: body)
        let target = direction == "OUT" ? f.bPortal : f.aPortal
        let board = direction == "OUT" ? f.bBoard : f.aBoard
        try wkPipelineExpect(target.offers.isEmpty, "file advertised before a cross paste")
        let token = f.paste(direction); f.drive(50)
        try wkPipelineExpect(f.replies.contains("WKCLIP_PASTE READY " + token), "early file paste not ready: " + direction)
        try wkPipelineExpect(target.offers.count == 1 && target.fulfilled.isEmpty, "early paste waited for file bytes")
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        try wkPipelineExpect(urls?.count == 1, "native Finder URL absent")
        // Later local copy must leave an already-started Finder job alive.
        board.clearContents(); board.setString("new destination local copy", forType: .string); f.drive(20)
        f.resumeBulk()
        try wkPipelineExpect(target.fulfilled.values.contains(body), "file bytes/hash not preserved after new local copy")
        try wkPipelineExpect(board.string(forType: .string) == "new destination local copy", "file completion overwrote local clipboard")
        try wkPipelineExpect(target.failed.isEmpty, "active Finder job revoked by new local copy")
    }
    private static func noPortalFile(_ direction: String) throws {
        let f = try WKPipelineFixture(denyPortal: true)
        let body = Data(repeating: 0x91, count: 1024)
        try f.publishFile(direction: direction, nonce: "92", body: body)
        let token = f.paste(direction); f.drive(100)
        let board = direction == "OUT" ? f.bBoard : f.aBoard
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        try wkPipelineExpect(f.replies.contains("WKCLIP_PASTE READY " + token) && urls?.count == 1, "verified file fallback failed")
        try wkPipelineExpect(try Data(contentsOf: urls![0]) == body, "fallback integrity failed")
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
        try wkPipelineExpect(!f.replies.contains("WKCLIP_PASTE READY " + token), "stale paste was authorized")
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
        try wkPipelineExpect(!f.replies.contains("WKCLIP_PASTE READY " + token), "cancelled paste replayed")
    }
    private static func staleDestination() throws {
        let f = try WKPipelineFixture(); f.publishText("OUT", "outgoing")
        f.bBoard.clearContents(); f.bBoard.setString("unobserved menu copy", forType: .string)
        let token = f.paste("OUT"); f.drive(60)
        try wkPipelineExpect(!f.replies.contains("WKCLIP_PASTE READY " + token), "unobserved destination change bypassed prepare")
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
        try wkPipelineExpect(!f.replies.contains("WKCLIP_PASTE READY " + token), "cached ACK authorized a stale commit")
        try wkPipelineExpect(f.bBoard.string(forType: .string) == "new local after commit", "commit replay replaced local data")
    }
    private static func disconnect() throws {
        let f = try WKPipelineFixture(); f.holdBulk = true
        try f.publishFile(direction: "OUT", nonce: "93", body: Data(repeating: 1, count: 2000))
        _ = f.paste("OUT"); f.drive(30)
        f.at.onConnection(false); f.bt.onConnection(false); f.drive(10)
        try wkPipelineExpect(!f.bPortal.failed.isEmpty, "disconnect left a Finder read waiting forever")
        f.aBoard.clearContents(); f.aBoard.setString("offline local", forType: .string); f.drive(10)
        try wkPipelineExpect(f.aBoard.string(forType: .string) == "offline local", "offline native clipboard damaged")
    }
}

