import AppKit
import Foundation

@main @MainActor final class ProbeApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 340),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    private let text = NSTextView(frame: NSRect(x: 16, y: 16, width: 568, height: 308))
    private let scroll = NSScrollView(frame: NSRect(x: 16, y: 16, width: 568, height: 308))
    private var child: Process?, buffer = ""
    private var quitting = false
    private var quitReplySent = false
    private var quitTimer: Timer?
    private var outputHandle: FileHandle?
    #if WK_PROBE_UI_TEST
    private static let testMode = CommandLine.arguments.contains("--self-test-lifecycle") || CommandLine.arguments.contains("--self-test-close")
    #else
    private static let testMode = false
    #endif
    static func main() {
        #if WK_PROBE_UI_TEST
        print("PROBE_UI_STAGE entry"); fflush(stdout)
        #endif
        let app = NSApplication.shared, delegate = ProbeApp()
        #if WK_PROBE_UI_TEST
        print("PROBE_UI_STAGE initialized"); fflush(stdout)
        #endif
        app.delegate = delegate; app.setActivationPolicy(testMode ? .accessory : .regular)
        #if WK_PROBE_UI_TEST
        if testMode { app.finishLaunching() }
        #endif
        app.run()
        withExtendedLifetime(delegate) {}
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if WK_PROBE_UI_TEST
        print("PROBE_UI_STAGE launched"); fflush(stdout)
        #endif
        window.title = "WiredKVM USB 测速"; window.isReleasedWhenClosed = false; window.delegate = self
        text.isEditable = false; text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.string = "正在测试 USB2 和双向桥接（直接 Bulk 对照）。\n程序从线内临时运行，不安装。\n完成前请保留本盘；成功后会自动退出。\n关闭窗口或点“退出测速”会结束本程序和测试进程。\n\n"
        scroll.frame = NSRect(x: 16, y: 54, width: 568, height: 270)
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        text.frame = scroll.contentView.bounds; text.isSelectable = true
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        window.contentView?.addSubview(scroll)
        let quit = NSButton(title: "退出测速", target: self, action: #selector(quitProbe))
        quit.frame = NSRect(x: 472, y: 12, width: 112, height: 30); quit.bezelStyle = .rounded
        window.contentView?.addSubview(quit); window.center()
        if !Self.testMode { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true) }
        let task = Process(), output = Pipe()
        var executable = Bundle.main.url(forResource: "wiredkvm-usb-throughput-probe", withExtension: nil)
        #if WK_PROBE_UI_TEST
        if Self.testMode {
            executable = URL(fileURLWithPath: CommandLine.arguments.contains("--self-test-close") ? "/bin/sleep" : "/usr/bin/printf")
        }
        #endif
        guard let executable else { append("找不到完整测速工具，请退出后重新装载程序盘。"); return }
        task.executableURL = executable
        task.arguments = ["--role", "target", "--raw-all"]; task.standardInput = FileHandle.nullDevice
        #if WK_PROBE_UI_TEST
        if Self.testMode {
            task.executableURL = URL(fileURLWithPath: CommandLine.arguments.contains("--self-test-close") ? "/bin/sleep" : "/usr/bin/printf")
            task.arguments = CommandLine.arguments.contains("--self-test-close") ? ["2"] : ["{\"kind\":\"memory-usb\",\"mode\":2,\"bytes\":512,\"measurementCompleted\":true,\"bodyRateMeasured\":false,\"MBps\":0}\\n"]
        }
        #endif
        task.standardOutput = output; task.standardError = output; child = task; outputHandle = output.fileHandleForReading
        output.fileHandleForReading.readabilityHandler = { @Sendable [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil; return }
            let value = String(decoding: bytes, as: UTF8.self)
            DispatchQueue.main.async { self?.consume(value) }
        }
        task.terminationHandler = { @Sendable [weak self] task in DispatchQueue.main.async {
            #if WK_PROBE_UI_TEST
            print("PROBE_UI_STAGE child_finished"); fflush(stdout)
            #endif
            guard let self else { return }
            if self.quitting { self.finishQuitIfExited(); return }
            if task.terminationReason == .uncaughtSignal && task.terminationStatus == 14 {
                self.append("\n测速超过 240 秒，已停止；本次未通过。请保留窗口中的信息。")
            } else {
                self.append(task.terminationStatus == 0 ? "\n测速完成，3 秒后自动退出。" : "\n测试未完成，请保留错误文字后点“退出测速”。")
            }
            if task.terminationStatus == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + (Self.testMode ? 0.1 : 3)) { NSApplication.shared.terminate(nil) }
            }
        } }
        do {
            try task.run()
            #if WK_PROBE_UI_TEST
            print("PROBE_UI_STAGE child_started"); fflush(stdout)
            #endif
            #if WK_PROBE_UI_TEST
            if CommandLine.arguments.contains("--self-test-close") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.window.close() }
            }
            #endif
        } catch { append("无法启动测速程序。") }
    }
    private func append(_ value: String) {
        guard text.string.utf8.count < 16384 else { return }
        let follow = scroll.contentView.bounds.maxY >= text.bounds.maxY - 2
        text.string += value
        if follow { text.scrollToEndOfDocument(nil) }
    }
    private func consume(_ value: String) {
        buffer += value
        while let end = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<end]); buffer.removeSubrange(...end)
            guard let bytes = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let mode = object["mode"] as? Int else {
                if line.hasPrefix("USB_PROBE_ERROR ") { append("测试失败：\(line.dropFirst(16))\n") }
                continue
            }
            let title = [1: "mini → 硬件", 2: "硬件 → mini", 4: "mini → Book 桥接", 5: "Book → mini 桥接"][mode] ?? "USB"
            let size = object["bytes"] as? Int ?? 0
            let packet = size > 0 && size < 1048576 ? "（\(size) 字节边界检查）" : ""
            if object["measurementCompleted"] as? Bool == true,
               object["bodyRateMeasured"] as? Bool == false {
                append("\(title)\(packet)：校验通过；数据太少，不计算持续速度\n")
            } else if let rate = object["MBps"] as? Double {
                append(String(format: "%@%@：%.2f MB/s\n", title, packet, rate))
                if let wait = object["firstByteWaitSeconds"] as? Double, wait >= 0.1 {
                    append(String(format: "  首字节等待 %.2f 秒，单独记录\n", wait))
                }
            } else if let phase = object["phase"] as? String {
                let step = ["admission": "等待硬件握手", "rendezvous": "等待另一端开始（最多 70 秒）", "body": "正在传输", "completion": "等待完成确认"][phase] ?? phase
                append("\(title)\(packet)：\(step)\n")
            } else if object["kind"] as? String == "progress", let count = object["bytes"] as? Int {
                append("\(title)：已传输 \(count / 1048576) MiB\n")
            }
        }
        if buffer.utf8.count > 16384 { buffer = "" }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    @objc private func quitProbe() { NSApplication.shared.terminate(nil) }
    func windowWillClose(_ notification: Notification) { NSApplication.shared.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let child, child.isRunning {
            if !quitting {
                quitting = true; child.terminate()
                // AppKit's pending-termination loop must not depend only on
                // an ordinary dispatch-main callback from Process.
                let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(pollQuit(_:)), userInfo: nil, repeats: true)
                quitTimer = timer; RunLoop.main.add(timer, forMode: .common)
            }
            return .terminateLater
        }
        outputHandle?.readabilityHandler = nil
        return .terminateNow
    }
    @objc private func pollQuit(_ timer: Timer) { finishQuitIfExited() }
    private func finishQuitIfExited() {
        guard quitting, !quitReplySent, child?.isRunning != true else { return }
        quitReplySent = true; quitTimer?.invalidate(); quitTimer = nil
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        quitTimer?.invalidate(); quitTimer = nil
        outputHandle?.readabilityHandler = nil
        #if WK_PROBE_UI_TEST
        if Self.testMode {
            guard let child, !child.isRunning else { exit(2) }
            print("PROBE_UI_LIFECYCLE_PASS child_exited=true application_exited=true")
            fflush(stdout)
        }
        #endif
    }
}
