import AppKit
import CryptoKit
import Darwin
import ImageIO

enum WKClipboardError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { if case .invalid(let reason) = self { return reason }; return "clipboard-error" }
}

// Immutable metadata for a future file. No source path crosses the wire.
struct WKFileOffer: Codable, Equatable {
    let id: String
    let name: String
    let size: Int
    let sha256: String
    let nonce: String

    init(id: String = UUID().uuidString.lowercased(), name: String, size: Int,
         sha256: String, nonce: String) {
        self.id = id; self.name = name; self.size = size; self.sha256 = sha256; self.nonce = nonce
    }

    static func validID(_ id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return uuid.uuidString.lowercased() == id
    }

    func validate() throws {
        guard Self.validID(id),
              WKMessage.validFilename(name), size >= 0, size <= WKMessage.maximumContent,
              WKMessage.validNonce(nonce), sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
            throw WKClipboardError.invalid("invalid-file-offer")
        }
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= 2048 else { throw WKClipboardError.invalid("invalid-file-offer") }
        return bytes
    }

    static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= 2048,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == Set(["id", "name", "size", "sha256", "nonce"]) else {
            throw WKClipboardError.invalid("invalid-file-offer")
        }
        let offer = try JSONDecoder().decode(Self.self, from: bytes)
        try offer.validate(); return offer
    }
}

// Version one intentionally limits each item to 1 MiB. Metadata and the SHA-256
// cover the entire envelope; the inner digest additionally identifies file bytes.
struct WKMessage: Codable {
    static let maximumContent = 1_048_576
    private static let binaryMagic = Data("WKB2".utf8)
    private static let binaryFixedHeader = 88
    var version = 1
    var kind: String
    var nonce: String
    var name: String?
    var size: Int
    var sha256: String
    var body: Data
    var fileID: String?

    init(kind: String, nonce: String = "0", name: String? = nil, body: Data = Data(), fileID: String? = nil) {
        self.kind = kind; self.nonce = nonce; self.name = name
        self.body = body; size = body.count; sha256 = Self.digest(body)
        self.fileID = fileID
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validNonce(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 20 && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
    static func validFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255 &&
        !name.contains("/") && !name.contains(":") && !name.unicodeScalars.contains { $0.value == 0 }
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(self)
        var result = Data(SHA256.hash(data: json)); result.append(json)
        guard result.count <= WKLink.maximumMessage else { throw WKClipboardError.invalid("item-too-large") }
        return result
    }

    // WKB2: magic[4], version[1]=2, kind[1]=1(file), flagsLE16=0,
    // headerBytesLE32, bodyBytesLE32, nonceBytesLE16, nameBytesLE16,
    // fileIDBytesLE16, reservedLE16=0, bodySHA256[32], envelopeSHA256[32],
    // UTF8 nonce/name/fileID, raw body.
    // The outer SHA covers every byte except its own 32-byte field.
    func encodedBinary() throws -> Data {
        try validate()
        guard kind == "file", let name else { throw WKClipboardError.invalid("binary-file-only") }
        let nonceBytes = Data(nonce.utf8); let nameBytes = Data(name.utf8)
        let idBytes = Data((fileID ?? "").utf8)
        let headerBytes = Self.binaryFixedHeader + nonceBytes.count + nameBytes.count + idBytes.count
        var prefix = Self.binaryMagic
        prefix.append(contentsOf: [2, 1]); prefix.appendLE(UInt16(0))
        prefix.appendLE(UInt32(headerBytes)); prefix.appendLE(UInt32(body.count))
        prefix.appendLE(UInt16(nonceBytes.count)); prefix.appendLE(UInt16(nameBytes.count))
        prefix.appendLE(UInt16(idBytes.count)); prefix.appendLE(UInt16(0))
        prefix.append(contentsOf: SHA256.hash(data: body))
        var tail = nonceBytes; tail.append(nameBytes); tail.append(idBytes); tail.append(body)
        var integrity = SHA256(); integrity.update(data: prefix); integrity.update(data: tail)
        var result = prefix; result.append(contentsOf: integrity.finalize()); result.append(tail)
        guard result.count <= WKLink.maximumMessage else { throw WKClipboardError.invalid("item-too-large") }
        return result
    }

    static func decode(_ bytes: Data) throws -> WKMessage {
        if bytes.prefix(4) == binaryMagic { return try decodeBinary(Data(bytes)) }
        guard bytes.count > 32, bytes.count <= WKLink.maximumMessage else { throw WKClipboardError.invalid("invalid-envelope-size") }
        let json = Data(bytes.dropFirst(32))
        guard Data(SHA256.hash(data: json)) == bytes.prefix(32) else { throw WKClipboardError.invalid("envelope-checksum-mismatch") }
        let value = try JSONDecoder().decode(Self.self, from: json)
        try value.validate(); return value
    }

    private static func decodeBinary(_ bytes: Data) throws -> WKMessage {
        guard bytes.count >= binaryFixedHeader, bytes.count <= WKLink.maximumMessage,
              bytes[4] == 2, bytes[5] == 1, bytes.readLE(at: 6) as UInt16 == 0,
              bytes.readLE(at: 22) as UInt16 == 0 else {
            throw WKClipboardError.invalid("invalid-binary-envelope")
        }
        let headerBytes = Int(bytes.readLE(at: 8) as UInt32)
        let bodyBytes = Int(bytes.readLE(at: 12) as UInt32)
        let nonceBytes = Int(bytes.readLE(at: 16) as UInt16)
        let nameBytes = Int(bytes.readLE(at: 18) as UInt16)
        let idBytes = Int(bytes.readLE(at: 20) as UInt16)
        guard (1...20).contains(nonceBytes), (1...255).contains(nameBytes),
              idBytes == 0 || idBytes == 36,
              bodyBytes <= maximumContent,
              headerBytes == binaryFixedHeader + nonceBytes + nameBytes + idBytes,
              bytes.count == headerBytes + bodyBytes else {
            throw WKClipboardError.invalid("invalid-binary-length")
        }
        var integrity = SHA256()
        integrity.update(data: bytes.prefix(56)); integrity.update(data: bytes.dropFirst(binaryFixedHeader))
        guard Data(integrity.finalize()) == bytes[56..<binaryFixedHeader] else {
            throw WKClipboardError.invalid("envelope-checksum-mismatch")
        }
        let nonceEnd = binaryFixedHeader + nonceBytes
        let nameEnd = nonceEnd + nameBytes
        guard let nonce = String(data: bytes[binaryFixedHeader..<nonceEnd], encoding: .utf8),
              let name = String(data: bytes[nonceEnd..<nameEnd], encoding: .utf8),
              let id = String(data: bytes[nameEnd..<headerBytes], encoding: .utf8) else {
            throw WKClipboardError.invalid("invalid-binary-utf8")
        }
        var message = WKMessage(kind: "file", nonce: nonce, name: name, body: Data(bytes[headerBytes...]), fileID: idBytes == 0 ? nil : id)
        message.sha256 = bytes[24..<56].map { String(format: "%02x", $0) }.joined()
        try message.validate(); return message
    }

    func validate() throws {
        guard version == 1, Self.validNonce(nonce), size == body.count,
              size <= Self.maximumContent, sha256 == Self.digest(body),
              fileID == nil || (kind == "file" && WKFileOffer.validID(fileID!)) else {
            throw WKClipboardError.invalid("content-integrity-check-failed")
        }
        switch kind {
        case "arm", "cancel", "check", "commit", "metadata-refresh":
            guard body.isEmpty, name == nil, nonce != "0" else { throw WKClipboardError.invalid("invalid-control") }
        case "prepare", "pull":
            guard name == nil, nonce != "0", body.count <= 512,
                  let object = try JSONSerialization.jsonObject(with: body) as? [String: String],
                  Set(object.keys) == Set(["source", "destination", "originalSide", "originalSession", "originalStamp"]),
                  object.values.allSatisfy({ Self.validNonce($0) }),
                  object["source"] != "0", object["destination"] != "0",
                  ["0", "1"].contains(object["originalSide"] ?? ""), object["originalSession"] != "0", object["originalStamp"] != "0" else {
                throw WKClipboardError.invalid("invalid-control")
            }
        case "text":
            guard name == nil, String(data: body, encoding: .utf8) != nil else { throw WKClipboardError.invalid("invalid-utf8") }
        case "png":
            guard name == nil, Array(body.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] else {
                throw WKClipboardError.invalid("invalid-png")
            }
            try WKClipboard.validateImage(body)
        case "file":
            guard let name, Self.validFilename(name) else { throw WKClipboardError.invalid("invalid-filename") }
        case "file-offer":
            guard name == nil else { throw WKClipboardError.invalid("invalid-file-offer") }
            let offer = try WKFileOffer.decode(body)
            guard offer.nonce == nonce else { throw WKClipboardError.invalid("file-offer-nonce-mismatch") }
        case "stream-ready":
            guard name == nil, let id = String(data: body, encoding: .utf8), WKFileOffer.validID(id) else { throw WKStreamError.invalid }
        case "stream-diagnostic":
            guard name == nil, body.count <= 64, let code = String(data: body, encoding: .utf8),
                  (code.hasPrefix("stream-") || code.hasPrefix("posix-")), WKMetadata.safeCode(code) else { throw WKStreamError.invalid }
        case "metadata-snapshot":
            guard name == nil, nonce != "0", body.count == 38, body.prefix(4) == Data("WKCV".utf8) else { throw WKStreamError.invalid }
        case "bundle-metadata":
            guard let name, WKFileOffer.validID(name), nonce != "0", body.count <= 128 * 1024 else { throw WKStreamError.invalid }
            let bundle = try WKClipboardBundle.decode(body)
            guard bundle.items.allSatisfy({ $0.representations.allSatisfy({ $0.kind == .fileURL }) }) else { throw WKStreamError.invalid }
        case "stream-offer":
            guard name == nil, try WKStreamOffer.decode(body).nonce == nonce else { throw WKClipboardError.invalid("invalid-stream-offer") }
        default: throw WKClipboardError.invalid("unsupported-content")
        }
    }
}

final class WKClipboard {
    // Clipboard TIFF is often uncompressed (several MiB for a screenshot).
    // Bound decoding separately; the normalized PNG still obeys the wire limit.
    static let maximumSourceImageBytes = 128 * 1024 * 1024
    let board: NSPasteboard
    let receiveRoot: URL
    init(board: NSPasteboard, receiveRoot: URL? = nil) {
        self.board = board
#if WK_PORTABLE
        self.receiveRoot = receiveRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("WiredKVM-Portable-Received-" + UUID().uuidString, isDirectory: true)
#else
        self.receiveRoot = receiveRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WiredKVM/Received", isDirectory: true)
#endif
    }
    var changeCount: Int { board.changeCount }

    func singleFileURL() throws -> URL? {
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard files.count <= 1 else { throw WKClipboardError.invalid("single-file-only") }
        return files.first
    }
#if WK_TREE
    func selectedFileURLs() throws -> [URL] {
        let urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard urls.count <= 128 else { throw WKClipboardError.invalid("selection-over-128-roots") }
        return urls
    }
#endif

    func snapshot(nonce: String = "0") throws -> WKMessage? {
        let start = board.changeCount
        let fileURLs = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        var result: WKMessage?
        if !fileURLs.isEmpty {
            guard fileURLs.count == 1 else { throw WKClipboardError.invalid("single-file-only") }
            let file = fileURLs[0]
            guard WKMessage.validFilename(file.lastPathComponent) else { throw WKClipboardError.invalid("invalid-filename") }
            result = WKMessage(kind: "file", nonce: nonce, name: file.lastPathComponent, body: try Self.readRegularFile(file))
        } else if board.types?.contains(where: { $0.rawValue.contains("promised-file") }) == true {
            throw WKClipboardError.invalid("file-promises-not-supported")
        } else if let png = try imagePNG() {
            result = WKMessage(kind: "png", nonce: nonce, body: png)
        } else if let string = board.string(forType: .string) {
            result = WKMessage(kind: "text", nonce: nonce, body: Data(string.utf8))
        }
        guard board.changeCount == start else { throw WKClipboardError.invalid("clipboard-changed-during-read") }
        try result?.validate()
        return result
    }

    private func imagePNG() throws -> Data? {
        if let png = board.data(forType: .png) {
            guard png.count <= WKMessage.maximumContent else { throw WKClipboardError.invalid("item-over-1MiB") }
            try Self.validateImage(png)
            return png
        }
        for type in [NSPasteboard.PasteboardType.tiff, .init("public.jpeg"), .init("public.heic")] {
            guard let bytes = board.data(forType: type) else { continue }
            let image = try Self.decodeImage(bytes, maximumBytes: Self.maximumSourceImageBytes)
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw WKClipboardError.invalid("image-conversion-failed")
            }
            guard png.count <= WKMessage.maximumContent else { throw WKClipboardError.invalid("item-over-1MiB") }
            try Self.validateImage(png)
            return png
        }
        return nil
    }

    static func validateImage(_ bytes: Data) throws {
        _ = try decodeImage(bytes, maximumBytes: WKMessage.maximumContent)
    }

    private static func imageBudget(_ properties: [CFString: Any], width: Int, height: Int) -> Bool {
        let depth = properties[kCGImagePropertyDepth] as? Int ?? 8
        guard depth > 0, depth <= 16 else { return false }
        let model = properties[kCGImagePropertyColorModel] as? String ?? "RGB"
        let channels = model == "Gray" ? 2 : model == "RGB" ? 4 : model == "CMYK" ? 5 : 0
        return channels > 0 && width * height * channels * ((depth+7)/8) <= maximumSourceImageBytes
    }

    static func decodeImage(_ bytes: Data, maximumBytes: Int) throws -> CGImage {
        guard bytes.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_777_216,
              Self.imageBudget(properties, width: width, height: height),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw WKClipboardError.invalid("invalid-or-oversized-image")
        }
        return image
    }

    static func readRegularFile(_ url: URL) throws -> Data {
        let fd = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard fd >= 0 else { throw WKClipboardError.invalid("file-open-failed-or-symlink") }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            throw WKClipboardError.invalid("regular-file-only")
        }
        guard before.st_size >= 0, before.st_size <= WKMessage.maximumContent else { throw WKClipboardError.invalid("file-over-1MiB") }
        let forkSize = fgetxattr(fd, "com.apple.ResourceFork", nil, 0, 0, 0)
        guard forkSize == 0 || (forkSize < 0 && errno == ENOATTR) else {
            throw WKClipboardError.invalid("resource-fork-not-supported")
        }
        var bytes = Data(count: Int(before.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WKClipboardError.invalid("file-changed-during-read") }
                offset += count
            }
        }
        var after = stat(); var current = stat()
        let found = url.path.withCString { lstat($0, &current) }
        guard fstat(fd, &after) == 0, found == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              current.st_dev == after.st_dev, current.st_ino == after.st_ino,
              (current.st_mode & S_IFMT) == S_IFREG else { throw WKClipboardError.invalid("file-changed-during-read") }
        return bytes
    }

    @discardableResult func apply(_ item: WKMessage, expectedChangeCount: Int) throws -> URL? {
        try item.validate()
        guard board.changeCount == expectedChangeCount else { throw WKClipboardError.invalid("new-local-copy-wins") }
        let output = NSPasteboardItem()
        var received: URL?
        switch item.kind {
        case "text":
            guard output.setString(String(data: item.body, encoding: .utf8)!, forType: .string) else { throw WKClipboardError.invalid("clipboard-encode-failed") }
        case "png":
            let image = try Self.decodeImage(item.body, maximumBytes: WKMessage.maximumContent)
            guard let tiff = NSBitmapImageRep(cgImage: image).representation(using: .tiff, properties: [:]),
                  tiff.count <= Self.maximumSourceImageBytes,
                  output.setData(item.body, forType: .png), output.setData(tiff, forType: .tiff) else {
                throw WKClipboardError.invalid("clipboard-encode-failed")
            }
        case "file":
            received = try persist(item)
            guard output.setString(received!.absoluteString, forType: .fileURL) else { throw WKClipboardError.invalid("clipboard-encode-failed") }
        default: throw WKClipboardError.invalid("not-clipboard-content")
        }
        guard board.changeCount == expectedChangeCount else {
            if let received { try? FileManager.default.removeItem(at: received.deletingLastPathComponent()) }
            throw WKClipboardError.invalid("new-local-copy-wins")
        }
        board.clearContents()
        guard board.writeObjects([output]) else { throw WKClipboardError.invalid("clipboard-write-denied") }
        return received
    }

    // Publishes a portal's already-established file URL without reading it or
    // materializing its contents. The caller owns portal lifecycle/integrity.
    func applyFileURL(_ url: URL, expectedChangeCount: Int) throws {
        try applyFileURLs([url], expectedChangeCount: expectedChangeCount)
    }
    func applyFileURLs(_ urls: [URL], expectedChangeCount: Int) throws {
        guard !urls.isEmpty, urls.count <= 128 else { throw WKClipboardError.invalid("invalid-portal-selection") }
        var items: [NSPasteboardItem] = []
        for url in urls {
        guard url.isFileURL, url.path.hasPrefix("/"),
              url.host == nil || url.host == "" || url.host == "localhost",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              !url.path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw WKClipboardError.invalid("invalid-portal-file-url")
        }
        guard board.changeCount == expectedChangeCount else { throw WKClipboardError.invalid("new-local-copy-wins") }
        let item = NSPasteboardItem()
        guard item.setString(url.absoluteString, forType: .fileURL) else { throw WKClipboardError.invalid("clipboard-encode-failed") }
        items.append(item)
        }
        guard board.changeCount == expectedChangeCount else { throw WKClipboardError.invalid("new-local-copy-wins") }
        board.clearContents()
        guard board.writeObjects(items) else { throw WKClipboardError.invalid("clipboard-write-denied") }
    }

    private func persist(_ item: WKMessage) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: receiveRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = receiveRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var committed = false
        defer { if !committed { try? fm.removeItem(at: directory) } }
        let temporary = directory.appendingPathComponent(".wk-partial-" + UUID().uuidString)
        let destination = directory.appendingPathComponent(item.name!)
        let fd = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw WKClipboardError.invalid("receive-file-create-failed") }
        defer { Darwin.close(fd) }
        try item.body.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WKClipboardError.invalid("receive-file-write-failed") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw WKClipboardError.invalid("receive-file-flush-failed") }
        let renamed = temporary.path.withCString { old in destination.path.withCString { new in renamex_np(old, new, UInt32(RENAME_EXCL)) } }
        guard renamed == 0 else { throw WKClipboardError.invalid("receive-file-commit-failed") }
        guard try Self.readRegularFile(destination) == item.body else { throw WKClipboardError.invalid("receive-file-verify-failed") }
        committed = true; return destination
    }
}

struct WKBulkImage {
    let png: Data, tiff: Data
    static func prepare(_ png: Data) throws -> Self {
        guard png.prefix(8) == Data([137,80,78,71,13,10,26,10]), png.count <= WKStreamOffer.maximumImage else { throw WKStreamError.invalid }
        let image = try WKClipboard.decodeImage(png, maximumBytes: WKStreamOffer.maximumImage)
        guard let tiff = NSBitmapImageRep(cgImage: image).representation(using: .tiff, properties: [:]),
              tiff.count <= WKClipboard.maximumSourceImageBytes else { throw WKStreamError.capacity }
        return Self(png: png, tiff: tiff)
    }
}
extension WKClipboard {
    // Called only by a bounded background image job, with revision rechecked
    // before returning and again immediately before destination publication.
    func bulkImagePNG(expectedRevision: Int) throws -> Data? {
        guard changeCount == expectedRevision else { throw WKStreamError.changed }
        let result: Data?
        if let png = board.data(forType: .png) {
            guard png.count <= WKStreamOffer.maximumImage else { throw WKClipboardError.invalid("image-over-64MiB") }
            _ = try Self.decodeImage(png, maximumBytes: WKStreamOffer.maximumImage); result = png
        } else {
            var converted: Data?
            for type in [NSPasteboard.PasteboardType.tiff, .init("public.jpeg"), .init("public.heic")] {
                guard let bytes = board.data(forType: type) else { continue }
                guard bytes.count <= Self.maximumSourceImageBytes else { throw WKClipboardError.invalid("image-source-over-128MiB") }
                let image = try Self.decodeImage(bytes, maximumBytes: Self.maximumSourceImageBytes)
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                      png.count <= WKStreamOffer.maximumImage else { throw WKClipboardError.invalid("image-over-64MiB") }
                converted = png; break
            }
            result = converted
        }
        guard changeCount == expectedRevision else { throw WKStreamError.changed }
        return result
    }
    var hasImage: Bool { board.types?.contains(where: { [.png, .tiff, .init("public.jpeg"), .init("public.heic")].contains($0) }) == true }
    func applyBulkImage(_ image: WKBulkImage, expectedChangeCount: Int) throws {
        guard changeCount == expectedChangeCount else { throw WKStreamError.changed }
        let item = NSPasteboardItem()
        guard item.setData(image.png, forType: .png), item.setData(image.tiff, forType: .tiff),
              changeCount == expectedChangeCount else { throw WKStreamError.changed }
        board.clearContents()
        guard board.writeObjects([item]) else { throw WKClipboardError.invalid("clipboard-write-denied") }
    }
}
