#if WK_TREE
import Foundation
import CryptoKit
import WKTransferTreeCore

enum WKTreeError: Error { case core(Int32), invalid, limit, changed }

final class WKTreeJob: @unchecked Sendable {
    let token: OpaquePointer
    init() { token = wk_tree_cancel_new()! }
    func cancel() { wk_tree_cancel_set(token) }
    deinit { wk_tree_cancel_free(token) }
}

struct WKTreeManifest: Sendable {
    struct Entry: Sendable, Equatable {
        let path: String, directory: Bool, size: UInt64, offset: UInt64
    }
    let entries: [Entry], roots: [Entry], prefixBytes: Int, size: UInt64
    let byPath: [String: Entry], children: [String: [Entry]]
    init(_ data: Data, total: UInt64) throws {
        guard data.count <= 8 * 1024 * 1024 else { throw WKTreeError.limit }
        let result = data.withUnsafeBytes { wk_tree_manifest_validate($0.bindMemory(to: UInt8.self).baseAddress, $0.count, total) }
        guard result == 0 else { throw WKTreeError.core(result) }
        var pos = 32, entries: [Entry] = [], keys = Set<String>()
        let count: UInt32 = data.readLE(at: 8)
        for _ in 0..<count {
            let directory = data[pos] == 1
            let n: UInt32 = data.readLE(at: pos + 4)
            let size: UInt64 = data.readLE(at: pos + 8), offset: UInt64 = data.readLE(at: pos + 16)
            pos += 24
            guard let path = String(data: data.subdata(in: pos..<pos+Int(n)), encoding: .utf8) else { throw WKTreeError.invalid }
            pos += Int(n)
            // APFS/HFS names may be normalization- and case-insensitive. Reject
            // aliases before Finder is offered a tree that could overwrite itself.
            let canonical = path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard keys.insert(canonical).inserted else { throw WKTreeError.invalid }
            entries.append(Entry(path: path, directory: directory, size: size, offset: offset + UInt64(data.count)))
        }
        self.entries = entries; roots = entries.filter { !$0.path.contains("/") }; prefixBytes = data.count; size = total
        byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        children = Dictionary(grouping: entries) { entry in entry.path.lastIndex(of: "/").map { String(entry.path[..<$0]) } ?? "" }
    }
}

// Creation and read/verify are disk work. This wrapper does not open the
// general pasteboard, USB, a network listener, or any receiving destination.
final class WKTransferTree: @unchecked Sendable {
    private let handle: OpaquePointer
    private let job: WKTreeJob
    let manifestData: Data, manifest: WKTreeManifest, size: UInt64, manifestSHA256: String
    init(urls: [URL], job: WKTreeJob) throws {
        guard !urls.isEmpty, urls.count <= 128, urls.allSatisfy({ $0.isFileURL && !$0.path.utf8.contains(0) }) else { throw WKTreeError.invalid }
        let strings = urls.map { Array($0.path.utf8CString) }
        // Allocate stable C strings for this synchronous call; Rust owns the
        // resulting descriptors and copies metadata before returning.
        let pointers = strings.map { bytes -> UnsafeMutablePointer<CChar> in
            let p = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            p.initialize(from: bytes, count: bytes.count); return p
        }
        defer { for (p, bytes) in zip(pointers, strings) { p.deinitialize(count: bytes.count); p.deallocate() } }
        let immutable = pointers.map { Optional(UnsafePointer($0)) }
        var error: Int32 = 0
        guard let h = immutable.withUnsafeBufferPointer({ wk_tree_create($0.baseAddress, $0.count, job.token, &error) }) else { throw WKTreeError.core(error) }
        var owned = true; defer { if owned { wk_tree_free(h) } }
        let n = wk_tree_manifest_size(h), total = wk_tree_size(h)
        guard n >= 32, n <= 8 * 1024 * 1024 else { throw WKTreeError.limit }
        var bytes = Data(count: n)
        guard bytes.withUnsafeMutableBytes({ wk_tree_manifest_copy(h, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }) == 0 else { throw WKTreeError.invalid }
        manifest = try WKTreeManifest(bytes, total: total)
        handle = h; self.job = job; manifestData = bytes; size = total
        manifestSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(); owned = false
    }
    deinit { wk_tree_free(handle) }
    func cancel() { job.cancel() }
    func unchanged() -> Bool { wk_tree_verify(handle) == 0 }
    func read(offset: UInt64, maximum: Int) throws -> Data {
        guard offset <= size, (0...65536).contains(maximum) else { throw WKTreeError.invalid }
        var data = Data(count: min(maximum, Int(size-offset)))
        if data.isEmpty { return data }
        let n = data.withUnsafeMutableBytes { wk_tree_read(handle, offset, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        guard n == data.count else { throw WKTreeError.core(Int32(n < 0 ? -n : 3)) }; return data
    }
}
#endif
