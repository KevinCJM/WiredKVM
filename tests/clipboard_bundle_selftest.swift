// Generated data and unique private pasteboards only. Never NSPasteboard.general.
import AppKit
import CryptoKit

private struct BundleTestFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ value: @autoclosure () throws -> Bool, _ reason: String) throws {
    if try !value() { throw BundleTestFailure(description: reason) }
}
private func rejected(_ reason: String, _ body: () throws -> Void) throws {
    do { try body() } catch is BundleTestFailure { throw BundleTestFailure(description: reason) } catch { return }
    throw BundleTestFailure(description: reason)
}

@main enum ClipboardBundleSelfTest {
    static func main() {
        do { try run(); print("CLIPBOARD_BUNDLE_SELFTEST PASS private_pasteboards_only=true physicalUSB=false") }
        catch { print("CLIPBOARD_BUNDLE_SELFTEST FAIL \(error)"); exit(1) }
    }
    static func run() throws {
        let source = NSPasteboard.withUniqueName(), destination = NSPasteboard.withUniqueName()
        defer { source.releaseGlobally(); destination.releaseGlobally() }
        let a = WKClipboard(board: source), b = WKClipboard(board: destination)
        try expect(WKMetadata.line(role: "host", event: "CHECK", fields: ["token": "42"]) != nil,
            "v2 numeric transaction missing from safe diagnostics")
        try expect(WKMetadata.line(role: "host", event: "CHECK", fields: ["token": "42.43"]) != nil,
            "legacy numeric transaction missing from safe diagnostics")
        for invalid in ["42.43.44", "/Users/private/secret", "42.payload", ".42", "42."] {
            try expect(WKMetadata.line(role: "host", event: "CHECK", fields: ["token": invalid]) == nil,
                "non-numeric diagnostic token admitted")
        }
        for code in ["bulk-transport-required", "bundle-decode-failed", "bundle-invalid-image", "bundle-new-local-copy-wins"] {
            try expect(WKMetadata.errorCode(WKClipboardError.invalid(code)) == code && WKMetadata.safeCode(code),
                "fixed bundle code removed by diagnostic boundary")
        }
        try expect(!WKMetadata.safeCode("bundle-/Users/private/secret"), "arbitrary bundle diagnostic admitted")
        func publish(_ items: [NSPasteboardItem]) throws {
            source.clearContents(); try expect(source.writeObjects(items), "private board unavailable")
        }
        func text(_ string: String) -> NSPasteboardItem {
            let item = NSPasteboardItem(); precondition(item.setString(string, forType: .string)); return item
        }
        func transfer(_ bundle: WKClipboardBundle) throws -> WKClipboardBundle {
            try WKClipboardBundle.decode(bundle.encoded())
        }
        let first = text("第一行 🐾\nsecond line"), second = text("second item")
        let html = Data("<b>第一行 🐾</b>".utf8), rtf = Data("{\\rtf1\\ansi rich text}".utf8)
        first.setData(html, forType: .html); first.setData(rtf, forType: .rtf)
        first.setData(Data("do not transfer private data".utf8), forType: .init("org.fixture.private"))
        try publish([first, second])
        let revision = source.changeCount
        let bundle = try WKClipboardBundle.capture(clipboard: a, expectedRevision: revision)
        try expect(source.changeCount == revision, "capture changed source revision")
        try expect(bundle.items.count == 2 && bundle.items[0].representations.count == 3, "item order or standard representations lost")
        let received = try transfer(bundle)
        let committed = try received.apply(to: b, expectedChangeCount: destination.changeCount)
        let actual = destination.pasteboardItems!
        try expect(committed == destination.changeCount && actual.count == 2, "atomic multi-item publication")
        try expect(actual[0].string(forType: .string) == "第一行 🐾\nsecond line" && actual[1].string(forType: .string) == "second item", "ordered UTF-8 text")
        try expect(actual[0].data(forType: .html) == html && actual[0].data(forType: .rtf) == rtf, "rich bytes changed")
        try expect(actual[0].data(forType: .init("org.fixture.private")) == nil, "private representation leaked")
        print("BUNDLE standard-text-html-rtf-item-order-private-filter PASS")

        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 128, bitsPerPixel: 32), let pixels = bitmap.bitmapData else {
            throw BundleTestFailure(description: "image fixture")
        }
        for n in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) { pixels[n] = UInt8(n % 251) }
        let png = bitmap.representation(using: .png, properties: [:])!
        let tiff = bitmap.representation(using: .tiff, properties: [:])!
        let picture = text("image caption")
        picture.setData(png, forType: .png); picture.setData(tiff, forType: .tiff)
        try publish([picture])
        let pictureBundle = try WKClipboardBundle.capture(clipboard: a, expectedRevision: source.changeCount)
        try expect(pictureBundle.items[0].representations.filter { $0.kind == .png }.count == 1, "image duplicated")
        try expect(pictureBundle.items[0].representations.last?.body == png, "PNG not preferred verbatim")
        let pictureCopy = try transfer(pictureBundle)
        let destinationBeforePreparation = destination.changeCount
        let preparedImage = try pictureCopy.prepare()
        try expect(destination.changeCount == destinationBeforePreparation, "image preparation accessed target pasteboard")
        try preparedImage.apply(to: b, expectedChangeCount: destinationBeforePreparation)
        try expect(destination.string(forType: .string) == "image caption", "image suppressed sibling text")
        try expect(destination.data(forType: .png) == png && destination.data(forType: .tiff) != nil, "PNG/TIFF publication")
        let wire = try pictureCopy.encoded()
        try expect(wire.range(of: png) != nil && wire.range(of: Data(png.base64EncodedString().utf8)) == nil, "image is not raw binary")
        let tiffOnly = text("TIFF caption"); tiffOnly.setData(tiff, forType: .tiff)
        try publish([tiffOnly])
        let converted = try WKClipboardBundle.capture(clipboard: a, expectedRevision: source.changeCount)
        try expect(converted.items[0].representations.map(\.kind) == [.text, .png], "TIFF normalization lost item text")
        let badOptionalImage = text("usable caption")
        badOptionalImage.setData(Data([1, 2, 3]), forType: .png)
        try publish([badOptionalImage])
        let fallback = try WKClipboardBundle.capture(clipboard: a, expectedRevision: source.changeCount)
        try expect(fallback.items[0].representations.map(\.kind) == [.text], "broken optional image suppressed usable text")
        let badOnlyImage = NSPasteboardItem(); badOnlyImage.setData(Data([1, 2, 3]), forType: .png)
        try publish([badOnlyImage])
        try rejected("broken picture-only item admitted") { _ = try WKClipboardBundle.capture(clipboard: a, expectedRevision: source.changeCount) }
        print("BUNDLE same-item-text-image-single-PNG-TIFF-normalization PASS")

        // A previously legal 64 MiB PNG must not become illegal merely because
        // its synthesized TIFF takes the combined representation bytes above
        // 128 MiB. Wire bytes and additional decoded TIFF have separate budgets.
        do {
            guard let large = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4096, pixelsHigh: 4096,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 4096 * 4, bitsPerPixel: 32), let pixels = large.bitmapData else {
                throw BundleTestFailure(description: "large image fixture")
            }
            memset(pixels, 127, large.bytesPerRow * large.pixelsHigh)
            let smallPNG = large.representation(using: .png, properties: [:])!
            let padding = WKStreamOffer.maximumImage - smallPNG.count
            var ancillary = Data("npAD".utf8); ancillary.append(Data(repeating: 0, count: padding - 12))
            var paddedPNG = Data(smallPNG.dropLast(12)), length = UInt32(ancillary.count - 4).bigEndian
            withUnsafeBytes(of: &length) { paddedPNG.append(contentsOf: $0) }; paddedPNG.append(ancillary)
            var crc = WKBulkControl.crc(ancillary).bigEndian
            withUnsafeBytes(of: &crc) { paddedPNG.append(contentsOf: $0) }; paddedPNG.append(smallPNG.suffix(12))
            let expanded = try WKBulkImage.prepare(paddedPNG)
            try expect(expanded.png.count + expanded.tiff.count > WKClipboardBundle.maximumBytes,
                "separate-budget fixture must exceed old combined budget")
            let largeBundle = WKClipboardBundle(items: [.init(representations: [.init(kind: .png, body: paddedPNG)])])
            _ = try largeBundle.prepare()
            let twoImages = WKClipboardBundle(items: (0..<2).map { _ in .init(representations: [.init(kind: .png, body: smallPNG)]) })
            try rejected("total decoded image budget was not enforced") { _ = try twoImages.prepare() }
        }
        print("BUNDLE separate-wire-and-decoded-image-budgets PASS")

        let file = text("file display text")
        let secretURL = URL(fileURLWithPath: "/Users/fixture-private/never-read.bin")
        file.setString(secretURL.absoluteString, forType: .fileURL)
        try publish([file, text("after file")])
        var sourceURLs: [URL] = []
        let fileBundle = try WKClipboardBundle.capture(clipboard: a, expectedRevision: source.changeCount, fileReference: {
            sourceURLs.append($0); return "file_0"
        })
        let fileBytes = try fileBundle.encoded()
        try expect(sourceURLs == [secretURL] && fileBytes.range(of: Data(secretURL.absoluteString.utf8)) == nil,
            "source file path leaked or file resolver not used")
        var references: [String] = []
        let localURL = URL(fileURLWithPath: "/private/tmp/wk-generated-portal/received.bin")
        try WKClipboardBundle.decode(fileBytes).apply(to: b, expectedChangeCount: destination.changeCount, fileURL: {
            references.append($0); return localURL
        })
        try expect(references == ["file_0"] && destination.pasteboardItems![0].string(forType: .fileURL) == localURL.absoluteString,
            "destination URL not mapped")
        try expect(destination.pasteboardItems![1].string(forType: .string) == "after file", "file/item order lost")
        try rejected("missing file resolver admitted") { _ = try fileBundle.apply(to: b, expectedChangeCount: destination.changeCount) }
        try rejected("path accepted as opaque file reference") {
            _ = try WKClipboardBundle(items: [.init(representations: [.init(kind: .fileURL, fileReference: "../secret")])]).encoded()
        }
        print("BUNDLE file-reference-no-source-path-no-file-read-order PASS")

        let stale = destination.changeCount
        destination.clearContents(); destination.setString("local copy wins", forType: .string)
        try rejected("stale transfer overwrote local copy") { _ = try received.apply(to: b, expectedChangeCount: stale) }
        try expect(destination.string(forType: .string) == "local copy wins", "local clipboard was cleared on reject")
        try rejected("stale prepared image overwrote local copy") { _ = try preparedImage.apply(to: b, expectedChangeCount: stale) }
        try expect(destination.string(forType: .string) == "local copy wins", "prepared image cleared newer clipboard")
        var publishChecks = 0
        try rejected("copy during preparation was overwritten") {
            _ = try received.apply(to: b, expectedChangeCount: destination.changeCount, check: {
                publishChecks += 1
                if publishChecks == 2 { destination.clearContents(); destination.setString("copy during preparation", forType: .string) }
            })
        }
        try expect(destination.string(forType: .string) == "copy during preparation", "late commit replaced local copy")
        var checks = 0
        try rejected("source revision race admitted") {
            _ = try WKClipboardBundle.capture(clipboard: a, expectedRevision: source.changeCount, check: {
                checks += 1
                if checks == 2 { source.clearContents(); source.setString("new source", forType: .string) }
            })
        }
        let beforeCancel = destination.changeCount
        try rejected("cancelled apply committed") { _ = try received.apply(to: b, expectedChangeCount: beforeCancel, check: { throw WKClipboardError.invalid("cancelled") }) }
        try expect(destination.changeCount == beforeCancel, "cancel changed destination")
        try rejected("changed source revision admitted") { _ = try WKClipboardBundle.capture(clipboard: a, expectedRevision: -1) }
        print("BUNDLE revision-capture-apply-local-wins-cancellation PASS")

        let oneMiB = Data(repeating: 65, count: WKClipboardBundle.maximumText)
        let textLimit = WKClipboardBundle(items: [.init(representations: [.init(kind: .text, body: oneMiB)])])
        try expect(try transfer(textLimit).items[0].representations[0].body.count == oneMiB.count, "text boundary rejected")
        try rejected("text over limit admitted") {
            _ = try WKClipboardBundle(items: [.init(representations: [.init(kind: .html, body: oneMiB + Data([65]))])]).encoded()
        }
        let many = WKClipboardBundle(items: (0..<128).map { _ in .init(representations: [.init(kind: .text)]) })
        try expect(try transfer(many).items.count == 128, "128-item boundary rejected")
        try rejected("129 items admitted") { _ = try WKClipboardBundle(items: many.items + [many.items[0]]).encoded() }
        try rejected("container over total limit admitted") {
            _ = try WKClipboardBundle(items: (0..<128).map { _ in .init(representations: [.init(kind: .text, body: oneMiB)]) }).encoded()
        }
        try rejected("duplicate type admitted") {
            _ = try WKClipboardBundle(items: [.init(representations: [.init(kind: .text), .init(kind: .text)])]).encoded()
        }
        try rejected("invalid UTF-8 admitted") {
            _ = try WKClipboardBundle(items: [.init(representations: [.init(kind: .text, body: Data([255]))])]).encoded()
        }
        var corrupted = wire; corrupted[corrupted.count - 1] ^= 1
        try rejected("corrupt body admitted") { _ = try WKClipboardBundle.decode(corrupted) }
        try rejected("truncated container admitted") { _ = try WKClipboardBundle.decode(Data(wire.dropLast())) }
        var oversize = Data("WKCB".utf8); oversize.appendLE(UInt16(1)); oversize.appendLE(UInt16(0))
        oversize.appendLE(UInt32(WKClipboardBundle.maximumManifest + 1)); oversize.appendLE(UInt64(0)); oversize.append(Data(repeating: 0, count: 32))
        try rejected("manifest over limit admitted") { _ = try WKClipboardBundle.decode(oversize) }
        let privateOnly = NSPasteboardItem(); privateOnly.setData(Data([1]), forType: .init("org.fixture.private"))
        try publish([privateOnly])
        try rejected("private-only item admitted") { _ = try WKClipboardBundle.capture(clipboard: a, expectedRevision: source.changeCount) }
        print("BUNDLE limits-malformed-integrity-unsupported PASS")
    }
}
