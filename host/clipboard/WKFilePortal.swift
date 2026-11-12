import Foundation
import CFNetwork
import CryptoKit
import Darwin

// Fixed counters only. No request URL, capability, filename or clipboard data
// leaves the file server. A successful GET is not a Finder destination commit.
final class WKPortalCounters: @unchecked Sendable {
    enum Event: Int { case metadata, missing, waiting, served, failed, malformed, capacity, proxy }
    static let count = 8
    private let lock = NSLock()
    private var values = [UInt32](repeating: 0, count: 8)
    func record(_ event: Event) {
        lock.lock(); values[event.rawValue] &+= 1; lock.unlock()
    }
    func snapshot() -> [UInt32] { lock.lock(); defer { lock.unlock() }; return values }
}

enum WKFilePortalError: Error, CustomStringConvertible {
    case unavailable, stopped, invalidOffer, capacity, integrity, failed, timeout, proxy, accessDenied, system(Int32), mount
    var description: String {
        switch self {
        case .unavailable: return "file-portal-unavailable"
        case .stopped: return "file-portal-stopped"
        case .invalidOffer: return "file-portal-invalid-offer"
        case .capacity: return "file-portal-capacity"
        case .integrity: return "file-portal-integrity"
        case .failed: return "file-portal-failed"
        case .timeout: return "file-portal-timeout"
        case .proxy: return "file-portal-requires-direct-loopback"
        case .accessDenied: return "file-portal-access-denied"
        case .system(let code): return "file-portal-system-\(code)"
        case .mount: return "file-portal-mount-failed"
        }
    }
}

// Immutable snapshots outlive clipboard replacement. Only explicitly retired,
// completed/failed entries older than ten minutes without GET leases are reclaimed.
final class WKPortalStore: @unchecked Sendable {
    enum Payload {
        case memory(Data), file(WKReceivedFile), receiving(WKReceivingFile)
        func read(offset: Int, maximum: Int, cancelled: () -> Bool = { false }) throws -> Data {
            switch self {
            case .memory(let data): return data.subdata(in: offset..<min(data.count, offset + maximum))
            case .file(let file): return try file.read(offset: UInt64(offset), maximum: maximum)
            case .receiving(let file): return try file.read(offset: UInt64(offset), maximum: maximum, cancelled: cancelled)
            }
        }
    }
    struct Metadata: Equatable, Sendable {
        let id: String, name: String, size: Int, sha256: String
        let created: Date
        static func == (left: Self, right: Self) -> Bool {
            left.id == right.id && left.name == right.name && left.size == right.size && left.sha256 == right.sha256
        }
    }
    private struct Entry {
        let metadata: Metadata
        var data: Data?
        var file: WKReceivedFile?
        var receiving: WKReceivingFile?
        var streaming = false
        var failed = false
        var retired: Date?
        var leases = 0
#if WK_TREE
        var tree: WKTreeManifest?
#endif
    }
    private let condition = NSCondition()
    private var entries: [String: Entry] = [:]
    private var stopped = false
    private let now: () -> Date
    static let maximumItems = 64
    static let maximumPending = 8
    static let maximumSize = 1024 * 1024
    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func offer(id: String, name: String, size: Int, sha256: String, streaming: Bool = false) throws -> Metadata {
        guard id.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil,
              !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !name.contains("/"), !name.contains("\\"), (0...(streaming ? Int(WKStreamOffer.maximumSize) : Self.maximumSize)).contains(size),
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw WKFilePortalError.invalidOffer
        }
        if !streaming && size == 0 && sha256 != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" {
            throw WKFilePortalError.invalidOffer
        }
        let metadata = Metadata(id: id, name: name, size: size, sha256: sha256, created: now())
        condition.lock(); defer { condition.unlock() }
        guard !stopped else { throw WKFilePortalError.stopped }
        if let previous = entries[id] {
            guard previous.metadata == metadata, previous.streaming == streaming, !previous.failed else { throw WKFilePortalError.invalidOffer }
            return previous.metadata
        }
        let expiry = now().addingTimeInterval(-600)
        entries = entries.filter { _, entry in
            !(entry.leases == 0 && (entry.data != nil || entry.file != nil || entry.failed) && entry.retired.map { $0 <= expiry } == true)
        }
        guard entries.count < Self.maximumItems,
              entries.values.filter({ $0.data == nil && $0.file == nil && !$0.failed }).count < Self.maximumPending else { throw WKFilePortalError.capacity }
        entries[id] = Entry(metadata: metadata, data: size == 0 && !streaming ? Data() : nil, streaming: streaming)
        return metadata
    }

    func metadata(_ id: String) -> Metadata? {
        condition.lock(); defer { condition.unlock() }
        return !stopped ? entries[id]?.metadata : nil
    }
#if WK_TREE
    func offerTree(id: String, manifest: WKTreeManifest, sha256: String) throws {
        _ = try offer(id: id, name: "WiredKVM Selection", size: Int(manifest.size), sha256: sha256, streaming: true)
        condition.lock(); defer { condition.unlock() }
        guard !stopped, entries[id]?.tree == nil else { throw WKFilePortalError.invalidOffer }
        entries[id]?.tree = manifest
    }
    func tree(_ id: String) -> WKTreeManifest? {
        condition.lock(); defer { condition.unlock() }; return !stopped ? entries[id]?.tree : nil
    }
#endif
    func allMetadata() -> [Metadata] {
        condition.lock(); defer { condition.unlock() }
        return !stopped ? entries.values.map(\.metadata).sorted { $0.id < $1.id } : []
    }
    func fulfill(id: String, data: Data) throws {
        guard let metadata = metadata(id) else { throw WKFilePortalError.unavailable }
        guard data.count == metadata.size,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == metadata.sha256 else {
            fail(id: id); throw WKFilePortalError.integrity
        }
        condition.lock(); defer { condition.unlock() }
        guard !stopped, var entry = entries[id], !entry.failed else { throw WKFilePortalError.failed }
        entry.data = data; entries[id] = entry
        condition.broadcast()
    }
    func fail(id: String) {
        condition.lock(); defer { condition.unlock() }
        guard var entry = entries[id], entry.data == nil, entry.file == nil else { return }
        entry.failed = true; entry.receiving?.fail(); entries[id] = entry; condition.broadcast()
    }
    func retire(id: String) {
        condition.lock(); defer { condition.unlock() }
        guard var entry = entries[id] else { return }
        if entry.retired == nil { entry.retired = now(); entries[id] = entry }
    }
    func acquire(id: String) throws {
        condition.lock(); defer { condition.unlock() }
        guard !stopped, var entry = entries[id] else { throw WKFilePortalError.unavailable }
        entry.leases += 1; entries[id] = entry
    }
    func release(id: String) {
        condition.lock(); defer { condition.unlock() }
        guard var entry = entries[id] else { return }
        entry.leases = max(0, entry.leases - 1); entries[id] = entry
    }
    func stop() {
        condition.lock(); stopped = true; entries.values.forEach { $0.receiving?.fail() }; entries.removeAll(); condition.broadcast(); condition.unlock()
    }
    func beginReceiving(id: String, file: WKReceivingFile) throws {
        condition.lock(); defer { condition.unlock() }
        guard !stopped, var entry = entries[id], entry.streaming, !entry.failed,
              file.size == UInt64(entry.metadata.size) else { throw WKFilePortalError.invalidOffer }
        if entry.file != nil { return }
        guard entry.receiving == nil else { throw WKFilePortalError.invalidOffer }
        entry.receiving = file; entries[id] = entry; condition.broadcast()
    }
    func fulfill(id: String, file: WKReceivedFile) throws {
        condition.lock(); defer { condition.unlock() }
        guard !stopped, var entry = entries[id], entry.streaming, !entry.failed,
              file.size == UInt64(entry.metadata.size) else { throw WKFilePortalError.integrity }
        entry.file = file; entries[id] = entry; condition.broadcast()
    }
    // Only HTTP workers call this. No UI, pasteboard, or HID queue waits here.
    func wait(id: String, timeout: TimeInterval, cancelled: () -> Bool) throws -> Data {
        let payload = try waitPayload(id: id, timeout: timeout, cancelled: cancelled)
        guard case .memory(let data) = payload else { throw WKFilePortalError.capacity }; return data
    }
    func waitPayload(id: String, timeout: TimeInterval, cancelled: () -> Bool) throws -> Payload {
        let end = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while true {
            guard !stopped else { throw WKFilePortalError.stopped }
            guard let entry = entries[id], !entry.failed else { throw WKFilePortalError.failed }
            if let data = entry.data { return .memory(data) }
            if let file = entry.file { return .file(file) }
            if let receiving = entry.receiving { return .receiving(receiving) }
            // CH32 streaming uses the file engine's 60s inactivity deadline;
            // an actively arriving large file must not expire after 120s total.
            let deadline = entry.streaming ? entry.metadata.created.addingTimeInterval(86400) : end
            guard Date() < deadline else { throw WKFilePortalError.timeout }
            condition.unlock(); let isCancelled = cancelled(); condition.lock()
            guard !isCancelled else { throw WKFilePortalError.stopped }
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.25)))
        }
    }
}

enum WKPortalProxy {
    // Never execute a PAC script with a capability URL. Refuse automatic proxy
    // configuration, even when a current exception might bypass that script.
    // This never changes global proxies. The system WebDAV client is outside
    // this process: preflight plus periodic checks cannot atomically prevent
    // its requests racing a user-initiated proxy change. Validate that boundary
    // on supported macOS releases before claiming a strict no-proxy guarantee.
    static func direct(_ url: URL) -> Bool {
        guard url.host == "127.0.0.1", let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else { return false }
        let dictionary = settings as NSDictionary
        for key in [kCFNetworkProxiesProxyAutoConfigEnable, kCFNetworkProxiesProxyAutoDiscoveryEnable] {
            if (dictionary[key] as? NSNumber)?.boolValue == true { return false }
        }
        if dictionary[kCFNetworkProxiesProxyAutoConfigJavaScript] != nil { return false }
        let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as NSArray
        guard proxies.count == 1, let proxy = proxies.firstObject as? NSDictionary,
              let type = proxy[kCFProxyTypeKey] as? String else { return false }
        return type == kCFProxyTypeNone as String
    }
}

private final class WKPortalConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    // shutdown interrupts blocking calls; only the owning worker closes the fd,
    // avoiding accidental use of a recycled descriptor during stop().
    func interrupt() { lock.lock(); if descriptor >= 0 { _ = shutdown(descriptor, SHUT_RDWR) }; lock.unlock() }
    func finish() { lock.lock(); if descriptor >= 0 { _ = Darwin.close(descriptor); descriptor = -1 }; lock.unlock() }
}

final class WKPortalHTTPServer: @unchecked Sendable {
    let counters = WKPortalCounters()
    private let store: WKPortalStore
    private let state = NSLock()
    private let acceptQueue = DispatchQueue(label: "WiredKVM.portal.accept")
    private let workers = DispatchQueue(label: "WiredKVM.portal.http", qos: .utility, attributes: .concurrent)
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private var proxyTimer: DispatchSourceTimer?
    private var connections: [UUID: WKPortalConnection] = [:]
    private var stopped = false
    private(set) var url: URL!
    private(set) var capability = ""
    private(set) var port: UInt16 = 0
    private let waitTimeout: TimeInterval
    private let proxyCheck: (URL) -> Bool
    var onProxyFailure: (() -> Void)?

    var isAvailable: Bool {
        state.lock(); defer { state.unlock() }
        return !stopped && listener >= 0 && source != nil
    }

    init(store: WKPortalStore, waitTimeout: TimeInterval = 120, proxyCheck: @escaping (URL) -> Bool = WKPortalProxy.direct) {
        self.store = store; self.waitTimeout = waitTimeout; self.proxyCheck = proxyCheck
    }
    func start() throws {
        state.lock(); let canStart = listener < 0 && source == nil && !stopped; state.unlock()
        guard canStart else { throw WKFilePortalError.unavailable }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WKFilePortalError.system(errno) }
        var owned = true
        defer { if owned { _ = Darwin.close(fd) } }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw WKFilePortalError.system(errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 8) == 0 else { throw WKFilePortalError.system(errno) }
        var count = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &count) } }) == 0 else { throw WKFilePortalError.system(errno) }
        var random = [UInt8](repeating: 0, count: 24)
        random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        capability = random.map { String(format: "%02x", $0) }.joined()
        port = UInt16(bigEndian: address.sin_port)
        url = URL(string: "http://127.0.0.1:\(port)/\(capability)/")!
        guard proxyCheck(url) else { throw WKFilePortalError.proxy }
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        reader.setEventHandler { [weak self] in self?.acceptAvailable(fd) }
        reader.setCancelHandler { _ = Darwin.close(fd) }
        state.lock(); listener = fd; source = reader; state.unlock()
        owned = false; reader.resume()
        let timer = DispatchSource.makeTimerSource(queue: acceptQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.proxyCheck(self.url) else { return }
            self.stop(); self.store.stop(); self.onProxyFailure?()
        }
        state.lock(); proxyTimer = timer; state.unlock(); timer.resume()
    }
    func stop() {
        state.lock()
        stopped = true
        let reader = source; source = nil; listener = -1
        let timer = proxyTimer; proxyTimer = nil
        let active = Array(connections.values)
        state.unlock()
        timer?.cancel(); reader?.cancel()
        active.forEach { $0.interrupt() }
    }
    private func acceptAvailable(_ fd: Int32) {
        for _ in 0..<8 {
            state.lock(); let isStopped = stopped; state.unlock()
            if isStopped { return }
            var peer = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) } }
            if client < 0 { return }
            var enabled: Int32 = 1; var timeout = timeval(tv_sec: 5, tv_usec: 0)
            let configured = fcntl(client, F_SETFL, 0) == 0 && fcntl(client, F_SETFD, FD_CLOEXEC) == 0 &&
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 &&
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 &&
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
            let id = UUID(), connection = WKPortalConnection(client)
            state.lock()
            let atCapacity = connections.count >= 8
            let accepted = !stopped && configured && peer.sin_addr.s_addr == inet_addr("127.0.0.1") && !atCapacity
            if accepted { connections[id] = connection }
            state.unlock()
            guard accepted else { if atCapacity { counters.record(.capacity) }; connection.finish(); continue }
            workers.async { [self] in
                defer { connection.finish(); state.lock(); connections.removeValue(forKey: id); state.unlock() }
                handle(client)
            }
        }
    }

    private struct Request { let method: String, target: String, headers: [String: String] }
    private func request(_ fd: Int32) -> Request? {
        var buffer = Data(), scratch = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        let marker = Data("\r\n\r\n".utf8)
        while buffer.range(of: marker) == nil {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let count = recv(fd, &scratch, scratch.count, 0)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: scratch.prefix(count))
            guard buffer.count <= 16384 else { return nil }
        }
        guard let end = buffer.range(of: marker), let text = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, lines[0].utf8.count <= 2048,
              ["HTTP/1.1", "HTTP/1.0"].contains(String(first[2])) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).lowercased()
            guard name.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil, headers[name] == nil else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
            headers[name] = value
        }
        guard headers["host"] == "127.0.0.1:\(port)", headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"), (0...16384).contains(length),
              first[0] == "PROPFIND" || length == 0 else { return nil }
        var remaining = length - buffer.distance(from: end.upperBound, to: buffer.endIndex)
        while remaining > 0 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let count = recv(fd, &scratch, min(remaining, scratch.count), 0)
            guard count > 0 else { return nil }; remaining -= count
        }
        return Request(method: String(first[0]), target: String(first[1]), headers: headers)
    }
    private enum Resource {
        case root, directory(WKPortalStore.Metadata), file(WKPortalStore.Metadata)
#if WK_TREE
        case tree(WKPortalStore.Metadata, WKTreeManifest.Entry)
#endif
    }
    private func resource(_ target: String) -> Resource? {
        guard target.hasPrefix("/"), !target.contains("?"), !target.contains("#"),
              let decoded = target.removingPercentEncoding, !decoded.contains("\\"), !decoded.contains("\0") else { return nil }
        var pieces = decoded.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard pieces.first == "", pieces.count >= 2, pieces[1] == capability else { return nil }
        pieces.removeFirst(2)
        if pieces.last == "" { pieces.removeLast() }
        guard !pieces.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else { return nil }
        if pieces.isEmpty { return .root }
        guard let metadata = store.metadata(pieces[0]) else { return nil }
        if pieces.count == 1 { return .directory(metadata) }
#if WK_TREE
        if let tree = store.tree(metadata.id) {
            guard let entry = tree.byPath[pieces.dropFirst().joined(separator: "/")], entry.directory || !decoded.hasSuffix("/") else { return nil }
            return .tree(metadata, entry)
        }
#endif
        if pieces.count == 2 && pieces[1] == metadata.name && !decoded.hasSuffix("/") { return .file(metadata) }
        return nil
    }
    private func send(_ fd: Int32, _ bytes: Data) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        return bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
                let count = Darwin.send(fd, base.advanced(by: offset), min(65536, bytes.count - offset), 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }; offset += count
            }
            return true
        }
    }
    @discardableResult private func header(_ fd: Int32, _ status: Int, length: Int = 0, type: String = "application/octet-stream", extra: [String: String] = [:]) -> Bool {
        let reasons = [200: "OK", 206: "Partial Content", 207: "Multi-Status", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 416: "Range Not Satisfiable", 503: "Service Unavailable"]
        var text = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Length: \(length)\r\nContent-Type: \(type)\r\nConnection: close\r\n"
        for key in extra.keys.sorted() { text += "\(key): \(extra[key]!)\r\n" }
        return send(fd, Data((text + "\r\n").utf8))
    }
    private func disconnected(_ fd: Int32) -> Bool {
        state.lock(); let isStopped = stopped; state.unlock()
        if isStopped { return true }
        var byte: UInt8 = 0
        let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
    }
    private func handle(_ fd: Int32) {
        guard proxyCheck(url) else { counters.record(.proxy); header(fd, 503); return }
        guard let request = request(fd) else { counters.record(.malformed); header(fd, 400); return }
        guard let item = resource(request.target) else { counters.record(.missing); header(fd, 404); return }
        switch request.method {
        case "OPTIONS": header(fd, 200, extra: ["DAV": "1", "Allow": "OPTIONS, HEAD, PROPFIND, GET", "MS-Author-Via": "DAV"])
        case "PROPFIND":
            guard let depth = request.headers["depth"], ["0", "1"].contains(depth) else { header(fd, 403); return }
            counters.record(.metadata)
            let body = properties(item, descendants: depth == "1")
            if header(fd, 207, length: body.count, type: "application/xml; charset=utf-8") { _ = send(fd, body) }
        case "HEAD", "GET":
            let metadata: WKPortalStore.Metadata, contentSize: Int, baseOffset: Int, etag: String
            switch item {
            case .file(let m): metadata = m; contentSize = m.size; baseOffset = 0; etag = m.sha256
#if WK_TREE
            case .tree(let m, let entry) where !entry.directory:
                metadata = m; contentSize = Int(entry.size); baseOffset = Int(entry.offset)
                etag = WKMessage.digest(Data((m.sha256 + ":" + entry.path).utf8))
#endif
            default: header(fd, 405); return
            }
            // Pin before responding: clipboard retirement must not remove a file
            // while Finder is waiting for data or sending its final bytes.
            do { try store.acquire(id: metadata.id) } catch { counters.record(.missing); header(fd, 404); return }
            defer { store.release(id: metadata.id) }
            guard let range = Self.range(request.headers["range"], size: contentSize) else {
                header(fd, 416, extra: ["Content-Range": "bytes */\(contentSize)"]); return
            }
            var extra = ["Accept-Ranges": "bytes", "ETag": "\"\(etag)\""]
            if range.partial { extra["Content-Range"] = "bytes \(range.start)-\(range.end - 1)/\(contentSize)" }
            if request.method == "HEAD" {
                counters.record(.metadata)
                header(fd, range.partial ? 206 : 200, length: range.end - range.start, extra: extra)
                return
            }
            counters.record(.waiting)
            var served = false
            var announced = false
            defer {
                if announced && !served {
                    // macOS WebDAV may treat a clean EOF in a short 200 body
                    // as a completed cached file and zero-fill the remainder.
                    // An interrupted announced body must fail at TCP level.
                    var reset = linger(l_onoff: 1, l_linger: 0)
                    _ = setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
                }
                counters.record(served ? .served : .failed)
            }
            do {
                let data = try store.waitPayload(id: metadata.id, timeout: waitTimeout, cancelled: { self.disconnected(fd) })
                guard proxyCheck(url), !disconnected(fd) else { return }
                // The normal path waits for the entire verified file. The
                // opt-in reader exposes checksummed, written prefixes and
                // withholds the tail until whole-file verification. Obtain
                // actual bytes before headers; never substitute zero content.
                let first = try data.read(offset: baseOffset + range.start, maximum: min(65536, range.end - range.start), cancelled: { self.disconnected(fd) })
                guard range.start == range.end || !first.isEmpty else { return }
                guard header(fd, range.partial ? 206 : 200, length: range.end - range.start, extra: extra) else { return }
                announced = true
                guard first.isEmpty || send(fd, first) else { return }
                var offset = range.start + first.count
                while offset < range.end {
                    let part = try data.read(offset: baseOffset + offset, maximum: min(65536, range.end - offset), cancelled: { self.disconnected(fd) })
                    guard !part.isEmpty, send(fd, part) else { return }; offset += part.count
                }
                served = true
            } catch { if !announced && !disconnected(fd) { header(fd, 503) } }
        default: header(fd, 405, extra: ["Allow": "OPTIONS, HEAD, PROPFIND, GET"])
        }
    }
    static func range(_ value: String?, size: Int) -> (start: Int, end: Int, partial: Bool)? {
        guard let value else { return (0, size, false) }
        guard size > 0, value.hasPrefix("bytes="), !value.contains(",") else { return nil }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        func number(_ text: Substring) -> Int? {
            guard !text.isEmpty, text.count <= 20, text.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            return Int(text)
        }
        if parts[0].isEmpty {
            guard let count = number(parts[1]), count > 0 else { return nil }
            return (max(0, size - min(size, count)), size, true)
        }
        guard let start = number(parts[0]), start < size else { return nil }
        if parts[1].isEmpty { return (start, size, true) }
        guard let end = number(parts[1]), end >= start else { return nil }
        return (start, min(size - 1, end) + 1, true)
    }
    private func properties(_ item: Resource, descendants: Bool) -> Data {
        var items = [item]
        if descendants {
            switch item {
            case .root: items += store.allMetadata().map { .directory($0) }
            case .directory(let metadata):
#if WK_TREE
                if let tree = store.tree(metadata.id) { items += tree.roots.map { .tree(metadata, $0) } }
                else { items.append(.file(metadata)) }
#else
                items.append(.file(metadata))
#endif
#if WK_TREE
            case .tree(let metadata, let entry):
                if entry.directory, let children = store.tree(metadata.id)?.children[entry.path] { items += children.map { .tree(metadata, $0) } }
#endif
            case .file: break
            }
        }
        func xml(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;") }
        func escaped(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))! }
        var body = "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">"
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX"); dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let iso = ISO8601DateFormatter()
        for item in items {
            let path: String, name: String, size: Int, collection: Bool, etag: String, created: Date
            switch item {
            case .root: path = "/\(capability)/"; name = "WiredKVM"; size = 0; collection = true; etag = "root"; created = Date()
            case .directory(let value): path = "/\(capability)/\(value.id)/"; name = value.id; size = 0; collection = true; etag = value.id; created = value.created
            case .file(let value): path = "/\(capability)/\(value.id)/\(escaped(value.name))"; name = value.name; size = value.size; collection = false; etag = value.sha256; created = value.created
#if WK_TREE
            case .tree(let value, let entry):
                path = "/\(capability)/\(value.id)/" + entry.path.split(separator: "/").map { escaped(String($0)) }.joined(separator: "/") + (entry.directory ? "/" : "")
                name = String(entry.path.split(separator: "/").last!); size = Int(entry.size); collection = entry.directory
                etag = WKMessage.digest(Data((value.sha256 + ":" + entry.path).utf8)); created = value.created
#endif
            }
            body += "<D:response><D:href>\(xml(path))</D:href><D:propstat><D:prop><D:displayname>\(xml(name))</D:displayname><D:resourcetype>\(collection ? "<D:collection/>" : "")</D:resourcetype><D:getcontentlength>\(size)</D:getcontentlength><D:getcontenttype>\(collection ? "httpd/unix-directory" : "application/octet-stream")</D:getcontenttype><D:getetag>&quot;\(xml(etag))&quot;</D:getetag><D:getlastmodified>\(dateFormatter.string(from: created))</D:getlastmodified><D:creationdate>\(iso.string(from: created))</D:creationdate><D:supportedlock/><D:lockdiscovery/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
        }
        body += "</D:multistatus>"
        return Data(body.utf8)
    }
}

// Completion closures are transferred to and invoked only on the main queue.
// Boxing keeps the existing non-@Sendable public callback signatures usable.
private final class WKPortalCallback<Value>: @unchecked Sendable {
    let body: (Value) -> Void
    init(_ body: @escaping (Value) -> Void) { self.body = body }
}

final class WKFilePortal: @unchecked Sendable {
    private let state = NSLock()
    private let lifecycle = DispatchQueue(label: "WiredKVM.portal.lifecycle", qos: .utility)
    private var generation: UUID?
    private var mounted: URL?
    private var store: WKPortalStore?
    private var server: WKPortalHTTPServer?
    private var ownedDirectory: URL?

    var diagnosticCounts: [UInt32]? {
        state.lock(); let current = server; state.unlock()
        return current?.counters.snapshot()
    }

    // No filesystem reads: a paste-readiness check must never block on WebDAV.
    var isAvailable: Bool {
        state.lock(); defer { state.unlock() }
        return generation != nil && mounted != nil && server?.isAvailable == true
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        let callback = WKPortalCallback(completion)
        let token = UUID()
        state.lock()
        guard generation == nil else { state.unlock(); DispatchQueue.main.async { callback.body(.failure(WKFilePortalError.unavailable)) }; return }
        generation = token; state.unlock()
        lifecycle.async { [self] in
            var result: Result<Void, Error>
            do {
                let directory = try createDirectory(token)
                let mount = directory.appendingPathComponent("mount", isDirectory: true)
                let newStore = WKPortalStore(), newServer = WKPortalHTTPServer(store: newStore)
                newServer.onProxyFailure = { [weak self] in self?.stop(expectedGeneration: token, completion: {}) }
                state.lock(); ownedDirectory = directory; store = newStore; server = newServer
                let current = generation == token; state.unlock()
                guard current else { throw WKFilePortalError.stopped }
                try newServer.start()
                let success = run("/sbin/mount_webdav", ["-S", "-o", "nobrowse,rdonly,nodev,nosuid", "-v", "WiredKVM Files", newServer.url.absoluteString, mount.path], seconds: 12, cancelled: {
                    self.state.lock(); defer { self.state.unlock() }; return self.generation != token
                })
                guard success, Self.ownWebDAVMount(mount) else { throw WKFilePortalError.mount }
                // A successful mount does not grant the application TCC access
                // to a network volume, even for a loopback-only mount it owns.
                // Request ordinary directory access off the UI/HID queues before
                // advertising readiness. Without this, writeObjects can report
                // success while CFPasteboard silently drops the file URL.
                do {
                    _ = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
                } catch {
                    let failure = error as NSError
                    if (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoPermissionError) ||
                        (failure.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(failure.code)) {
                        throw WKFilePortalError.accessDenied
                    }
                    throw error
                }
                state.lock(); let stillCurrent = generation == token
                if stillCurrent { mounted = mount }; state.unlock()
                guard stillCurrent else { throw WKFilePortalError.stopped }
                result = .success(())
            } catch {
                cleanup(); state.lock(); if generation == token { generation = nil }; state.unlock()
                result = .failure(error)
            }
            let completedResult = result
            DispatchQueue.main.async { [self] in
                state.lock(); let current = generation == token; state.unlock()
                if case .success = completedResult, !current { callback.body(.failure(WKFilePortalError.stopped)) }
                else { callback.body(completedResult) }
            }
        }
    }
    func stop() { stop(completion: {}) }
    func stop(completion: @escaping () -> Void) {
        stop(expectedGeneration: nil, completion: completion)
    }
    private func stop(expectedGeneration: UUID?, completion: @escaping () -> Void) {
        let callback = WKPortalCallback<Void> { _ in completion() }
        state.lock()
        if let expectedGeneration, generation != expectedGeneration {
            state.unlock(); DispatchQueue.main.async { callback.body(()) }; return
        }
        generation = nil; mounted = nil
        let oldStore = store, oldServer = server
        // Queue cleanup before a subsequent start can enqueue a new generation.
        lifecycle.async { [self] in
            cleanup()
            DispatchQueue.main.async { callback.body(()) }
        }
        state.unlock()
        oldStore?.stop(); oldServer?.stop()
    }
    func offer(id: String, name: String, size: Int, sha256: String) throws -> URL {
        state.lock(); defer { state.unlock() }
        guard generation != nil, let mounted, let store else { throw WKFilePortalError.unavailable }
        _ = try store.offer(id: id, name: name, size: size, sha256: sha256)
        return mounted.appendingPathComponent(id, isDirectory: true).appendingPathComponent(name)
    }
    func fulfill(id: String, data: Data) throws {
        state.lock(); let target = store; state.unlock()
        guard let target else { throw WKFilePortalError.unavailable }
        try target.fulfill(id: id, data: data)
    }
    func offerStream(_ offer: WKStreamOffer) throws -> URL {
        try offer.validate()
        state.lock(); defer { state.unlock() }
        guard generation != nil, let mounted, let store else { throw WKFilePortalError.unavailable }
        _ = try store.offer(id: offer.id, name: offer.name, size: Int(offer.size), sha256: String(repeating: "0", count: 64), streaming: true)
        return mounted.appendingPathComponent(offer.id, isDirectory: true).appendingPathComponent(offer.name)
    }
    func fulfill(id: String, file: WKReceivedFile) throws {
        state.lock(); let target = store; state.unlock()
        guard let target else { throw WKFilePortalError.unavailable }; try target.fulfill(id: id, file: file)
    }
    func beginReceiving(id: String, file: WKReceivingFile) throws {
        state.lock(); let target = store; state.unlock()
        guard let target else { throw WKFilePortalError.unavailable }; try target.beginReceiving(id: id, file: file)
    }
#if WK_TREE
    func offerTree(_ offer: WKStreamOffer, manifest: WKTreeManifest) throws -> [URL] {
        try offer.validate()
        state.lock(); defer { state.unlock() }
        guard generation != nil, let mounted, let store, offer.kind == "collection", manifest.size == offer.size,
              manifest.prefixBytes == offer.manifestBytes, let sha = offer.manifestSHA256 else { throw WKFilePortalError.unavailable }
        try store.offerTree(id: offer.id, manifest: manifest, sha256: sha)
        return manifest.roots.map { mounted.appendingPathComponent(offer.id, isDirectory: true).appendingPathComponent($0.path, isDirectory: $0.directory) }
    }
#endif
    func fail(id: String) { state.lock(); let target = store; state.unlock(); target?.fail(id: id) }
    func retire(id: String) { state.lock(); let target = store; state.unlock(); target?.retire(id: id) }

    private func createDirectory(_ token: UUID) throws -> URL {
#if WK_PORTABLE
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("WiredKVM-Portable-Portal", isDirectory: true)
#else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WiredKVM/Portal", isDirectory: true)
#endif
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(base.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { throw WKFilePortalError.unavailable }
        let directory = base.appendingPathComponent(token.uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw WKFilePortalError.system(errno) }
        guard mkdir(directory.appendingPathComponent("mount").path, 0o700) == 0 else {
            _ = rmdir(directory.path); throw WKFilePortalError.system(errno)
        }
        return try Self.canonicalLocalDirectory(directory)
    }
    // Resolve while this is still a local, unmounted directory. Resolving the
    // mounted WebDAV URL can block or fail before network-volume permission;
    // Foundation then leaves /var unchanged while getfsstat reports /private/var.
    static func canonicalLocalDirectory(_ directory: URL) throws -> URL {
        guard let path = directory.path.withCString({ realpath($0, nil) }) else {
            throw WKFilePortalError.system(errno)
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    private static func mountRecord(_ url: URL) -> statfs? {
        let capacity = getfsstat(nil, 0, MNT_NOWAIT)
        guard capacity > 0 else { return nil }
        let records = UnsafeMutablePointer<statfs>.allocate(capacity: Int(capacity) + 8)
        defer { records.deallocate() }
        let count = getfsstat(records, Int32((Int(capacity) + 8) * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard count > 0 else { return nil }
        for index in 0..<min(Int(count), Int(capacity) + 8) {
            var record = records[index]
            let name = withUnsafePointer(to: &record.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            if name == url.path { return record }
        }
        return nil
    }
    private static func ownWebDAVMount(_ url: URL) -> Bool {
        guard var record = mountRecord(url), record.f_owner == getuid() else { return false }
        let kind = withUnsafePointer(to: &record.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) } }
        return kind == "webdav" && record.f_flags & UInt32(MNT_RDONLY) != 0 && record.f_flags & UInt32(MNT_DONTBROWSE) != 0
    }
    private func cleanup() {
        state.lock()
        let oldServer = server, oldStore = store, directory = ownedDirectory
        server = nil; store = nil; mounted = nil; ownedDirectory = nil
        state.unlock()
        oldStore?.stop(); oldServer?.stop()
        guard let directory else { return }
        let mount = directory.appendingPathComponent("mount", isDirectory: true)
        if Self.mountRecord(mount) != nil {
            guard Self.ownWebDAVMount(mount) else { return }
            _ = run("/sbin/umount", [mount.path], seconds: 5)
        }
        guard Self.mountRecord(mount) == nil else { return }
        // Never recursively remove a mount point, even after a mount failure.
        _ = rmdir(mount.path); _ = rmdir(directory.path)
    }
    private func run(_ executable: String, _ arguments: [String], seconds: TimeInterval, cancelled: () -> Bool = { false }) -> Bool {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let limit = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < limit && !cancelled() { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            // No unbounded waitUntilExit: cleanup is best effort and never
            // removes an entry that the mount table still reports as mounted.
            return false
        }
        return process.terminationStatus == 0
    }
}
