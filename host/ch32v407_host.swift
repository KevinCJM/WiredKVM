import AppKit
import Foundation
import Darwin

// Development launcher. Uses the same capture, absolute pointer, edge return,
// token validation and clipboard coordinator as the installed ESP32 product.
// It is built separately and never installs or starts itself during a build.
@MainActor
final class CH32Host {
    let clipboard = WKClipboardProcess()
    let pasteHUD = WKPasteProgressHUD()
    let native = Process(), input = Pipe(), output = Pipe()
    var buffer = "", stopping = false
    var signals: [DispatchSourceSignal] = []
    func start(control: String, files: String, position: String) throws {
        guard WKCH32Device.matches(path: control, role: "host", files: false),
              WKCH32Device.matches(path: files, role: "host") else { throw WKStreamError.invalid }
        let runtime = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let socket = try clipboard.prepare()
        native.executableURL = runtime.appendingPathComponent("wiredkvm-native")
        native.arguments = ["--transport", "cdc:" + control, "--source", "macos", "--target", "desktop",
            "--absolute-mouse", "--position", position, "--capture", runtime.appendingPathComponent("macos-capture").path,
            "--clipboard-socket", socket.path]
        native.standardInput = input; native.standardOutput = output; native.standardError = output
        WKClipboardProcess.prepareWriter(input)
        clipboard.onControl = { [weak self] line in
            guard let self, self.native.isRunning else { return }; _ = WKClipboardProcess.writeLine(line, to: self.input)
        }
        clipboard.onStatus = { wkLog($0) }
        clipboard.onPasteProgress = { [weak self] in self?.pasteHUD.update($0) }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.consume(text) }
        }
        native.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.stop() } }
        try native.run()
        try clipboard.start(executable: runtime.appendingPathComponent("wiredkvm-companion"), socket: socket, ch32Files: files)
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN); let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }; source.resume(); signals.append(source)
        }
        wkLog("CH32 control started. Control + Option + Esc returns to this Mac.")
    }
    private func consume(_ text: String) {
        buffer += text
        while let end = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<end]); buffer.removeSubrange(...end)
            let prefix = "CPP_CLIPBOARD_INTENT "
            if line.hasPrefix(prefix) { clipboard.sendIntent(String(line.dropFirst(prefix.count))) }
            else if line.hasPrefix("CPP_WIREDKVM_FAILURE") || line.hasPrefix("CPP_USB_HID") { wkLog(line) }
        }
        if buffer.utf8.count > 16384 { buffer = "" }
    }
    func stop() {
        guard !stopping else { return }; stopping = true
        clipboard.stop(); output.fileHandleForReading.readabilityHandler = nil
        if native.isRunning { native.terminate() }
        NSApplication.shared.terminate(nil)
    }
}

@main struct CH32HostMain {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--self-test"] {
            do { try WKClipboardProcess.selfTest() } catch { wkLog("CH32 GUI test failed: \(error)"); exit(1) }
            return
        }
        guard args.count == 2 || args.count == 3, args.count < 3 || ["left", "right"].contains(args[2]) else {
            wkLog("usage: wiredkvm-ch32-host CONTROL_CDC_PATH FILE_CDC_PATH [left|right]"); exit(2)
        }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let host = CH32Host()
        do { try host.start(control: args[0], files: args[1], position: args.count == 3 ? args[2] : "right") }
        catch { wkLog("CH32 host start failed: \(error)"); host.stop(); exit(1) }
        withExtendedLifetime(host) { app.run() }
    }
}
