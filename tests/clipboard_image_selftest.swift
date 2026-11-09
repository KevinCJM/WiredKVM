// Uses randomly named private pasteboards and generated pixels only.
// No general pasteboard, device, socket, system input, or user's files.
import AppKit
import ImageIO

func wkLog(_ message: String) { print(message) }

private struct ImageTestFailure: Error, CustomStringConvertible { let description: String }
private func check(_ value: @autoclosure () throws -> Bool, _ reason: String) throws {
    if try !value() { throw ImageTestFailure(description: reason) }
}

@main enum ClipboardImageSelfTest {
    static func main() {
        do { try run(); print("CLIPBOARD_IMAGE_SELFTEST PASS private_pasteboards_only=true") }
        catch { print("CLIPBOARD_IMAGE_SELFTEST FAIL \(error)"); exit(1) }
    }
    static func run() throws {
        let source = NSPasteboard.withUniqueName(), destination = NSPasteboard.withUniqueName()
        defer { source.releaseGlobally(); destination.releaseGlobally() }
        let a = WKClipboard(board: source), b = WKClipboard(board: destination)
        func bitmap(_ width: Int, _ height: Int) throws -> NSBitmapImageRep {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: width*4, bitsPerPixel: 32), let pixels = rep.bitmapData else {
                throw ImageTestFailure(description: "fixture allocation")
            }
            for y in 0..<height { for x in 0..<width {
                let n=y*rep.bytesPerRow+x*4
                pixels[n]=UInt8(x%128); pixels[n+1]=UInt8(y%128); pixels[n+2]=64; pixels[n+3]=128
            } }
            return rep
        }
        let rep = try bitmap(768,512)
        let tiff = rep.representation(using: .tiff, properties: [.compressionMethod: NSNumber(value: NSBitmapImageRep.TIFFCompression.none.rawValue)])!
        let png = rep.representation(using: .png, properties: [:])!
        try check(tiff.count > WKMessage.maximumContent && png.count < WKMessage.maximumContent, "large TIFF / small PNG fixture")
        source.clearContents(); try check(source.setData(tiff, forType: .tiff), "private board write")
        let originalRevision=source.changeCount
        guard let message=try a.snapshot(nonce:"71") else { throw ImageTestFailure(description: "TIFF-only snapshot missing") }
        try check(message.kind=="png", "TIFF normalized to PNG")
        try check(source.changeCount==originalRevision && source.data(forType:.tiff)==tiff, "source clipboard unchanged")
        let decoded=try WKMessage.decode(message.encoded())
        _=try b.apply(decoded,expectedChangeCount:destination.changeCount)
        try check(destination.data(forType:.png)==message.body, "PNG wire bytes preserved")
        guard let destinationTIFF=destination.data(forType:.tiff), let received=NSBitmapImageRep(data:destinationTIFF) else {
            throw ImageTestFailure(description:"destination TIFF representation missing")
        }
        try check(received.pixelsWide==768 && received.pixelsHigh==512 && received.hasAlpha, "TIFF dimensions and alpha")
        let color=received.colorAt(x:10,y:20)!.usingColorSpace(.deviceRGB)!
        try check(abs(color.alphaComponent-128.0/255)<0.01, "alpha preserved")
        print("CLIPBOARD_IMAGE large-TIFF-to-small-PNG-and-dual-format PASS")

        source.clearContents(); source.setData(png,forType:.png); source.setData(tiff,forType:.tiff)
        try check(try a.snapshot(nonce:"72")?.body==png, "PNG preference preserves exact bytes")
        print("CLIPBOARD_IMAGE original-PNG-preferred PASS")

        let jpeg=rep.representation(using:.jpeg,properties:[.compressionFactor:0.8])!
        source.clearContents(); source.setData(jpeg,forType:.init("public.jpeg")); source.setString("image caption",forType:.string)
        try check(try a.snapshot(nonce:"73")?.kind=="png", "JPEG selected before caption text")
        print("CLIPBOARD_IMAGE JPEG-only-source PASS")

        let expected=destination.changeCount
        destination.clearContents(); destination.setString("new local copy",forType:.string)
        do { _=try b.apply(message,expectedChangeCount:expected); throw ImageTestFailure(description:"stale image overwrote local copy") }
        catch is ImageTestFailure { throw ImageTestFailure(description:"stale image overwrote local copy") }
        catch { }
        try check(destination.string(forType:.string)=="new local copy", "new local clipboard retained")
        print("CLIPBOARD_IMAGE local-copy-wins PASS")

        let tooWide=try bitmap(8193,1).representation(using:.tiff,properties:[:])!
        for invalid in [Data([0,1,2,3]),tooWide] {
            source.clearContents(); source.setData(invalid,forType:.tiff)
            do { _=try a.snapshot(); throw ImageTestFailure(description:"invalid image accepted") }
            catch is ImageTestFailure { throw ImageTestFailure(description:"invalid image accepted") }
            catch { }
        }
        print("CLIPBOARD_IMAGE invalid-and-oversized-dimensions-rejected PASS")
    }
}
