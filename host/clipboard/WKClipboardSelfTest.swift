import AppKit
import Darwin

private struct WKTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
    if try !condition() { throw WKTestFailure(description: reason) }
}

private final class WKMemoryTransport: WKTransport {
    var onReport: (Data) -> Void = { _ in }
    var onConnection: (Bool) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    var reports: [Data] = []
    func start() {}
    func tick(_ time: Double) {}
    func send(_ bytes: Data) -> Bool { reports.append(bytes); return true }
    func stop() {}
}

private final class WKTestWire {
    let a = WKLink(nonce: { 0x1001 })
    let b = WKLink(nonce: { 0x2001 })
    var toA: [Data] = []
    var toB: [Data] = []
    var now: Double = 0
    var filter: (Bool, Data) -> [Data] = { _, bytes in [bytes] }
    init() {
        a.sendReport = { [unowned self] in toB.append(contentsOf: filter(true, $0)); return true }
        b.sendReport = { [unowned self] in toA.append(contentsOf: filter(false, $0)); return true }
        a.connected(true, at: now); b.connected(true, at: now)
    }
    func step() {
        now += 0.01; a.tick(now); b.tick(now)
        for _ in 0..<8 {
            let aa = toA; toA.removeAll(); let bb = toB; toB.removeAll()
            if aa.isEmpty && bb.isEmpty { break }
            for r in aa { a.receive(r, at: now) }
            for r in bb { b.receive(r, at: now) }
        }
    }
    func advance(_ count: Int = 100) { for _ in 0..<count { step() } }
}

enum WKSelfTest {
    static func run() throws {
        try reportValidation()
        try reliableDelivery()
        try disconnectAndReplay()
        try unixStream()
        try privateClipboard()
        try metadataDiagnostics()
        try WKFilePipelineSelfTest.run()
    }

    private static func reportValidation() throws {
        let packet = WKReport(kind: .data, flags: 3, session: 0x0102030405060708,
                              sequence: 3, transfer: 4, payload: Data([0, 1, 2, 255]))
        let bytes = packet.encode()
        try expect(bytes.count == 64 && bytes[8] == 8 && bytes[15] == 1, "report framing / endianness")
        try expect(WKReport(bytes)?.payload == packet.payload, "report round trip")
        var invalid = bytes; invalid[6] = 41
        try expect(WKReport(invalid) == nil && WKReport(Data(repeating: 0, count: 64)) == nil, "invalid report accepted")
        let message = WKMessage(kind: "text", body: Data("你好 🌏".utf8))
        let encoded = try message.encoded()
        try expect(try WKMessage.decode(encoded).body == message.body, "Unicode envelope")
        var corrupted = encoded; corrupted[corrupted.count - 2] ^= 1
        do { _ = try WKMessage.decode(corrupted); throw WKTestFailure(description: "corrupt envelope accepted") }
        catch is WKTestFailure { throw WKTestFailure(description: "corrupt envelope accepted") }
        catch {}
        try expect(!WKMessage.validFilename("../escape") && !WKMessage.validFilename("..") && WKMessage.validFilename("汉字 🌏.txt"), "filename validation")
        for volume in ["WiredKVM Setup", "WiredKVM Setup 1", "WiredKVM Setup 2", "WiredKVM Setup 123"] {
            try expect(WKCompanionInstall.isSetupLocation("/Volumes/\(volume)/WiredKVM Companion.app"), "setup volume suffix not relocated")
        }
        for path in ["/Applications/WiredKVM Companion.app", "/tmp/Volumes/WiredKVM Setup 1/WiredKVM Companion.app",
                     "/Volumes/WiredKVM Setup Other/WiredKVM Companion.app", "/Volumes/WiredKVM Setup1/WiredKVM Companion.app",
                     "/Volumes/WiredKVM Setup /WiredKVM Companion.app", "/Volumes/WiredKVM Setup -1/WiredKVM Companion.app",
                     "/Volumes/WiredKVM Setup 1 Other/WiredKVM Companion.app", "/Volumes/WiredKVM Setup 1/../Other.app"] {
            try expect(!WKCompanionInstall.isSetupLocation(path), "setup relocation boundary")
        }
        wkLog("WKCLIP_TEST framing-and-integrity PASS")
    }

    private static func reliableDelivery() throws {
        let wire = WKTestWire(); wire.advance(5)
        try expect(wire.a.ready && wire.b.ready, "handshake")
        let body = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 * 13) })
        var received: [Data] = []; var accepted = false
        wire.b.receiveMessage = { received.append($0); return true }
        wire.a.onCompletion = { _, success in accepted = success }
        var lostData = false; var lostFinal = false; var delayed: Data?
        wire.filter = { fromA, bytes in
            let report = WKReport(bytes)!
            if fromA && report.kind == .data && report.sequence == 2 && !lostData { lostData = true; return [] }
            if fromA && report.kind == .data && report.sequence == 9 && delayed == nil { delayed = bytes; return [] }
            if fromA && report.kind == .data && report.sequence == 10, let old = delayed {
                delayed = Data(); return [bytes, old, bytes]
            }
            if !fromA && report.kind == .ack && report.sequence == UInt32((body.count - 1) / 40) && !lostFinal {
                lostFinal = true; return []
            }
            return [bytes, bytes]
        }
        _ = wire.a.send(body); wire.advance(400)
        try expect(received == [body] && accepted && lostData && lostFinal, "loss / duplicate / ordering / final ACK dedupe")
        wire.filter = { _, bytes in [bytes] }
        wire.b.receiveMessage = { _ in false }; accepted = true
        _ = wire.a.send(Data([1, 2, 3])); wire.advance(20)
        try expect(!accepted, "rejection must not acknowledge success")
        let countBeforeReplay = received.count
        wire.b.receiveMessage = { received.append($0); return true }
        wire.b.receive(WKReport(kind: .data, flags: 3, session: wire.a.session,
                               transfer: 1, payload: Data([99])).encode(), at: wire.now)
        try expect(received.count == countBeforeReplay, "previous completed transfer replayed")
        let maximum = Data(repeating: 0xa5, count: WKLink.maximumMessage)
        accepted = false
        _ = wire.a.send(maximum); wire.advance(4000)
        try expect(accepted && received.last == maximum, "maximum bounded message transfer")
        try expect(wire.a.send(Data(repeating: 0, count: WKLink.maximumMessage + 1)) == nil, "message size limit")
        wkLog("WKCLIP_TEST loss-duplicate-order-final-ack PASS")
    }

    private static func disconnectAndReplay() throws {
        let wire = WKTestWire(); wire.advance(5)
        var received = 0; var completed = true
        wire.b.receiveMessage = { _ in received += 1; return true }
        wire.a.onCompletion = { _, success in completed = success }
        _ = wire.a.send(Data(repeating: 7, count: 400))
        wire.b.connected(false, at: wire.now)
        wire.advance(500)
        try expect(received == 0 && !completed && !wire.a.ready, "disconnect did not cancel")

        // Replace the target session while Book's COM socket remains alive. Old
        // HELLO / ACK / DATA already buffered in UART cannot restore that peer.
        let replay = WKTestWire(); replay.advance(5)
        let previous = replay.a.peerSession
        replay.a.receive(WKReport(kind: .hello, session: 0x9999).encode(), at: replay.now)
        replay.a.receive(WKReport(kind: .hello, session: previous).encode(), at: replay.now)
        var oldAck = Data(); oldAck.appendLE(previous)
        replay.a.receive(WKReport(kind: .helloAck, session: replay.a.session, payload: oldAck).encode(), at: replay.now)
        replay.a.receive(WKReport(kind: .data, flags: 3, session: previous, transfer: 1, payload: Data([9])).encode(), at: replay.now)
        try expect(replay.a.peerSession == 0x9999 && !replay.a.ready, "retired session replay")
        wkLog("WKCLIP_TEST disconnect-and-retired-session PASS")
    }

    private static func unixStream() throws {
        let directory = URL(fileURLWithPath: "/tmp/wkclip-test-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("channel").path
        let server = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else { throw WKTestFailure(description: "test Unix socket unavailable") }
        defer { Darwin.close(server) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            path.utf8CString.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try expect(bound == 0 && chmod(path, 0o600) == 0 && listen(server, 1) == 0, "private Unix server setup")
        _ = fcntl(server, F_SETFL, O_NONBLOCK)
        let transport = WKUnixTransport(path: path)
        var connected = false; var reports: [Data] = []
        transport.onConnection = { connected = $0 }; transport.onReport = { reports.append($0) }
        transport.tick(0)
        let peer = accept(server, nil, nil)
        guard peer >= 0 else { throw WKTestFailure(description: "private Unix connection failed") }
        defer { Darwin.close(peer); transport.stop() }
        _ = fcntl(peer, F_SETFL, O_NONBLOCK)
        try expect(connected, "same-UID socket rejected")
        let first = WKReport(kind: .hello, session: 123).encode()
        let second = WKReport(kind: .ping, session: 456).encode()
        let initial = Data(first.prefix(17))
        let wroteFirst = initial.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
        try expect(wroteFirst == 17, "partial report fixture")
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        try expect(reports.isEmpty, "partial report was delivered")
        var tail = Data(first.dropFirst(17)); tail.append(second)
        let wroteTail = tail.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
        try expect(wroteTail == tail.count, "joined report fixture")
        let readDeadline = Date().addingTimeInterval(1)
        while reports.count < 2 && Date() < readDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        try expect(reports == [first, second], "stream partial / concatenated framing")
        try expect(transport.send(first) && transport.send(second), "socket transmit enqueue")
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        var output = [UInt8](repeating: 0, count: 128)
        let count = Darwin.read(peer, &output, output.count)
        var expected = first; expected.append(second)
        try expect(count == 128 && Data(output) == expected, "socket output framing")
        for _ in 0..<64 { try expect(transport.send(first), "socket queue capacity") }
        try expect(!transport.send(first), "socket queue unbounded")
        transport.stop(); try expect(!connected, "socket disconnect notification")
        wkLog("WKCLIP_TEST private-unix-stream-framing-bounds PASS")
    }

    private static func privateClipboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wiredkvm-self-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clipboard = WKClipboard(board: board, receiveRoot: root.appendingPathComponent("received"))
        board.clearContents()
        try expect(board.setString("你好 macOS 🌏\nsecond line", forType: .string), "private pasteboard service unavailable (sandbox)")
        guard let text = try clipboard.snapshot() else { throw WKTestFailure(description: "private pasteboard read unavailable (sandbox)") }
        try expect(text.kind == "text", "private text snapshot")
        _ = try clipboard.apply(text, expectedChangeCount: board.changeCount)
        try expect(board.string(forType: .string) == "你好 macOS 🌏\nsecond line", "private text round trip")
        let version = board.changeCount
        board.clearContents(); board.setString("new local copy", forType: .string)
        do { _ = try clipboard.apply(text, expectedChangeCount: version); throw WKTestFailure(description: "local copy overwritten") }
        catch is WKTestFailure { throw WKTestFailure(description: "local copy overwritten") }
        catch {}
        try expect(board.string(forType: .string) == "new local copy", "local copy changed after refusal")
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32),
              let pixels = bitmap.bitmapData else { throw WKTestFailure(description: "PNG fixture") }
        for index in 0..<16 { pixels[index] = UInt8(index * 16) }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw WKTestFailure(description: "PNG fixture encoding") }
        board.clearContents(); board.setData(png, forType: .png)
        guard let picture = try clipboard.snapshot() else { throw WKTestFailure(description: "PNG snapshot") }
        _ = try clipboard.apply(picture, expectedChangeCount: board.changeCount)
        try expect(picture.kind == "png" && board.data(forType: .png) == png, "private PNG integrity")
        let upperBound = WKMessage(kind: "file", name: "limit.bin", body: Data(repeating: 1, count: WKMessage.maximumContent))
        try expect(try upperBound.encoded().count <= WKLink.maximumMessage, "max content does not fit wire envelope")
        let name = "中文 🌏.bin"
        let bytes = Data((0..<32768).map { UInt8(truncatingIfNeeded: $0) })
        let file = root.appendingPathComponent(name)
        try bytes.write(to: file)
        board.clearContents(); board.writeObjects([file as NSURL])
        guard let payload = try clipboard.snapshot(nonce: "42") else { throw WKTestFailure(description: "private file pasteboard unavailable") }
        try expect(payload.kind == "file" && payload.body == bytes, "file snapshot")
        let saved = try clipboard.apply(payload, expectedChangeCount: board.changeCount)!
        try expect(try Data(contentsOf: saved) == bytes && saved.lastPathComponent == name, "file exact integrity")
        try expect(board.string(forType: .fileURL) == saved.absoluteString, "file URL pasteboard")
        let zero = WKMessage(kind: "file", name: ".partial", body: Data())
        let empty = try clipboard.apply(zero, expectedChangeCount: board.changeCount)!
        try expect(try Data(contentsOf: empty).isEmpty, "zero byte / partial name")
        let symlink = root.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        for bad in [symlink, root] {
            do { _ = try WKClipboard.readRegularFile(bad); throw WKTestFailure(description: "unsupported file accepted") }
            catch is WKTestFailure { throw WKTestFailure(description: "unsupported file accepted") }
            catch {}
        }
        let fork = [UInt8](repeating: 0x5a, count: 5)
        let setFork = fork.withUnsafeBytes { bytes in file.path.withCString { setxattr($0, "com.apple.ResourceFork", bytes.baseAddress, bytes.count, 0, 0) } }
        guard setFork == 0 else { throw WKTestFailure(description: "resource fork fixture failed") }
        do { _ = try WKClipboard.readRegularFile(file); throw WKTestFailure(description: "resource fork accepted") }
        catch is WKTestFailure { throw WKTestFailure(description: "resource fork accepted") }
        catch {}
        wkLog("WKCLIP_TEST private-pasteboard-unicode-file-sha-local-wins PASS")
    }

    private static func metadataDiagnostics() throws {
        let secret = "private-payload-DO-NOT-LOG-秘密"
        for field in ["payload", "name", "path", "types"] {
            try expect(WKMetadata.line(role: "host", event: "COPY", fields: [field: secret]) == nil, "unsafe metadata key accepted")
        }
        try expect(WKMetadata.line(role: "host", event: "COPY", fields: ["nonce": secret]) == nil, "payload accepted as nonce")
        try expect(WKMetadata.line(role: "host", event: "ERROR", fields: ["code": "failure-/Users/private/secret.txt"]) == nil, "path accepted as error code")
        let fileError = NSError(domain: NSCocoaErrorDomain, code: 260,
                                userInfo: [NSFilePathErrorKey: "/Users/private/secret.txt", NSLocalizedDescriptionKey: secret])
        try expect(WKMetadata.errorCode(fileError) == "cocoa-260", "NSError user data leaked")
        try expect(WKMetadata.errorCode(WKClipboardError.invalid(secret)) == "clipboard-error", "unknown internal message leaked")

        let wire = WKTestWire(); wire.advance(5)
        var tx: [(Double, WKTransferProgress)] = [], rx: [(Double, WKTransferProgress)] = []
        wire.a.onProgress = { tx.append((wire.now, $0)) }
        wire.b.onProgress = { rx.append((wire.now, $0)) }
        var delivered = Data()
        wire.b.receiveMessage = { delivered = $0; return true }
        let body = Data(repeating: 0x73, count: 10_000)
        _ = wire.a.send(body); wire.advance(100)
        try expect(delivered == body, "diagnostics changed delivery")
        try expect(tx.first?.1.phase == .start && tx.last?.1.phase == .complete && tx.last?.1.acknowledged == 250 && tx.last?.1.total == 250, "TX complete counters missing")
        try expect(rx.first?.1.total == nil && rx.last?.1.phase == .complete && rx.last?.1.total == 250, "RX total must be unknown until complete")
        try expect(tx.count <= 12 && rx.count <= 3, "fast progress not throttled to 10 percent")
        let txUpdates = tx.filter { $0.1.phase == .progress }
        for pair in zip(txUpdates, txUpdates.dropFirst()) {
            try expect(pair.1.0 - pair.0.0 >= 1 || pair.1.1.acknowledged * 10 / 250 > pair.0.1.acknowledged * 10 / 250,
                       "TX progress violated time/percentage throttle")
        }
        let slow = WKTestWire(); slow.advance(5)
        var slowRX: [(Double, WKTransferProgress)] = []
        slow.b.onProgress = { slowRX.append((slow.now, $0)) }; slow.b.receiveMessage = { _ in true }
        for seq in 0..<100 {
            slow.now += 0.05
            slow.b.receive(WKReport(kind: .data, flags: (seq == 0 ? 1 : 0) | (seq == 99 ? 2 : 0),
                                   session: slow.a.session, sequence: UInt32(seq), transfer: 99,
                                   payload: Data(repeating: 1, count: 40)).encode(), at: slow.now)
        }
        try expect(slowRX.count >= 5 && slowRX.count <= 7 && slowRX.last?.1.phase == .complete, "slow RX heartbeat/complete throttle")
        for pair in zip(slowRX.filter { $0.1.phase == .progress }, slowRX.filter { $0.1.phase == .progress }.dropFirst()) {
            try expect(pair.1.0 - pair.0.0 >= 1, "RX progress exceeded one per second")
        }

        wkLog("WKCLIP_TEST metadata-privacy-and-throttled-progress PASS")
    }
}
