// Small signed launcher. Its sealed tar.xz stores both roles once. The full
// application is verified and started from the local disk, never the slow MSC.
import AppKit
import CryptoKit

enum WKClipboardError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { if case let .invalid(s) = self { return s }; return "安装未完成" }
}
enum WKMetadata {
    static func line(role: String, event: String, fields: [String:String]) -> String? { nil }
    static func errorCode(_ error: Error) -> String { "install" }
}
func wkLog(_ value: String) { fputs(value + "\n", stderr) }

enum WKSetupPayload {
    static func install(bundle: URL, progress: (String) -> Void) throws -> URL {
        try WKCompanionInstall.requireReadOnlySetup(bundle)
        progress("正在校验板载安装器…")
        try WKCompanionInstall.verifySignature(bundle, identifier: "com.wiredkvm.onboarding")
        let deadline = Date().addingTimeInterval(8)
        var roles = Set<String>()
        repeat {
            roles = Set(WKUSBDiscovery.ports().map(\.role))
            if !roles.isEmpty { break }; Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        guard roles.count == 1, let role = roles.first else {
            throw WKClipboardError.invalid("无法确定连接线角色。请确认本机只连接这根线的一侧，然后重新打开安装器。")
        }
        WKCompanionInstall.kind = role == "host" ? .host : .companion
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wk-setup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = bundle.appendingPathComponent("Contents/Resources/applications.tar.xz")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String:Any]
        let bytes = try Data(contentsOf: archive)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard bytes.count <= 4*1024*1024, info?["WKPayloadSHA256"] as? String == digest else {
            throw WKClipboardError.invalid("板载安装包不完整，本次未覆盖任何应用。")
        }
        // The complete archive is authenticated by the launcher's sealed
        // signature before extraction into an owned, fresh private directory.
        progress(role == "host" ? "正在准备主控程序…" : "正在准备被控组件…")
        let local = root.appendingPathComponent("applications.tar.xz"); try bytes.write(to: local)
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["-xJf", local.path, "-C", root.path, "--no-same-owner"]
        task.standardInput = FileHandle.nullDevice; task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run(); let end = Date().addingTimeInterval(30)
        while task.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        if task.isRunning { task.terminate(); task.waitUntilExit(); throw WKClipboardError.invalid("准备本机安装包超时，请重试。") }
        guard task.terminationStatus == 0 else { throw WKClipboardError.invalid("安装包解压失败，原程序已保留。") }
        let name = role == "host" ? "WiredKVM.app" : "WiredKVM Companion.app"
        return try WKCompanionInstall.installApplication(source: root.appendingPathComponent(name),
            applications: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            operations: .live, progress: progress)
    }
}

@main enum WiredKVMSetup {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let installer = WKInstallApplication(title: "安装 WiredKVM · 一次设置，以后插线即用", work: { progress in
            try WKSetupPayload.install(bundle: Bundle.main.bundleURL, progress: progress)
        }, open: WKCompanionInstall.openLocalApplication)
        app.delegate = installer; withExtendedLifetime(installer) { app.run() }
    }
}
