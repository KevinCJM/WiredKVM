import Foundation
import Darwin
import IOKit.hid

protocol WKTransport: AnyObject {
    var onReport: (Data) -> Void { get set }
    var onConnection: (Bool) -> Void { get set }
    var onError: (String) -> Void { get set }
    func start()
    func tick(_ time: Double)
    func send(_ bytes: Data) -> Bool
    func stop()
}

// Whole reports may be prioritized, but an already-started stream frame must
// finish first. Keep a bounded prefix of realtime frames, preserving their FIFO.
struct WKReportWriteQueue {
    private(set) var bytes = Data()
    private var priorityEnd = 0
    private var leadingNormalBytes = 0
    var isEmpty: Bool { bytes.isEmpty }
    mutating func clear() { bytes.removeAll(); priorityEnd = 0; leadingNormalBytes = 0 }
    mutating func enqueue(_ report: Data, realtime: Bool = false) -> Bool {
        let realtimeBytes = max(0, priorityEnd-leadingNormalBytes)
        let normalBytes = bytes.count-realtimeBytes
        let occupied = realtime ? realtimeBytes : normalBytes
        guard report.count == WKReport.size, occupied + report.count <= 64 * WKReport.size else { return false }
        if realtime {
            if priorityEnd == 0 {
                leadingNormalBytes = bytes.count % WKReport.size
                priorityEnd = leadingNormalBytes
            }
            bytes.insert(contentsOf: report, at: bytes.startIndex + priorityEnd)
            priorityEnd += report.count
        } else { bytes.append(report) }
        return true
    }
    mutating func consume(_ count: Int) {
        precondition((0...bytes.count).contains(count))
        bytes.removeFirst(count); priorityEnd = max(0, priorityEnd-count)
        leadingNormalBytes = max(0, leadingNormalBytes-count)
    }
}

// Only a same-user Unix domain socket is allowed; there is no TCP fallback.
final class WKUnixTransport: WKTransport {
    // Both sources must finish cancellation before the descriptor can be reused.
    // The cancellation handlers retain this lease, never the transport itself.
    private final class SocketLease {
        let fd: Int32
        private var sources = 2
        init(_ fd: Int32) { self.fd = fd }
        func sourceCancelled() {
            sources -= 1
            if sources == 0 { Darwin.close(fd) }
        }
    }
    var onReport: (Data) -> Void = { _ in }
    var onConnection: (Bool) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    let path: String
    private var fd: Int32 = -1
    private var input = Data()
    private var output = WKReportWriteQueue()
    private var nextAttempt: Double = 0
    private var generation: UInt64 = 0
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var writerSuspended = true
    init(path: String) { self.path = path }
    func start() {}
    func stop() { disconnect() }
    deinit { disconnect(notify: false) }

    private func disconnect(notify: Bool = true) {
        let wasConnected = fd >= 0
        fd = -1; generation &+= 1
        reader?.cancel(); reader = nil
        if let writer {
            writer.cancel()
            // A suspended dispatch source cannot complete cancellation.
            if writerSuspended { writer.resume() }
        }
        writer = nil; writerSuspended = true
        input.removeAll(); output.clear()
        if wasConnected && notify { onConnection(false) }
    }

    private func watchSocket(_ candidate: Int32) {
        generation &+= 1
        let expected = generation
        let lease = SocketLease(candidate)
        let readSource = DispatchSource.makeReadSource(fileDescriptor: candidate, queue: .main)
        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: candidate, queue: .main)
        readSource.setEventHandler { [weak self] in
            guard let self, self.fd == candidate, self.generation == expected else { return }
            self.drainRead(candidate, generation: expected)
        }
        writeSource.setEventHandler { [weak self] in
            guard let self, self.fd == candidate, self.generation == expected else { return }
            self.drainWrite(candidate, generation: expected)
        }
        readSource.setCancelHandler { lease.sourceCancelled() }
        writeSource.setCancelHandler { lease.sourceCancelled() }
        reader = readSource; writer = writeSource; writerSuspended = true
        readSource.resume()
    }

    private func drainRead(_ candidate: Int32, generation expected: UInt64) {
        var buffer = [UInt8](repeating: 0, count: 16 * WKReport.size)
        // Bound each callback to 64 reports so continuous traffic yields to UI,
        // clipboard commands and link timers. Read readiness schedules the rest.
        for _ in 0..<4 {
            let count = Darwin.read(candidate, &buffer, buffer.count)
            if count > 0 {
                input.append(contentsOf: buffer.prefix(count))
                while input.count >= WKReport.size {
                    let report = Data(input.prefix(WKReport.size)); input.removeFirst(WKReport.size)
                    onReport(report)
                    // User callbacks may stop and reconnect, reusing the fd.
                    guard fd == candidate, generation == expected else { return }
                }
            } else if count == 0 { disconnect(); return }
            else if errno == EINTR { continue }
            else if errno == EWOULDBLOCK || errno == EAGAIN { return }
            else { disconnect(); return }
        }
    }

    private func drainWrite(_ candidate: Int32, generation expected: UInt64) {
        for _ in 0..<4 where !output.isEmpty {
            let count = output.bytes.withUnsafeBytes { Darwin.write(candidate, $0.baseAddress, $0.count) }
            if count > 0 { output.consume(count) }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EWOULDBLOCK || errno == EAGAIN) { return }
            else { disconnect(); return }
        }
        guard fd == candidate, generation == expected else { return }
        if output.isEmpty && !writerSuspended {
            writer?.suspend(); writerSuspended = true
        }
    }

    private func connectSocket() {
        guard path.hasPrefix("/"), path.utf8.count < 104 else { onError("invalid-private-socket-path"); return }
        var info = stat(); var parent = stat()
        let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard path.withCString({ lstat($0, &info) }) == 0,
              parentPath.withCString({ lstat($0, &parent) }) == 0,
              info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_mode & 0o077 == 0,
              parent.st_uid == getuid(), (parent.st_mode & S_IFMT) == S_IFDIR,
              parent.st_mode & 0o077 == 0 else { return }
        let candidate = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard candidate >= 0 else { onError("socket-create-failed"); return }
        guard fcntl(candidate, F_SETFL, fcntl(candidate, F_GETFL) | O_NONBLOCK) == 0 else {
            Darwin.close(candidate); onError("socket-nonblocking-failed"); return
        }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            path.utf8CString.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(candidate, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard result == 0, getpeereid(candidate, &uid, &gid) == 0, uid == getuid() else {
            Darwin.close(candidate); return
        }
        var noPipe: Int32 = 1
        _ = setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(candidate, F_SETFL, fcntl(candidate, F_GETFL) | O_NONBLOCK)
        fd = candidate; watchSocket(candidate); onConnection(true)
    }

    func send(_ bytes: Data) -> Bool {
        guard fd >= 0, output.enqueue(bytes) else { return false }
        if writerSuspended { writerSuspended = false; writer?.resume() }
        return true
    }
    // Insert after any partially written frame and earlier realtime reports;
    // never splice a 64-byte report or reorder gesture fragments.
    func sendRealtime(_ bytes: Data) -> Bool {
        guard fd >= 0, output.enqueue(bytes, realtime: true) else { return false }
        if writerSuspended { writerSuspended = false; writer?.resume() }
        return true
    }

    func tick(_ time: Double) {
        if fd < 0 {
            if time >= nextAttempt { nextAttempt = time + 1; connectSocket() }
        }
    }
}

final class WKHIDTransport: WKTransport {
    var onReport: (Data) -> Void = { _ in }
    var onConnection: (Bool) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: WKReport.size)
    private let writeQueue = DispatchQueue(label: "WiredKVM.clipboard.hid-output")
    private let queueLock = NSLock()
    private var queued = 0
    private var generation: UInt64 = 0
    private let identities: [(vendor: Int, product: Int)]
    private let serial: String
    private var nextAttach: Double = 0

    init(vendor: Int = 0x303a, product: Int = 0x700c, serial: String = "Prototype-DoNotShip") {
        self.identities = [(vendor, product)]; self.serial = serial
    }
    private init(identities: [(vendor: Int, product: Int)], serial: String) {
        self.identities = identities; self.serial = serial
    }
    static func ch32Target() -> WKHIDTransport {
        WKHIDTransport(identities: WKUSBDiscovery.targetIdentities, serial: "CH32V407-DoNotShip")
    }
    deinit { buffer.deallocate() }

    func start() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        let matching: [[String: Any]] = identities.map {
            [kIOHIDVendorIDKey: $0.vendor, kIOHIDProductIDKey: $0.product,
             kIOHIDManufacturerKey: "WiredKVM Prototype", kIOHIDSerialNumberKey: serial,
             kIOHIDPrimaryUsagePageKey: 0xff60, kIOHIDPrimaryUsageKey: 0x61]
        }
        IOHIDManagerSetDeviceMatchingMultiple(m, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { context, result, _, device in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<WKHIDTransport>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { context, _, _, device in
            guard let context else { return }
            Unmanaged<WKHIDTransport>.fromOpaque(context).takeUnretainedValue().removed(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess { onError("hid-access-denied-\(result)") }
    }

    private func attach(_ candidate: IOHIDDevice) {
        guard device == nil,
              let vendor = IOHIDDeviceGetProperty(candidate, kIOHIDVendorIDKey as CFString) as? Int,
              let product = IOHIDDeviceGetProperty(candidate, kIOHIDProductIDKey as CFString) as? Int,
              identities.contains(where: { $0.vendor == vendor && $0.product == product }),
              IOHIDDeviceGetProperty(candidate, kIOHIDManufacturerKey as CFString) as? String == "WiredKVM Prototype",
              IOHIDDeviceGetProperty(candidate, kIOHIDSerialNumberKey as CFString) as? String == serial,
              IOHIDDeviceGetProperty(candidate, kIOHIDPrimaryUsagePageKey as CFString) as? Int == 0xff60,
              IOHIDDeviceGetProperty(candidate, kIOHIDPrimaryUsageKey as CFString) as? Int == 0x61 else { return }
        let result = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { onError("hid-device-open-denied-\(result)"); return }
        device = candidate; generation &+= 1
        IOHIDDeviceRegisterInputReportCallback(candidate, buffer, WKReport.size,
            { context, result, _, type, reportID, report, length in
                guard let context, result == kIOReturnSuccess, type == kIOHIDReportTypeInput,
                      reportID == 0, length == WKReport.size else { return }
                let owner = Unmanaged<WKHIDTransport>.fromOpaque(context).takeUnretainedValue()
                guard owner.device != nil else { return }
                owner.onReport(Data(bytes: report, count: length))
            }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(candidate, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        onConnection(true)
    }

    private func removed(_ candidate: IOHIDDevice) {
        guard let current = device, CFEqual(current, candidate) else { return }
        detach()
    }

    private func detach() {
        guard let old = device else { return }
        device = nil; generation &+= 1
        IOHIDDeviceUnscheduleFromRunLoop(old, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        // Output calls already queued retain the IOHIDDevice, and are serialized
        // before close. Input buffer remains owned until the transport is released.
        writeQueue.async { _ = IOHIDDeviceClose(old, IOOptionBits(kIOHIDOptionsTypeNone)) }
        onConnection(false)
    }

    func send(_ bytes: Data) -> Bool {
        guard let current = device, bytes.count == WKReport.size else { return false }
        queueLock.lock()
        guard queued < 64 else { queueLock.unlock(); return false }
        queued += 1; queueLock.unlock()
        let sentGeneration = generation
        writeQueue.async { [weak self] in
            guard let self else { return }
            let result = bytes.withUnsafeBytes { buffer in
                IOHIDDeviceSetReport(current, kIOHIDReportTypeOutput, 0,
                                     buffer.bindMemory(to: UInt8.self).baseAddress!, bytes.count)
            }
            self.queueLock.lock(); self.queued -= 1; self.queueLock.unlock()
            if result != kIOReturnSuccess {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == sentGeneration else { return }
                    self.onError("hid-write-failed-\(result)"); self.detach()
                }
            }
        }
        return true
    }
    func tick(_ time: Double) {
        if device == nil, time >= nextAttach, let manager {
            nextAttach = time + 1
            if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
                for candidate in devices where device == nil { attach(candidate) }
            }
        }
    }
    func stop() {
        detach()
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }
        writeQueue.sync {}
    }
}
