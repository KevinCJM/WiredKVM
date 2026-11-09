// Launch this isolated .app through Launch Services. It uses the production
// installer lifecycle with deliberately slow synthetic work, no real install.
import AppKit
import Darwin

enum WKClipboardError: Error { case invalid(String) }
func wkLog(_ value: String) {}

@main struct InstallerLifecycleProbe {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let resultURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let began = Date()
        var beats = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in beats += 1 }
        let runner = WKInstallApplication(work: { progress in
            precondition(!Thread.isMainThread)
            progress("安装流程隔离自测：模拟慢速校验，不安装组件。")
            Thread.sleep(forTimeInterval: 2)
            return URL(fileURLWithPath: "/private/tmp/wiredkvm-no-real-install.app")
        }, open: { _, complete in
            precondition(Thread.isMainThread)
            complete(.success(()))
        }, completed: { result in
            timer.invalidate()
            guard case .success = result, beats >= 20 else { exit(3) }
            let report: [String: Any] = ["result": "PASS", "main_loop_heartbeats": beats,
                                       "duration": Date().timeIntervalSince(began),
                                       "real_install": false, "real_clipboard": false, "real_usb": false]
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: resultURL, options: .atomic)
            } catch { exit(4) }
            exit(0)
        })
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = runner
        withExtendedLifetime(runner) { app.run() }
    }
}
