import AppKit
import Foundation
import Darwin
import CryptoKit

struct CH32PortableRuntime: Decodable {
    let native, capture, companion, touch, loader, asset: String
    let hashes: [String: String]
    private func verify(_ paths: [String]) throws {
        for path in paths {
            guard path.hasPrefix("/"), let expected=hashes[path] else { throw WKStreamError.invalid }
            let hash=SHA256.hash(data:try Data(contentsOf:URL(fileURLWithPath:path))).map{String(format:"%02x",$0)}.joined()
            guard hash==expected else { throw WKStreamError.invalid }
        }
    }
    func verifyInput() throws { try verify([native,capture,touch]) }
    func verifyProgram() throws { try verify([companion,loader,asset]) }
    static func selfTest() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("wk-portable-preflight-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        let input=root.appendingPathComponent("input");let body=Data("input-fixture".utf8);try body.write(to:input)
        defer {try? FileManager.default.removeItem(at:input);try? FileManager.default.removeItem(at:root)}
        let digest=SHA256.hash(data:body).map{String(format:"%02x",$0)}.joined()
        let r=CH32PortableRuntime(native:input.path,capture:input.path,companion:root.appendingPathComponent("missing-component").path,
            touch:input.path,loader:root.appendingPathComponent("missing-loader").path,asset:root.appendingPathComponent("missing-image").path,hashes:[input.path:digest])
        try r.verifyInput();var rejected=false;do{try r.verifyProgram()}catch{rejected=true};precondition(rejected)
        wkLog("PORTABLE_PREFLIGHT_PASS unavailable_program_keeps_input_valid=true")
    }
}

// Development launcher. Uses the same capture, absolute pointer, edge return,
// token validation and clipboard coordinator as the installed ESP32 product.
// It is built separately and never installs or starts itself during a build.
@MainActor
final class CH32Host {
    let clipboard = WKClipboardProcess()
    let diagnostics = WKClipboardDiagnostics()
    let pasteHUD = WKPasteProgressHUD()
    let native = Process(), input = Pipe(), output = Pipe()
    var buffer = "", stopping = false
    var signals: [DispatchSourceSignal] = []
    private var portable: CH32PortableRuntime?
    private var filePort = ""
    private var programLoader: Process?
    private var loaderRetry: Timer?
    private var clipboardStarted = false
    private var socketURL: URL?
    private var helperHealth: Timer?
    func start(control: String, files: String, position: String, portable: CH32PortableRuntime? = nil) throws {
        guard WKCH32Device.matches(path: control, role: "host", files: false),
              WKCH32Device.matches(path: files, role: "host") else { throw WKStreamError.invalid }
        let runtime = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        try portable?.verifyInput(); self.portable=portable;filePort=files
        let socket = try clipboard.prepare()
        socketURL=socket
        native.executableURL = portable.map{URL(fileURLWithPath:$0.native)} ?? runtime.appendingPathComponent("wiredkvm-native")
        native.arguments = ["--transport", "cdc:" + control, "--source", "macos", "--target", "desktop",
            "--absolute-mouse", "--position", position, "--capture", portable?.capture ?? runtime.appendingPathComponent("macos-capture").path,
            "--clipboard-socket", socket.path]
        if let portable {
            native.arguments! += ["--invert-scroll","--raw-touch",portable.touch]
            var env=ProcessInfo.processInfo.environment;env["WK_RAW_TOUCH_PROTOCOL"]="2";env["WK_RAW_TOUCH_HELPER"]=portable.touch
            native.environment=env
        }
        native.standardInput = input; native.standardOutput = output; native.standardError = output
        WKClipboardProcess.prepareWriter(input)
        clipboard.onControl = { [weak self] line in
            guard let self, self.native.isRunning else { return }; _ = WKClipboardProcess.writeLine(line, to: self.input)
        }
        clipboard.onStatus = { wkLog($0) }
        clipboard.onDiagnostic = { [weak self] line in self?.diagnostics.record(line) }
        clipboard.onPasteProgress = { [weak self] in self?.pasteHUD.update($0) }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.consume(text) }
        }
        native.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.stop() } }
        try native.run()
        if portable == nil { try clipboard.start(executable: runtime.appendingPathComponent("wiredkvm-companion"), socket: socket, ch32Files: files) }
        if portable != nil {
            helperHealth=Timer.scheduledTimer(withTimeInterval:2,repeats:true){[weak self] _ in
                Task {@MainActor [weak self] in
                    guard let self,!self.stopping,self.clipboardStarted,!self.clipboard.isRunning else{return}
                    self.clipboardStarted=false;self.startProgramLoader()
                }
            }
        }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN); let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }; source.resume(); signals.append(source)
        }
        wkLog("CH32 control started. Control + Option + Esc returns to this Mac.")
    }
    private func startProgramLoader() {
        guard let portable, !stopping, native.isRunning, !clipboardStarted, programLoader == nil else { return }
        do {try portable.verifyProgram()}catch{retryProgramLoader();return}
        let process=Process();process.executableURL=URL(fileURLWithPath:portable.loader)
        process.arguments=["--load",portable.asset,"--port",filePort]
        process.standardInput=FileHandle.nullDevice;process.standardOutput=FileHandle.standardError;process.standardError=FileHandle.standardError
        process.terminationHandler = { [weak self] child in DispatchQueue.main.async {
            guard let self, !self.stopping else { return };self.programLoader=nil
            if child.terminationStatus==0, let socket=self.socketURL {
                do {
                    try self.clipboard.start(executable:URL(fileURLWithPath:portable.companion),socket:socket,ch32Files:self.filePort)
                    self.clipboardStarted=true;wkLog("CH32 portable clipboard started; native input retained")
                } catch { self.retryProgramLoader() }
            } else { self.retryProgramLoader() }
        } }
        do {try process.run();programLoader=process}
        catch {retryProgramLoader()}
    }
    private func retryProgramLoader() {
        guard !stopping else {return}
        wkLog("CH32 program channel waiting; native input remains active")
        loaderRetry=Timer.scheduledTimer(withTimeInterval:5,repeats:false){[weak self] _ in
            Task {@MainActor [weak self] in self?.startProgramLoader()}
        }
    }
    private func consume(_ text: String) {
        buffer += text
        while let end = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<end]); buffer.removeSubrange(...end)
            diagnostics.record(line)
            let prefix = "CPP_CLIPBOARD_INTENT "
            if line.contains("GESTURE_CAPTURE_READY ready=1") { wkLog("CH32_INPUT_READY"); startProgramLoader() }
            else if line.hasPrefix(prefix) { clipboard.sendIntent(String(line.dropFirst(prefix.count))) }
            else if line.hasPrefix("CPP_WIREDKVM_FAILURE") || line.hasPrefix("CPP_USB_HID") { wkLog(line) }
        }
        if buffer.utf8.count > 16384 { buffer = "" }
    }
    func stop() {
        guard !stopping else { return }; stopping = true
        loaderRetry?.invalidate();loaderRetry=nil
        helperHealth?.invalidate();helperHealth=nil
        if let programLoader,programLoader.isRunning{programLoader.terminate()}
        clipboard.stop(); output.fileHandleForReading.readabilityHandler = nil
        if native.isRunning { native.terminate() }
        NSApplication.shared.terminate(nil)
    }
}

@main struct CH32HostMain {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--self-test"] {
            do { try CH32PortableRuntime.selfTest();try WKClipboardProcess.selfTest() } catch { wkLog("CH32 GUI test failed: \(error)"); exit(1) }
            return
        }
        if args.count==2 && args[0]=="--runtime-config" {
            let app=NSApplication.shared;app.setActivationPolicy(.accessory);let host=CH32Host()
            do {
                let runtime=try JSONDecoder().decode(CH32PortableRuntime.self,from:Data(contentsOf:URL(fileURLWithPath:args[1])))
                guard let control=WKUSBDiscovery.unique(role:"host",files:false),let files=WKUSBDiscovery.unique(role:"host",files:true) else {throw WKStreamError.invalid}
                try host.start(control:control,files:files,position:"right",portable:runtime)
            } catch {wkLog("CH32 portable runtime failed preflight");host.stop();exit(1)}
            withExtendedLifetime(host){app.run()};return
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
