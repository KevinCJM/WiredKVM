// Standalone, or linked into the CH32 test harness with WK_CH32_TEST.
// Uses ephemeral loopback sockets and memory fixtures. No mounts, pasteboards,
// user files, USB devices, system proxy changes, or running-app changes.
import Foundation
import CryptoKit
import Darwin

private final class PortalTestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func put(_ value: T) { lock.lock(); self.value = value; lock.unlock() }
}

#if !WK_CH32_TEST
@main
#endif
struct WKFilePortalSelfTest {
    static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
    }
    static func mustThrow(_ message: String, _ body: () throws -> Void) {
        do { try body(); preconditionFailure(message) } catch {}
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func canonicalDirectoryTests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wk-portal-path-" + UUID().uuidString)
        let real = root.appendingPathComponent("real"), alias = root.appendingPathComponent("alias")
        let mount = real.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { _ = unlink(alias.path); _ = rmdir(mount.path); _ = rmdir(real.path); _ = rmdir(root.path) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let canonical = try WKFilePortal.canonicalLocalDirectory(alias.appendingPathComponent("mount"))
        check(canonical.lastPathComponent == "mount" && canonical.deletingLastPathComponent().lastPathComponent == "real", "resolve before mounting")
        var a = stat(), b = stat()
        check(stat(mount.path, &a) == 0 && stat(canonical.path, &b) == 0 && a.st_ino == b.st_ino && a.st_dev == b.st_dev, "same local directory")
        mustThrow("missing path cannot silently retain an alias") { _ = try WKFilePortal.canonicalLocalDirectory(root.appendingPathComponent("missing")) }
        print("PORTAL_CANONICAL_DIRECTORY_PASS before_mount=true symlink_parent=true no_mount=true")
    }

    struct Response: Sendable { let status: Int, headers: [String: String], body: Data }
    static func request(_ url: URL, _ method: String = "GET", headers: [String: String] = [:], target: String? = nil) throws -> Response {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WKFilePortalError.system(errno) }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(url.port!).bigEndian
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw WKFilePortalError.system(errno) }
        var text = "\(method) \(target ?? URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedPath) HTTP/1.1\r\n"
        if headers["Host"] == nil { text += "Host: 127.0.0.1:\(url.port!)\r\n" }
        for key in headers.keys.sorted() { text += "\(key): \(headers[key]!)\r\n" }
        text += "Connection: close\r\n\r\n"
        let sent = Data(text.utf8).withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == text.utf8.count else { throw WKFilePortalError.system(errno) }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count == 0 { break }
            guard count > 0 else { throw WKFilePortalError.system(errno) }
            bytes.append(contentsOf: buffer.prefix(count))
            check(bytes.count < 2 * 1024 * 1024, "bounded test response")
        }
        guard let end = bytes.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: bytes[..<end.lowerBound], encoding: .utf8) else { throw WKFilePortalError.failed }
        let lines = headerText.components(separatedBy: "\r\n")
        let status = Int(lines[0].split(separator: " ")[1])!
        var parsed: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            parsed[String(pair[0]).lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        return Response(status: status, headers: parsed, body: Data(bytes[end.upperBound...]))
    }

    static func storeTests() throws {
        let bytes = Data("fixture".utf8), hash = digest(bytes), store = WKPortalStore()
        _ = try store.offer(id: "copy1", name: "中文 & test.txt", size: bytes.count, sha256: hash)
        _ = try store.offer(id: "copy1", name: "中文 & test.txt", size: bytes.count, sha256: hash)
        mustThrow("immutable id") { _ = try store.offer(id: "copy1", name: "changed.txt", size: bytes.count, sha256: hash) }
        for name in ["", ".", "..", "../x", "a/b", "a\\b", "a\0b", "bad\nname"] {
            mustThrow("invalid name") { _ = try store.offer(id: "other", name: name, size: bytes.count, sha256: hash) }
        }
        mustThrow("size bound") { _ = try store.offer(id: "other", name: "x", size: 1024 * 1024 + 1, sha256: hash) }
        try store.fulfill(id: "copy1", data: bytes)
        check(try store.wait(id: "copy1", timeout: 0.1, cancelled: { false }) == bytes, "verified data")
        _ = try store.offer(id: "empty", name: "empty", size: 0, sha256: digest(Data()))
        check(try store.wait(id: "empty", timeout: 0.1, cancelled: { false }).isEmpty, "empty file verified at offer")
        mustThrow("empty file still needs correct digest") { _ = try store.offer(id: "wrongempty", name: "x", size: 0, sha256: hash) }
        _ = try store.offer(id: "bad", name: "bad", size: bytes.count, sha256: hash)
        mustThrow("integrity") { try store.fulfill(id: "bad", data: Data(repeating: 0, count: bytes.count)) }
        mustThrow("failed data never released") { _ = try store.wait(id: "bad", timeout: 0.1, cancelled: { false }) }
        let pending = WKPortalStore()
        for n in 0..<8 { _ = try pending.offer(id: "p\(n)", name: "x", size: bytes.count, sha256: hash) }
        mustThrow("eight pending") { _ = try pending.offer(id: "p8", name: "x", size: bytes.count, sha256: hash) }
        try pending.fulfill(id: "p0", data: bytes)
        _ = try pending.offer(id: "p8", name: "x", size: bytes.count, sha256: hash)

        let clock = PortalTestBox(Date(timeIntervalSince1970: 1_000_000))
        let retained = WKPortalStore(now: { clock.get() })
        for n in 0..<64 {
            _ = try retained.offer(id: "r\(n)", name: "x", size: bytes.count, sha256: hash)
            try retained.fulfill(id: "r\(n)", data: bytes)
        }
        for n in 0..<4 { retained.retire(id: "r\(n)") }
        try retained.acquire(id: "r0")
        clock.put(clock.get().addingTimeInterval(599))
        mustThrow("ten minute retirement") { _ = try retained.offer(id: "new", name: "x", size: bytes.count, sha256: hash) }
        clock.put(clock.get().addingTimeInterval(2))
        _ = try retained.offer(id: "new", name: "x", size: bytes.count, sha256: hash)
        check(retained.metadata("r0") != nil && retained.metadata("r1") == nil, "active GET pinned")
        check(retained.metadata("r63") != nil, "latest/unretired retained")
        retained.release(id: "r0")
        _ = try retained.offer(id: "new2", name: "x", size: bytes.count, sha256: hash)
        check(retained.metadata("r0") == nil, "released retired snapshot reclaimed")
        retained.retire(id: "new")
        clock.put(clock.get().addingTimeInterval(601))
        _ = try retained.offer(id: "new3", name: "x", size: bytes.count, sha256: hash)
        check(retained.metadata("new") != nil, "retired pending not reclaimed")
        retained.fail(id: "new")
        _ = try retained.offer(id: "new4", name: "x", size: bytes.count, sha256: hash)
        check(retained.metadata("new") == nil, "failed expired snapshot reclaimed")
        store.stop(); pending.stop(); retained.stop()
        print("PORTAL_STORE_PASS immutable=true integrity=true pending=8 retained=64 leases=true retirement=600")
        fflush(stdout)
    }

    static func httpTests() throws {
        let data = Data((0..<65536).map { UInt8($0 % 251) }), hash = digest(data)
        let store = WKPortalStore()
        let proxy = PortalTestBox(true)
        let server = WKPortalHTTPServer(store: store, waitTimeout: 0.4, proxyCheck: { _ in proxy.get() })
        try server.start()
        defer { server.stop(); store.stop() }
        check(server.url.host == "127.0.0.1" && server.port != 0 && server.capability.count == 48, "private loopback endpoint")
        let root = server.url!
        _ = try store.offer(id: "one", name: "测试 & file.bin", size: data.count, sha256: hash)
        let file = root.appendingPathComponent("one").appendingPathComponent("测试 & file.bin")
        let before = Date()
        let head = try request(file, "HEAD")
        check(head.status == 200 && head.headers["content-length"] == String(data.count) && head.body.isEmpty, "metadata before content")
        check(Date().timeIntervalSince(before) < 0.3, "HEAD never waits for USB")
        print("PORTAL_HTTP_METADATA_PASS"); fflush(stdout)
        let props = try request(root.appendingPathComponent("one"), "PROPFIND", headers: ["Depth": "1"])
        check(props.status == 207 && String(data: props.body, encoding: .utf8)!.contains("&amp;"), "DAV metadata escaped")
        check(try request(root, "OPTIONS").headers["dav"] == "1", "DAV class1")
        for (method, target, headers, status) in [
            ("PUT", file, [:], 405), ("GET", file, ["Host": "example.invalid"], 400),
            ("PROPFIND", root, ["Depth": "infinity"], 403)
        ] { check(try request(target, method, headers: headers).status == status, "request rejected") }
        check(try request(file, target: "/wrong/one/file").status == 404, "capability")
        check(try request(file, target: "/\(server.capability)/%2e%2e/x").status == 404, "traversal")

        let completed = DispatchSemaphore(value: 0), received = PortalTestBox<Result<Response, Error>?>(nil)
        DispatchQueue.global().async {
            received.put(Result { try request(file) }); completed.signal()
        }
        check(completed.wait(timeout: .now() + 0.1) == .timedOut, "GET waits in background")
        store.retire(id: "one") // A new clipboard offer must not cancel this GET.
        try store.fulfill(id: "one", data: data)
        check(completed.wait(timeout: .now() + 2) == .success, "GET wakes after verification")
        let response = try received.get()!.get()
        check(response.status == 200 && response.body == data, "retired leased GET finishes")
        print("PORTAL_HTTP_DEFERRED_GET_PASS"); fflush(stdout)
        let ranged = try request(file, headers: ["Range": "bytes=11-99"])
        check(ranged.status == 206 && ranged.body == data.subdata(in: 11..<100), "single range")
        check(try request(file, headers: ["Range": "bytes=999999-"]).status == 416, "range bounds")
        _ = try store.offer(id: "bad", name: "bad", size: data.count, sha256: hash)
        store.fail(id: "bad")
        let failed = try request(root.appendingPathComponent("bad/bad"))
        check(failed.status == 503 && failed.body.isEmpty && failed.headers["content-length"] == "0", "failed transfer must not announce successful content")
        _ = try store.offer(id: "late", name: "late", size: data.count, sha256: hash)
        let expired = try request(root.appendingPathComponent("late/late"))
        check(expired.status == 503 && expired.body.isEmpty && expired.headers["content-length"] == "0", "bounded wait ends with failure status")
        let counts = server.counters.snapshot()
        check(counts.count == 8 && counts[0] == 2 && counts[1] == 2 && counts[2] == 4 &&
              counts[3] == 2 && counts[4] == 2 && counts[5] == 1 && counts[6] == 0,
              "HTTP counter categories must match observed outcomes")
        print("PORTAL_COUNTERS_PASS fixed_numeric=true no_request_paths=true")
        proxy.put(false)
        do { check(try request(file).status == 503, "proxy change fails closed") }
        catch { /* The proxy monitor may close the listener/connection first. */ }
        print("PORTAL_HTTP_PASS metadata=true deferred_get=true range=true readonly=true capability=true timeout=true proxy_guard=true")

        let refused = WKPortalHTTPServer(store: WKPortalStore(), proxyCheck: { _ in false })
        mustThrow("proxy preflight refusal") { try refused.start() }
        refused.stop()
    }
    static func main() throws {
        try canonicalDirectoryTests(); try storeTests(); try httpTests()
        let portal = WKFilePortal(), stopped = PortalTestBox(false)
        portal.stop { check(Thread.isMainThread, "stop completion main thread"); stopped.put(true) }
        let deadline = Date().addingTimeInterval(2)
        while !stopped.get() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(stopped.get(), "idle stop callback bounded")
        print("PORTAL_SELFTEST_PASS no_mount=true no_clipboard=true no_usb=true")
    }
}
