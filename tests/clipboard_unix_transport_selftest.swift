// Standalone test: swiftc -D WK_PORTABLE -O -framework AppKit -framework IOKit
// host/clipboard/WKOnboarding.swift host/clipboard/WKClipboardTransport.swift
// tests/clipboard_unix_transport_selftest.swift -o /tmp/wk-unix-transport-test
// Only private temporary AF_UNIX sockets; no clipboard, HID open, UART or GUI.
import Foundation
import Darwin

// The transport only depends on the raw report size, not its application format.
enum WKReport { static let size = 64 }

private struct Failure: Error, CustomStringConvertible { let description: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(description: message) }
}
private func pump(_ seconds: Double = 0.01) {
    let end = Date(timeIntervalSinceNow: seconds)
    repeat { RunLoop.current.run(until: min(end, Date(timeIntervalSinceNow: 0.002))) } while Date() < end
}
private func wait(_ message: String, timeout: Double = 2, _ ready: () -> Bool) throws {
    let end = Date(timeIntervalSinceNow: timeout)
    while !ready() && Date() < end { pump(0.002) }
    try expect(ready(), message)
}
private func report(_ sequence: Int) -> Data {
    var data = Data(repeating: UInt8(truncatingIfNeeded: sequence), count: WKReport.size)
    for index in 0..<8 { data[index] = UInt8(truncatingIfNeeded: sequence >> (index * 8)) }
    return data
}

private final class Server {
    let directory: URL
    let path: String
    var listener: Int32 = -1
    var peer: Int32 = -1
    init() throws {
        directory = URL(fileURLWithPath: "/tmp/wk-unix-" + String(UUID().uuidString.prefix(8)))
        path = directory.appendingPathComponent("socket").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try expect(listener >= 0, "server socket")
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.initializeMemory(as: UInt8.self, repeating: 0)
            path.utf8CString.withUnsafeBytes { target.copyBytes(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try expect(bound == 0 && chmod(path, 0o600) == 0 && listen(listener, 4) == 0, "server bind/listen")
        try expect(fcntl(listener, F_SETFL, O_NONBLOCK) == 0, "nonblocking listener")
    }
    deinit {
        closePeer()
        if listener >= 0 { Darwin.close(listener) }
        try? FileManager.default.removeItem(at: directory)
    }
    func acceptPeer() throws {
        peer = Darwin.accept(listener, nil, nil)
        try expect(peer >= 0 && fcntl(peer, F_SETFL, O_NONBLOCK) == 0, "accept same-user client")
        var enabled: Int32 = 1
        _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }
    func closePeer() { if peer >= 0 { Darwin.close(peer); peer = -1 } }
    func write(_ data: Data) throws {
        var offset = 0
        let end = Date(timeIntervalSinceNow: 2)
        while offset < data.count && Date() < end {
            let count = data.withUnsafeBytes { Darwin.write(peer, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { pump(0.002) }
            else { throw Failure(description: "server write") }
        }
        try expect(offset == data.count, "server write deadline")
    }
    func read() throws -> Data {
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<256 {
            let count = Darwin.read(peer, &buffer, buffer.count)
            if count > 0 { result.append(contentsOf: buffer.prefix(count)) }
            else if count == 0 { break }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { break }
            else { throw Failure(description: "server read") }
        }
        return result
    }
}

@main private enum UnixTransportSelfTest {
    static func main() {
        do {
            try realtimeQueueFraming()
            try framingAndFairness()
            try backpressure()
            try reconnectAndCancellation()
            try privateSocketPolicy()
            print("WK_UNIX_EVENT_TRANSPORT_TEST_PASS")
        } catch {
            fputs("WK_UNIX_EVENT_TRANSPORT_TEST_FAIL \(error)\n", stderr)
            exit(1)
        }
    }
    static func realtimeQueueFraming() throws {
        var queue = WKReportWriteQueue()
        for frame in [report(1), report(2), report(3)] { try expect(queue.enqueue(frame), "queue bulk") }
        var delivered = Data(queue.bytes.prefix(17)); queue.consume(17)
        try expect(queue.enqueue(report(100), realtime: true), "queue realtime")
        try expect(queue.enqueue(report(101), realtime: true), "queue next realtime")
        for size in [5, 29, 127, 11, 1000] {
            let count = min(size, queue.bytes.count)
            delivered.append(queue.bytes.prefix(count)); queue.consume(count)
        }
        let expected = [report(1), report(100), report(101), report(2), report(3)].reduce(into: Data()) { $0.append($1) }
        try expect(delivered == expected && queue.isEmpty, "priority spliced a partial report or changed realtime order")
        for _ in 0..<64 { try expect(queue.enqueue(report(1)), "bulk capacity") }
        try expect(!queue.enqueue(report(1)), "bulk exceeded bound")
        for _ in 0..<64 { try expect(queue.enqueue(report(2), realtime: true), "reserved realtime capacity") }
        try expect(!queue.enqueue(report(2), realtime: true), "realtime exceeded bound")
        queue.clear(); try expect(queue.isEmpty, "clear retained output")
        for _ in 0..<64 { try expect(queue.enqueue(report(2), realtime: true), "realtime capacity") }
        for _ in 0..<64 { try expect(queue.enqueue(report(1)), "realtime traffic exhausted reserved clipboard capacity") }
        try expect(!queue.enqueue(report(1)), "reserved clipboard queue exceeded bound")
        print("WK_UNIX_TEST realtime-priority-partial-frame-FIFO-bounds-reservation PASS")
    }

    static func framingAndFairness() throws {
        let server = try Server()
        let channel = WKUnixTransport(path: server.path)
        defer { channel.stop(); pump() }
        var reports: [Data] = [], connections: [Bool] = [], mainThread = true
        channel.onConnection = { connections.append($0); mainThread = mainThread && Thread.isMainThread }
        channel.onReport = { reports.append($0); mainThread = mainThread && Thread.isMainThread }
        channel.tick(0); try server.acceptPeer()
        try expect(connections == [true], "connection callback")
        try server.write(Data(report(1).prefix(17)))
        pump(); try expect(reports.isEmpty, "split report delivered early")
        var tail = Data(report(1).dropFirst(17)); tail.append(report(2))
        try server.write(tail)
        try wait("read must progress without tick") { reports.count == 2 }
        try expect(reports == [report(1), report(2)], "split/concatenated reports")

        let initialCount = reports.count
        var yieldedAt: Int?
        channel.onReport = {
            reports.append($0); mainThread = mainThread && Thread.isMainThread
            if reports.count == initialCount + 1 { DispatchQueue.main.async { yieldedAt = reports.count - initialCount } }
        }
        let burst = (3..<259).map(report)
        try server.write(burst.reduce(into: Data()) { $0.append($1) })
        try wait("burst/no duplicates") { reports.count == 258 && yieldedAt != nil }
        try expect(Array(reports.dropFirst(2)) == burst, "burst ordering")
        try expect(yieldedAt! <= 64, "read drain monopolized main queue")
        pump(); try expect(reports.count == 258 && mainThread, "callback queue/duplicate delivery")

        try expect(!channel.send(Data(count: 63)) && !channel.send(Data(count: 65)), "invalid output report")
        let outgoing = (300..<364).map(report)
        for frame in outgoing { try expect(channel.send(frame), "64 report capacity") }
        try expect(!channel.send(report(364)), "output queue exceeded 64 reports")
        var received = Data()
        let deadline = Date(timeIntervalSinceNow: 2)
        while received.count < 64 * 64 && Date() < deadline { pump(0.002); received.append(try server.read()) }
        try expect(received == outgoing.reduce(into: Data()) { $0.append($1) }, "event-driven output ordering")
        print("WK_UNIX_TEST framing-burst-main-queue-budget-bounds PASS")
    }

    static func backpressure() throws {
        let server = try Server(), channel = WKUnixTransport(path: server.path)
        defer { channel.stop(); pump() }
        channel.tick(0); try server.acceptPeer()
        // Stay above Darwin's socket low-water mark, otherwise an empty peer
        // may never be considered writable at all (an invalid fixture).
        var capacity: Int32 = 8192
        _ = setsockopt(server.peer, SOL_SOCKET, SO_RCVBUF, &capacity, socklen_t(MemoryLayout<Int32>.size))
        var expected = Data(), sequence = 0, blocked = false
        // Do not read from the server until both the kernel and bounded output
        // buffer are full. This exercises genuine EAGAIN, not only queue size.
        for _ in 0..<512 {
            for _ in 0..<64 {
                let frame = report(sequence)
                if !channel.send(frame) { break }
                expected.append(frame); sequence += 1
            }
            pump(0.005)
            let frame = report(sequence)
            if !channel.send(frame) {
                pump(0.02)
                if !channel.send(frame) { blocked = true; break }
            }
            expected.append(frame); sequence += 1
        }
        try expect(blocked, "did not reach socket backpressure")
        var mainQueueRan = false
        DispatchQueue.main.async { mainQueueRan = true }
        try wait("blocked output starved main queue") { mainQueueRan }
        try expect(!channel.send(report(sequence)), "blocked queue grew")
        var received = Data()
        let deadline = Date(timeIntervalSinceNow: 3)
        while received.count < expected.count && Date() < deadline {
            received.append(try server.read()); pump(0.002)
        }
        try expect(received == expected, "EAGAIN resume lost/duplicated bytes expected=\(expected.count) received=\(received.count) prefix=\(received == expected.prefix(received.count))")
        try expect(channel.send(report(sequence)), "writer did not recover")
        var last = Data()
        let finalDeadline = Date(timeIntervalSinceNow: 1)
        while last.count < 64 && Date() < finalDeadline { pump(0.002); last.append(try server.read()) }
        try expect(last == report(sequence), "idle writer did not resume")
        print("WK_UNIX_TEST EAGAIN-recovery-no-tick PASS")
    }

    static func reconnectAndCancellation() throws {
        let server = try Server()
        var channel: WKUnixTransport? = WKUnixTransport(path: server.path)
        var states: [Bool] = [], reports: [Data] = []
        channel!.onConnection = { states.append($0) }
        channel!.onReport = { reports.append($0) }
        channel!.tick(0); try server.acceptPeer()
        try server.write(Data(report(1).prefix(19)))
        pump(); server.closePeer()
        try wait("EOF callback") { states == [true, false] }
        try expect(!channel!.send(report(9)), "send after EOF")
        channel!.tick(1.1); try server.acceptPeer()
        try server.write(report(2))
        try wait("reconnect framing") { reports.count == 1 }
        try expect(reports == [report(2)], "old partial input crossed sessions")

        for _ in 0..<64 { try expect(channel!.send(report(3)), "queue before stop") }
        channel!.stop(); server.closePeer()
        // Reconnect before old cancellation handlers run; they must never close
        // the new fd or flush any old connection's queued reports into it.
        channel!.tick(2.2); try server.acceptPeer()
        try expect(channel!.send(report(4)), "send on immediate reconnect")
        var received = Data()
        let deadline = Date(timeIntervalSinceNow: 1)
        while received.count < 64 && Date() < deadline { pump(0.002); received.append(try server.read()) }
        try expect(received == report(4), "old output crossed sessions/new fd was closed")
        channel!.onReport = { reports.append($0); channel?.stop() }
        try server.write(report(5) + report(6))
        try wait("reentrant stop") { reports.count == 2 }
        pump(); try expect(reports.last == report(5), "read continued after callback stopped transport")
        channel = nil; pump()
        try expect(states == [true, false, true, false, true, false], "duplicate lifecycle callbacks")

        // Deallocation with an idle, suspended write source must be safe too.
        server.closePeer()
        var idle: WKUnixTransport? = WKUnixTransport(path: server.path)
        idle!.tick(0); try server.acceptPeer()
        idle = nil; pump()
        var byte: UInt8 = 0
        try expect(Darwin.read(server.peer, &byte, 1) == 0, "dispatch source retained transport/descriptor")
        print("WK_UNIX_TEST EOF-reconnect-stop-deinit PASS")
    }

    static func privateSocketPolicy() throws {
        let server = try Server(), channel = WKUnixTransport(path: server.path)
        defer { channel.stop(); pump() }
        var connections = 0
        channel.onConnection = { if $0 { connections += 1 } }
        try expect(chmod(server.directory.path, 0o755) == 0, "set unsafe parent")
        channel.tick(0); try expect(connections == 0, "unsafe parent accepted")
        try expect(chmod(server.directory.path, 0o700) == 0 && chmod(server.path, 0o666) == 0, "set unsafe socket")
        channel.tick(1.1); try expect(connections == 0, "unsafe socket accepted")
        try expect(chmod(server.path, 0o600) == 0, "restore private socket")
        channel.tick(2.2); try server.acceptPeer()
        try expect(connections == 1, "same-UID private socket rejected")
        print("WK_UNIX_TEST private-socket-policy PASS")
    }

}
