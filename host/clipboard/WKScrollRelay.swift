import AppKit
import ApplicationServices
import Darwin

// Pixel scroll uses the existing opaque 64-byte USB reports, never TCP/Wi-Fi.
struct WKScrollPacket {
    enum Kind: UInt8 { case probe = 1, capability, sample }
    var kind: Kind
    var phase: UInt8 = 0, momentum: UInt8 = 0
    var session: UInt64 = 0
    var sequence: UInt32 = 0
    var vertical: Int32 = 0, horizontal: Int32 = 0
    var flags: UInt64 = 0
    var time: UInt64 = 0 // monotonic microseconds, translated by the host relay
    var origin: UInt64 = 0 // capture process incarnation; no input text
    var source: UInt8 = 0 // 1 mouse, 2 trackpad; discrete wheels retain standard HID
    var features: UInt8 = 0 // capability: 1 pixel scrolling, 2 native gestures
    static let magic = Data("WKSC".utf8)
    static func now() -> UInt64 { UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000) }
    static func nonce() -> UInt64 { UInt64.random(in: 1...UInt64.max) }
    static func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        return crc ^ UInt32.max
    }
    func encode() -> Data {
        var d = Data(repeating: 0, count: 64)
        d.replaceSubrange(0..<4, with: Self.magic); d[4] = 1; d[5] = kind.rawValue
        d[6] = phase; d[7] = momentum
        func put<T: FixedWidthInteger>(_ n: T, _ at: Int) {
            for i in 0..<MemoryLayout<T>.size { d[at+i] = UInt8(truncatingIfNeeded: n >> (i*8)) }
        }
        put(session, 8); put(sequence, 16); put(vertical, 20); put(horizontal, 24)
        put(flags, 28); put(time, 36); put(origin, 44); d[52] = source; d[53] = features
        put(Self.checksum(d.prefix(60)), 60)
        return d
    }
    init(kind: Kind, session: UInt64 = 0) { self.kind = kind; self.session = session; source = kind == .sample ? 2 : 0 }
    init?(_ d: Data) {
        guard d.count == 64, d.prefix(4) == Self.magic, d[4] == 1,
              let kind = Kind(rawValue: d[5]), d[54..<60].allSatisfy({ $0 == 0 }) else { return nil }
        func get<T: FixedWidthInteger>(_ at: Int) -> T {
            var n: T = 0
            for i in 0..<MemoryLayout<T>.size { n |= T(truncatingIfNeeded: d[at+i]) << (i*8) }
            return n
        }
        let crc: UInt32 = get(60)
        guard crc == Self.checksum(d.prefix(60)) else { return nil }
        self.kind = kind; phase = d[6]; momentum = d[7]; session = get(8)
        sequence = get(16); vertical = get(20); horizontal = get(24)
        flags = get(28); time = get(36); origin = get(44); source = d[52]; features = d[53]
        let allowedFlags: CGEventFlags = [.maskAlphaShift, .maskShift, .maskControl, .maskAlternate, .maskCommand]
        guard phase & ~UInt8(0x8f) == 0, momentum <= 3,
              abs(Int64(vertical)) <= 8192, abs(Int64(horizontal)) <= 8192,
              (kind == .capability || flags & ~allowedFlags.rawValue == 0) else { return nil }
        if kind == .sample && !(1...2).contains(source) { return nil }
        if features > 3 || (kind != .capability && features != 0) { return nil }
        if kind != .sample && (source != 0 || phase != 0 || momentum != 0 || vertical != 0 || horizontal != 0) { return nil }
        if kind == .probe && flags != 0 { return nil }
    }
}

enum WKScrollSocket {
#if WK_SCROLL_TESTS
    static var testDirectory: String?
#endif
    static var directory: String {
#if WK_SCROLL_TESTS
        if let testDirectory { return testDirectory }
#endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WiredKVM/Scroll", isDirectory: true).path
    }
    static var serverPath: String { directory + "/relay.sock" }
    static func address(_ path: String) -> sockaddr_un? {
        guard path.hasPrefix("/"), path.utf8.count < 104 else { return nil }
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &a.sun_path) { p in
            p.initializeMemory(as: UInt8.self, repeating: 0)
            path.utf8CString.withUnsafeBytes { p.copyBytes(from: $0) }
        }
        return a
    }
    static func privatePath(_ path: String, socket: Bool) -> Bool {
        var s = stat()
        return path.withCString({ lstat($0, &s) }) == 0 && s.st_uid == getuid() &&
            s.st_mode & S_IFMT == (socket ? S_IFSOCK : S_IFDIR) && s.st_mode & 0o077 == 0
    }
    static func open(_ path: String) -> Int32 {
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return -1 }
        guard privatePath(directory, socket: false), var a = address(path) else { return -1 }
        // Never replace an existing endpoint or follow a symlink.
        var st = stat()
        guard path.withCString({ lstat($0, &st) }) != 0 && errno == ENOENT else { return -1 }
        let fd = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return -1 }
        let result = withUnsafePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, chmod(path, 0o600) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(fd); if result == 0 { unlink(path) }; return -1
        }
        return fd
    }
    static func send(_ d: Data, fd: Int32, to address: inout sockaddr_un) -> Bool {
        d.withUnsafeBytes { b in
            withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, b.baseAddress, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == b.count
                }
            }
        }
    }
    static func read(_ fd: Int32) -> (Data, sockaddr_un)? {
        var bytes = [UInt8](repeating: 0, count: 2049), from = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let count = withUnsafeMutablePointer(to: &from) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &bytes, bytes.count, 0, $0, &length)
            }
        }
        guard count > 0 else { return nil }
        return (Data(bytes.prefix(count)), from)
    }
    static func path(_ a: sockaddr_un) -> String {
        var a = a
        return withUnsafeBytes(of: &a.sun_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

// Main-thread owned client; socket work is nonblocking and never waits in an EventTap.
final class WKScrollClient {
    private struct Template {
        let id: UInt32, raw: Data, definition: WKGestureEnvelope
        var acknowledged = false
        var sentAt: UInt64 = 0
    }
    private var fd: Int32 = -1
    private var path = ""
    private var peer: sockaddr_un?
    private var session: UInt64 = 0, received: UInt64 = 0, probeAt: UInt64 = 0
    private var sequence: UInt32 = 0
    private let origin = WKScrollPacket.nonce()
    private var timer: DispatchSourceTimer?
    private var features: UInt8 = 0
    private var gestureActive = false
    private var gestureAliveAt: UInt64 = 0
    private var templates: [UInt8: Template] = [:]
    var ready: Bool { session != 0 && WKScrollPacket.now() &- received < 300_000 }
    var gesturesReady: Bool { ready && features & 2 != 0 }
    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.tick() }; timer.resume(); self.timer = timer
    }
    func stop() {
        cancel(); timer?.cancel(); timer = nil
        if fd >= 0 { Darwin.close(fd); fd = -1; unlink(path) }
        session = 0; peer = nil; features = 0; gestureActive = false; templates.removeAll()
    }
    deinit { stop() }
    private func tick() {
        if fd < 0 {
            path = WKScrollSocket.directory + "/c-\(getpid())-\(WKScrollPacket.nonce()).sock"
            fd = WKScrollSocket.open(path)
        }
        guard fd >= 0 else { return }
        for _ in 0..<16 {
            guard let (d, from) = WKScrollSocket.read(fd) else { break }
            guard WKScrollSocket.path(from) == WKScrollSocket.serverPath,
                  let p = WKScrollPacket(d), p.kind == .capability else { continue }
            if session != p.session {
                for key in Array(templates.keys) { templates[key]?.acknowledged = false; templates[key]?.sentAt = 0 }
            }
            if p.origin == origin {
                let acks: [(UInt8, UInt32)] = [(29, UInt32(truncatingIfNeeded: p.flags)), (30, UInt32(truncatingIfNeeded: p.flags >> 32))]
                for (type, id) in acks where templates[type]?.id == id { templates[type]?.acknowledged = true }
            } else {
                for key in Array(templates.keys) { templates[key]?.acknowledged = false }
            }
            session = p.session; features = p.features; received = WKScrollPacket.now()
        }
        let now = WKScrollPacket.now()
        if now &- probeAt >= 100_000 {
            probeAt = now
            guard WKScrollSocket.privatePath(WKScrollSocket.serverPath, socket: true),
                  var address = WKScrollSocket.address(WKScrollSocket.serverPath) else { session = 0; return }
            peer = address
            var p = WKScrollPacket(kind: .probe); p.time = now
            _ = WKScrollSocket.send(p.encode(), fd: fd, to: &address)
        }
        if gestureActive && gesturesReady && now &- gestureAliveAt >= 100_000 {
            gestureAliveAt = now; sendGestureControl(3)
        }
    }
    @discardableResult func forward(_ event: CGEvent, source: UInt8 = 2) -> Bool {
        guard ready, (1...2).contains(source) else { return false }
        var p = WKScrollPacket(kind: .sample, session: session)
        p.source = source
        p.vertical = Int32(clamping: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        p.horizontal = Int32(clamping: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        p.phase = UInt8(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventScrollPhase))
        p.momentum = UInt8(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventMomentumPhase))
        p.flags = event.flags.intersection([.maskAlphaShift, .maskShift, .maskControl, .maskAlternate, .maskCommand]).rawValue
        return send(&p)
    }
    private func send(_ p: inout WKScrollPacket) -> Bool {
        guard fd >= 0, var address = peer else { return false }
        sequence &+= 1; p.sequence = sequence; p.time = WKScrollPacket.now(); p.origin = origin
        guard WKScrollPacket(p.encode()) != nil else { return false }
        return WKScrollSocket.send(p.encode(), fd: fd, to: &address)
    }
    func cancel() {
        gestureActive = false
        if gesturesReady { sendGestureControl(2) }
        guard ready else { return }
        var p = WKScrollPacket(kind: .sample, session: session); p.phase = 8; p.momentum = 3
        _ = send(&p)
    }
    private func sendGestureControl(_ kind: UInt8) {
        guard fd >= 0, var address = peer else { return }
        sequence &+= 1
        let envelope = WKGestureEnvelope(control: kind, origin: origin, sequence: sequence, time: WKScrollPacket.now())
        _ = WKScrollSocket.send(envelope.local(session: session), fd: fd, to: &address)
    }
    @discardableResult func forwardGesture(_ event: CGEvent, source: UInt8) -> Bool {
        guard gesturesReady, fd >= 0, var address = peer, (1...2).contains(source) else { return false }
        let phase = event.getIntegerValueField(CGEventField(rawValue: 132)!)
        let subtype = WKGestureEnvelope.subtype(event)
        if event.type.rawValue == 20 || subtype == 62 || phase & 12 != 0 || (phase == 0 && (subtype == 16 || subtype == 22 || event.type.rawValue == 31)) { gestureActive = false }
        else if subtype != 0 || event.type.rawValue != 29 { gestureActive = true }
        let now = WKScrollPacket.now()
        guard var envelope = WKGestureEnvelope(event: event, origin: origin, sequence: 0, time: now) else { return false }
        envelope.source = source
        let type = envelope.eventType
        if [29, 30].contains(type) {
            if templates[type] == nil, let raw = envelope.raw() {
                var id = UInt32.random(in: 1...UInt32.max)
                while templates.values.contains(where: { $0.id == id }) { id = UInt32.random(in: 1...UInt32.max) }
                if let definition = envelope.template(id: id) { templates[type] = Template(id: id, raw: raw, definition: definition) }
            }
            if var template = templates[type] {
                if !template.acknowledged && now &- template.sentAt >= 100_000 {
                    sequence &+= 1; var definition = template.definition
                    definition.sequence = sequence; definition.time = now
                    if WKScrollSocket.send(definition.local(session: session), fd: fd, to: &address) { template.sentAt = now }
                    templates[type] = template
                }
                if template.acknowledged, let delta = envelope.delta(base: template.raw, id: template.id) { envelope = delta }
            }
        }
        sequence &+= 1; envelope.sequence = sequence
        return WKScrollSocket.send(envelope.local(session: session), fd: fd, to: &address)
    }
}

// Existing host companion multiplexes private local scroll into its wired USB
// transport. Capabilities come from mini, not from a network or a local guess.
final class WKScrollHost {
    private var fd: Int32 = -1
    private var lockFD: Int32 = -1
    private var capability: WKScrollPacket?
    private var received: UInt64 = 0
    var ready: Bool { capability?.session != nil && capability?.session != 0 && WKScrollPacket.now() &- received < 300_000 }
    var peerGesturesSubmitted: UInt32 { capability?.sequence ?? 0 }
    var sendReport: (Data) -> Bool = { _ in false }
    func start() {
        guard fd < 0 else { return }
        do {
            try FileManager.default.createDirectory(atPath: WKScrollSocket.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return }
        guard WKScrollSocket.privatePath(WKScrollSocket.directory, socket: false) else { return }
        let lock = Darwin.open(WKScrollSocket.directory + "/relay.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { return }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lock); return
        }
        if WKScrollSocket.privatePath(WKScrollSocket.serverPath, socket: true) { unlink(WKScrollSocket.serverPath) }
        fd = WKScrollSocket.open(WKScrollSocket.serverPath)
        if fd >= 0 { lockFD = lock } else { Darwin.close(lock) }
    }
    func stop() {
        if fd >= 0 { Darwin.close(fd); fd = -1; unlink(WKScrollSocket.serverPath) }
        if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }
        capability = nil
    }
    deinit { stop() }
    func receive(_ data: Data) -> Bool {
        guard data.prefix(4) == WKScrollPacket.magic else { return false }
        if let p = WKScrollPacket(data), p.kind == .capability {
            capability = p; received = WKScrollPacket.now()
        }
        return true
    }
    func disconnected() { capability = nil }
    func tick() {
        guard fd >= 0 else { return }
        let now = WKScrollPacket.now()
        let active = capability.flatMap { now &- received < 300_000 && $0.session != 0 ? $0 : nil }
        for _ in 0..<32 {
            guard let (data, from) = WKScrollSocket.read(fd) else { break }
            let client = WKScrollSocket.path(from)
            guard client.hasPrefix(WKScrollSocket.directory + "/c-"),
                  WKScrollSocket.privatePath(client, socket: true) else { continue }
            if let (session, envelope) = WKGestureEnvelope.local(data) {
                guard let cap = active, cap.features & 2 != 0, session == cap.session,
                      now >= envelope.time, now - envelope.time < 50_000 else { continue }
                var forwarded = envelope; forwarded.time = cap.time &+ (now &- received)
                for report in forwarded.reports(session: session) { if !sendReport(report) { break } }
                continue
            }
            guard let p = WKScrollPacket(data) else { continue }
            if p.kind == .probe {
                var reply = WKScrollPacket(kind: .capability, session: active?.session ?? 0)
                reply.features = active?.features ?? 0
                reply.origin = active?.origin ?? 0
                reply.flags = active?.flags ?? 0
                reply.sequence = active?.sequence ?? 0
                reply.time = now; var address = from
                _ = WKScrollSocket.send(reply.encode(), fd: fd, to: &address)
            } else if p.kind == .sample, let cap = active, p.session == cap.session,
                      now >= p.time, now - p.time < 50_000 {
                var forwarded = p
                forwarded.time = cap.time &+ (now &- received)
                _ = sendReport(forwarded.encode())
            }
        }
    }
}

final class WKScrollReceiver {
    private(set) var session = WKScrollPacket.nonce()
    private var sequence: UInt32?
    private var origin: UInt64 = 0
    private var retiredOrigins: [UInt64] = []
    private var connected = false
    private var advertised: UInt64 = 0
    var access: () -> Bool = { CGPreflightPostEventAccess() }
    static func event(from p: WKScrollPacket) -> CGEvent? {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: p.vertical, wheel2: p.horizontal, wheel3: 0) else { return nil }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(p.phase))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(p.momentum))
        event.setIntegerValueField(.eventSourceUserData, value: 0x574b5343)
        event.flags = CGEventFlags(rawValue: p.flags)
        return event
    }
    var post: (WKScrollPacket) -> Void = { p in event(from: p)?.post(tap: .cghidEventTap) }
    var onScroll: () -> Void = {}
    var gesturesSupported = false
    var gestureCount: () -> UInt32 = { 0 }
    var gestureTemplateAcks: () -> (UInt64, UInt32, UInt32) = { (0, 0, 0) }
    func connection(_ value: Bool) {
        connected = value; session = WKScrollPacket.nonce(); sequence = nil; advertised = 0
        origin = 0; retiredOrigins.removeAll()
    }
    func tick(now: UInt64 = WKScrollPacket.now(), send: (Data) -> Bool) {
        guard connected, now &- advertised >= 100_000 else { return }
        var p = WKScrollPacket(kind: .capability, session: access() ? session : 0)
        p.features = access() ? (gesturesSupported ? 3 : 1) : 0
        p.sequence = gestureCount()
        let acks = gestureTemplateAcks(); p.origin = acks.0
        p.flags = UInt64(acks.1) | (UInt64(acks.2) << 32)
        p.time = now
        if send(p.encode()) { advertised = now }
    }
    func receive(_ data: Data, now: UInt64 = WKScrollPacket.now()) -> Bool {
        guard data.prefix(4) == WKScrollPacket.magic else { return false }
        guard connected, access(), let p = WKScrollPacket(data), p.kind == .sample,
              p.session == session, p.origin != 0, p.time <= now &+ 50_000,
              (p.time > now || now - p.time < 150_000) else { return true }
        if p.origin != origin {
            guard !retiredOrigins.contains(p.origin) else { return true }
            if origin != 0 { retiredOrigins.append(origin); if retiredOrigins.count > 8 { retiredOrigins.removeFirst() } }
            origin = p.origin; sequence = nil
        }
        if let previous = sequence {
            let delta = p.sequence &- previous
            guard delta > 0 && delta < 0x8000_0000 else { return true }
        }
        sequence = p.sequence; onScroll(); post(p); return true
    }
}
