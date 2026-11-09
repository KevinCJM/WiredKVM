import AppKit
import CryptoKit
import Darwin

// A user opens the signed bundle on the setup volume. Local first-run setup
// manages the visible login item after launch; no shell injection or USB autorun.
enum WKCompanionInstall {
    enum Kind { case host, companion }
    static var kind: Kind = .companion
    private static var identity: String { kind == .host ? "com.wiredkvm.menu" : "com.wiredkvm.companion" }
    private static var executableName: String { kind == .host ? "WiredKVM" : "WiredKVMCompanion" }
    private static var applicationName: String { kind == .host ? "WiredKVM.app" : "WiredKVM Companion.app" }
    private static let setupVolumeName = "WiredKVM Setup"

    static func isSetupLocation(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 4, components[0].isEmpty, components[1] == "Volumes",
              path.hasSuffix(".app"),
              !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        let volume = String(components[2])
        if volume == setupVolumeName { return true }
        let prefix = setupVolumeName + " "
        guard volume.hasPrefix(prefix) else { return false }
        let suffix = volume.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    // Enter AppKit before doing any disk I/O or Launch Services handoff.
    // Finder must receive the launch acknowledgement even on slow media.
    @MainActor static func continueHereIfNeeded() -> Bool {
        let source = Bundle.main.bundleURL.standardizedFileURL
        guard isSetupLocation(source.path) else { return true }
        runInstaller(source: source, bundled: false)
        return false
    }

    @MainActor static func runBundledInstaller() {
        runInstaller(source: Bundle.main.bundleURL.standardizedFileURL, bundled: true)
    }

    @MainActor private static func runInstaller(source: URL, bundled: Bool) {
        let runner = WKInstallApplication(work: { progress in
            try requireReadOnlySetup(source)
            var payload = source
            if bundled {
                guard Bundle.main.bundleIdentifier == "com.wiredkvm.setup",
                      let resources = Bundle.main.resourceURL,
                      resources.standardizedFileURL == source.appendingPathComponent("Contents/Resources").standardizedFileURL else {
                    throw WKClipboardError.invalid("安装器身份或资源路径无效，本次未覆盖任何文件。")
                }
                progress("正在校验安装包…")
                try verifySignature(source, identifier: "com.wiredkvm.setup")
                payload = resources.appendingPathComponent("WiredKVM Companion.app", isDirectory: true)
                try requireReadOnlySetup(payload)
            }
            let applications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            return try installApplication(source: payload, applications: applications, operations: .live, progress: progress)
        }, open: openLocalApplication)
        let application = NSApplication.shared
        application.delegate = runner
        withExtendedLifetime(runner) { application.run() }
    }

    static func requireReadOnlySetup(_ url: URL) throws {
        var mount = statfs(), info = stat()
        guard isSetupLocation(url.path), url.path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              url.path.withCString({ statfs($0, &mount) }) == 0,
              mount.f_flags & UInt32(MNT_RDONLY) != 0 else {
            throw WKClipboardError.invalid("请从只读 WiredKVM Setup 安装盘打开安装器，本次未覆盖任何文件。")
        }
    }

    struct ApplicationInfo: Equatable { let build: UInt64; let digest: Data }
    enum InstallAction { case reuse, upgrade }
    // Injectable only for isolated filesystem tests. Production always uses
    // live signature validation, graceful termination and atomic rename.
    struct InstallOperations {
        var validate: (URL, Bool) throws -> ApplicationInfo
        var terminate: (URL) throws -> Void
        var rename: (URL, URL, UInt32) throws -> Void
        static var live: Self {
            Self(validate: WKCompanionInstall.validate, terminate: WKCompanionInstall.terminateInstalledApplication,
                 rename: WKCompanionInstall.atomicRename)
        }
    }

    static func buildNumber(_ text: String) throws -> UInt64 {
        guard !text.isEmpty, text.utf8.count <= 20,
              text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let build = UInt64(text), build > 0 else {
            throw WKClipboardError.invalid("应用构建编号无效，本次未覆盖旧应用。")
        }
        return build
    }

    static func action(source: ApplicationInfo, existing: ApplicationInfo) throws -> InstallAction {
        guard source.build >= existing.build else {
            throw WKClipboardError.invalid("安装盘中的版本比本地版本旧，已阻止降级；本次未覆盖旧应用。")
        }
        if source.build == existing.build {
            guard source.digest == existing.digest else {
                throw WKClipboardError.invalid("相同构建编号的应用内容不同，已停止安装；本次未覆盖旧应用。")
            }
            return .reuse
        }
        return .upgrade
    }

    static func installApplication(source: URL, applications: URL, operations: InstallOperations,
                                   progress: (String) -> Void = { _ in }) throws -> URL {
        progress("正在校验组件…")
        let sourceInfo = try operations.validate(source, false)
        try ensureApplicationsDirectory(applications)
        let destination = applications.appendingPathComponent(applicationName, isDirectory: true)
        let existing = try pathExists(destination) ? try operations.validate(destination, true) : nil
        if let existing, try action(source: sourceInfo, existing: existing) == .reuse { return destination }

        // The private container belongs to this transaction. After a successful
        // swap it holds the only old copy until backup rename succeeds.
        let stagingDirectory = applications.appendingPathComponent(".WiredKVM-Staging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var mayRemoveStaging = true
        defer { if mayRemoveStaging { try? FileManager.default.removeItem(at: stagingDirectory) } }
        let staging = stagingDirectory.appendingPathComponent("WiredKVM Companion.app", isDirectory: true)
        progress("正在复制到本机…")
        try FileManager.default.copyItem(at: source, to: staging)
        progress("正在校验本机副本…")
        guard try operations.validate(staging, true) == sourceInfo else {
            throw WKClipboardError.invalid("应用复制校验失败，本次未覆盖旧应用。")
        }
        if let existing {
            progress("正在退出旧版组件…")
            try operations.terminate(destination)
            // Termination pumps the main run loop. Recheck the paths and both
            // bundles afterwards, before committing any filesystem mutation.
            try ensureApplicationsDirectory(applications)
            guard try operations.validate(destination, true) == existing,
                  try operations.validate(staging, true) == sourceInfo else {
                throw WKClipboardError.invalid("等待退出期间应用内容发生变化，本次未覆盖旧应用。")
            }
            let backup = applications.appendingPathComponent(".WiredKVM-Backup-\(existing.build)-" + UUID().uuidString + ".app", isDirectory: true)
            try operations.rename(staging, destination, UInt32(RENAME_SWAP))
            mayRemoveStaging = false
            do {
                try operations.rename(staging, backup, UInt32(RENAME_EXCL))
                mayRemoveStaging = true
            } catch {
                // Never delete or overwrite this old bundle, including on an
                // error after the new application has already been committed.
                throw WKClipboardError.invalid("新版已保存，旧版备份移动失败。旧版完整保留在 \(staging.path)；请保留该目录。")
            }
        } else {
            try ensureApplicationsDirectory(applications)
            guard try operations.validate(staging, true) == sourceInfo else {
                throw WKClipboardError.invalid("应用复制校验失败，尚未安装。")
            }
            try operations.rename(staging, destination, UInt32(RENAME_EXCL))
        }
        progress("准备启动组件…")
        return destination
    }

    private static func pathExists(_ url: URL) throws -> Bool {
        var info = stat()
        if url.path.withCString({ lstat($0, &info) }) == 0 { return true }
        guard errno == ENOENT else { throw WKClipboardError.invalid("无法检查本地应用路径，本次未覆盖任何文件。") }
        return false
    }

    private static func atomicRename(_ from: URL, _ to: URL, _ flags: UInt32) throws {
        let result = from.path.withCString { old in to.path.withCString { new in renamex_np(old, new, flags) } }
        guard result == 0 else { throw WKClipboardError.invalid("无法原子保存应用；现有副本已保留。") }
    }

    static func matchesInstalledApplication(bundleIdentifier: String?, bundleURL: URL?, processID: pid_t,
                                            destination: URL, installerPID: pid_t) -> Bool {
        bundleIdentifier == identity && processID > 0 && processID != installerPID &&
            bundleURL?.standardizedFileURL == destination.standardizedFileURL
    }

    private static func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    private static func terminateInstalledApplication(_ destination: URL) throws {
        func matching() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: identity).filter {
                !$0.isTerminated && matchesInstalledApplication(bundleIdentifier: $0.bundleIdentifier,
                    bundleURL: $0.bundleURL, processID: $0.processIdentifier, destination: destination, installerPID: getpid())
            }
        }
        let applications = onMain { matching() }
        for application in applications {
            guard onMain({ application.terminate() }) else {
                throw WKClipboardError.invalid("旧版未接受退出请求。请退出本地 WiredKVM Companion 后重试；本次未覆盖它。")
            }
        }
        let deadline = Date(timeIntervalSinceNow: 5)
        while onMain({ applications.contains(where: { !$0.isTerminated }) }) && Date() < deadline {
            if Thread.isMainThread { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
            else { Thread.sleep(forTimeInterval: 0.02) }
        }
        guard onMain({ applications.allSatisfy({ $0.isTerminated }) && matching().isEmpty }) else {
            throw WKClipboardError.invalid("等待旧版退出超时或应用重新启动，本次未覆盖它，也未强制结束进程。")
        }
    }

    private static func ensureApplicationsDirectory(_ url: URL) throws {
        if try !pathExists(url) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        }
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0,
              info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_mode & 0o022 == 0 else {
            throw WKClipboardError.invalid("~/Applications 不是当前用户拥有的安全目录。请检查其目录权限后重试。")
        }
    }

    private static func validate(_ url: URL, _ requireOwnership: Bool) throws -> ApplicationInfo {
        var root = stat()
        guard url.path.withCString({ lstat($0, &root) }) == 0, (root.st_mode & S_IFMT) == S_IFDIR,
              root.st_mode & 0o022 == 0, (!requireOwnership || root.st_uid == getuid()),
              let bundle = Bundle(url: url), bundle.bundleIdentifier == identity,
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == executableName,
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            throw WKClipboardError.invalid("应用身份不匹配，或同名位置不是 WiredKVM Companion；本次未覆盖任何文件。")
        }
        let executable = url.appendingPathComponent("Contents/MacOS/" + executableName)
        var file = stat()
        guard executable.path.withCString({ lstat($0, &file) }) == 0,
              (file.st_mode & S_IFMT) == S_IFREG, file.st_mode & 0o111 != 0,
              file.st_size > 0, file.st_size <= 100 * 1024 * 1024 else {
            throw WKClipboardError.invalid("应用可执行文件不完整，尚未开始剪贴板同步。")
        }
        try verifySignature(url, identifier: identity)
        return ApplicationInfo(build: try buildNumber(version), digest: try bundleDigest(url, requireOwnership: requireOwnership))
    }

    static func verifySignature(_ url: URL, identifier: String) throws {
        let verification = Process()
        verification.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        // codesign treats -R's argument as a filename unless it starts with '='.
        verification.arguments = ["--verify", "--deep", "--strict", "-R", "=identifier \"\(identifier)\"", url.path]
        verification.standardOutput = FileHandle.nullDevice
        verification.standardError = FileHandle.nullDevice
        try verification.run()
        let deadline = Date().addingTimeInterval(30)
        while verification.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if verification.isRunning {
            verification.terminate()
            throw WKClipboardError.invalid("签名校验超时，已停止本次安装；旧组件未被替换。")
        }
        verification.waitUntilExit()
        guard verification.terminationStatus == 0 else {
            throw WKClipboardError.invalid("应用签名校验失败。请重新获取完整的 WiredKVM Companion；本次未启动或覆盖它。")
        }
    }

    // Compare the complete signed bundle, not just its executable: a changed
    // Info.plist/resource under an unchanged build must also be rejected.
    private static func bundleDigest(_ root: URL, requireOwnership: Bool) throws -> Data {
        var hash = SHA256(), entries = 0, totalBytes: Int64 = 0
        func visit(_ directory: URL, relative: String) throws {
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                entries += 1
                var info = stat()
                guard entries <= 4096, child.path.withCString({ lstat($0, &info) }) == 0,
                      info.st_mode & 0o022 == 0, (!requireOwnership || info.st_uid == getuid()) else {
                    throw WKClipboardError.invalid("应用目录内容或所有权不安全，本次未覆盖旧应用。")
                }
                let name = relative + "/" + child.lastPathComponent
                let kind = info.st_mode & S_IFMT
                guard kind == S_IFDIR || kind == S_IFREG else {
                    throw WKClipboardError.invalid("应用包含链接或异常文件，本次未覆盖旧应用。")
                }
                hash.update(data: Data("\(name.utf8.count):\(name):\(info.st_mode & 0o777):\(kind):".utf8))
                if kind == S_IFDIR { try visit(child, relative: name) }
                else {
                    totalBytes += info.st_size
                    guard info.st_size >= 0, info.st_size <= 100 * 1024 * 1024, totalBytes <= 256 * 1024 * 1024 else {
                        throw WKClipboardError.invalid("应用文件大小异常，本次未覆盖旧应用。")
                    }
                    hash.update(data: Data(SHA256.hash(data: try Data(contentsOf: child))))
                }
            }
        }
        try visit(root, relative: "")
        return Data(hash.finalize())
    }

    @MainActor static func openLocalApplication(_ url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = kind == .host ? ["--first-run"] : ["--role", "target", "--first-run"]
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        let expectedBundle = url.standardizedFileURL.resolvingSymlinksInPath()
        let installerPID = getpid()
        var finished = false
        func finish(_ result: Result<Void, Error>) {
            guard !finished else { return }
            finished = true; completion(result)
        }
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            DispatchQueue.main.async {
                if let error { finish(.failure(error)); return }
                guard let application, application.processIdentifier > 0,
                      application.processIdentifier != installerPID,
                      let launchedBundle = application.bundleURL,
                      launchedBundle.standardizedFileURL.resolvingSymlinksInPath() == expectedBundle else {
                    finish(.failure(WKClipboardError.invalid("macOS 没有启动已安装的本地副本。请从 ~/Applications 打开 WiredKVM Companion。")))
                    return
                }
                finish(.success(()))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            finish(.failure(WKClipboardError.invalid("等待 macOS 启动组件超时。应用已保存在 ~/Applications，本次未安装后台服务。")))
        }
    }
}

// Shared by the real installer and an isolated slow-work Launch Services probe.
// Only the main thread touches AppKit; validation/copy never block this loop.
@MainActor final class WKInstallApplication: NSObject, NSApplicationDelegate {
    typealias Work = (@escaping (String) -> Void) throws -> URL
    typealias Open = (URL, @escaping (Result<Void, Error>) -> Void) -> Void
    private let work: Work
    private let open: Open
    private let completed: ((Result<Void, Error>) -> Void)?
    private let title: String
    private var window: NSWindow?
    private let label = NSTextField(wrappingLabelWithString: "正在准备安装…")
    private let progress = NSProgressIndicator()
    private let exitButton = NSButton(title: "退出", target: nil, action: nil)
    init(title: String = "安装 WiredKVM Companion", work: @escaping Work, open: @escaping Open, completed: ((Result<Void, Error>) -> Void)? = nil) {
        self.title = title; self.work = work; self.open = open; self.completed = completed
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 190),
                              styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        label.frame = NSRect(x: 26, y: 68, width: 428, height: 95)
        progress.style = .spinning; progress.frame = NSRect(x: 26, y: 25, width: 24, height: 24)
        progress.startAnimation(nil)
        exitButton.frame = NSRect(x: 360, y: 18, width: 94, height: 32)
        exitButton.isEnabled = false; exitButton.target = self; exitButton.action = #selector(exitInstaller)
        window.contentView?.addSubview(label); window.contentView?.addSubview(progress)
        window.contentView?.addSubview(exitButton)
        self.window = window; window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Defer past didFinishLaunching so Launch Services receives its reply.
        DispatchQueue.main.async { [self] in
            let install = work
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let result = Result { try install { text in
                    DispatchQueue.main.async { [self] in label.stringValue = text }
                } }
                DispatchQueue.main.async { [self] in
                    switch result {
                    case .success(let url):
                        label.stringValue = "正在启动本机组件…"
                        open(url) { [self] outcome in finish(outcome) }
                    case .failure(let error): finish(.failure(error))
                    }
                }
            }
        }
    }
    private func finish(_ result: Result<Void, Error>) {
        progress.stopAnimation(nil); exitButton.isEnabled = true
        if let completed { completed(result); return }
        switch result {
        case .success:
            wkLog("WKCLIP_STATUS INSTALLED user-applications")
            NSApplication.shared.terminate(nil)
        case .failure(let error):
            window?.title = "安装未完成"
            label.stringValue = "\(error)"
            wkLog("WKCLIP_STATUS ERROR local-install-failed")
        }
    }
    @objc private func exitInstaller() { NSApplication.shared.terminate(nil) }
}
