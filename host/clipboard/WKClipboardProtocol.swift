import Foundation

// The serial bridge and USB device carry opaque, fixed-size reports. All multi-byte
// integers below are little endian. No HID report ID or stream length prefix exists.
struct WKReport {
    enum Kind: UInt8 { case hello = 1, helloAck, data, ack, abort, ping, pong }
    static let size = 64
    static let payloadSize = 40
    static let defaultMagic = Data("WKC1".utf8)
    static let fileMagic = Data("WKF2".utf8)
    var kind: Kind
    var flags: UInt8 = 0
    var session: UInt64
    var sequence: UInt32 = 0
    var transfer: UInt32 = 0
    var payload = Data()

    func encode(wireMagic: Data = Self.defaultMagic) -> Data {
        precondition(payload.count <= Self.payloadSize && wireMagic.count == 4)
        var result = Data(wireMagic); result.append(contentsOf: [kind.rawValue, flags])
        result.appendLE(UInt16(payload.count)); result.appendLE(session)
        result.appendLE(sequence); result.appendLE(transfer); result.append(payload)
        result.append(Data(repeating: 0, count: Self.size - result.count))
        return result
    }

    init(kind: Kind, flags: UInt8 = 0, session: UInt64, sequence: UInt32 = 0,
         transfer: UInt32 = 0, payload: Data = Data()) {
        self.kind = kind; self.flags = flags; self.session = session
        self.sequence = sequence; self.transfer = transfer; self.payload = payload
    }

    init?(_ bytes: Data, wireMagic: Data = Self.defaultMagic) {
        guard wireMagic.count == 4, bytes.count == Self.size,
              bytes.prefix(4) == wireMagic,
              let kind = Kind(rawValue: bytes[4]) else { return nil }
        let length: UInt16 = bytes.readLE(at: 6)
        guard length <= Self.payloadSize else { return nil }
        self.kind = kind; flags = bytes[5]; session = bytes.readLE(at: 8)
        sequence = bytes.readLE(at: 16); transfer = bytes.readLE(at: 20)
        payload = Data(bytes[24..<(24 + Int(length))])
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ number: T) {
        var value = number.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
    func readLE<T: FixedWidthInteger>(at offset: Int) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size { value |= T(self[offset + i]) << (8 * i) }
        return value
    }
}

// Diagnostics contain counters only. The wire format has no total-length field,
// so RX total is deliberately unknown until END; no payload is inspected here.
struct WKTransferProgress {
    enum Direction: String { case tx = "TX", rx = "RX" }
    enum Phase: String { case start = "START", progress = "PROGRESS", complete = "COMPLETE", cancel = "CANCEL", reset = "RESET", reject = "REJECT" }
    let direction: Direction
    let phase: Phase
    let transfer: UInt32
    let acknowledged: Int
    let total: Int?
}

// Main-thread owned. Four reports in flight, cumulative ACK, go-back-N retry.
// A final ACK means the complete message was validated and accepted by the app.
final class WKLink {
    static let maximumMessage = 1_500_000
    static let retryInterval: Double = 0.20
    static let window = 4
    let wireMagic: Data
    var sendReport: (Data) -> Bool = { _ in false }
    var receiveMessage: (Data) -> Bool = { _ in false }
    // Ephemeral queries (paste readiness) must be revalidated when their ACK was
    // lost. nil means a normal idempotent content commit, which is never replayed.
    var revalidateMessage: (Data) -> Bool? = { _ in nil }
    var onCompletion: (UInt32, Bool) -> Void = { _, _ in }
    var onReady: (Bool) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    var onProgress: (WKTransferProgress) -> Void = { _ in }
    private(set) var ready = false
    private(set) var session: UInt64 = 0
    private(set) var peerSession: UInt64 = 0
    private var physical = false
    private var helloAcknowledged = false
    private var now: Double = 0
    private var lastPeer: Double = 0
    private var lastHello: Double = -10
    private var lastPing: Double = -10
    private var nextTransfer: UInt32 = 1
    private let nonce: () -> UInt64

    private struct Outgoing {
        let id: UInt32
        let body: Data
        let count: Int
        var acknowledged = -1
        var next = 0
        var lastSend: Double = 0
        var lastProgress: Double = 0
        var retries = 0
    }
    private struct Incoming {
        let id: UInt32
        var next: UInt32 = 0
        var body = Data()
        var lastProgress: Double
    }
    private var outgoing: Outgoing?
    private var incoming: Incoming?
    private var completed: (id: UInt32, final: UInt32, accepted: Bool, revalidate: Data?)?
    private var rejected: [UInt32] = []
    private var retiredPeerSessions: [UInt64] = []
    private var latestIncomingTransfer: UInt32 = 0
    private struct ProgressStamp { let transfer: UInt32; let time: Double; let bucket: Int }
    private var txProgress: ProgressStamp?
    private var rxProgress: ProgressStamp?
    var transmitting: Bool { outgoing != nil }
    var receivingTransferIdentifier: UInt32 { latestIncomingTransfer }

    init(wireMagic: Data = WKReport.defaultMagic,
         nonce: @escaping () -> UInt64 = { UInt64.random(in: 1...UInt64.max) }) {
        precondition(wireMagic.count == 4)
        self.wireMagic = Data(wireMagic); self.nonce = nonce
    }

    func connected(_ value: Bool, at time: Double) {
        now = time; physical = value
        reset()
        if value { hello() }
    }

    private func reset() {
        if let tx = outgoing {
            progress(.tx, .reset, tx.id, tx.acknowledged + 1, tx.count)
            outgoing = nil; onCompletion(tx.id, false)
        }
        if let rx = incoming { progress(.rx, .reset, rx.id, Int(rx.next), nil) }
        incoming = nil; completed = nil; rejected.removeAll(); latestIncomingTransfer = 0
        txProgress = nil; rxProgress = nil
        peerSession = 0; helloAcknowledged = false; retiredPeerSessions.removeAll()
        session = nonce(); lastPeer = now; lastHello = -10; lastPing = -10
        setReady(false)
    }

    private func setReady(_ value: Bool) {
        if ready != value { ready = value; onReady(value) }
    }

    @discardableResult private func emit(_ report: WKReport) -> Bool { sendReport(report.encode(wireMagic: wireMagic)) }
    private func hello() {
        _ = emit(WKReport(kind: .hello, session: session)); lastHello = now
    }

    @discardableResult func send(_ body: Data) -> UInt32? {
        guard ready, !body.isEmpty, body.count <= Self.maximumMessage else { return nil }
        cancelOutgoing()
        let id = nextTransfer
        nextTransfer &+= 1; if nextTransfer == 0 { nextTransfer = 1 }
        let count = (body.count + WKReport.payloadSize - 1) / WKReport.payloadSize
        outgoing = Outgoing(id: id, body: body,
                            count: count,
                            lastSend: now, lastProgress: now)
        progress(.tx, .start, id, 0, count)
        fillWindow()
        return id
    }

    func cancelOutgoing() {
        guard let tx = outgoing else { return }
        progress(.tx, .cancel, tx.id, tx.acknowledged + 1, tx.count)
        outgoing = nil
        _ = emit(WKReport(kind: .abort, session: session, transfer: tx.id))
        onCompletion(tx.id, false)
    }

    func cancelIncoming() {
        guard let rx = incoming else { return }
        progress(.rx, .cancel, rx.id, Int(rx.next), nil)
        incoming = nil; rememberRejected(rx.id)
        _ = emit(WKReport(kind: .abort, session: peerSession, transfer: rx.id))
    }

    private func rememberRejected(_ id: UInt32) {
        if !rejected.contains(id) { rejected.append(id) }
        if rejected.count > 32 { rejected.removeFirst() }
    }

    private func report(_ tx: Outgoing, _ index: Int) -> WKReport {
        let start = index * WKReport.payloadSize
        let end = min(start + WKReport.payloadSize, tx.body.count)
        return WKReport(kind: .data, flags: (index == 0 ? 1 : 0) | (index == tx.count - 1 ? 2 : 0),
                        session: session, sequence: UInt32(index), transfer: tx.id,
                        payload: Data(tx.body[start..<end]))
    }

    private func fillWindow() {
        guard var tx = outgoing else { return }
        while tx.next < tx.count && tx.next <= tx.acknowledged + Self.window {
            guard emit(report(tx, tx.next)) else { break }
            tx.next += 1; tx.lastSend = now
        }
        outgoing = tx
    }

    func tick(_ time: Double) {
        now = time
        guard physical else { return }
        if now - lastPeer > 3 {
            onError("peer-timeout"); reset(); hello(); return
        }
        if !ready {
            if now - lastHello >= 0.5 { hello() }
            return
        }
        if now - lastPing >= 0.5 { _ = emit(WKReport(kind: .ping, session: session)); lastPing = now }
        if let rx = incoming, now - rx.lastProgress > 3 { cancelIncoming(); onError("receive-timeout") }
        if var tx = outgoing, now - tx.lastSend >= Self.retryInterval {
            if tx.retries >= 15 || now - tx.lastProgress > 4 {
                onError("send-timeout"); cancelOutgoing(); return
            }
            tx.retries += 1; tx.lastSend = now
            for index in (tx.acknowledged + 1)..<tx.next { _ = emit(report(tx, index)) }
            outgoing = tx
        }
        fillWindow()
    }

    func receive(_ bytes: Data, at time: Double) {
        now = time
        guard physical, let r = WKReport(bytes, wireMagic: wireMagic), r.session != 0 else { return }
        switch r.kind {
        case .hello:
            guard r.payload.isEmpty, r.flags == 0, !retiredPeerSessions.contains(r.session) else { return }
            if peerSession != 0 && peerSession != r.session {
                retiredPeerSessions.append(peerSession)
                if retiredPeerSessions.count > 64 { retiredPeerSessions.removeFirst() }
                cancelOutgoing()
                if let rx = incoming { progress(.rx, .reset, rx.id, Int(rx.next), nil) }
                incoming = nil; completed = nil; rejected.removeAll(); latestIncomingTransfer = 0
                helloAcknowledged = false; setReady(false)
            }
            peerSession = r.session; lastPeer = now
            var peer = Data(); peer.appendLE(session)
            _ = emit(WKReport(kind: .helloAck, session: r.session, payload: peer))
            if !helloAcknowledged { hello() }
            setReady(helloAcknowledged)
        case .helloAck:
            guard r.session == session, r.payload.count == 8 else { return }
            let peer: UInt64 = r.payload.readLE(at: 0)
            guard peer != 0, !retiredPeerSessions.contains(peer), peerSession == 0 || peerSession == peer else { return }
            peerSession = peer; helloAcknowledged = true; lastPeer = now; setReady(true)
        case .ping, .pong:
            guard r.session == peerSession else { return }
            lastPeer = now
            if r.kind == .ping { _ = emit(WKReport(kind: .pong, session: session)) }
        case .abort:
            if r.session == session, let tx = outgoing, tx.id == r.transfer {
                progress(.tx, .cancel, tx.id, tx.acknowledged + 1, tx.count)
                lastPeer = now; outgoing = nil; onCompletion(tx.id, false)
            } else if r.session == peerSession {
                lastPeer = now
                if let rx = incoming, rx.id == r.transfer {
                    progress(.rx, .cancel, rx.id, Int(rx.next), nil); incoming = nil
                }
                rememberRejected(r.transfer)
            }
        case .ack:
            guard ready, r.session == session, var tx = outgoing, r.transfer == tx.id,
                  r.sequence < UInt32(tx.next) else { return }
            lastPeer = now
            if r.flags & 0x80 != 0 {
                progress(.tx, .reject, tx.id, tx.acknowledged + 1, tx.count)
                outgoing = nil; onCompletion(tx.id, false); return
            }
            if Int(r.sequence) > tx.acknowledged {
                tx.acknowledged = Int(r.sequence); tx.lastProgress = now; tx.retries = 0
            }
            if tx.acknowledged == tx.count - 1 {
                progress(.tx, .complete, tx.id, tx.count, tx.count)
                outgoing = nil; onCompletion(tx.id, true)
            } else {
                progress(.tx, .progress, tx.id, tx.acknowledged + 1, tx.count)
                outgoing = tx; fillWindow()
            }
        case .data:
            guard ready, r.session == peerSession, r.transfer != 0, !r.payload.isEmpty,
                  r.flags & ~UInt8(3) == 0 else { return }
            lastPeer = now
            if var done = completed, done.id == r.transfer {
                if let body = done.revalidate { done.accepted = done.accepted && revalidateMessage(body) == true }
                completed = done
                acknowledge(r.transfer, done.final, accepted: done.accepted); return
            }
            if rejected.contains(r.transfer) {
                acknowledge(r.transfer, r.sequence, accepted: false); return
            }
            if incoming?.id != r.transfer {
                guard r.sequence == 0, r.flags & 1 != 0 else { return }
                let forward = r.transfer &- latestIncomingTransfer
                guard latestIncomingTransfer == 0 || (forward > 0 && forward < 0x8000_0000) else {
                    acknowledge(r.transfer, r.sequence, accepted: false); return
                }
                cancelIncoming()
                latestIncomingTransfer = r.transfer
                incoming = Incoming(id: r.transfer, lastProgress: now)
                progress(.rx, .start, r.transfer, 0, nil)
            }
            guard var rx = incoming else { return }
            if r.sequence != rx.next {
                if rx.next > 0 { acknowledge(rx.id, rx.next - 1, accepted: true) }
                return
            }
            guard (r.sequence == 0) == (r.flags & 1 != 0),
                  rx.body.count + r.payload.count <= Self.maximumMessage else {
                cancelIncoming(); return
            }
            // Release the stored value before append so Data can grow in place;
            // retaining two copies here would copy the full file every 40 bytes.
            incoming = nil
            rx.body.append(r.payload); rx.next += 1; rx.lastProgress = now
            if r.flags & 2 != 0 {
                incoming = nil
                let accepted = receiveMessage(rx.body)
                progress(.rx, accepted ? .complete : .reject, rx.id,
                         Int(rx.next) - (accepted ? 0 : 1), Int(rx.next))
                completed = (rx.id, r.sequence, accepted, revalidateMessage(rx.body) == nil ? nil : rx.body)
                acknowledge(rx.id, r.sequence, accepted: accepted)
            } else {
                incoming = rx
                progress(.rx, .progress, rx.id, Int(rx.next), nil)
                acknowledge(rx.id, r.sequence, accepted: true)
            }
        }
    }

    private func acknowledge(_ id: UInt32, _ seq: UInt32, accepted: Bool) {
        _ = emit(WKReport(kind: .ack, flags: accepted ? 0 : 0x80, session: peerSession,
                          sequence: seq, transfer: id))
    }

    private func progress(_ direction: WKTransferProgress.Direction, _ phase: WKTransferProgress.Phase,
                          _ id: UInt32, _ acknowledged: Int, _ total: Int?) {
        let bucket = total.map { $0 > 0 ? acknowledged * 10 / $0 : 0 } ?? 0
        let previous = direction == .tx ? txProgress : rxProgress
        if phase == .progress, let previous, previous.transfer == id,
           now - previous.time < 1, bucket <= previous.bucket { return }
        let stamp = ProgressStamp(transfer: id, time: now, bucket: bucket)
        if direction == .tx { txProgress = stamp } else { rxProgress = stamp }
        onProgress(WKTransferProgress(direction: direction, phase: phase, transfer: id,
                                      acknowledged: acknowledged, total: total))
    }
}
