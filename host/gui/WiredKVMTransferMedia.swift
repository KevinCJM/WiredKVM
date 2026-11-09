import Foundation
import Darwin
import CryptoKit

struct WKTransferMediaError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct WKTransferFile {
    let url: URL
    let name: String
    let byteCount: Int64
    let sha256: String
}

struct WKTransferJob {
    let directory: URL
    let incoming: URL
    let outgoing: URL
    let payload: URL
    let ready: URL
    let source: WKTransferFile?
}

// This layer only touches a locally owned, normally mounted exchange image.
// The caller must first obtain the existing media ownership lease.
enum WKTransferMedia {
    static let maximumBytes = 65536

    private static func failure(_ text: String) -> WKTransferMediaError {
        WKTransferMediaError(message: text)
    }

    private static func ordinaryDirectory(_ url: URL) throws {
        var info = stat()
        guard url.isFileURL, lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            throw failure("传输目录不是普通目录，未读写文件。")
        }
    }

    private static func createDirectory(_ url: URL, allowingExisting: Bool = false) throws {
        if mkdir(url.path, 0o700) == 0 { return }
        if allowingExisting && errno == EEXIST { try ordinaryDirectory(url); return }
        throw failure("无法创建独立传输目录；已有文件不会覆盖。")
    }

    private static func allEntries(_ directory: URL) throws -> [URL] {
        // Foundation's URL enumeration may hide AppleDouble sidecars even
        // without .skipsHiddenFiles. Use POSIX so malformed/extra entries are
        // checked too, instead of accidentally accepting a partial batch.
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("无法读取传输目录。") }
        guard let stream = fdopendir(fd) else { close(fd); throw failure("无法读取传输目录。") }
        defer { closedir(stream) }
        var entries: [URL] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw failure("目录读取未完成。") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard entries.count < 64 else { throw failure("目录项超出单文件传输范围。") }
            entries.append(directory.appendingPathComponent(name))
        }
        return entries
    }

    static func makeJob(root: URL, id: String, outbound: URL? = nil,
                        maximumBytes: Int = maximumBytes) throws -> WKTransferJob {
        guard id.range(of: "^[0-9A-F]{8}$", options: .regularExpression) != nil else {
            throw failure("传输编号无效。")
        }
        try ordinaryDirectory(root)
        let base = root.appendingPathComponent("WKJOB", isDirectory: true)
        try createDirectory(base, allowingExisting: true)
        let directory = base.appendingPathComponent(id, isDirectory: true)
        try createDirectory(directory) // Never reuse a previous transaction.
        let incoming = directory.appendingPathComponent("IN", isDirectory: true)
        let outgoing = directory.appendingPathComponent("OUT", isDirectory: true)
        let payload = outgoing.appendingPathComponent("PAYLOAD", isDirectory: true)
        for item in [incoming, outgoing, payload] { try createDirectory(item) }
        let source = try outbound.map {
            try stageSingleFile(from: $0, toDirectory: payload, maximumBytes: maximumBytes)
        }
        // Finder creates READY remotely. Creating it here would forge feedback.
        return WKTransferJob(directory: directory, incoming: incoming, outgoing: outgoing,
                             payload: payload,
                             ready: directory.appendingPathComponent("READY", isDirectory: true),
                             source: source)
    }

    private static func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec &&
        a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec &&
        a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    // Finder.h (CoreServices SDK): FileInfo is 16 bytes, followed by
    // ExtendedFileInfo whose extendedFinderFlags are at offset 24 overall.
    // https://developer.apple.com/documentation/coreservices/1429613-anonymous/kextendedflagobjectisbusy
    // These are rejection signals only. Missing/clear flags do NOT prove that
    // Finder finished a copy; WKFileCompletionGate remains independent.
    private static func rejectIncompleteFinderInfo(_ bytes: Data) throws {
        guard bytes.count == 32 else { throw failure("Finder 元数据长度无效，未自动提交。") }
        let flags = UInt16(bytes[24]) << 8 | UInt16(bytes[25])
        let busyType = bytes[0] == 98 && bytes[1] == 122 && bytes[2] == 121 &&
            (32...63).contains(bytes[3]) // kFirst/LastMagicBusyFiletype: 'bzy '...'bzy?'
        // Invalid extended flags are ambiguous, so do not use their busy bit
        // (or absence) as reassurance. Conservatively stop this prototype.
        guard flags & 0x8080 == 0, !busyType else {
            throw failure("文件被 Finder 标记为忙碌、未完成或元数据无效，未自动提交。")
        }
    }

    private static func finderInfo(fd: Int32) throws -> Data? {
        let name = "com.apple.FinderInfo"
        let count = fgetxattr(fd, name, nil, 0, 0, 0)
        if count == -1 && errno == ENOATTR { return nil }
        guard count == 32 else { throw failure("无法可靠读取 Finder 元数据，未自动提交。") }
        var bytes = Data(count: 32)
        let read = bytes.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, 32, 0, 0) }
        guard read == 32 else { throw failure("读取期间 Finder 元数据发生变化，未自动提交。") }
        try rejectIncompleteFinderInfo(bytes)
        return bytes
    }

    // macOS AppleDouble v2 layout and ATTR extension:
    // https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_xattr.c
    // Only the current macOS FinderInfo/resource-fork container is recognized.
    // An arbitrary ._ file must not disappear from the single-file count merely
    // because its first four bytes happen to match the AppleDouble magic.
    private static func validateAppleDouble(_ data: Data) throws {
        func invalid() -> WKTransferMediaError { failure("AppleDouble 元数据无效或不受支持，未自动提交。") }
        func u16(_ offset: Int) -> Int { Int(data[offset]) << 8 | Int(data[offset + 1]) }
        func u32(_ offset: Int) -> Int {
            Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 |
                Int(data[offset + 2]) << 8 | Int(data[offset + 3])
        }
        guard data.count >= 26, u32(0) == 0x00051607, u32(4) == 0x00020000 else { throw invalid() }
        let count = u16(24), tableEnd = 26 + count * 12
        guard (1...2).contains(count), tableEnd <= data.count else { throw invalid() }
        var entries: [Int: Range<Int>] = [:]
        for index in 0..<count {
            let base = 26 + index * 12
            let kind = u32(base), start = u32(base + 4), length = u32(base + 8)
            guard [2, 9].contains(kind), entries[kind] == nil,
                  start >= tableEnd, start <= data.count, length <= data.count - start else { throw invalid() }
            let extent = start..<(start + length)
            guard !entries.values.contains(where: { $0.overlaps(extent) }) else { throw invalid() }
            entries[kind] = extent
        }
        guard let finder = entries[9], finder.count >= 32 else { throw invalid() }
        try rejectIncompleteFinderInfo(Data(data[finder.lowerBound..<(finder.lowerBound + 32)]))
        if finder.count == 32 { return }
        // Apple stores additional xattrs after FinderInfo plus two pad bytes.
        let header = finder.lowerBound + 34
        guard finder.count >= 70, data[header - 2] == 0, data[header - 1] == 0,
              u32(header) == 0x41545452 else { throw invalid() }
        let total = u32(header + 8), start = u32(header + 12), length = u32(header + 16)
        guard start >= header + 36, start <= finder.upperBound,
              length <= finder.upperBound - start, total >= start + length,
              total <= finder.upperBound else { throw invalid() }
        // total_size includes Apple's reserved attribute free space. Individual
        // values must lie inside data_start + data_length, not that capacity.
        let dataEnd = start + length
        let attributes = u16(header + 34)
        var cursor = header + 36
        var names = Set<Data>(), extents: [Range<Int>] = []
        for _ in 0..<attributes {
            guard cursor <= start, start - cursor >= 11 else { throw invalid() }
            let offset = u32(cursor), size = u32(cursor + 4), nameSize = Int(data[cursor + 10])
            guard (2...128).contains(nameSize), nameSize <= start - cursor - 11,
                  offset >= start, offset <= dataEnd, size <= dataEnd - offset else { throw invalid() }
            let name = Data(data[(cursor + 11)..<(cursor + 11 + nameSize)])
            guard name.last == 0, !name.dropLast().contains(0),
                  String(data: name.dropLast(), encoding: .utf8) != nil, names.insert(name).inserted else { throw invalid() }
            let extent = offset..<(offset + size)
            guard !extents.contains(where: { $0.overlaps(extent) }) else { throw invalid() }
            extents.append(extent)
            cursor = (cursor + 11 + nameSize + 3) & ~3
        }
        guard cursor <= start else { throw invalid() }
    }

    private static func snapshot(_ url: URL, maximumBytes: Int,
                                 checkingFinderInfo: Bool = true) throws -> (Data, stat) {
        guard url.isFileURL, maximumBytes > 0, maximumBytes <= 16 * 1024 * 1024 else {
            throw failure("文件或大小限制无效。")
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw failure("无法读取普通源文件；链接不会跟随。") }
        defer { close(fd) }
        var initial = stat()
        guard fstat(fd, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
              initial.st_size >= 0, initial.st_size <= maximumBytes else {
            throw failure("目前仅支持一个不超过 \(maximumBytes) 字节的普通文件。")
        }
        let initialFinderInfo = checkingFinderInfo ? try finderInfo(fd: fd) : nil
        func readCopy() throws -> Data {
            var bytes = [UInt8](repeating: 0, count: Int(initial.st_size))
            var offset = 0
            while offset < bytes.count {
                let remaining = bytes.count - offset
                let count = bytes.withUnsafeMutableBytes {
                    pread(fd, $0.baseAddress!.advanced(by: offset), remaining, off_t(offset))
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("读取期间源文件发生变化。") }
                offset += count
            }
            var after = stat()
            guard fstat(fd, &after) == 0, sameFile(initial, after) else {
                throw failure("读取期间源文件发生变化。")
            }
            return Data(bytes)
        }
        let bytes = try readCopy()
        // Small prototype files make a second read cheap. Compare bytes, not
        // just timestamps: neither side may silently stage a torn snapshot.
        guard try readCopy() == bytes else { throw failure("源文件正在变化，请稍后重试。") }
        if checkingFinderInfo {
            guard try finderInfo(fd: fd) == initialFinderInfo else {
                throw failure("读取期间 Finder 元数据发生变化，未自动提交。")
            }
        }
        var pathInfo = stat()
        guard lstat(url.path, &pathInfo) == 0, sameFile(initial, pathInfo),
              pathInfo.st_mode & S_IFMT == S_IFREG else {
            throw failure("源文件已被替换。")
        }
        return (bytes, initial)
    }

    private static func describe(_ url: URL, bytes: Data) -> WKTransferFile {
        WKTransferFile(url: url, name: url.lastPathComponent, byteCount: Int64(bytes.count),
                       sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    static func inspectFile(at url: URL, maximumBytes: Int = maximumBytes) throws -> WKTransferFile {
        let (bytes, _) = try snapshot(url, maximumBytes: maximumBytes)
        return describe(url, bytes: bytes)
    }

    static func stageSingleFile(from source: URL, toDirectory directory: URL,
                                maximumBytes: Int = maximumBytes) throws -> WKTransferFile {
        try ordinaryDirectory(directory)
        let name = source.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.contains(":"), !name.contains("\0"), !name.hasSuffix("."),
              !name.hasSuffix(" "), name.utf16.count <= 255 else {
            throw failure("文件名不适合当前交换盘。")
        }
        let (bytes, _) = try snapshot(source, maximumBytes: maximumBytes)
        let target = directory.appendingPathComponent(name)
        // A private staging name plus renamex_np(RENAME_EXCL) publishes a
        // complete file atomically and never replaces an existing target.
        let temporary = directory.appendingPathComponent(".wk-stage-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("无法创建文件暂存副本。") }
        var published = false
        defer { close(fd); if !published { _ = unlink(temporary.path) } }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes {
                write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw failure("文件暂存写入失败，未发布副本。") }
            offset += count
        }
        guard fsync(fd) == 0,
              renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            throw failure("文件暂存未完成；已有文件不会覆盖。")
        }
        published = true
        let result = try inspectFile(at: target, maximumBytes: maximumBytes)
        guard result.sha256 == describe(source, bytes: bytes).sha256 else {
            throw failure("暂存副本校验失败，未继续传输。")
        }
        return result
    }

    // Structural validation is deliberately NOT a Finder completion signal.
    // The coordinator separately requires media ejection and transfer evidence.
    static func validateSingleFile(at directory: URL,
                                   maximumBytes: Int = maximumBytes) throws -> URL {
        try ordinaryDirectory(directory)
        let entries = try allEntries(directory)
        // Finder may add .DS_Store and AppleDouble metadata. Exclude only valid
        // metadata; do not hide arbitrary dotfiles or in-progress payloads.
        var payloads: [URL] = []
        var sidecars: [URL] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if name == ".DS_Store" {
                let (data, _) = try snapshot(entry, maximumBytes: maximumBytes)
                guard data.count >= 8, Array(data.prefix(8)) == [0, 0, 0, 1, 66, 117, 100, 49] else {
                    throw failure("目录含无法识别的元数据，未自动提交。")
                }
            } else if name.hasPrefix("._") { sidecars.append(entry) }
            else { payloads.append(entry) }
        }
        guard payloads.count == 1 else { throw failure("接收目录必须且只能包含一个普通文件。") }
        let file = payloads[0]
        let lower = file.lastPathComponent.lowercased()
        guard !lower.hasPrefix(".wk-stage-"),
              ![".partial", ".part", ".download", ".crdownload", ".tmp"].contains(where: lower.hasSuffix) else {
            throw failure("检测到可能未完成的文件，未自动提交。")
        }
        for sidecar in sidecars {
            guard sidecar.lastPathComponent == "._" + file.lastPathComponent else {
                throw failure("存在不属于本次文件的元数据。")
            }
            // A FAT AppleDouble container cannot itself have synthesized
            // xattrs (that would require a recursive ._._ sidecar). Inspect
            // its bounded, stable bytes and FinderInfo entry instead. Payload
            // files still require the normal xattr check; no errno is ignored.
            let (data, _) = try snapshot(sidecar, maximumBytes: maximumBytes, checkingFinderInfo: false)
            try validateAppleDouble(data)
        }
        _ = try inspectFile(at: file, maximumBytes: maximumBytes)
        return file
    }
}

// Narrow, read-only FAT16 directory observer for ASCII 8.3 transaction markers.
// Caller brackets a lookup with unchanged generation/writeSequence and no
// outstanding I/O. Even then, presence is a step hint, never copy completion.
final class WKFAT16View {
    private let fd: Int32
    private let bytes: UInt64
    private let sectorsPerCluster: UInt64
    private let rootOffset: UInt64
    private let rootBytes: Int
    private let dataOffset: UInt64
    private let clusterCount: UInt64
    private let fat: [UInt8]

    private static func fail(_ message: String) -> WKTransferMediaError {
        WKTransferMediaError(message: "交换盘观察失败：" + message)
    }

    private static func read(_ fd: Int32, offset: UInt64, count: Int, bound: UInt64) throws -> [UInt8] {
        guard count >= 0, count <= 1024 * 1024, offset <= bound,
              UInt64(count) <= bound - offset else { throw fail("块范围无效") }
        var data = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = data.withUnsafeMutableBytes {
                pread(fd, $0.baseAddress!.advanced(by: done), count - done, off_t(offset) + off_t(done))
            }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw fail("镜像读取不完整") }
            done += n
        }
        return data
    }

    init(image: URL) throws {
        let handle = open(image.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard handle >= 0 else { throw Self.fail("镜像无法打开") }
        do {
            var info = stat()
            guard fstat(handle, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= 512 else { throw Self.fail("镜像不是普通文件") }
            let size = UInt64(info.st_size)
            let boot = try Self.read(handle, offset: 0, count: 512, bound: size)
            func u16(_ i: Int) -> UInt64 { UInt64(boot[i]) | UInt64(boot[i + 1]) << 8 }
            func u32(_ i: Int) -> UInt64 { u16(i) | u16(i + 2) << 16 }
            let sectorSize = u16(11), clusterSectors = UInt64(boot[13])
            let reserved = u16(14), copies = UInt64(boot[16]), entries = u16(17)
            let total = u16(19) == 0 ? u32(32) : u16(19), fatSectors = u16(22)
            guard boot[510] == 0x55, boot[511] == 0xaa, sectorSize == 512,
                  clusterSectors > 0, clusterSectors <= 128,
                  clusterSectors & (clusterSectors - 1) == 0,
                  reserved > 0, copies == 2, entries > 0, entries <= 4096,
                  fatSectors > 0, fatSectors <= 512, u32(28) == 0,
                  total > 0, total <= size / 512 else { throw Self.fail("不支持或不完整的 FAT16 参数") }
            let rootSectors = (entries * 32 + 511) / 512
            let start = reserved + copies * fatSectors + rootSectors
            guard start < total else { throw Self.fail("文件系统布局越界") }
            let clusters = (total - start) / clusterSectors
            guard clusters >= 4085, clusters < 65525, fatSectors * 256 >= clusters + 2 else {
                throw Self.fail("不是有效 FAT16")
            }
            let table = try Self.read(handle, offset: reserved * 512,
                                      count: Int(fatSectors * 512), bound: size)
            let second = try Self.read(handle, offset: (reserved + fatSectors) * 512,
                                       count: table.count, bound: size)
            guard table == second, table[0] == boot[21], table[1] == 0xff else {
                throw Self.fail("FAT 副本不一致或尚未写完")
            }
            fd = handle; bytes = total * 512; sectorsPerCluster = clusterSectors
            rootOffset = (reserved + copies * fatSectors) * 512
            rootBytes = Int(entries * 32); dataOffset = start * 512
            clusterCount = clusters; fat = table
        } catch { close(handle); throw error }
    }

    deinit { close(fd) }

    private func directory(cluster: UInt64?) throws -> [UInt8] {
        guard let cluster else {
            return try Self.read(fd, offset: rootOffset, count: rootBytes, bound: bytes)
        }
        var result: [UInt8] = [], seen = Set<UInt64>(), current = cluster
        while true {
            guard current >= 2, current < 0xfff0, current < clusterCount + 2,
                  seen.insert(current).inserted,
                  result.count + Int(sectorsPerCluster * 512) <= 1024 * 1024 else {
                throw Self.fail("目录簇链无效或过长")
            }
            result += try Self.read(fd, offset: dataOffset + (current - 2) * sectorsPerCluster * 512,
                                    count: Int(sectorsPerCluster * 512), bound: bytes)
            let index = Int(current * 2)
            let next = UInt64(fat[index]) | UInt64(fat[index + 1]) << 8
            if next >= 0xfff8 { return result }
            guard next >= 2, next < 0xfff0 else { throw Self.fail("目录簇链未完成") }
            current = next
        }
    }

    func exists(directoryComponents: [String]) throws -> Bool {
        guard !directoryComponents.isEmpty, directoryComponents.count <= 8 else {
            throw Self.fail("目录深度无效")
        }
        var cluster: UInt64?
        for component in directoryComponents {
            guard component.range(of: "^[A-Z0-9_]{1,8}(\\.[A-Z0-9_]{1,3})?$",
                                  options: .regularExpression) != nil else {
                throw Self.fail("仅支持事务目录短名称")
            }
            let pieces = component.split(separator: ".")
            let key = String(pieces[0]).padding(toLength: 8, withPad: " ", startingAt: 0) +
                      (pieces.count == 2 ? String(pieces[1]) : "").padding(toLength: 3, withPad: " ", startingAt: 0)
            let wanted = Array(key.utf8)
            let contents = try directory(cluster: cluster)
            var matches: [UInt64] = []
            for index in stride(from: 0, to: contents.count, by: 32) {
                if contents[index] == 0 { break }
                let attributes = contents[index + 11]
                if contents[index] == 0xe5 || attributes == 0x0f || attributes & 0x08 != 0 { continue }
                if Array(contents[index..<(index + 11)]) != wanted { continue }
                guard attributes & 0x10 != 0,
                      contents[index + 20] == 0, contents[index + 21] == 0,
                      contents[(index + 28)..<(index + 32)].allSatisfy({ $0 == 0 }) else {
                    throw Self.fail("标记不是有效目录")
                }
                matches.append(UInt64(contents[index + 26]) | UInt64(contents[index + 27]) << 8)
            }
            guard matches.count <= 1 else { throw Self.fail("事务目录重复") }
            guard let match = matches.first else { return false }
            // Validate the final marker's chain too, rather than accepting an
            // allocated directory entry whose clusters haven't been committed.
            _ = try directory(cluster: match)
            cluster = match
        }
        return true
    }
}
