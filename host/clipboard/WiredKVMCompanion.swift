import AppKit
import Darwin

func wkLog(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
func wkReply(_ message: String) { FileHandle.standardOutput.write(Data((message + "\n").utf8)) }

// Fail closed at the log boundary: only these numeric/enum fields may leave the
// companion. Error userInfo/description, pasteboard types and file metadata are
// never formatted. This also makes GUI persistence safe to allowlist independently.
enum WKMetadata {
    static let events: Set<String> = ["COPY", "ARM", "CANCEL", "REVISION", "LINK", "TRANSPORT", "PORTAL", "STREAM_IO", "TX", "RX", "FILE_TX", "FILE_RX", "BULK_TX", "BULK_RX", "TX_BIND", "APPLY", "COMPLETE", "PASTE", "CHECK", "ERROR"]
    static let errorCodes: Set<String> = [
        "image-over-64MiB", "image-source-over-128MiB", "item-too-large", "invalid-envelope-size", "envelope-checksum-mismatch", "content-integrity-check-failed",
        "invalid-control", "invalid-utf8", "invalid-png", "invalid-filename", "unsupported-content", "single-file-only",
        "file-promises-not-supported", "item-over-1MiB", "image-conversion-failed", "clipboard-changed-during-read",
        "invalid-or-oversized-image", "file-open-failed-or-symlink", "regular-file-only", "file-over-1MiB",
        "resource-fork-not-supported", "file-changed-during-read", "new-local-copy-wins", "clipboard-encode-failed",
        "not-clipboard-content", "clipboard-write-denied", "receive-file-create-failed", "receive-file-write-failed",
        "receive-file-flush-failed", "receive-file-commit-failed", "receive-file-verify-failed", "clipboard-error",
        "peer-timeout", "receive-timeout", "send-timeout", "invalid-command-stream", "unsupported-or-unavailable-clipboard",
        "paste-not-ready-copy-again-or-wait", "destination-clipboard-changed-or-unavailable", "transfer-rejected-or-interrupted",
        "invalid-private-socket-path", "socket-create-failed", "socket-nonblocking-failed", "local-install-failed",
        "file-portal-unavailable", "file-portal-access-denied", "file-transfer-queue-full", "file-offer-mismatch", "invalid-file-offer",
        "stream-file-interrupted", "stream-file-publish-failed", "stream-invalid", "stream-disconnected", "stream-integrity",
        "stream-source-changed", "stream-source-stat-failed", "stream-source-identity-changed", "stream-source-size-changed",
        "stream-source-mtime-changed", "stream-source-ctime-changed", "stream-capacity", "stream-timeout", "stream-io", "bulk-image-decode-failed", "collection-publish-failed"
    ]
    private static let booleans: Set<String> = ["accepted", "ready", "linkReady", "completedNonceMatches", "completedDirectionMatches",
        "latestNonceMatches", "latestDirectionMatches", "notCancelled", "revisionMatches", "notTransmitting", "noPending",
        "appliedNonceMatches", "appliedRevisionMatches"]
    private static let nonces: Set<String> = ["nonce", "latestNonce", "completedNonce", "appliedNonce"]
    private static let revisions: Set<String> = ["baseline", "revision", "previousRevision", "observedRevision", "appliedRevision"]
    static func signedInteger(_ value: String) -> Bool {
        let digits = value.hasPrefix("-") ? String(value.dropFirst()) : value
        return WKMessage.validNonce(digits)
    }
    static func safeCode(_ value: String) -> Bool {
        if errorCodes.contains(value) { return true }
        return ["cocoa-", "posix-", "osstatus-", "other-", "hid-access-denied-", "hid-device-open-denied-", "hid-write-failed-"]
            .contains { value.hasPrefix($0) && signedInteger(String(value.dropFirst($0.count))) }
    }
    static func errorCode(_ error: Error) -> String {
        if case WKClipboardError.invalid(let code) = error { return errorCodes.contains(code) ? code : "clipboard-error" }
        let value = error as NSError
        let family: String
        switch value.domain {
        case NSCocoaErrorDomain: family = "cocoa"
        case NSPOSIXErrorDomain: family = "posix"
        case NSOSStatusErrorDomain: family = "osstatus"
        default: family = "other"
        }
        return "\(family)-\(value.code)"
    }
    static func line(role: String, event: String, fields: [String: String]) -> String? {
        guard ["host", "target"].contains(role), events.contains(event), fields.count <= 32 else { return nil }
        if event == "STREAM_IO" {
            let numeric = Set("steps elapsedUs gapMaxUs pendingMax inFlightMax readWaitSteps windowFullSteps readCalls readBytes readZero readMax writeCalls writeWanted writeBytes writeZero writePartial writeMax".split(separator:" ").map(String.init))
            guard Set(fields.keys) == numeric.union(["phase"]), ["PROGRESS", "RESULT"].contains(fields["phase"] ?? "") else { return nil }
        }
        for (key, value) in fields {
            guard !value.isEmpty, value.utf8.count <= 80 else { return nil }
            let valid: Bool
            if booleans.contains(key) { valid = ["0", "1"].contains(value) }
            else if nonces.contains(key) { valid = value == "none" || WKMessage.validNonce(value) }
            else if revisions.contains(key) { valid = value == "none" || signedInteger(value) }
            else {
                switch key {
                case "phase": valid = ["START", "PROGRESS", "COMPLETE", "CANCEL", "RESET", "REJECT", "REQUEST", "RESULT"].contains(value)
                case "direction": valid = ["OUT", "IN"].contains(value)
                case "transfer", "acked": valid = WKMessage.validNonce(value)
                case "total": valid = value == "unknown" || WKMessage.validNonce(value)
                case "peerAccepted": valid = ["0", "1", "unknown"].contains(value)
                case "token":
                    let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                    valid = parts.count == 2 && parts.allSatisfy(WKMessage.validNonce)
                case "result": valid = ["READY", "BLOCK", "CHECK"].contains(value)
                case "code": valid = safeCode(value)
                case "usbMbps": valid = ["unknown", "1.5", "12", "480"].contains(value)
                case "davMetadata", "davMissing", "davWaiting", "davServed", "davFailed", "davMalformed", "davCapacity", "davProxy":
                    valid = WKMessage.validNonce(value) && UInt32(value) != nil
                case "steps", "elapsedUs", "gapMaxUs", "pendingMax", "inFlightMax", "readWaitSteps", "windowFullSteps",
                     "readCalls", "readBytes", "readZero", "readMax", "writeCalls", "writeWanted", "writeBytes", "writeZero", "writePartial", "writeMax":
                    valid = WKMessage.validNonce(value) && UInt32(value) != nil
                default: valid = false
                }
            }
            guard valid else { return nil }
        }
        let pairs = fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }
        return (["WKCLIP_DIAG", "role=\(role)", "event=\(event)"] + pairs).joined(separator: " ")
    }
}

// Main-thread coordinator. Clipboard changes and incoming transfers are serialized
// here so that a fresh local copy cannot be overwritten by an older remote item.
protocol WKFilePortalServing: AnyObject {
    var isAvailable: Bool { get }
    var diagnosticCounts: [UInt32]? { get }
    func start(completion: @escaping (Result<Void, Error>) -> Void)
    func stop()
    func stop(completion: @escaping () -> Void)
    func offer(id: String, name: String, size: Int, sha256: String) throws -> URL
    func fulfill(id: String, data: Data) throws
    func offerStream(_ offer: WKStreamOffer) throws -> URL
    func fulfill(id: String, file: WKReceivedFile) throws
#if WK_TREE
    func offerTree(_ offer: WKStreamOffer, manifest: WKTreeManifest) throws -> [URL]
#endif
    func fail(id: String)
    func retire(id: String)
}

extension WKFilePortalServing {
    var diagnosticCounts: [UInt32]? { nil }
    func stop(completion: @escaping () -> Void) { stop(); completion() }
    func offerStream(_ offer: WKStreamOffer) throws -> URL { throw WKFilePortalError.unavailable }
    func fulfill(id: String, file: WKReceivedFile) throws { throw WKFilePortalError.unavailable }
#if WK_TREE
    func offerTree(_ offer: WKStreamOffer, manifest: WKTreeManifest) throws -> [URL] { throw WKFilePortalError.unavailable }
#endif
}

extension WKFilePortal: WKFilePortalServing {}

enum WKCompanionInputPolicy {
    // Native keyboard, pointer and touch reports remain firmware-owned. The
    // portable clipboard receiver must not inject a second scroll/gesture path.
#if WK_PORTABLE
    static let legacyInputRelay = false
#else
    static let legacyInputRelay = true
#endif
}

#if !WK_CH32_TEST
@MainActor private final class WKTargetAutoRunner {
    private var companion: WKCompanion?
    private var profile: String?
    private var timer: Timer?
    private var changing = false
#if WK_PORTABLE
    private var waitingItem: NSStatusItem?
    private func showWaiting() {
        guard waitingItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "⇄"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "临时连接：等待 USB 线", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "结束 WiredKVM 临时会话", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared; menu.addItem(quit); item.menu = menu
        waitingItem = item
    }
    private func hideWaiting() {
        if let item = waitingItem { NSStatusBar.system.removeStatusItem(item) }
        waitingItem = nil
    }
#endif
#if !WK_PORTABLE
    private var firstRun: WKFirstRunWindow?
#endif
    func start(headless: Bool, first: Bool) {
#if !WK_PORTABLE
        if first { firstRun = WKFirstRunWindow.shared(role: "target"); firstRun?.show() }
#endif
        refresh(headless: headless)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh(headless: headless) }
        }
    }
    private func refresh(headless: Bool) {
        guard !changing else { return }
        let files = WKUSBDiscovery.unique(role: "target", files: true)
#if WK_PORTABLE
        // This build requires CH32 Bulk. Missing hardware must not silently
        // select the old ESP32 HID image/file implementation.
        guard files != nil else {
            if let old = companion {
                changing = true
                old.stop { Task { @MainActor in
                    self.companion = nil; self.profile = nil; self.changing = false
                    self.showWaiting()
                } }
            } else { showWaiting() }
            return
        }
#endif
        let next = files ?? "ESP32"
        guard profile != next else { return }; changing = true
        let launch = { [self] in
#if WK_PORTABLE
            hideWaiting()
#endif
            let transport: WKTransport = files == nil ? WKHIDTransport() :
                WKHIDTransport.ch32Target()
            let stream = files.map { path in WKStreamFiles { try WKCDCStreamIO(path: path, role: "target") } }
            let component = WKCompanion(role: "target", clipboard: WKClipboard(board: .general), transport: transport,
                portal: WKFilePortal(), stream: stream, pixelScrollEnabled: WKCompanionInputPolicy.legacyInputRelay)
            if let files { component.usbLinkRateProvider = { WKUSBDiscovery.rate(path: files) } }
            companion = component; profile = next; changing = false; component.start(headless: headless)
        }
        if let old = companion { old.stop { Task { @MainActor in launch() } } } else { launch() }
    }
}
@main struct WiredKVMCompanionMain {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
#if WK_PORTABLE
        // Side-effect-free packaging check: before AppKit, USB, permissions,
        // pasteboard creation, mount or any per-user state.
        if arguments == ["--portable-check"] {
            var capabilities: [String: Any] = ["mode": "portable", "installer": false, "loginItem": false,
                "persistentPreferences": false, "automaticSetupEject": false,
                "legacyInputRelay": WKCompanionInputPolicy.legacyInputRelay, "binaryBulk": true]
#if WK_TREE
            capabilities["collections"] = true
#else
            capabilities["collections"] = false
#endif
            wkReply(String(decoding: try! JSONSerialization.data(withJSONObject: capabilities, options: .sortedKeys), as: UTF8.self))
            return
        }
#else
        if arguments == ["--self-test"] {
            do { try WKSelfTest.run(); wkLog("WKCLIP_SELF_TEST PASS"); exit(0) }
            catch { wkLog("WKCLIP_SELF_TEST FAIL \(error)"); exit(1) }
        }
#endif
        var role = "target"; var socketPath: String?; var headless = false; var ch32Files: String?
        var index = 0; var firstRun = false; var inputOnly = false
        while index < arguments.count {
            switch arguments[index] {
            case "--role", "--socket", "--ch32-files":
                guard index + 1 < arguments.count else { usage() }
                if arguments[index] == "--role" { role = arguments[index + 1] }
                else if arguments[index] == "--ch32-files" { ch32Files = arguments[index + 1] }
                else { socketPath = arguments[index + 1] }
                index += 2
            case "--headless": headless = true; index += 1
            case "--input-only": inputOnly = true; index += 1
            case "--first-run": firstRun = true; index += 1
            default: usage()
            }
        }
        guard ["host", "target"].contains(role), (role != "host" || socketPath?.hasPrefix("/") == true),
              role != "target" || socketPath == nil else { usage() }
#if WK_PORTABLE
        // Portable distribution cannot enter the installed first-run flow.
        guard !firstRun, Bundle.main.bundleIdentifier != "com.wiredkvm.setup",
              role != "host" || ch32Files != nil || inputOnly else { usage() }
#endif
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        if inputOnly {
            // Branch before installer, clipboard, portal and file-stream creation.
            // Do not let an input-only invocation alter installation/login state.
            guard headless, !firstRun, ch32Files == nil,
                  Bundle.main.bundleIdentifier != "com.wiredkvm.setup" else { usage() }
            let transport: WKTransport
            if role == "host" { transport = WKUnixTransport(path: socketPath!) }
            else if WKUSBDiscovery.unique(role: "target", files: true) != nil {
                transport = WKHIDTransport.ch32Target()
            } else { transport = WKHIDTransport() }
            let relay = WKInputRelay(role: WKInputRelay.Role(rawValue: role)!, transport: transport)
            relay.onTerminate = { application.terminate(nil) }
            relay.start()
            withExtendedLifetime(relay) { application.run() }
            relay.stop(); return
        }
#if !WK_PORTABLE
        if Bundle.main.bundleIdentifier == "com.wiredkvm.setup" {
            WKCompanionInstall.runBundledInstaller()
            return
        }
        if role == "target" && ch32Files == nil && !WKCompanionInstall.continueHereIfNeeded() { return }
#endif
        if role == "target" && ch32Files == nil {
            let runner = WKTargetAutoRunner(); runner.start(headless: headless, first: firstRun)
            withExtendedLifetime(runner) { application.run() }; return
        }
        if let ch32Files, !WKCH32Device.matches(path: ch32Files, role: role) { wkLog("CH32 device identity/interface mismatch"); exit(2) }
        let transport: WKTransport = role == "host" ? WKUnixTransport(path: socketPath!) :
            (ch32Files == nil ? WKHIDTransport() : WKHIDTransport.ch32Target())
        let stream = ch32Files.map { path in WKStreamFiles { try WKCDCStreamIO(path: path, role: role) } }
        let companion = WKCompanion(role: role, clipboard: WKClipboard(board: .general), transport: transport,
                                    portal: WKFilePortal(), stream: stream, pixelScrollEnabled: WKCompanionInputPolicy.legacyInputRelay)
        if let ch32Files { companion.usbLinkRateProvider = { WKUSBDiscovery.rate(path: ch32Files) } }
        companion.start(headless: headless)
        withExtendedLifetime(companion) { application.run() }
    }
    static func usage() -> Never {
#if WK_PORTABLE
        wkLog("usage: WiredKVMPortable [--role target] [--headless] [--ch32-files /dev/cu.usbmodem...] | --role host --socket ABS_PATH [--ch32-files /dev/cu.usbmodem...] | --portable-check")
#else
        wkLog("usage: wiredkvm-companion [--role target] [--headless] [--ch32-files /dev/cu.usbmodem...] | --role host --socket ABS_PATH [--ch32-files /dev/cu.usbmodem...] | --role host --socket ABS_PATH --input-only --headless | --role target --input-only --headless | --self-test")
#endif
        exit(2)
    }
}
#endif
