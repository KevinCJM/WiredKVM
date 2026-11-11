import Foundation
import CryptoKit
import Darwin
import IOKit
import IOKit.serial

// CH32 binary image/file path. Only bounded metadata uses WKC3. Bodies use
// an independent CDC-ACM interface (USB bulk, not a UART or a baud-rate link).
struct WKStreamOffer: Codable, Equatable {
    static let maximumSize: UInt64 = 64 * 1024 * 1024 * 1024
    let id: String, name: String, nonce: String
    let size: UInt64
    var kind: String = "file"
    var generation: UInt64 = WKStreamSequence.next()
#if WK_TREE
    var manifestBytes: Int? = nil
    var manifestSHA256: String? = nil
#endif
    static let maximumImage = 64 * 1024 * 1024
    func validate() throws {
        var kinds = ["file", "png"]
#if WK_TREE
        kinds.append("collection")
        if kind == "collection" {
            guard let n = manifestBytes, (32...(8 * 1024 * 1024)).contains(n), UInt64(n) <= size,
                  let digest = manifestSHA256, digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw WKStreamError.invalid }
        } else if manifestBytes != nil || manifestSHA256 != nil { throw WKStreamError.invalid }
#endif
        guard WKFileOffer.validID(id), WKMessage.validFilename(name),
              !name.contains("\\"), !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              WKMessage.validNonce(nonce), nonce != "0", generation > 0, kinds.contains(kind),
              size <= (kind == "png" ? UInt64(Self.maximumImage) : Self.maximumSize) else { throw WKStreamError.invalid }
    }
    func encoded() throws -> Data { try validate(); return try JSONEncoder().encode(self) }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2048 else { throw WKStreamError.invalid }
        let item = try JSONDecoder().decode(Self.self, from: data); try item.validate(); return item
    }
}
// Monotonic admission prevents a late OPEN from reviving a cancelled transfer.
// The bridge keeps only active transfers and a high-water mark per direction.
private enum WKStreamSequence {
    static let lock = NSLock()
    static var value: UInt64 = 0
    static func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
struct WKBulkControl {
    static let magic = Data("WKB5".utf8)
    enum Kind: UInt8 { case session = 1, grant, cancel, accepted, cancelled, retired, pasteCancel, retiredAck }
    let kind: Kind, origin: UInt8, epoch: UInt64, id: String, generation: UInt64
    static let zeroID = "00000000-0000-0000-0000-000000000000"
    func encode() -> Data {
        var d = Data(Self.magic); d.append(contentsOf: [kind.rawValue, origin, 0, 0]); d.appendLE(epoch)
        var u = UUID(uuidString: id)!.uuid; withUnsafeBytes(of: &u) { d.append(contentsOf: $0) }
        d.appendLE(generation); d.append(Data(repeating: 0, count: 20)); d.appendLE(Self.crc(d)); return d
    }
    init(kind: Kind, origin: UInt8, epoch: UInt64, id: String = zeroID, generation: UInt64 = 0) {
        self.kind = kind; self.origin = origin; self.epoch = epoch; self.id = id; self.generation = generation
    }
    init?(_ d: Data) {
        guard d.count == 64, d.prefix(4) == Self.magic, let k = Kind(rawValue: d[4]), d[5] < 2,
              d[6..<8].allSatisfy({ $0 == 0 }), d[40..<60].allSatisfy({ $0 == 0 }),
              Self.crc(Data(d.prefix(60))) == d.readLE(at: 60) as UInt32 else { return nil }
        let b = Array(d[16..<32]); let u = UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
        kind = k; origin = d[5]; epoch = d.readLE(at: 8); id = u.uuidString.lowercased(); generation = d.readLE(at: 32)
    }
    static func crc(_ d: Data) -> UInt32 {
        var c = UInt32.max
        for b in d { c ^= UInt32(b); for _ in 0..<8 { c = (c >> 1) ^ ((c & 1) == 1 ? 0xedb88320 : 0) } }
        return ~c
    }
}
enum WKStreamError: Error { case invalid, disconnected, integrity, changed, capacity, timeout, system(Int32) }
private func streamErrorCode(_ error: Error) -> String {
    guard let e=error as? WKStreamError else{return "stream-io"}
    switch e {
    case .invalid:return "stream-invalid"
    case .disconnected:return "stream-disconnected"
    case .integrity:return "stream-integrity"
    case .changed:return "stream-source-changed"
    case .capacity:return "stream-capacity"
    case .timeout:return "stream-timeout"
    case .system(let code):return "posix-"+String(code)
    }
}

// Only the receiver creates this after length and whole-file SHA-256 pass.
// The unlinked file is pinned by its descriptor; no later pathname substitution.
final class WKReceivedFile: @unchecked Sendable {
    private let fd: Int32
    let size: UInt64, sha256: String
    fileprivate init(fd: Int32, size: UInt64, sha256: String) { self.fd = fd; self.size = size; self.sha256 = sha256 }
    deinit { Darwin.close(fd) }
    func read(offset: UInt64, maximum: Int) throws -> Data {
        guard offset <= size, maximum >= 0, maximum <= 65536 else { throw WKStreamError.invalid }
        var data = Data(count: min(maximum, Int(size - offset)))
        if data.isEmpty { return data }
        let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, $0.count, off_t(offset)) }
        guard n == data.count else { throw WKStreamError.system(errno) }; return data
    }
}

final class WKStreamSource: @unchecked Sendable {
    let offer: WKStreamOffer
    fileprivate let fd: Int32
    private let original: stat
    private let cancellation = NSLock()
    private var cancelled = false
#if WK_TREE
    private var tree: WKTransferTree?
    init(tree: WKTransferTree, nonce: String) throws {
        var metadata = WKStreamOffer(id: UUID().uuidString.lowercased(), name: "WiredKVM Selection", nonce: nonce, size: tree.size, kind: "collection")
        metadata.manifestBytes = tree.manifestData.count; metadata.manifestSHA256 = tree.manifestSHA256
        try metadata.validate(); self.tree = tree; offer = metadata; fd = -1; original = stat()
    }
#endif
    init(url: URL, nonce: String, kind: String = "file", unlinkAfterOpen: Bool = false) throws {
        let f = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard f >= 0 else { throw WKStreamError.system(errno) }
        if unlinkAfterOpen && unlink(url.path) != 0 { Darwin.close(f); throw WKStreamError.system(errno) }
        var st = stat()
        guard fstat(f, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size >= 0,
              UInt64(st.st_size) <= WKStreamOffer.maximumSize else { Darwin.close(f); throw WKStreamError.invalid }
        // A file-copy feature must not silently discard a resource fork.
        guard fgetxattr(f, "com.apple.ResourceFork", nil, 0, 0, 0) <= 0 else { Darwin.close(f); throw WKStreamError.invalid }
        let metadata = WKStreamOffer(id: UUID().uuidString.lowercased(), name: url.lastPathComponent, nonce: nonce, size: UInt64(st.st_size), kind: kind)
        do { try metadata.validate() } catch { Darwin.close(f); throw error }
        fd = f; original = st; offer = metadata
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }
    func cancel() {
        cancellation.lock(); cancelled = true; cancellation.unlock()
#if WK_TREE
        tree?.cancel()
#endif
    }
    private func checkCancellation() throws {
        cancellation.lock(); let value = cancelled; cancellation.unlock()
        if value { throw WKStreamError.disconnected }
    }
    fileprivate func read(offset: UInt64, count: Int) throws -> Data {
        try checkCancellation()
#if WK_TREE
        if let tree { return try tree.read(offset: offset, maximum: count) }
#endif
        guard count >= 0, count <= 65536, offset <= offer.size, UInt64(count) <= offer.size-offset else { throw WKStreamError.invalid }
        if count == 0 { return Data() }
        var bytes = Data(count: count)
        let n = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, $0.count, off_t(offset)) }
        guard n == count else { throw WKStreamError.changed }
        try checkCancellation(); return bytes
    }
    fileprivate func unchanged() -> Bool {
        validationFailure() == nil
    }
    fileprivate func validationFailure(expectedHash: Data? = nil) -> String? {
        do { try checkCancellation() } catch { return streamErrorCode(error) }
#if WK_TREE
        if let tree { return tree.unchanged() ? nil : "stream-source-changed" }
#endif
        var s = stat()
        guard fstat(fd, &s) == 0 else { return "stream-source-stat-failed" }
        guard s.st_dev == original.st_dev && s.st_ino == original.st_ino else { return "stream-source-identity-changed" }
        guard s.st_size == original.st_size else { return "stream-source-size-changed" }
        guard s.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec && s.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec else { return "stream-source-mtime-changed" }
        if s.st_ctimespec.tv_sec != original.st_ctimespec.tv_sec || s.st_ctimespec.tv_nsec != original.st_ctimespec.tv_nsec {
            guard let expectedHash, expectedHash.count == 32 else { return "stream-source-ctime-changed" }
            // Extended metadata can change after an offer (for example, while
            // the system is indexing a newly received file).
            // Ctime alone is not content proof. Re-read the pinned descriptor
            // off the stream/UI queues and compare with the bytes transmitted.
            // A changed mtime/size/identity or unstable re-read still fails.
            do {
                var hash = SHA256(), offset: UInt64 = 0
                while offset < offer.size {
                    let bytes = try read(offset: offset, count: Int(min(65536, offer.size-offset)))
                    hash.update(data: bytes); offset += UInt64(bytes.count)
                }
                try checkCancellation()
                var after = stat()
                guard fstat(fd, &after) == 0 else { return "stream-source-stat-failed" }
                guard after.st_dev == s.st_dev && after.st_ino == s.st_ino else { return "stream-source-identity-changed" }
                guard after.st_size == s.st_size else { return "stream-source-size-changed" }
                guard after.st_mtimespec.tv_sec == s.st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec == s.st_mtimespec.tv_nsec else { return "stream-source-mtime-changed" }
                guard after.st_ctimespec.tv_sec == s.st_ctimespec.tv_sec && after.st_ctimespec.tv_nsec == s.st_ctimespec.tv_nsec else { return "stream-source-ctime-changed" }
                guard Data(hash.finalize()) == expectedHash else { return "stream-source-changed" }
            } catch { return streamErrorCode(error) }
        }
        return nil
    }
}

protocol WKStreamIO: AnyObject {
    var port: UInt8 { get }
    var writeDescriptor: Int32? { get }
    func forwardControl(_ data: Data) -> Bool
    func read(maximum: Int) throws -> Data
    func write(_ data: Data) throws -> Int
    func write(_ data: Data, offset: Int) throws -> Int
    func close()
}

extension WKStreamIO {
    var writeDescriptor: Int32? { nil }
    // Compatibility for injected transports; the CDC implementation borrows
    // the original batch so each short write does not copy its remaining body.
    func write(_ data: Data, offset: Int) throws -> Int {
        guard (0...data.count).contains(offset) else { throw WKStreamError.invalid }
        return try write(offset == 0 ? data : Data(data.dropFirst(offset)))
    }
    // Real control travels through WKTransport. An injected USB simulator can
    // apply firmware filtering here before forwarding the report to the peer.
    func forwardControl(_ data: Data) -> Bool { true }
}

#if WK_STREAM_PROFILE
// Opt-in observability only: retain the same calls, bytes, return values and
// scheduling. No contents, filenames, UUIDs, extra device reads or busy waits.
final class WKStreamProfileIO: WKStreamIO {
    struct Counts {
        var readCalls: UInt64 = 0, readBytes: UInt64 = 0, readZero: UInt64 = 0, readMax: UInt64 = 0
        var writeCalls: UInt64 = 0, writeWanted: UInt64 = 0, writeBytes: UInt64 = 0
        var writeZero: UInt64 = 0, writePartial: UInt64 = 0, writeMax: UInt64 = 0
    }
    let underlying: WKStreamIO
    var counts = Counts()
    var port: UInt8 { underlying.port }
    var writeDescriptor: Int32? { underlying.writeDescriptor }
    init(_ underlying: WKStreamIO) { self.underlying = underlying }
    func forwardControl(_ data: Data) -> Bool { underlying.forwardControl(data) }
    func close() { underlying.close() }
    func read(maximum: Int) throws -> Data {
        counts.readCalls &+= 1
        let data = try underlying.read(maximum: maximum), n = UInt64(data.count)
        counts.readBytes &+= n; counts.readMax = max(counts.readMax, n)
        if n == 0 { counts.readZero &+= 1 }; return data
    }
    func write(_ data: Data) throws -> Int {
        try write(data, offset: 0)
    }
    func write(_ data: Data, offset: Int) throws -> Int {
        guard (0...data.count).contains(offset) else { throw WKStreamError.invalid }
        let wanted = data.count - offset
        counts.writeCalls &+= 1; counts.writeWanted &+= UInt64(wanted)
        let n = try underlying.write(data, offset: offset)
        if n >= 0 && n <= wanted {
            counts.writeBytes &+= UInt64(n); counts.writeMax = max(counts.writeMax, UInt64(n))
            if n == 0 { counts.writeZero &+= 1 }
            else if n < wanted { counts.writePartial &+= 1 }
        }
        return n // the engine retains its existing validation/error policy
    }
}
#endif

// Discovery is identity- AND interface-bound. Never open an arbitrary serial
// adapter simply because its filename contains usbmodem.
enum WKCH32Device {
    static func matches(path: String, role: String, files: Bool = true) -> Bool {
        WKUSBDiscovery.ports().contains { $0.path == path && $0.role == role && $0.function == (role == "host" ? (files ? 2 : 0) : 3) }
    }
}
// Darwin imports `struct flock` with the same name as the BSD function.
@_silgen_name("flock") private func wkStreamFileLock(_ fd: Int32, _ operation: Int32) -> Int32

// Owned by the file worker. A duplicate pins this exact open file description
// until the dispatch cancellation handler has run; a reused fd cannot receive
// an old readiness callback. No source is active while there is no pending data.
final class WKWriteReadiness {
    private let source: DispatchSourceWrite
    private var enabled = false, stopped = false
    init(fd: Int32, queue: DispatchQueue, ready: @escaping () -> Void) throws {
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw WKStreamError.system(errno) }
        source = DispatchSource.makeWriteSource(fileDescriptor: copy, queue: queue)
        source.setEventHandler(handler: ready)
        source.setCancelHandler { Darwin.close(copy) }
    }
    func setEnabled(_ value: Bool) {
        guard !stopped, value != enabled else { return }
        enabled = value
        if value { source.resume() } else { source.suspend() }
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        if !enabled { source.resume() }
        source.cancel()
    }
    deinit { stop() }
}
final class WKCDCStreamIO: WKStreamIO {
    private var fd: Int32 = -1
    let port: UInt8
    var writeDescriptor: Int32? { fd >= 0 ? fd : nil }
    init(path: String, role: String) throws {
        port = role == "host" ? 0 : 1
        guard WKCH32Device.matches(path: path, role: role) else { throw WKStreamError.invalid }
        let f = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard f >= 0 else { throw WKStreamError.system(errno) }
        // The startup image loader and clipboard stream must never read the
        // same CDC function concurrently. Releasing the fd releases this lock.
        guard wkStreamFileLock(f, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(f); throw WKStreamError.system(errno) }
        var config = termios()
        guard tcgetattr(f, &config) == 0 else { Darwin.close(f); throw WKStreamError.system(errno) }
        cfmakeraw(&config); config.c_cflag |= tcflag_t(CLOCAL | CREAD)
        config.c_cflag &= ~tcflag_t(CCTS_OFLOW | CRTS_IFLOW); config.c_cc.16 = 0; config.c_cc.17 = 0
        guard tcsetattr(f, TCSANOW, &config) == 0 else { Darwin.close(f); throw WKStreamError.system(errno) }
        fd = f; _ = ioctl(f, TIOCSDTR)
    }
    deinit { close() }
    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    func read(maximum: Int) throws -> Data {
        guard fd >= 0 else { throw WKStreamError.disconnected }
        var data = Data(count: maximum)
        let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
        if n < 0 && [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { return Data() }
        guard n >= 0 else { throw WKStreamError.system(errno) }
        // A nonblocking TTY may return zero without EOF. POLLHUP detects removal.
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&p, 1, 0) > 0 && p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw WKStreamError.disconnected }
        data.count = n; return data
    }
    func write(_ data: Data) throws -> Int {
        try write(data, offset: 0)
    }
    func write(_ data: Data, offset: Int) throws -> Int {
        guard fd >= 0 else { throw WKStreamError.disconnected }
        guard (0...data.count).contains(offset) else { throw WKStreamError.invalid }
        if offset == data.count { return 0 }
        let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
        if n < 0 && [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { return 0 }
        guard n >= 0 else { throw WKStreamError.system(errno) }; return n
    }
}

// A cancelled OS read/write may finish in the background, but it never owns
// the transfer loop. The descriptor stays pinned until that syscall returns.
// Global admission bounds retired tasks even when a filesystem stops forever.
private enum WKDiskBudget {
    static let lock = NSLock(); static var active = 0
    static func take() -> Bool { lock.lock(); defer { lock.unlock() }; guard active < 32 else { return false }; active += 1; return true }
    static func release() { lock.lock(); active -= 1; lock.unlock() }
}
private final class WKDiskTask<T> {
    private let lock = NSLock(); private var value: Result<T, Error>?
    init(inline: Bool, gate: (() -> Void)?, notify: (() -> Void)? = nil, work: @escaping () throws -> T) {
        guard WKDiskBudget.take() else { value = .failure(WKStreamError.capacity); return }
        let run = { [self] in
            gate?(); let result = Result { try work() }
            lock.lock(); value = result; lock.unlock(); WKDiskBudget.release(); notify?()
        }
        if inline { run() } else { DispatchQueue.global(qos: .utility).async(execute: DispatchWorkItem(block: run)) }
    }
    func result() -> Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

// A bounded streaming engine. Production owns it on one utility queue; tests
// may call step() with a deterministic clock and the actual firmware bridge.
final class WKStreamEngine {
    // Fixed wire cells survive selective cancellation at USB packet boundaries.
    // 128 cells/transaction bound both-hop residual body below 256 KiB.
    static let cell = 512, header = 80, chunk = 432, window = 128, queueLimit = 64 * 1024
    struct Frame {
        var kind: UInt8, epoch: UInt64, id: String, offset: UInt64, body: Data
        func encode() throws -> Data {
            guard let uuid = UUID(uuidString: id), body.count <= WKStreamEngine.chunk else { throw WKStreamError.invalid }
            var result = Data("WKS5".utf8); result.appendLE(UInt32(WKStreamEngine.cell))
            result.append(contentsOf: [kind, 0, 0, 0]); result.appendLE(epoch)
            var bytes = uuid.uuid; withUnsafeBytes(of: &bytes) { result.append(contentsOf: $0) }
            result.appendLE(offset); result.appendLE(UInt32(body.count))
            var hash = SHA256(); hash.update(data: result); hash.update(data: body)
            result.append(contentsOf: hash.finalize()); result.append(body); result.append(Data(repeating: 0, count: WKStreamEngine.chunk - body.count)); return result
        }
        static func decode(_ d: Data) throws -> Self {
            guard d.count == WKStreamEngine.cell, d.prefix(4) == Data("WKS5".utf8), d[9...11].allSatisfy({ $0 == 0 }),
                  d.readLE(at: 4) as UInt32 == WKStreamEngine.cell else { throw WKStreamError.invalid }
            let n = Int(d.readLE(at: 44) as UInt32)
            guard n <= WKStreamEngine.chunk, d[(80+n)...].allSatisfy({ $0 == 0 }) else { throw WKStreamError.invalid }
            let body = Data(d[80..<(80+n)])
            var hash = SHA256(); hash.update(data: d.prefix(48)); hash.update(data: body)
            guard Data(hash.finalize()) == d[48..<80] else { throw WKStreamError.integrity }
            let b = Array(d[20..<36]); let u = UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
            return Self(kind: d[8], epoch: d.readLE(at: 12), id: u.uuidString.lowercased(), offset: d.readLE(at: 36), body: body)
        }
    }

    private final class Outgoing {
        let source: WKStreamSource
        var offset: UInt64 = 0, acked: UInt64 = 0, hash = SHA256(), finished = false
        var granted = false
        var reader: WKDiskTask<Data>?, finalCheck: WKDiskTask<String?>?
        var finalHash: Data?
        var prefetched = Data()
        var activity: Double
        init(_ source: WKStreamSource, _ now: Double) { self.source = source; activity = now }
    }
    private final class Incoming {
        let offer: WKStreamOffer
        var fd: Int32, offset: UInt64 = 0, hash = SHA256(), activity: Double
        var written: UInt64 = 0, staged = Data(), writer: WKDiskTask<Int>?
#if WK_TREE
        var manifestData = Data(), manifestTask: WKDiskTask<WKTreeManifest>?
        var manifestReported = false, finalHash: Data?
#endif
        init(_ offer: WKStreamOffer, _ now: Double, directory: URL) throws {
            self.offer = offer; activity = now
            let url = directory.appendingPathComponent(UUID().uuidString)
            let f = Darwin.open(url.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard f >= 0 else { throw WKStreamError.system(errno) }
            fd = f
            guard unlink(url.path) == 0 else { Darwin.close(f); fd = -1; throw WKStreamError.system(errno) }
        }
        deinit { if fd >= 0 { Darwin.close(fd) } }
    }
    private let io: WKStreamIO, directory: URL
    private let inlineDisk: Bool
    var diskGate: (() -> Void)? // injected blocking-disk fault; production nil
    private var input = Data()
    private struct Packet { let id: String; var bytes: Data; var started = false }
    private var output: [Packet] = []
    private var grants: [String: UInt64] = [:]
    private var roundRobin = 0
    private var lastSession: Double = -10
    private struct PendingControl { let control: WKBulkControl; var last: Double = -10; var first: Double? }
    private var pendingControls: [String: PendingControl] = [:]
    var onCancelUnconfirmed: (String) -> Void = { _ in }
    var onRetire: (String) -> Void = { _ in }
    var onControl: (Data) -> Void = { _ in }
    var onAccepted: (String) -> Void = { _ in }
    var onProgress: (String, UInt64, UInt64) -> Void = { _,_,_ in }
    var outputBytes: Int { output.reduce(0) { $0 + $1.bytes.count } }
    var activeCount: Int { outgoing.count + incoming.count }

    private var outgoing: [String: Outgoing] = [:], incoming: [String: Incoming] = [:]
    private(set) var epoch: UInt64 = 0
    private(set) var maxBuffered = 0, stopped = false
    private(set) var lastWriteProgress = 0
    var onWorkAvailable: (() -> Void)?
    var timeout: Double = 60
    var onFile: (String, WKReceivedFile) -> Void = { _, _ in }
#if WK_TREE
    var onManifest: (String, WKTreeManifest) -> Void = { _, _ in }
#endif
    var onComplete: (String) -> Void = { _ in }
    var onFailure: (String) -> Void = { _ in }
    var onFault: (Error) -> Void = { _ in }
    var onDiagnostic: (String) -> Void = { _ in }
    private func diagnostic(_ error: Error, phase: String = "REJECT") {
        // Fixed enums/numbers only: no path, UUID, frame bytes or error description.
        onDiagnostic("WKCLIP_DIAG role=\(io.port == 0 ? "host" : "target") event=ERROR code=\(streamErrorCode(error)) phase=\(phase)")
    }
    init(io: WKStreamIO, directory: URL, inlineDisk: Bool = false) {
#if WK_STREAM_PROFILE
        self.io = WKStreamProfileIO(io)
#else
        self.io = io
#endif
        self.directory = directory; self.inlineDisk = inlineDisk
    }
#if WK_STREAM_PROFILE
    private var profileStart: Double?, profileLast: Double?
    private var profileSteps: UInt64 = 0, profileGap: UInt64 = 0, profilePending: UInt64 = 0
    private var profileFlight: UInt64 = 0, profileReadWait: UInt64 = 0, profileWindowFull: UInt64 = 0
    private var profileRecords = 0
    private func profileBegin(_ now: Double) {
        guard profileRecords < 64, let measured = io as? WKStreamProfileIO else { return }
        guard profileStart != nil || activeCount > 0 || !output.isEmpty else { return }
        if profileStart == nil { profileStart = now; profileLast = now; measured.counts = .init() }
        if let previous = profileLast { profileGap = max(profileGap, Self.profileMicros(now - previous)) }
        profileLast = now; profileSteps &+= 1
        let flight = outgoing.values.reduce(UInt64(0)) { $0 + ($1.offset - $1.acked) }
        profileFlight = max(profileFlight, flight)
        if outgoing.values.contains(where: { $0.reader != nil && $0.prefetched.isEmpty }) { profileReadWait &+= 1 }
        if outgoing.values.contains(where: { $0.offset - $0.acked >= UInt64(Self.chunk * Self.window) }) { profileWindowFull &+= 1 }
    }
    private static func profileMicros(_ seconds: Double) -> UInt64 {
        UInt64(min(Double(UInt32.max), max(0, seconds * 1_000_000)))
    }
    private func profileEnd(_ now: Double) {
        guard profileRecords < 64, let started = profileStart, let measured = io as? WKStreamProfileIO else { return }
        profilePending = max(profilePending, UInt64(outputBytes))
        let active = activeCount > 0 || !output.isEmpty
        guard now - started >= 1 || !active else { return }
        let c = measured.counts
        let values: [String: UInt64] = ["steps":profileSteps, "elapsedUs":Self.profileMicros(now-started),
            "gapMaxUs":profileGap, "pendingMax":profilePending, "inFlightMax":profileFlight,
            "readWaitSteps":profileReadWait, "windowFullSteps":profileWindowFull,
            "readCalls":c.readCalls, "readBytes":c.readBytes, "readZero":c.readZero, "readMax":c.readMax,
            "writeCalls":c.writeCalls, "writeWanted":c.writeWanted, "writeBytes":c.writeBytes,
            "writeZero":c.writeZero, "writePartial":c.writePartial, "writeMax":c.writeMax]
        let fields = values.keys.sorted().map { "\($0)=\(min(values[$0]!,UInt64(UInt32.max)))" }.joined(separator:" ")
        onDiagnostic("WKCLIP_DIAG role=\(io.port == 0 ? "host" : "target") event=STREAM_IO phase=\(active ? "PROGRESS" : "RESULT") \(fields)")
        profileRecords += 1; profileStart = active ? now : nil; profileLast = active ? now : nil
        profileSteps = 0; profileGap = 0; profilePending = 0; profileFlight = 0; profileReadWait = 0; profileWindowFull = 0
        measured.counts = .init()
    }
#endif
    func setEpoch(_ value: UInt64) {
        guard value != epoch else { return }; cancelAll(); epoch = value; input.removeAll(); output.removeAll()
        grants.removeAll(); pendingControls.removeAll(); lastSession = -10
        emitControl(WKBulkControl(kind: .session, origin: io.port, epoch: epoch).encode())
    }
    func cancelAll() { let ids = Set(outgoing.keys).union(incoming.keys); for item in outgoing.values { item.source.cancel() }; outgoing.removeAll(); incoming.removeAll(); output.removeAll(); grants.removeAll(); pendingControls.removeAll(); for id in ids { onFailure(id) } }
    func stop() { emitControl(WKBulkControl(kind: .session, origin: io.port, epoch: 0).encode()); stopped = true; cancelAll(); io.close(); input.removeAll(); output.removeAll() }
    func add(_ source: WKStreamSource, now: Double) throws {
        guard !stopped, epoch != 0, outgoing.count < 4, pendingControls.count < 12, outgoing[source.offer.id] == nil else { throw WKStreamError.capacity }
        let item = Outgoing(source, now)
        item.granted = grants.removeValue(forKey: source.offer.id) == source.offer.generation
        outgoing[source.offer.id] = item
    }
    func expect(_ offer: WKStreamOffer, now: Double) throws {
        try offer.validate()
        guard !stopped, epoch != 0, incoming.count < 4, pendingControls.count < 12, incoming[offer.id] == nil else { throw WKStreamError.capacity }
        var fs = statfs()
        guard statfs(directory.path, &fs) == 0 else { throw WKStreamError.system(errno) }
        let promised = incoming.values.reduce(UInt64(0)) { $0 + $1.offer.size - $1.written }
        let available = UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
        guard available > 256 * 1024 * 1024, offer.size + promised <= available - 256 * 1024 * 1024 else { throw WKStreamError.capacity }
        incoming[offer.id] = try Incoming(offer, now, directory: directory)
        onDiagnostic("WKCLIP_DIAG role=\(io.port == 0 ? "host" : "target") event=BULK_RX phase=REQUEST transfer=\(offer.generation) acked=0 total=\(offer.size)")
        let control = WKBulkControl(kind: .grant, origin: 1-io.port, epoch: epoch, id: offer.id, generation: offer.generation)
        pendingControls[offer.id] = PendingControl(control: control)

    }
    // Drop whole unsent cells. A partially written cell must finish framing;
    // it is <=511 bytes, tagged and discarded by the bridge after cancellation.
    private func purge(_ id: String) {
        onRetire(id)
        output.removeAll { $0.id == id && !$0.started }
        outgoing[id]?.source.cancel()
        outgoing.removeValue(forKey: id); incoming.removeValue(forKey: id); grants.removeValue(forKey: id)
    }
    func cancel(_ id: String) {
        let source = outgoing[id]?.source.offer, target = incoming[id]?.offer
        guard let offer = source ?? target else { return }
        let origin = source != nil ? io.port : 1-io.port
        purge(id)
        if pendingControls.count >= 16 { onFault(WKStreamError.capacity); return }
        pendingControls[id] = PendingControl(control: WKBulkControl(kind: .cancel, origin: origin, epoch: epoch, id: id, generation: offer.generation))
    }
    private func emitControl(_ data: Data) {
        if io.forwardControl(data) { onControl(data) }
    }
    func control(_ data: Data) {
        guard let c = WKBulkControl(data), c.epoch == epoch, epoch != 0 else { return }
        switch c.kind {
        case .grant:
            guard c.origin == io.port else { return }
            if let item = outgoing[c.id], item.source.offer.generation == c.generation { item.granted = true }
            else if grants.count < 4 { grants[c.id] = c.generation }
            emitControl(WKBulkControl(kind: .accepted, origin: c.origin, epoch: epoch, id: c.id, generation: c.generation).encode())
        case .accepted:
            if pendingControls[c.id]?.control.kind == .grant && incoming[c.id]?.offer.generation == c.generation {
                onDiagnostic("WKCLIP_DIAG role=\(io.port == 0 ? "host" : "target") event=BULK_RX phase=START transfer=\(c.generation) acked=0 total=\(incoming[c.id]!.offer.size)")
                pendingControls.removeValue(forKey: c.id); onAccepted(c.id)
            }
        case .cancel:
            purge(c.id); pendingControls.removeValue(forKey: c.id); onFailure(c.id)
            emitControl(WKBulkControl(kind: .cancelled, origin: c.origin, epoch: epoch, id: c.id, generation: c.generation).encode())
        case .cancelled:
            if pendingControls[c.id]?.control.kind == .cancel { pendingControls.removeValue(forKey: c.id) }
        case .retired:
            emitControl(WKBulkControl(kind: .retiredAck, origin: c.origin, epoch: epoch, id: c.id, generation: c.generation).encode())
        case .retiredAck:
            if pendingControls[c.id]?.control.kind == .retired { pendingControls.removeValue(forKey: c.id) }
        case .session, .pasteCancel: break
        }
    }
    private func enqueue(_ frame: Frame) throws {
        let data = try frame.encode()
        guard outputBytes + data.count <= Self.queueLimit else { throw WKStreamError.capacity }
        // Cumulative ACKs never accumulate behind a stalled body stream.
        if frame.kind == 3 { output.removeAll { $0.id == frame.id && !$0.started && $0.bytes[8] == 3 } }
        output.append(Packet(id: frame.id, bytes: data)); maxBuffered = max(maxBuffered, input.count + outputBytes)
    }
    private func receive(_ frame: Frame, now: Double) throws {
        guard frame.epoch == epoch, epoch != 0 else { return } // reject old USB epoch
        if frame.kind == 3 {
            guard frame.body.isEmpty, let item = outgoing[frame.id], frame.offset >= item.acked, frame.offset <= item.offset else { return }
            item.acked = frame.offset; item.activity = now; onProgress(frame.id, item.acked, item.source.offer.size); return
        }
        if frame.kind == 5 {
            guard frame.body.isEmpty, let item = outgoing[frame.id], item.finished, frame.offset == item.source.offer.size else { return }
            outgoing.removeValue(forKey: frame.id)
            let retire = WKBulkControl(kind: .retired, origin: io.port, epoch: epoch, id: frame.id, generation: item.source.offer.generation)
            pendingControls[frame.id] = PendingControl(control: retire)
            onComplete(frame.id); return
        }
        if frame.kind == 4 { throw WKStreamError.invalid } // cancellation is exclusively priority control
        guard let item = incoming[frame.id] else { return }
        guard frame.offset == item.offset else { throw WKStreamError.integrity }
        if frame.kind == 1 {
            guard !frame.body.isEmpty, UInt64(frame.body.count) <= item.offer.size - item.offset else { throw WKStreamError.invalid }
            guard item.offset-item.written+UInt64(frame.body.count) <= UInt64(Self.chunk*Self.window) else { throw WKStreamError.capacity }
            item.staged.append(frame.body); item.hash.update(data: frame.body); item.offset += UInt64(frame.body.count); item.activity = now
#if WK_TREE
            if item.offer.kind == "collection", !item.manifestReported, item.manifestTask == nil, let length = item.offer.manifestBytes {
                item.manifestData.append(frame.body.prefix(max(0, length-item.manifestData.count)))
                if item.manifestData.count == length {
                    let bytes = item.manifestData, total = item.offer.size, digest = item.offer.manifestSHA256
                    item.manifestData = Data()
                    item.manifestTask = WKDiskTask(inline: inlineDisk, gate: nil, notify: onWorkAvailable) {
                        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == digest else { throw WKStreamError.integrity }
                        return try WKTreeManifest(bytes, total: total)
                    }
                }
            }
#endif
        } else if frame.kind == 2 {
            guard item.offset == item.offer.size, item.written == item.offset, item.writer == nil, item.staged.isEmpty, frame.body.count == 32, Data(item.hash.finalize()) == frame.body else { throw WKStreamError.integrity }
#if WK_TREE
            if item.offer.kind == "collection", !item.manifestReported { item.finalHash = frame.body; return }
#endif
            // A short write, altered source, disconnect, or bad digest never
            // produces a complete portal file or a successful final ACK.
            let result = WKReceivedFile(fd: item.fd, size: item.offset, sha256: frame.body.map { String(format: "%02x", $0) }.joined())
            item.fd = -1; incoming.removeValue(forKey: frame.id)
            onFile(frame.id, result)
            try enqueue(Frame(kind: 5, epoch: epoch, id: frame.id, offset: item.offset, body: Data()))
        } else { throw WKStreamError.invalid }
    }
    private func serviceDisks(now: Double) {
        for (id, item) in incoming {
            do {
#if WK_TREE
                if let result = item.manifestTask?.result() {
                    let manifest = try result.get(); item.manifestTask = nil; item.manifestReported = true
                    onManifest(id, manifest)
                    if let hash = item.finalHash {
                        let file = WKReceivedFile(fd: item.fd, size: item.offset, sha256: hash.map { String(format: "%02x", $0) }.joined())
                        item.fd = -1; incoming.removeValue(forKey: id); onFile(id, file)
                        try enqueue(Frame(kind: 5, epoch: epoch, id: id, offset: item.offset, body: Data())); continue
                    }
                }
#endif
                if let result = item.writer?.result() {
                    item.written += UInt64(try result.get()); item.writer = nil; item.activity = now
                    try enqueue(Frame(kind: 3, epoch: epoch, id: id, offset: item.written, body: Data()))
                    onProgress(id, item.written, item.offer.size)
                }
                if item.writer == nil && !item.staged.isEmpty {
                    let bytes = Data(item.staged.prefix(32768)), offset = item.written
                    item.staged = Data(item.staged.dropFirst(bytes.count))
                    item.writer = WKDiskTask(inline: inlineDisk, gate: diskGate, notify: onWorkAvailable) { [item] in
                        let n = bytes.withUnsafeBytes { pwrite(item.fd, $0.baseAddress!, $0.count, off_t(offset)) }
                        guard n == bytes.count else { throw WKStreamError.system(errno) }; return n
                    }
                }
            } catch { diagnostic(error);cancel(id); onFailure(id) }
        }
        for (id, item) in outgoing where item.granted {
            do {
                if let result = item.reader?.result() { item.prefetched = try result.get(); item.reader = nil }
                if item.reader == nil && item.prefetched.isEmpty && item.offset < item.source.offer.size {
                    let available = UInt64(Self.chunk*Self.window) - (item.offset-item.acked)
                    let n = Int(min(32768, min(available, item.source.offer.size-item.offset))), offset = item.offset
                    if n > 0 {
                        item.reader = WKDiskTask(inline: inlineDisk, gate: diskGate, notify: onWorkAvailable) { [source = item.source] in
                            try source.read(offset: offset, count: n)
                        }
                    }
                }
            } catch { diagnostic(error);cancel(id); onFailure(id) }
        }
    }
    // CDC can return a short read even with more cells already queued. Drain
    // without sleeping, but cap both bytes and syscalls so cancellation and
    // the next disk/control work keep their turn. A short read is not EOF.
    static func readAvailable(_ io: WKStreamIO) throws -> Data {
        var bytes = Data()
        for _ in 0..<32 {
            let remaining = 32768 - bytes.count
            if remaining == 0 { break }
            let part = try io.read(maximum: remaining)
            guard part.count <= remaining else { throw WKStreamError.invalid }
            if part.isEmpty { break }
            bytes.append(part)
        }
        return bytes
    }
    func step(now: Double) {
        guard !stopped else { return }
        lastWriteProgress = 0
#if WK_STREAM_PROFILE
        profileBegin(now); defer { profileEnd(now) }
#endif
        do {
            if epoch != 0 && now - lastSession >= 0.1 {
                emitControl(WKBulkControl(kind: .session, origin: io.port, epoch: epoch).encode()); lastSession = now
            }
            for id in pendingControls.keys.sorted(by: { pendingControls[$0]!.control.generation < pendingControls[$1]!.control.generation }) {
                guard var pending = pendingControls[id], now-pending.last >= 0.02 else { continue }
                if pending.first == nil { pending.first = now }
                if [.cancel, .retired].contains(pending.control.kind), now-pending.first! >= 0.3 {
                    pendingControls.removeValue(forKey: id); onCancelUnconfirmed(id); continue
                }
                pending.last = now; pendingControls[id] = pending
                emitControl(pending.control.encode())
            }
            input.append(try Self.readAvailable(io))
            guard input.count <= 65536 else { throw WKStreamError.capacity }
            var consumed = 0
            while input.count - consumed >= Self.cell {
                let bytes = Data(input[consumed..<(consumed+Self.cell)])
                guard bytes.prefix(4) == Data("WKS5".utf8) else { consumed += 1; continue }
                consumed += Self.cell
                do { let frame = try Frame.decode(bytes); try receive(frame, now: now) }
                catch {
                    diagnostic(error)
                    // The fixed boundary is intact. Reject only the named
                    // transaction, preserving unrelated verified snapshots.
                    let raw = Array(bytes[20..<36])
                    let id = UUID(uuid:(raw[0],raw[1],raw[2],raw[3],raw[4],raw[5],raw[6],raw[7],raw[8],raw[9],raw[10],raw[11],raw[12],raw[13],raw[14],raw[15])).uuidString.lowercased()
                    if bytes.readLE(at:12) as UInt64 == epoch { cancel(id); onFailure(id) }
                } // one bad transaction never kills independent snapshots
            }
            if consumed > 0 { input = Data(input.dropFirst(consumed)) }
            // Use newly received bodies/credits in this turn instead of
            // leaving disk work idle until the next timer callback.
            serviceDisks(now: now)
            let ids = outgoing.keys.sorted()
            // Round-robin fixed cells: neither an image nor a long file owns the
            // whole stream. Bounded work gives cancellation a turn every tick.
            if !ids.isEmpty {
                for _ in 0..<64 {
                    let id = ids[roundRobin % ids.count]; roundRobin = (roundRobin + 1) % ids.count
                    guard let item = outgoing[id] else { continue }
                    if now-item.activity >= timeout { cancel(id); onFailure(id); continue }
                    guard item.granted, outputBytes <= Self.queueLimit-8192 else { continue }
                    if item.offset < item.source.offer.size && item.offset-item.acked < UInt64(Self.chunk*Self.window) {
                        guard !item.prefetched.isEmpty else { continue }
                        let length = min(Self.chunk, item.prefetched.count)
                        let bytes = Data(item.prefetched.prefix(length)); item.prefetched = Data(item.prefetched.dropFirst(length))
                        try enqueue(Frame(kind: 1, epoch: epoch, id: id, offset: item.offset, body: bytes))
                        item.hash.update(data: bytes); item.offset += UInt64(length)
                    } else if item.offset == item.source.offer.size && item.acked == item.offset && !item.finished {
                        if item.finalCheck == nil {
                            let digest = Data(item.hash.finalize()); item.finalHash = digest
                            item.finalCheck = WKDiskTask(inline: inlineDisk, gate: diskGate, notify: onWorkAvailable) { [source = item.source] in source.validationFailure(expectedHash: digest) }
                        }
                        guard let result = item.finalCheck?.result() else { continue }
                        do {
                            if let code = try result.get() {
                                onDiagnostic("WKCLIP_DIAG role=\(io.port == 0 ? "host" : "target") event=ERROR code=\(code) phase=REJECT")
                                cancel(id); onFailure(id); continue
                            }
                        } catch { diagnostic(error); cancel(id); onFailure(id); continue }
                        guard let digest = item.finalHash else { throw WKStreamError.integrity }
                        try enqueue(Frame(kind: 2, epoch: epoch, id: id, offset: item.offset, body: digest))
                        item.finished = true
                    }
                }
            }
            for (id, item) in incoming where now-item.activity >= timeout { cancel(id); onFailure(id) }
            // A short nonblocking write is not backpressure: Darwin CDC may
            // accept only 1 KiB even while its queue can accept another write.
            // Drain one bounded batch now, stopping on zero/EAGAIN or 32 calls.
            // Keep the same byte budget and preserve partial-cell cancellation.
            if !output.isEmpty {
                var batch = Data(); for p in output { if batch.count+p.bytes.count > 32768 { break }; batch.append(p.bytes) }
                var sent = 0
                for _ in 0..<32 {
                    if sent == batch.count { break }
                    let n = try io.write(batch, offset: sent)
                    guard n >= 0 && n <= batch.count - sent else { throw WKStreamError.invalid }
                    if n == 0 { break }
                    sent += n
                }
                lastWriteProgress = sent
                var n = sent
                while n > 0 {
                    if n >= output[0].bytes.count { n -= output[0].bytes.count; output.removeFirst() }
                    else { output[0].bytes = Data(output[0].bytes.dropFirst(n)); output[0].started = true; n = 0 }
                }
            }
            maxBuffered = max(maxBuffered, input.count+outputBytes+incoming.values.reduce(0) { $0+$1.staged.count }+outgoing.values.reduce(0) { $0+$1.prefetched.count })
        } catch { diagnostic(error);onFault(error); stop() }
    }

}

// Main-thread facade. File reads, writes, hashes and device I/O have one separate
// utility queue. It never owns the event tap, control link, or system pasteboard.
final class WKStreamFiles {
#if WK_TREE
    private var selectionJobs = 0 // main-thread admission; filesystem work is cancellable
    @discardableResult func prepareSelection(urls: [URL], nonce: String, completion: @escaping (Result<WKStreamSource, Error>) -> Void) -> WKTreeJob? {
        guard selectionJobs < 2 else { completion(.failure(WKStreamError.capacity)); return nil }
        selectionJobs += 1; let job = WKTreeJob()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { () throws -> WKStreamSource in
                // Preserve the single-file path and its immediate metadata offer.
                if urls.count == 1, try urls[0].resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    return try WKStreamSource(url: urls[0], nonce: nonce)
                }
                return try WKStreamSource(tree: WKTransferTree(urls: urls, job: job), nonce: nonce)
            }
            DispatchQueue.main.async { self?.selectionJobs -= 1; completion(result) }
        }
        return job
    }
#endif
    final class ImageJob {
        private let lock = NSLock(); private var revoked = false
        func cancel() { lock.lock(); revoked = true; lock.unlock() }
        func check() throws { lock.lock(); let value = revoked; lock.unlock(); if value { throw WKStreamError.changed } }
    }
    private var imageJobs = 0 // main-thread admission, at most two resident conversions
    private let worker = DispatchQueue(label: "WiredKVM.CH32.files", qos: .utility)
    private var engine: WKStreamEngine?, timer: DispatchSourceTimer?
    private var writeReady: WKWriteReadiness?, connectionGeneration: UInt64 = 0
    private let connect: () throws -> WKStreamIO
    private var directory: URL?, desiredEpoch: UInt64 = 0
    private var running = false, nextAttempt: Double = 0
    private(set) var isReady = false // main-thread observation only
    var onControl: (Data) -> Void = { _ in }
    var onAccepted: (String) -> Void = { _ in }
    var onProgress: (String, UInt64, UInt64) -> Void = { _,_,_ in }
    var onFile: (String, WKReceivedFile) -> Void = { _, _ in }
#if WK_TREE
    var onManifest: (String, WKTreeManifest) -> Void = { _, _ in }
#endif
    var onFailure: (String) -> Void = { _ in }
    var onComplete: (String) -> Void = { _ in }
    var onDiagnostic: (String) -> Void = { _ in }
    init(connect: @escaping () throws -> WKStreamIO) { self.connect = connect }
    func start() {
        worker.async { [self] in
            guard !running else { return }; running = true
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("WiredKVM-stream-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); directory = root
                let t = DispatchSource.makeTimerSource(queue: worker); timer = t
                t.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(200))
                t.setEventHandler { [weak self] in self?.service() }; service(); t.resume()
            } catch { DispatchQueue.main.async { wkLog("WKCLIP_STATUS ERROR ch32-file-channel-unavailable") } }
        }
    }
    private func service(writeWake: Bool = false) {
        guard running, let directory else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if engine == nil || engine?.stopped == true {
            guard now >= nextAttempt else { return }; nextAttempt = now + 0.5
            do {
                writeReady?.stop(); writeReady = nil
                let io = try connect(), e = WKStreamEngine(io: io, directory: directory)
                connectionGeneration &+= 1; let generation = connectionGeneration
                engine = e; e.setEpoch(desiredEpoch)
                e.onWorkAvailable = { [weak self] in
                    self?.worker.async { [weak self] in
                        guard let self, self.connectionGeneration == generation else { return }
                        self.service()
                    }
                }
                if let fd = io.writeDescriptor {
                    writeReady = try? WKWriteReadiness(fd: fd, queue: worker) { [weak self] in
                        guard let self, self.connectionGeneration == generation else { return }
                        self.service(writeWake: true)
                    }
                }
                e.onControl = { [weak self] data in DispatchQueue.main.async { self?.onControl(data) } }
                e.onDiagnostic = { [weak self] line in
                    wkLog(line)
                    let code = line.split(separator: " ").first(where: { $0.hasPrefix("code=") }).map { String($0.dropFirst(5)) }
                    if let code { DispatchQueue.main.async { self?.onDiagnostic(code) } }
                }
                e.onAccepted = { [weak self] id in DispatchQueue.main.async { self?.onAccepted(id) } }
                // UI progress is throttled; no per-cell main-thread flood.
                var lastProgress: [String: Double] = [:]
                e.onProgress = { [weak self] id, n, total in
                    let now = ProcessInfo.processInfo.systemUptime
                    if n == total || now - (lastProgress[id] ?? -10) >= 0.1 {
                        lastProgress[id] = now
                        if n == total { lastProgress.removeValue(forKey: id) }
                        DispatchQueue.main.async { self?.onProgress(id, n, total) }
                    }
                }
                e.onRetire = { id in lastProgress.removeValue(forKey: id) }
                e.onFile = { [weak self] id, file in DispatchQueue.main.async { self?.onFile(id, file) } }
#if WK_TREE
                e.onManifest = { [weak self] id, manifest in DispatchQueue.main.async { self?.onManifest(id, manifest) } }
#endif
                e.onFailure = { [weak self] id in lastProgress.removeValue(forKey: id); DispatchQueue.main.async { self?.onFailure(id) } }
                e.onComplete = { [weak self] id in lastProgress.removeValue(forKey: id); DispatchQueue.main.async { self?.onComplete(id) } }
                e.onCancelUnconfirmed = { id in DispatchQueue.main.async { wkLog("WKCLIP_STATUS ERROR bulk-cancel-unconfirmed " + id) } }
                e.onFault = { [weak self] _ in DispatchQueue.main.async { self?.isReady = false } }
                DispatchQueue.main.async { [weak self] in self?.isReady = true }
            } catch { DispatchQueue.main.async { [weak self] in self?.isReady = false }; return }
        }
        engine?.step(now: now)
        if let e = engine, !e.stopped {
            // A driver can report writable yet return EAGAIN. Disable that
            // readiness turn on zero progress; the health timer retries later.
            writeReady?.setEnabled(e.outputBytes > 0 && (!writeWake || e.lastWriteProgress > 0))
        } else { writeReady?.stop(); writeReady = nil }
    }
    func setEpoch(_ epoch: UInt64) { worker.async { [self] in desiredEpoch = epoch; engine?.setEpoch(epoch) } }
    func prepare(url: URL, nonce: String, completion: @escaping (Result<WKStreamSource, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async { let result = Result { try WKStreamSource(url: url, nonce: nonce) }; DispatchQueue.main.async { completion(result) } }
    }
    @discardableResult func prepareImage(clipboard: WKClipboard, revision: Int, nonce: String,
        completion: @escaping (Result<WKStreamSource, Error>) -> Void) -> ImageJob? {
        guard imageJobs < 2 else { completion(.failure(WKStreamError.capacity)); return nil }
        imageJobs += 1; let job = ImageJob()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () throws -> WKStreamSource in
                try job.check()
                guard let png = try clipboard.bulkImagePNG(expectedRevision: revision) else { throw WKStreamError.invalid }
                try job.check()
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("wk-image-"+UUID().uuidString+".png")
                defer { try? FileManager.default.removeItem(at: url) }
                try png.write(to: url, options: .withoutOverwriting)
                let source = try WKStreamSource(url: url, nonce: nonce, kind: "png", unlinkAfterOpen: true); try job.check(); return source
            }
            DispatchQueue.main.async { self?.imageJobs -= 1; completion(result) }
        }
        return job
    }
    @discardableResult func decodeImage(file: WKReceivedFile, completion: @escaping (Result<WKBulkImage, Error>) -> Void) -> ImageJob? {
        guard imageJobs < 2 else { completion(.failure(WKStreamError.capacity)); return nil }
        imageJobs += 1; let job = ImageJob()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () throws -> WKBulkImage in
                guard file.size <= WKStreamOffer.maximumImage else { throw WKStreamError.capacity }
                var bytes = Data(); bytes.reserveCapacity(Int(file.size))
                while bytes.count < file.size { try job.check(); bytes.append(try file.read(offset: UInt64(bytes.count), maximum: 65536)) }
                try job.check(); let image = try WKBulkImage.prepare(bytes); try job.check(); return image
            }
            DispatchQueue.main.async { self?.imageJobs -= 1; completion(result) }
        }
        return job
    }
    func send(_ source: WKStreamSource) { worker.async { [self] in
        do { guard let engine else { throw WKStreamError.disconnected }; try engine.add(source, now: ProcessInfo.processInfo.systemUptime) }
        catch { DispatchQueue.main.async { self.onFailure(source.offer.id) } }
    } }
    func expect(_ offer: WKStreamOffer) { worker.async { [self] in
        do { guard let engine else { throw WKStreamError.disconnected }; try engine.expect(offer, now: ProcessInfo.processInfo.systemUptime) }
        catch { DispatchQueue.main.async { self.onFailure(offer.id) } }
    } }
    func control(_ data: Data) { worker.async { [self] in engine?.control(data) } }
    func cancel(_ id: String) { worker.async { [self] in engine?.cancel(id) } }
    func stop() { worker.async { [self] in running = false; connectionGeneration &+= 1; timer?.cancel(); timer = nil; writeReady?.stop(); writeReady = nil; engine?.stop(); engine = nil; if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil; DispatchQueue.main.async { self.isReady = false } } }
}
