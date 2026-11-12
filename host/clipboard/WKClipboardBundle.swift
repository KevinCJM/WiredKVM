import AppKit
import CryptoKit
import ImageIO

// A bundle describes pasteboard items, not applications. Only the manifest is
// JSON; representation bodies are contiguous raw binary on the Bulk channel.
struct WKClipboardBundle {
    static let maximumBytes = 128 * 1024 * 1024
    static let maximumManifest = 1_048_576
    static let maximumItems = 128
    static let maximumText = 1_048_576
    static let maximumDecodedImageBytes = WKClipboard.maximumSourceImageBytes
    private static let headerBytes = 52
    private static let magic = Data("WKCB".utf8)
    private static let ownerType = NSPasteboard.PasteboardType("com.wiredkvm.clipboard.bundle-owner")

    enum Kind: String, Codable, CaseIterable {
        case text, html, rtf, png
        case fileURL = "file-url"
        var pasteboardType: NSPasteboard.PasteboardType {
            switch self {
            case .text: return .string
            case .html: return .html
            case .rtf: return .rtf
            case .png: return .png
            case .fileURL: return .fileURL
            }
        }
    }
    struct Representation {
        let kind: Kind
        let body: Data
        let fileReference: String?
        init(kind: Kind, body: Data = Data(), fileReference: String? = nil) {
            self.kind = kind; self.body = body; self.fileReference = fileReference
        }
    }
    struct Item {
        let representations: [Representation]
        init(representations: [Representation]) { self.representations = representations }
    }
    let items: [Item]
    init(items: [Item]) { self.items = items }

    private struct Descriptor: Codable {
        let kind: Kind, offset: Int, length: Int, sha256: String
        let fileReference: String?
    }
    private struct ManifestItem: Codable { let representations: [Descriptor] }
    private struct Manifest: Codable { let version: Int; let items: [ManifestItem] }
    private static func fail(_ code: String) -> WKClipboardError { .invalid("bundle-" + code) }
    private static func validReference(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    private static func validate(_ representation: Representation) throws {
        if representation.kind == .fileURL {
            guard representation.body.isEmpty, let reference = representation.fileReference,
                  validReference(reference) else { throw fail("invalid-file-reference") }
            return
        }
        guard representation.fileReference == nil else { throw fail("unexpected-file-reference") }
        if representation.kind == .png {
            guard representation.body.count <= WKStreamOffer.maximumImage,
                  representation.body.prefix(8) == Data([137,80,78,71,13,10,26,10]) else { throw fail("invalid-image") }
        } else {
            guard representation.body.count <= maximumText else { throw fail("text-over-1MiB") }
            if representation.kind == .text {
                guard String(data: representation.body, encoding: .utf8) != nil else { throw fail("invalid-utf8") }
            }
        }
    }
    private func validate() throws {
        guard !items.isEmpty, items.count <= Self.maximumItems else { throw Self.fail("item-capacity") }
        var total = 0
        for item in items {
            guard !item.representations.isEmpty, item.representations.count <= Kind.allCases.count,
                  Set(item.representations.map(\.kind)).count == item.representations.count else {
                throw Self.fail("invalid-representations")
            }
            for representation in item.representations {
                try Self.validate(representation)
                guard representation.body.count <= Self.maximumBytes - total else { throw Self.fail("capacity") }
                total += representation.body.count
            }
        }
    }

    func encoded() throws -> Data {
        try validate()
        var offset = 0
        let metadata = items.map { item in
            ManifestItem(representations: item.representations.map { representation in
                defer { offset += representation.body.count }
                return Descriptor(kind: representation.kind, offset: offset, length: representation.body.count,
                    sha256: WKMessage.digest(representation.body), fileReference: representation.fileReference)
            })
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let manifest = try encoder.encode(Manifest(version: 1, items: metadata))
        guard manifest.count <= Self.maximumManifest,
              offset <= Self.maximumBytes - Self.headerBytes - manifest.count else { throw Self.fail("capacity") }
        var prefix = Self.magic; prefix.appendLE(UInt16(1)); prefix.appendLE(UInt16(0))
        prefix.appendLE(UInt32(manifest.count)); prefix.appendLE(UInt64(offset))
        var checksum = SHA256(); checksum.update(data: prefix); checksum.update(data: manifest)
        for item in items { for representation in item.representations { checksum.update(data: representation.body) } }
        var result = Data(); result.reserveCapacity(Self.headerBytes + manifest.count + offset)
        result.append(prefix); result.append(contentsOf: checksum.finalize()); result.append(manifest)
        for item in items { for representation in item.representations { result.append(representation.body) } }
        return result
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count >= headerBytes, data.count <= maximumBytes,
              data.prefix(4) == magic, data.readLE(at: 4) as UInt16 == 1,
              data.readLE(at: 6) as UInt16 == 0 else { throw fail("invalid-header") }
        let manifestBytes = Int(data.readLE(at: 8) as UInt32)
        let bodyBytes: UInt64 = data.readLE(at: 12)
        guard manifestBytes > 0, manifestBytes <= maximumManifest,
              manifestBytes <= data.count - headerBytes,
              bodyBytes == UInt64(data.count - headerBytes - manifestBytes) else { throw fail("invalid-length") }
        var checksum = SHA256(); checksum.update(data: data.prefix(20)); checksum.update(data: data.dropFirst(headerBytes))
        guard Data(checksum.finalize()) == data[20..<headerBytes] else { throw fail("integrity") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(data[headerBytes..<(headerBytes + manifestBytes)]))
        guard manifest.version == 1, !manifest.items.isEmpty, manifest.items.count <= maximumItems else { throw fail("item-capacity") }
        let bodyStart = headerBytes + manifestBytes
        var offset = 0, items: [Item] = []
        for item in manifest.items {
            guard !item.representations.isEmpty, item.representations.count <= Kind.allCases.count else { throw fail("invalid-representations") }
            var representations: [Representation] = []
            for descriptor in item.representations {
                guard descriptor.offset == offset, descriptor.length >= 0,
                      descriptor.length <= data.count - bodyStart - offset else { throw fail("invalid-segment") }
                let body = Data(data[(bodyStart + offset)..<(bodyStart + offset + descriptor.length)])
                guard descriptor.sha256 == WKMessage.digest(body) else { throw fail("segment-integrity") }
                representations.append(Representation(kind: descriptor.kind, body: body, fileReference: descriptor.fileReference))
                offset += descriptor.length
            }
            items.append(Item(representations: representations))
        }
        guard offset == data.count - bodyStart else { throw fail("unreferenced-body") }
        let bundle = Self(items: items); try bundle.validate(); return bundle
    }

    // Called only after a cross-machine Paste intent. Reading an advertised
    // representation may call the source application's lazy pasteboard owner.
    static func capture(clipboard: WKClipboard, expectedRevision: Int,
        fileReference: (URL) throws -> String = { _ in throw fail("file-resolver-required") },
        check: () throws -> Void = {}) throws -> Self {
        try check()
        guard clipboard.changeCount == expectedRevision else { throw fail("source-changed") }
        guard let sourceItems = clipboard.board.pasteboardItems, !sourceItems.isEmpty,
              sourceItems.count <= maximumItems else { throw fail("item-capacity") }
        var result: [Item] = [], capturedBytes = 0
        for source in sourceItems {
            try check()
            guard clipboard.changeCount == expectedRevision else { throw fail("source-changed") }
            var representations: [Representation] = []
            for kind in [Kind.text, .html, .rtf] where source.types.contains(kind.pasteboardType) {
                let body: Data
                if kind == .text {
                    guard let string = source.string(forType: .string) else { throw fail("unavailable-text") }
                    body = Data(string.utf8)
                } else {
                    guard let bytes = source.data(forType: kind.pasteboardType) else { throw fail("unavailable-representation") }
                    body = bytes
                }
                let representation = Representation(kind: kind, body: body)
                try validate(representation)
                guard body.count <= maximumBytes - capturedBytes else { throw fail("capacity") }
                capturedBytes += body.count; representations.append(representation)
            }
            if source.types.contains(.fileURL) {
                guard let value = source.string(forType: .fileURL), let url = URL(string: value),
                      validLocalFileURL(url) else { throw fail("invalid-source-file-url") }
                let reference = try fileReference(url)
                let representation = Representation(kind: .fileURL, fileReference: reference)
                try validate(representation); representations.append(representation)
            } else {
                var png: Data?
                do {
                    png = try canonicalPNG(source)
                } catch {
                    // A broken optional picture must not suppress the same
                    // item's usable text. Cancellation/revision changes and
                    // total-container limits are still checked independently.
                    guard representations.contains(where: { [.text, .html, .rtf].contains($0.kind) }) else { throw error }
                    try check()
                    guard clipboard.changeCount == expectedRevision else { throw fail("source-changed") }
                }
                if let png {
                    guard png.count <= maximumBytes - capturedBytes else { throw fail("capacity") }
                    capturedBytes += png.count; representations.append(Representation(kind: .png, body: png))
                }
            }
            guard !representations.isEmpty else { throw fail("unsupported-item") }
            result.append(Item(representations: representations))
        }
        try check()
        guard clipboard.changeCount == expectedRevision else { throw fail("source-changed") }
        let bundle = Self(items: result); try bundle.validate(); return bundle
    }

    private static func canonicalPNG(_ item: NSPasteboardItem) throws -> Data? {
        if item.types.contains(.png) {
            guard let png = item.data(forType: .png), png.count <= WKStreamOffer.maximumImage,
                  png.prefix(8) == Data([137,80,78,71,13,10,26,10]) else { throw fail("invalid-image") }
            _ = try WKClipboard.decodeImage(png, maximumBytes: WKStreamOffer.maximumImage)
            return png
        }
        for type in [NSPasteboard.PasteboardType.tiff, .init("public.jpeg"), .init("public.heic")] where item.types.contains(type) {
            guard let bytes = item.data(forType: type) else { throw fail("unavailable-image") }
            let image = try WKClipboard.decodeImage(bytes, maximumBytes: WKClipboard.maximumSourceImageBytes)
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  png.count <= WKStreamOffer.maximumImage else { throw fail("image-over-64MiB") }
            return png
        }
        return nil
    }

    private static func validLocalFileURL(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && (url.host == nil || url.host == "" || url.host == "localhost") &&
            url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil &&
            !url.path.unicodeScalars.contains(where: { $0.value == 0 })
    }

    // Build and validate all representations off the control/main thread.
    // The resolver receives only already-established local portal references.
    struct Prepared {
        fileprivate let items: [NSPasteboardItem]
        fileprivate let owner: String
        @discardableResult func apply(to clipboard: WKClipboard, expectedChangeCount: Int,
            check: () throws -> Void = {}) throws -> Int {
            try check()
            guard clipboard.changeCount == expectedChangeCount else { throw WKClipboardBundle.fail("new-local-copy-wins") }
            let cleared = clipboard.board.clearContents()
            guard clipboard.changeCount == cleared else { throw WKClipboardBundle.fail("new-local-copy-wins") }
            guard clipboard.board.writeObjects(items) else { throw WKClipboardBundle.fail("write-denied") }
            let committed = clipboard.changeCount
            guard clipboard.board.string(forType: WKClipboardBundle.ownerType) == owner, clipboard.changeCount == committed else {
                throw WKClipboardBundle.fail("new-local-copy-wins")
            }
            return committed
        }
    }

    func prepare(fileURL: (String) throws -> URL = { _ in throw Self.fail("file-resolver-required") },
        check: () throws -> Void = {}) throws -> Prepared {
        try validate(); try check()
        var output: [NSPasteboardItem] = [], decodedImageBytes = 0
        let owner = UUID().uuidString
        for item in items {
            try check()
            let target = NSPasteboardItem()
            for representation in item.representations {
                try check()
                switch representation.kind {
                case .fileURL:
                    let url = try fileURL(representation.fileReference!)
                    guard Self.validLocalFileURL(url), target.setString(url.absoluteString, forType: .fileURL) else {
                        throw Self.fail("invalid-destination-file-url")
                    }
                case .png:
                    let image = try WKBulkImage.prepare(representation.body)
                    try check()
                    guard image.tiff.count <= Self.maximumDecodedImageBytes - decodedImageBytes else { throw Self.fail("image-memory-capacity") }
                    decodedImageBytes += image.tiff.count
                    guard target.setData(image.png, forType: .png), target.setData(image.tiff, forType: .tiff) else { throw Self.fail("write-denied") }
                default:
                    guard target.setData(representation.body, forType: representation.kind.pasteboardType) else { throw Self.fail("write-denied") }
                }
            }
            output.append(target)
        }
        guard output[0].setString(owner, forType: Self.ownerType) else { throw Self.fail("write-denied") }
        try check()
        return Prepared(items: output, owner: owner)
    }

    @discardableResult func apply(to clipboard: WKClipboard, expectedChangeCount: Int,
        fileURL: (String) throws -> URL = { _ in throw Self.fail("file-resolver-required") },
        check: () throws -> Void = {}) throws -> Int {
        try check()
        guard clipboard.changeCount == expectedChangeCount else { throw Self.fail("new-local-copy-wins") }
        return try prepare(fileURL: fileURL, check: check).apply(to: clipboard, expectedChangeCount: expectedChangeCount, check: check)
    }
}
