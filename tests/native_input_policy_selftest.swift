import Foundation
import Darwin

@main enum NativeInputPolicySelfTest {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wk-input-policy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mode.json")
        let policy = WKNativeInputPolicy(path: file.path)
        precondition(!policy.refresh(at: 1) && policy.mode == .legacy)
        func write(_ text: String, permissions: mode_t = 0o600) throws {
            try Data(text.utf8).write(to: file); precondition(chmod(file.path, permissions) == 0)
        }
        try write("{\"mode\":\"pixel\"}")
        precondition(policy.refresh(at: 2) && policy.pixelEnabled && !policy.gesturesEnabled)
        try write("{\"mode\":\"gestures\"}")
        precondition(!policy.refresh(at: 2.1) && policy.mode == .pixel)
        precondition(policy.refresh(at: 3) && policy.gesturesEnabled)
        try write("{\"mode\":\"unknown\"}")
        precondition(policy.refresh(at: 4) && policy.mode == .legacy)
        try write("{\"mode\":\"gestures\"}", permissions: 0o644)
        precondition(!policy.refresh(at: 5) && policy.mode == .legacy)
        try write(String(repeating: "x", count: 513))
        precondition(!policy.refresh(at: 6) && policy.mode == .legacy)
        try FileManager.default.removeItem(at: file)
        let target = directory.appendingPathComponent("target.json")
        try Data("{\"mode\":\"gestures\"}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: target.path)
        precondition(!policy.refresh(at: 7) && policy.mode == .legacy)
        try FileManager.default.removeItem(at: file)
        precondition(mkfifo(file.path, 0o600) == 0)
        precondition(!policy.refresh(at: 8) && policy.mode == .legacy)
        print("NATIVE_INPUT_POLICY_SELFTEST_PASS default_legacy=true independent_modes=true live_refresh=true malformed_permissions_symlink_FIFO_safe=true")
    }
}
