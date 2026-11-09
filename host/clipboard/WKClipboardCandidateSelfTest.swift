import Foundation
import CryptoKit

private struct WKCandidateTestFailure: Error, CustomStringConvertible { let description: String }
private func wkCandidateExpect(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
    if try !condition() { throw WKCandidateTestFailure(description: reason) }
}
private func wkCandidateReject(_ reason: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw WKCandidateTestFailure(description: "accepted invalid " + reason)
}

// This suite never opens a pasteboard, device, socket, app, or user's file.
enum WKClipboardCandidateSelfTest {
    static func run() throws {
        try framingAndLegacy()
        try binaryBoundaries()
        try offers()
        try lanesAndReplay()
        print("WKCLIP_CANDIDATE_TEST PASS framing legacy binary offers lanes replay")
    }

    private static func framingAndLegacy() throws {
        let report = WKReport(kind: .data, flags: 3, session: 0x0102030405060708,
                              sequence: 0, transfer: 1, payload: Data([0xaa]))
        let legacy = report.encode()
        try wkCandidateExpect(Array(legacy.prefix(24)) == [0x57, 0x4b, 0x43, 0x31, 3, 3, 1, 0,
            8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 0, 0, 1, 0, 0, 0], "legacy framing changed")
        let bulk = report.encode(wireMagic: WKReport.fileMagic)
        try wkCandidateExpect(legacy.dropFirst(4) == bulk.dropFirst(4), "lane framing differs")
        try wkCandidateExpect(WKReport(bulk) == nil && WKReport(legacy, wireMagic: WKReport.fileMagic) == nil, "cross-lane decoder")
        try wkCandidateExpect(WKReport(bulk, wireMagic: WKReport.fileMagic)?.payload == Data([0xaa]), "bulk decode")
        try wkCandidateExpect(WKReport(legacy, wireMagic: Data([1])) == nil, "invalid expected magic")

        let old = WKMessage(kind: "file", nonce: "0", name: "old.bin", body: Data([1, 2, 3]))
        let encoded = try old.encoded()
        let json = try JSONSerialization.jsonObject(with: Data(encoded.dropFirst(32))) as! [String: Any]
        try wkCandidateExpect(json["fileID"] == nil, "nil fileID changes old JSON")
        let decoded = try WKMessage.decode(encoded)
        try wkCandidateExpect(decoded.body == old.body && decoded.fileID == nil && decoded.version == 1, "legacy file decode")
        try wkCandidateExpect(try WKMessage.decode(WKMessage(kind: "text", body: Data("旧协议".utf8)).encoded()).kind == "text", "legacy text")
    }

    private static func reseal(_ bytes: Data) -> Data {
        var bytes = bytes
        var digest = SHA256(); digest.update(data: bytes.prefix(56)); digest.update(data: bytes.dropFirst(88))
        bytes.replaceSubrange(56..<88, with: Data(digest.finalize()))
        return bytes
    }

    private static func binaryBoundaries() throws {
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        for count in [0, 1, 65_536, WKMessage.maximumContent] {
            let body = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 17) })
            let input = WKMessage(kind: "file", nonce: "123", name: "图片 🌏.bin", body: body, fileID: id)
            let bytes = try input.encodedBinary()
            let output = try WKMessage.decode(bytes)
            try wkCandidateExpect(output.kind == "file" && output.nonce == input.nonce && output.name == input.name &&
                output.body == body && output.sha256 == input.sha256 && output.fileID == id, "binary roundtrip \(count)")
            try wkCandidateExpect(bytes.count == 88 + 3 + input.name!.utf8.count + 36 + count, "binary raw body overhead")
        }
        let plain = WKMessage(kind: "file", nonce: "12", name: "fixture.bin", body: Data([0, 255, 1]))
        let bytes = try plain.encodedBinary()
        try wkCandidateExpect(try WKMessage.decode(bytes).fileID == nil, "binary optional file ID")
        for length in [0, 1, 4, 87, bytes.count - 1] {
            try wkCandidateReject("binary truncation \(length)") { _ = try WKMessage.decode(Data(bytes.prefix(length))) }
        }
        var extra = bytes; extra.append(0)
        try wkCandidateReject("binary trailing bytes") { _ = try WKMessage.decode(extra) }
        for (offset, value) in [(4, UInt8(3)), (5, UInt8(99)), (6, UInt8(1)), (22, UInt8(1))] {
            var invalid = bytes; invalid[offset] = value
            try wkCandidateReject("binary version/kind/reserved") { _ = try WKMessage.decode(reseal(invalid)) }
        }
        for offset in [8, 12, 16, 18, 20] {
            var invalid = bytes; invalid[offset] = 0xff; invalid[offset + 1] = 0xff
            try wkCandidateReject("binary hostile length") { _ = try WKMessage.decode(reseal(invalid)) }
        }
        var invalidName = bytes; invalidName[90] = 47
        try wkCandidateReject("binary illegal name") { _ = try WKMessage.decode(reseal(invalidName)) }
        var invalidUTF8 = bytes; invalidUTF8[90] = 0xff
        try wkCandidateReject("binary invalid UTF8") { _ = try WKMessage.decode(reseal(invalidUTF8)) }
        var invalidNonce = bytes; invalidNonce[88] = 65
        try wkCandidateReject("binary invalid nonce") { _ = try WKMessage.decode(reseal(invalidNonce)) }
        var badBody = bytes; badBody[badBody.count - 1] ^= 1
        try wkCandidateReject("binary outer SHA") { _ = try WKMessage.decode(badBody) }
        try wkCandidateReject("binary inner SHA after resealing") { _ = try WKMessage.decode(reseal(badBody)) }
        var withID = try WKMessage(kind: "file", nonce: "12", name: "fixture.bin", body: Data([9]), fileID: id).encodedBinary()
        withID[88 + 2 + "fixture.bin".utf8.count] = 90
        try wkCandidateReject("binary invalid ID") { _ = try WKMessage.decode(reseal(withID)) }
        try wkCandidateReject("oversized binary") {
            _ = try WKMessage(kind: "file", name: "large.bin", body: Data(repeating: 0, count: WKMessage.maximumContent + 1)).encodedBinary()
        }
        try wkCandidateReject("non-file binary") { _ = try WKMessage(kind: "text", body: Data([65])).encodedBinary() }
        try wkCandidateReject("non-file ID") { _ = try WKMessage(kind: "text", body: Data([65]), fileID: id).encoded() }
    }

    private static func offers() throws {
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        let offer = WKFileOffer(id: id, name: "中文 🌏.bin", size: 65_536, sha256: String(repeating: "a", count: 64), nonce: "7")
        try wkCandidateExpect(try WKFileOffer.decode(offer.encoded()) == offer, "offer roundtrip")
        let message = WKMessage(kind: "file-offer", nonce: offer.nonce, body: try offer.encoded())
        try wkCandidateExpect(try WKMessage.decode(message.encoded()).kind == "file-offer", "offer envelope")
        try wkCandidateReject("offer nonce mismatch") {
            _ = try WKMessage(kind: "file-offer", nonce: "8", body: offer.encoded()).encoded()
        }
        try wkCandidateReject("offer outer filename") {
            _ = try WKMessage(kind: "file-offer", nonce: "7", name: "bad", body: offer.encoded()).encoded()
        }
        for bad in [
            WKFileOffer(id: id.uppercased(), name: offer.name, size: 1, sha256: offer.sha256, nonce: "7"),
            WKFileOffer(id: "invalid", name: offer.name, size: 1, sha256: offer.sha256, nonce: "7"),
            WKFileOffer(id: id, name: "../bad", size: 1, sha256: offer.sha256, nonce: "7"),
            WKFileOffer(id: id, name: offer.name, size: -1, sha256: offer.sha256, nonce: "7"),
            WKFileOffer(id: id, name: offer.name, size: WKMessage.maximumContent + 1, sha256: offer.sha256, nonce: "7"),
            WKFileOffer(id: id, name: offer.name, size: 1, sha256: offer.sha256.uppercased(), nonce: "7"),
            WKFileOffer(id: id, name: offer.name, size: 1, sha256: offer.sha256, nonce: "bad")
        ] { try wkCandidateReject("offer fields") { _ = try bad.encoded() } }
        var object = try JSONSerialization.jsonObject(with: offer.encoded()) as! [String: Any]
        object["sourcePath"] = "/must-not-be-accepted"
        try wkCandidateReject("offer unknown source field") { _ = try WKFileOffer.decode(JSONSerialization.data(withJSONObject: object)) }
        try wkCandidateReject("offer oversized JSON") { _ = try WKFileOffer.decode(Data(repeating: 32, count: 2049)) }
    }

    private static func lanesAndReplay() throws {
        let wire = WKCandidateWire(); wire.advance(10)
        try wkCandidateExpect(wire.links.allSatisfy { $0.ready }, "four independent handshakes")
        let body = try WKMessage(kind: "file", nonce: "19", name: "fixture.bin",
                                 body: Data(repeating: 0x5a, count: 65_536)).encodedBinary()
        var received: [Data] = []; var controls: [Data] = []
        var complete = false; var primaryComplete = false
        wire.bb.receiveMessage = { received.append($0); return true }
        wire.bp.receiveMessage = { controls.append($0); return true }
        wire.ab.onCompletion = { _, ok in complete = ok }
        wire.ap.onCompletion = { _, ok in primaryComplete = ok }
        var droppedData = false; var droppedAck = false; var delayed: Data?
        let final = UInt32((body.count - 1) / 40)
        wire.filter = { fromA, bytes in
            guard let report = WKReport(bytes, wireMagic: WKReport.fileMagic) else { return [bytes] }
            if fromA && report.kind == .data && report.sequence == 2 && !droppedData { droppedData = true; return [] }
            if fromA && report.kind == .data && report.sequence == 9 && delayed == nil { delayed = bytes; return [] }
            if fromA && report.kind == .data && report.sequence == 10, let old = delayed, !old.isEmpty {
                delayed = Data(); return [bytes, old, bytes]
            }
            if !fromA && report.kind == .ack && report.sequence == final && !droppedAck { droppedAck = true; return [] }
            return [bytes, bytes]
        }
        _ = wire.ab.send(body)
        _ = wire.ap.send(Data("primary-control".utf8))
        wire.advance(600)
        try wkCandidateExpect(complete && primaryComplete && received == [body] && controls == [Data("primary-control".utf8)], "concurrent lanes / retry / duplicate")
        try wkCandidateExpect(droppedAck && droppedData, "loss scenario exercised")

        let oldSession = wire.ab.session
        let oldData = WKReport(kind: .data, flags: 3, session: oldSession, transfer: 1, payload: Data([99])).encode(wireMagic: WKReport.fileMagic)
        let oldHello = WKReport(kind: .hello, session: oldSession).encode(wireMagic: WKReport.fileMagic)
        wire.filter = { _, bytes in [bytes] }
        wire.ab.connected(false, at: wire.now); wire.ab.connected(true, at: wire.now)
        wire.advance(30)
        let currentPeer = wire.bb.peerSession
        wire.bb.receive(oldHello, at: wire.now); wire.bb.receive(oldData, at: wire.now)
        try wkCandidateExpect(wire.bb.ready && wire.bb.peerSession == currentPeer && currentPeer != oldSession && received.count == 1,
                              "retired bulk session replay")
        try wkCandidateExpect(wire.ap.ready && wire.bp.ready, "bulk reset changed primary")

        let oldPeer = WKLink(nonce: { 99 })
        var output: [Data] = []; var applied = 0
        oldPeer.sendReport = { output.append($0); return true }
        oldPeer.receiveMessage = { _ in applied += 1; return true }
        oldPeer.connected(true, at: 0); output.removeAll()
        oldPeer.receive(oldHello, at: 0.1); oldPeer.receive(oldData, at: 0.2)
        try wkCandidateExpect(output.isEmpty && !oldPeer.ready && oldPeer.peerSession == 0 && applied == 0, "old peer ignored WKF2")

        // Equal numeric sessions/transfer IDs across lanes must still not cross-ACK.
        var cPrimary = false; var cBulk = false
        wire.ap.onCompletion = { _, ok in cPrimary = ok }; wire.ab.onCompletion = { _, ok in cBulk = ok }
        wire.toA.removeAll(); wire.toB.removeAll()
        let primaryID = wire.ap.send(Data(repeating: 1, count: 80))!
        let bulkID = wire.ab.send(Data(repeating: 2, count: 80))!
        let wrongAck = WKReport(kind: .ack, session: wire.ap.session, sequence: 1, transfer: primaryID).encode(wireMagic: WKReport.fileMagic)
        wire.ap.receive(wrongAck, at: wire.now)
        let otherWrongAck = WKReport(kind: .ack, session: wire.ab.session, sequence: 1, transfer: bulkID).encode()
        wire.ab.receive(otherWrongAck, at: wire.now)
        try wkCandidateExpect(!cPrimary && !cBulk && wire.ap.transmitting && wire.ab.transmitting, "cross-lane ACK changed state")
    }
}

private final class WKCandidateWire {
    let ap = WKLink(nonce: { 100 })
    let bp = WKLink(nonce: { 200 })
    let ab: WKLink
    let bb = WKLink(wireMagic: WKReport.fileMagic, nonce: { 200 })
    var links: [WKLink] { [ap, bp, ab, bb] }
    var toA: [Data] = []; var toB: [Data] = []
    var now: Double = 0
    var filter: (Bool, Data) -> [Data] = { _, bytes in [bytes] }
    init() {
        var next: UInt64 = 99
        ab = WKLink(wireMagic: WKReport.fileMagic, nonce: { next += 1; return next })
        for link in [ap, ab] { link.sendReport = { [unowned self] in toB.append(contentsOf: filter(true, $0)); return true } }
        for link in [bp, bb] { link.sendReport = { [unowned self] in toA.append(contentsOf: filter(false, $0)); return true } }
        for link in links { link.connected(true, at: 0) }
    }
    func advance(_ count: Int) {
        for _ in 0..<count {
            now += 0.01
            for link in links { link.tick(now) }
            for _ in 0..<8 {
                let a = toA; toA.removeAll(); let b = toB; toB.removeAll()
                if a.isEmpty && b.isEmpty { break }
                for bytes in a { ap.receive(bytes, at: now); ab.receive(bytes, at: now) }
                for bytes in b { bp.receive(bytes, at: now); bb.receive(bytes, at: now) }
            }
        }
    }
}

#if WK_PROTOCOL_CANDIDATE_TEST
@main enum WKCandidateMain {
    static func main() {
        do { try WKClipboardCandidateSelfTest.run() }
        catch { fputs("WKCLIP_CANDIDATE_TEST FAIL \(error)\n", stderr); exit(1) }
    }
}
#endif
