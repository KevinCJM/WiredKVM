// Isolated upgrade transactions plus real codesign validation of temporary
// fixtures. No fixture is launched; no user apps, permissions or services change.
// swiftc -O -framework AppKit host/clipboard/WKCompanionInstall.swift \
// tests/companion_install_selftest.swift -o /tmp/wk-install-selftest
import AppKit
import CryptoKit
import Darwin

enum WKClipboardError: Error { case invalid(String) }
enum WKMetadata {
    static func line(role: String, event: String, fields: [String: String]) -> String? { nil }
    static func errorCode(_ error: Error) -> String { "fixture" }
}
func wkLog(_ value: String) {}

private struct Failure: Error, CustomStringConvertible { let description: String }
private func expect(_ value: @autoclosure () throws -> Bool, _ reason: String) throws {
    if try !value() { throw Failure(description: reason) }
}
private func rejects(_ reason: String, _ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw Failure(description: "accepted: " + reason)
}

private final class Fixture {
    let root: URL
    let source: URL
    let applications: URL
    var destination: URL { applications.appendingPathComponent("WiredKVM Companion.app") }
    var terminations = 0
    var renames: [UInt32] = []
    init(sourceBuild: String = "8", sourceBody: String = "new", existingBuild: String? = "7", existingBody: String = "old") throws {
        root = URL(fileURLWithPath: "/tmp/wk-install-" + String(UUID().uuidString.prefix(8)))
        source = root.appendingPathComponent("Setup.app")
        applications = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try makeApp(source, build: sourceBuild, body: sourceBody)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        if let existingBuild { try makeApp(destination, build: existingBuild, body: existingBody) }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    private func makeApp(_ path: URL, build: String, body: String) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try Data(build.utf8).write(to: path.appendingPathComponent("build"))
        try Data(body.utf8).write(to: path.appendingPathComponent("payload"))
        try Data("com.wiredkvm.companion:signed-fixture".utf8).write(to: path.appendingPathComponent("identity"))
    }
    func validate(_ path: URL, _ owned: Bool) throws -> WKCompanionInstall.ApplicationInfo {
        var info = stat()
        guard path.path.withCString({ lstat($0, &info) }) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o022 == 0, !owned || info.st_uid == getuid(),
              try String(contentsOf: path.appendingPathComponent("identity"), encoding: .utf8) == "com.wiredkvm.companion:signed-fixture" else {
            throw Failure(description: "fixture signature/identity/ownership")
        }
        let buildText = try String(contentsOf: path.appendingPathComponent("build"), encoding: .utf8)
        let body = try Data(contentsOf: path.appendingPathComponent("payload"))
        return .init(build: try WKCompanionInstall.buildNumber(buildText), digest: Data(SHA256.hash(data: Data(buildText.utf8) + body)))
    }
    func rename(_ from: URL, _ to: URL, _ flags: UInt32) throws {
        renames.append(flags)
        let result = from.path.withCString { a in to.path.withCString { b in renamex_np(a, b, flags) } }
        if result != 0 { throw Failure(description: "fixture rename errno=\(errno)") }
    }
    func operations() -> WKCompanionInstall.InstallOperations {
        .init(validate: { try self.validate($0, $1) }, terminate: { _ in self.terminations += 1 },
              rename: { try self.rename($0, $1, $2) })
    }
    func install(_ operations: WKCompanionInstall.InstallOperations? = nil) throws -> URL {
        try WKCompanionInstall.installApplication(source: source, applications: applications, operations: operations ?? self.operations())
    }
    func entries(_ prefix: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(prefix) }
    }
    func body(_ path: URL) throws -> String { try String(contentsOf: path.appendingPathComponent("payload"), encoding: .utf8) }
    func checkBody(_ path: URL, _ expected: String, _ reason: String) throws { try expect(try body(path) == expected, reason) }
}

@main private enum InstallSelfTest {
    static func main() {
        do {
            try decisions()
            try installReuseUpgrade()
            try validationAndTerminationFailures()
            try atomicFailures()
            try unsafeDirectories()
            try exactProcessMatch()
            try realSignatureValidation()
            try hostRoleInstall()
            print("WK_COMPANION_INSTALL_TEST_PASS")
        } catch { fputs("WK_COMPANION_INSTALL_TEST_FAIL \(error)\n", stderr); exit(1) }
    }

    static func decisions() throws {
        for invalid in ["", "0", "-1", "+8", "8.1", " 8", "8 ", "18446744073709551616", "８"] {
            try rejects("invalid build \(invalid)") { _ = try WKCompanionInstall.buildNumber(invalid) }
        }
        try expect(try WKCompanionInstall.buildNumber("8") == 8, "valid build")
        let old = WKCompanionInstall.ApplicationInfo(build: 7, digest: Data([1]))
        try expect(try WKCompanionInstall.action(source: old, existing: old) == .reuse, "same build reuse")
        try expect(try WKCompanionInstall.action(source: .init(build: 8, digest: Data([2])), existing: old) == .upgrade, "new build upgrade")
        try rejects("same build different content") { _ = try WKCompanionInstall.action(source: .init(build: 7, digest: Data([2])), existing: old) }
        try rejects("downgrade") { _ = try WKCompanionInstall.action(source: .init(build: 6, digest: Data([2])), existing: old) }
        print("WK_INSTALL_TEST build-order-content-identity PASS")
    }

    static func realSignatureValidation() throws {
        let root = URL(fileURLWithPath: "/tmp/wk-signature-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        for identity in ["com.wiredkvm.setup", "com.wiredkvm.companion", "com.wiredkvm.menu", "com.wiredkvm.onboarding"] {
            let app = root.appendingPathComponent(identity + ".app")
            let contents = app.appendingPathComponent("Contents")
            let executableDirectory = contents.appendingPathComponent("MacOS")
            let resources = contents.appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
            // Copy a system executable only as inert Mach-O signing input.
            let executableName = identity == "com.wiredkvm.menu" ? "WiredKVM" : "WiredKVMCompanion"
            let executable = executableDirectory.appendingPathComponent(executableName)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)
            let plist = ["CFBundleIdentifier": identity, "CFBundleExecutable": executableName,
                         "CFBundlePackageType": "APPL", "CFBundleVersion": "9"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            let resource = resources.appendingPathComponent("payload.txt")
            try Data("signed content".utf8).write(to: resource)
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", "--identifier", identity, app.path]
            sign.standardOutput = FileHandle.nullDevice; sign.standardError = FileHandle.nullDevice
            try sign.run(); sign.waitUntilExit()
            try expect(sign.terminationStatus == 0, "fixture signing")
            try WKCompanionInstall.verifySignature(app, identifier: identity)
            try rejects("signed bundle with wrong required identity") {
                try WKCompanionInstall.verifySignature(app, identifier: "com.wiredkvm.wrong")
            }
            if identity == "com.wiredkvm.companion" {
                let validated = try WKCompanionInstall.InstallOperations.live.validate(app, true)
                try expect(validated.build == 9, "live application validation")
            }
            if identity == "com.wiredkvm.menu" {
                WKCompanionInstall.kind = .host
                let validated = try WKCompanionInstall.InstallOperations.live.validate(app, true)
                WKCompanionInstall.kind = .companion
                try expect(validated.build == 9, "live host application validation")
            }
            try Data("tampered content".utf8).write(to: resource)
            try rejects("modified signed resource") { try WKCompanionInstall.verifySignature(app, identifier: identity) }
        }
        print("WK_INSTALL_TEST real-codesign-setup-companion-identity-tamper PASS")
    }

    static func hostRoleInstall() throws {
        WKCompanionInstall.kind = .host
        defer { WKCompanionInstall.kind = .companion }
        let f = try Fixture(existingBuild: nil)
        let destination = try f.install()
        try expect(destination.lastPathComponent == "WiredKVM.app", "host role destination")
        try f.checkBody(destination, "new", "host body")
        let same = try f.install()
        try expect(same == destination && f.renames.count == 1 && f.terminations == 0, "host reuse")
        try expect(!FileManager.default.fileExists(atPath: f.destination.path), "host install must not overwrite companion")
        print("WK_INSTALL_TEST host-role-local-install-reuse-independent-destination PASS")
    }

    static func installReuseUpgrade() throws {
        let fresh = try Fixture(existingBuild: nil)
        _ = try fresh.install()
        try fresh.checkBody(fresh.destination, "new", "fresh install")
        try expect(fresh.terminations == 0 && fresh.renames == [UInt32(RENAME_EXCL)], "fresh operation order")

        let same = try Fixture(sourceBuild: "7", sourceBody: "old")
        _ = try same.install()
        try expect(same.terminations == 0 && same.renames.isEmpty, "identical install mutated app")
        let upgrade = try Fixture()
        _ = try upgrade.install()
        try upgrade.checkBody(upgrade.destination, "new", "upgrade destination")
        let backups = try upgrade.entries(".WiredKVM-Backup-7-")
        try expect(backups.count == 1, "unique old backup")
        try upgrade.checkBody(backups[0], "old", "old app backup changed")
        try expect(upgrade.terminations == 1 && upgrade.renames == [UInt32(RENAME_SWAP), UInt32(RENAME_EXCL)], "upgrade atomic sequence")
        try expect(try upgrade.entries(".WiredKVM-Staging-").isEmpty, "successful stage cleanup")

        for pair in [("7", "different"), ("6", "older")] {
            let rejected = try Fixture(sourceBuild: pair.0, sourceBody: pair.1)
            try rejects("content collision/downgrade") { _ = try rejected.install() }
            try rejected.checkBody(rejected.destination, "old", "rejected upgrade changed app")
            try expect(rejected.terminations == 0 && rejected.renames.isEmpty, "rejected upgrade stopped app")
        }
        print("WK_INSTALL_TEST fresh-reuse-upgrade-backup PASS")
    }

    static func validationAndTerminationFailures() throws {
        let badSource = try Fixture()
        try Data("wrong-identity".utf8).write(to: badSource.source.appendingPathComponent("identity"))
        try rejects("source identity") { _ = try badSource.install() }
        try badSource.checkBody(badSource.destination, "old", "invalid source changed old app")
        let badDestination = try Fixture()
        try Data("wrong-identity".utf8).write(to: badDestination.destination.appendingPathComponent("identity"))
        try rejects("destination identity") { _ = try badDestination.install() }
        try badDestination.checkBody(badDestination.destination, "old", "invalid destination overwritten")

        let corrupt = try Fixture()
        var corruptOps = corrupt.operations()
        corruptOps.validate = { path, owned in
            if path.path.contains(".WiredKVM-Staging-") { throw Failure(description: "incomplete staged copy") }
            return try corrupt.validate(path, owned)
        }
        try rejects("staging validation") { _ = try corrupt.install(corruptOps) }
        try expect(corrupt.terminations == 0 && corrupt.renames.isEmpty, "stopped app before staging validation")
        try corrupt.checkBody(corrupt.destination, "old", "stage failure removed old app")

        let refusal = try Fixture()
        var refusalOps = refusal.operations()
        refusalOps.terminate = { _ in throw Failure(description: "graceful termination refused/timed out") }
        try rejects("termination refusal") { _ = try refusal.install(refusalOps) }
        try refusal.checkBody(refusal.destination, "old", "termination failure changed app")
        try expect(refusal.renames.isEmpty, "termination failure committed rename")

        let race = try Fixture()
        var raceOps = race.operations()
        raceOps.terminate = { _ in try Data("changed-during-wait".utf8).write(to: race.destination.appendingPathComponent("payload")) }
        try rejects("destination changed while waiting") { _ = try race.install(raceOps) }
        try race.checkBody(race.destination, "changed-during-wait", "changed destination overwritten")
        try expect(race.renames.isEmpty, "failed revalidation committed rename")
        print("WK_INSTALL_TEST validation-termination-revalidation-failures PASS")
    }

    static func atomicFailures() throws {
        let beforeSwap = try Fixture()
        var swapOps = beforeSwap.operations()
        swapOps.rename = { _, _, _ in throw Failure(description: "swap rejected") }
        try rejects("atomic swap failure") { _ = try beforeSwap.install(swapOps) }
        try beforeSwap.checkBody(beforeSwap.destination, "old", "swap failure lost old app")
        try expect(try beforeSwap.entries(".WiredKVM-Staging-").isEmpty, "uncommitted stage leaked")

        let afterSwap = try Fixture()
        var backupOps = afterSwap.operations()
        backupOps.rename = { from, to, flags in
            if flags == UInt32(RENAME_EXCL) { throw Failure(description: "backup move rejected") }
            try afterSwap.rename(from, to, flags)
        }
        try rejects("backup move failure") { _ = try afterSwap.install(backupOps) }
        try afterSwap.checkBody(afterSwap.destination, "new", "atomic destination incomplete")
        let retained = try afterSwap.entries(".WiredKVM-Staging-")
        try expect(retained.count == 1, "only old copy deleted after backup failure")
        try afterSwap.checkBody(retained[0].appendingPathComponent("WiredKVM Companion.app"), "old", "retained old backup changed")

        let appeared = try Fixture(existingBuild: nil)
        var raceOps = appeared.operations()
        raceOps.rename = { from, to, flags in
            try FileManager.default.copyItem(at: appeared.source, to: to)
            try Data("arrived-later".utf8).write(to: to.appendingPathComponent("payload"))
            try appeared.rename(from, to, flags)
        }
        try rejects("destination appeared during fresh install") { _ = try appeared.install(raceOps) }
        try appeared.checkBody(appeared.destination, "arrived-later", "fresh install overwrote racing destination")
        print("WK_INSTALL_TEST atomic-swap-backup-failure-preservation PASS")
    }

    static func unsafeDirectories() throws {
        let writable = try Fixture()
        try expect(chmod(writable.applications.path, 0o777) == 0, "fixture chmod")
        try rejects("writable applications") { _ = try writable.install() }
        try writable.checkBody(writable.destination, "old", "unsafe directory changed old app")
        let linked = try Fixture(existingBuild: nil)
        try FileManager.default.removeItem(at: linked.applications)
        try FileManager.default.createSymbolicLink(at: linked.applications, withDestinationURL: linked.source)
        try rejects("symlink applications") { _ = try linked.install() }
        let appLink = try Fixture(existingBuild: nil)
        try FileManager.default.createSymbolicLink(at: appLink.destination, withDestinationURL: appLink.source)
        try rejects("symlink destination") { _ = try appLink.install() }
        try appLink.checkBody(appLink.source, "new", "symlink target changed")
        print("WK_INSTALL_TEST unsafe-directory-symlink-rejection PASS")
    }

    static func exactProcessMatch() throws {
        let target = URL(fileURLWithPath: "/Users/example/Applications/WiredKVM Companion.app")
        func matches(_ identity: String? = "com.wiredkvm.companion", path: URL?, _ pid: pid_t = 42) -> Bool {
            WKCompanionInstall.matchesInstalledApplication(bundleIdentifier: identity, bundleURL: path,
                processID: pid, destination: target, installerPID: 99)
        }
        try expect(matches(path: target), "exact installed process skipped")
        for path in ["/Volumes/WiredKVM Setup/WiredKVM Companion.app", "/Applications/WiredKVM Companion.app",
                     "/Users/example/Applications/WiredKVM Companion.app.backup", "/tmp/alias.app"] {
            try expect(!matches(path: URL(fileURLWithPath: path)), "unrelated bundle path matched")
        }
        try expect(!matches("other.bundle", path: target) && !matches(nil, path: target) && !matches(path: nil), "bundle identity check")
        try expect(!matches("com.wiredkvm.companion", path: target, 99) && !matches("com.wiredkvm.companion", path: target, 0), "installer/invalid PID matched")
        print("WK_INSTALL_TEST exact-process-selection PASS")
    }
}
