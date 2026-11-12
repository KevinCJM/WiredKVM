import AppKit
import Darwin

// A bounded, private diagnostic trail. Only protocol metadata is accepted;
// arbitrary subprocess output and clipboard data are never persisted.
final class WKClipboardDiagnostics: @unchecked Sendable {
    static let limit = 256 * 1024
    private let directory: URL
    private let queue = DispatchQueue(label: "WiredKVM.clipboard.diagnostics")
    private let lock = NSLock()
    private var queued = 0
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WiredKVM/Diagnostics", isDirectory: true)
    }
    var fileURL: URL { directory.appendingPathComponent("clipboard.log") }

    // Preserve only the firmware's fixed numeric status. Never accept arbitrary
    // native stderr just to collect throughput measurements.
    private static func rawTouchStatus(_ text: String) -> Bool {
        guard text.utf8.count <= 511 else { return false }
        let fields = text.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.first == "MT2" else { return false }
        var values: [String: String] = [:]
        for field in fields.dropFirst() {
            let pair = field.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2, values[String(pair[0])] == nil else { return false }
            values[String(pair[0])] = String(pair[1])
        }
        let base = Set("version enabled faults rx max_contacts resets gets sets get_ids set_ids errors inputs".split(separator: " ").map(String.init))
        let profile = Set("bp bpl bpg bph bpm bp0 bp1".split(separator: " ").map(String.init))
        let keys = Set(values.keys)
        guard keys == base || keys == base.union(profile),
              ["1", "2"].contains(values["version"]!), ["0", "1"].contains(values["enabled"]!) else { return false }
        for key in base {
            let value = values[key]!
            if key == "faults" {
                guard value.range(of: "^-?[0-9]{1,10}$", options: .regularExpression) != nil, Int32(value) != nil else { return false }
            } else {
                guard !value.isEmpty, value.utf8.count <= 10,
                      value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), UInt32(value) != nil else { return false }
            }
        }
        if keys != base {
            func hex(_ value: Substring) -> Bool {
                !value.isEmpty && value.utf8.count <= 8 && value.utf8.allSatisfy {
                    ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
                }
            }
            guard values["bp"] == "1" else { return false }
            for key in ["bpl", "bpg", "bph", "bpm"] { guard hex(Substring(values[key]!)) else { return false } }
            for key in ["bp0", "bp1"] {
                let numbers = values[key]!.split(separator: ":", omittingEmptySubsequences: false)
                guard numbers.count == 9, numbers.allSatisfy(hex) else { return false }
            }
        }
        return true
    }

    static func filtered(_ line: String) -> String? {
        guard line.utf8.count <= 2048, !line.contains("\n"), !line.contains("\r") else { return nil }
        let words = line.split(separator: " ").map(String.init)
        guard let prefix = words.first else { return nil }
        let allowed: Set<String>
        switch prefix {
        case "CPP_RAW_TOUCH_STATUS":
            return words.count == 2 && rawTouchStatus(words[1]) ? line : nil
        case "CPP_WIREDKVM_FAILURE":
            let codes: Set<String> = ["code=OTHER", "code=WK1_OVERFLOW", "code=WK1_REJECT",
                "code=HEARTBEAT_TIMEOUT", "code=HID_ACK_TIMEOUT", "code=UART_STALLED",
                "code=UART_WRITE_TIMEOUT", "code=DISCONNECTED"]
            return words.count == 2 && codes.contains(words[1]) ? line : nil
        case "WKCLIP_DIAG":
            allowed = Set("role event phase direction nonce baseline revision previousRevision observedRevision transfer acked total accepted ready token latestNonce completedNonce linkReady completedNonceMatches completedDirectionMatches latestNonceMatches latestDirectionMatches notCancelled revisionMatches notTransmitting peerAccepted noPending appliedNonce appliedRevision appliedNonceMatches appliedRevisionMatches code result usbMbps davMetadata davMissing davWaiting davServed davFailed davMalformed davCapacity davProxy steps elapsedUs gapMaxUs pendingMax inFlightMax readWaitSteps windowFullSteps readCalls readBytes readZero readMax writeCalls writeWanted writeBytes writeZero writePartial writeMax".split(separator: " ").map(String.init))
            if words.contains("event=STREAM_IO") {
                let numeric = Set("steps elapsedUs gapMaxUs pendingMax inFlightMax readWaitSteps windowFullSteps readCalls readBytes readZero readMax writeCalls writeWanted writeBytes writeZero writePartial writeMax".split(separator:" ").map(String.init))
                var seen = Set<String>()
                var values: [String:String] = [:]
                for word in words.dropFirst() {
                    let pair = word.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
                    guard pair.count == 2, seen.insert(String(pair[0])).inserted else { return nil }
                    values[String(pair[0])] = String(pair[1])
                    if numeric.contains(String(pair[0])) {
                        guard !pair[1].isEmpty, pair[1].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), UInt32(pair[1]) != nil else { return nil }
                    } else {
                        guard ["role", "event", "phase"].contains(String(pair[0])) else { return nil }
                    }
                }
                guard seen == numeric.union(["role", "event", "phase"]), ["host", "target"].contains(values["role"] ?? ""),
                      ["PROGRESS", "RESULT"].contains(values["phase"] ?? "") else { return nil }
            }
        case "CPP_CLIPBOARD_STATS":
            allowed = Set("unix_rx uart_rx unix_tx uart_tx crc_reject format_reject queue_drop no_client_drop uart_drop disconnect_drop_uart disconnect_drop_unix q_uart q_unix q_uart_max q_unix_max connections connected".split(separator: " ").map(String.init))
        case "CPP_CLIPBOARD_DISCONNECTED": allowed = ["reason", "errno"]
        case "WKGUI_EVENT": allowed = ["event", "role", "pid", "status", "reason"]
        case "CPP_CLIPBOARD_BACKPRESSURE", "CPP_CLIPBOARD_UART_BACKPRESSURE", "CPP_CLIPBOARD_UART_RECOVERED", "CPP_CLIPBOARD_LISTENING", "CPP_CLIPBOARD_CONNECTED":
            return words.count == 1 ? line : nil
        case "WKCLIP_PASTE", "WKCLIP_COPY":
            guard words.count == 3, ["READY", "BLOCK", "ARMED"].contains(words[1]),
                  words[2].range(of: "^[0-9]{1,20}(\\.[0-9]{1,20})?$", options: .regularExpression) != nil else { return nil }
            return line
        default: return nil
        }
        guard words.count > 1 else { return nil }
        for word in words.dropFirst() {
            let pair = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, allowed.contains(String(pair[0])), !pair[1].isEmpty, pair[1].count <= 96,
                  pair[1].range(of: "^[A-Za-z0-9_.:-]+$", options: .regularExpression) != nil else { return nil }
        }
        return line
    }

    func record(_ line: String) {
        guard let safe = Self.filtered(line) else { return }
        lock.lock()
        guard queued < 128 else { lock.unlock(); return }
        queued += 1; lock.unlock()
        let text = "time=\(String(format: "%.3f", Date().timeIntervalSince1970)) \(safe)\n"
        queue.async { [self] in
            defer { lock.lock(); queued -= 1; lock.unlock() }
            append(Data(text.utf8))
        }
    }

    private func append(_ bytes: Data) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            var parent = stat()
            guard directory.path.withCString({ lstat($0, &parent) }) == 0,
                  parent.st_uid == getuid(), parent.st_mode & S_IFMT == S_IFDIR,
                  parent.st_mode & 0o077 == 0 else { return }
            let fd = fileURL.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600) }
            guard fd >= 0 else { return }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o077 == 0, info.st_nlink == 1, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
            if info.st_size + off_t(bytes.count) > Self.limit, ftruncate(fd, 0) != 0 { return }
            _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        } catch { /* Diagnostics never stop keyboard, mouse, or clipboard work. */ }
    }

    func flushForTest() { queue.sync {} }
    static func selfTest() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("wk-diag-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let log = WKClipboardDiagnostics(directory: temporary)
        log.record("WKCLIP_DIAG role=host event=TX transfer=7 acked=2 total=9")
        log.record("WKCLIP_DIAG role=host event=TX payload=PRIVATE_CONTENT")
        log.record("WKCLIP_DIAG role=host event=ERROR code=/private/secret")
        log.record("unrelated PRIVATE_CONTENT")
        log.record("CPP_WIREDKVM_FAILURE code=WK1_OVERFLOW")
        log.record("CPP_WIREDKVM_FAILURE code=PRIVATE_CONTENT")
        log.record("CPP_WIREDKVM_ERROR PRIVATE_CONTENT")
        let status = "CPP_RAW_TOUCH_STATUS MT2,version=2,enabled=1,faults=0,rx=10,max_contacts=4,resets=1,gets=1,sets=1,get_ids=1,set_ids=1,errors=0,inputs=10"
        let profile = status + ",bp=1,bpl=ffff,bpg=10,bph=17d7840,bpm=ffff,bp0=200:1:200:1:1:0:1:0:0,bp1=200:1:200:1:1:0:1:0:0"
        let numericIO = "steps elapsedUs gapMaxUs pendingMax inFlightMax readWaitSteps windowFullSteps readCalls readBytes readZero readMax writeCalls writeWanted writeBytes writeZero writePartial writeMax".split(separator:" ").map { "\($0)=1" }.joined(separator:" ")
        let streamIO = "WKCLIP_DIAG role=host event=STREAM_IO phase=RESULT " + numericIO
        precondition(Self.filtered(streamIO) == streamIO)
        for invalid in [streamIO + " payload=PRIVATE_CONTENT", streamIO + " steps=2",
                        streamIO.replacingOccurrences(of:"writeMax=1",with:"writeMax=PRIVATE_CONTENT"),
                        streamIO.replacingOccurrences(of:"writeMax=1",with:"writeMax=4294967296"),
                        streamIO.replacingOccurrences(of:"writeMax=1",with:"writeMax=-1"),
                        streamIO.replacingOccurrences(of:"phase=RESULT",with:"phase=PRIVATE_CONTENT"),
                        streamIO.replacingOccurrences(of:"readMax=1 ",with:"")] { precondition(Self.filtered(invalid) == nil) }
        precondition(Self.filtered(status) == status && Self.filtered(profile) == profile)
        for invalid in [profile + ",payload=PRIVATE_CONTENT", profile + ",bp=1", profile + ",path=/private/secret",
                        profile.replacingOccurrences(of: "bpl=ffff", with: "bpl=PRIVATE_CONTENT"),
                        profile.replacingOccurrences(of: "bpl=ffff", with: "bpl=100000000"),
                        profile.replacingOccurrences(of: "bp0=200:1:200:1:1:0:1:0:0", with: "bp0=1:2"),
                        status.replacingOccurrences(of: "rx=10", with: "rx=4294967296"),
                        status.replacingOccurrences(of: "inputs=10", with: "inputs="),
                        profile.replacingOccurrences(of: ",bpm=ffff", with: "")] {
            precondition(Self.filtered(invalid) == nil)
        }
        log.record(profile)
        log.flushForTest()
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        precondition(text.contains("transfer=7") && !text.contains("PRIVATE_CONTENT") && !text.contains("/private/secret"))
        precondition(text.contains("CPP_WIREDKVM_FAILURE code=WK1_OVERFLOW"))
        precondition(text.contains("CPP_RAW_TOUCH_STATUS MT2,") && text.contains("bp0=200:1:200:1:1:0:1:0:0"))
        let permissions = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue & 0o777 == 0o600)
        let fd = Darwin.open(log.fileURL.path, O_WRONLY)
        precondition(fd >= 0 && ftruncate(fd, off_t(Self.limit)) == 0); Darwin.close(fd)
        log.record("WKGUI_EVENT event=EXIT role=HOST pid=7 status=0 reason=EXIT")
        log.flushForTest()
        let rotated = try Data(contentsOf: log.fileURL)
        precondition(rotated.count < 1024)
        print("CLIPBOARD_DIAGNOSTICS_PASS filtered=true private=true bounded=true")
    }
}

// Keep diagnostic framing outside the GUI's process-identity guard: a late
// final chunk still belongs in the log after that process has exited.
final class WKClipboardDiagnosticStream: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private let output: ((String) -> Void)?
    init(output: ((String) -> Void)?) { self.output = output }
    func consume(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        buffer += text
        while let end = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<end]); buffer.removeSubrange(...end)
            output?(line)
        }
        if buffer.utf8.count > 8192 { buffer = "" }
    }
}

struct WKPasteProgress {
    enum Phase: Equatable { case started, transferring, completed, cancelled }
    let token: String
    let remote: Bool
    var phase: Phase
    var percent: Int?
    var bytes = 0
}

// A nonactivating status panel: showing progress must not change the paste's
// destination focus. Fast text pastes finish before the panel is ever shown.
@MainActor private final class WKPasteProgressPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class WKPasteProgressHUD {
    private var active: WKPasteProgress?
    private var generation = 0
    private var panel: WKPasteProgressPanel?
    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    func update(_ value: WKPasteProgress) {
        let isNew = active?.token != value.token
        active = value
        if isNew {
            generation += 1
            let g = generation
            DispatchQueue.main.asyncAfter(deadline: .now()+0.2) { [weak self] in
                guard let self, self.generation == g, let active = self.active,
                      active.phase == .started || active.phase == .transferring else { return }
                self.show()
            }
        }
        render()
        if value.phase == .completed || value.phase == .cancelled {
            generation += 1
            let g = generation
            DispatchQueue.main.asyncAfter(deadline: .now()+0.8) { [weak self] in
                guard let self, self.generation == g else { return }
                self.panel?.orderOut(nil); self.active = nil
            }
        }
    }
    private func show() {
        if panel == nil {
            let p = WKPasteProgressPanel(contentRect:NSRect(x:0,y:0,width:360,height:132),
                styleMask:[.titled,.nonactivatingPanel],backing:.buffered,defer:false)
            p.title = "有线粘贴"; p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false; p.becomesKeyOnlyIfNeeded = true
            p.level = .floating; p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            let content = p.contentView!
            heading.font = .boldSystemFont(ofSize:14)
            heading.frame = NSRect(x:18,y:96,width:324,height:20)
            detail.frame = NSRect(x:18,y:69,width:324,height:20)
            bar.frame = NSRect(x:18,y:45,width:324,height:14)
            bar.style = .bar; bar.minValue = 0; bar.maxValue = 100
            let note = NSTextField(wrappingLabelWithString:"完成后自动粘贴；点击或切换窗口会取消本次操作。")
            note.font = .systemFont(ofSize:11); note.textColor = .secondaryLabelColor
            note.frame = NSRect(x:18,y:8,width:324,height:30)
            let views: [NSView] = [heading,detail,bar,note]
            for view in views { content.addSubview(view) }
            if let frame=NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x:frame.maxX-384,y:frame.minY+72))
            }
            panel = p
        }
        render(); panel?.orderFrontRegardless()
    }
    private func render() {
        guard panel != nil, let value=active else { return }
        heading.stringValue = value.remote ? "正在粘贴到 Mac mini" : "正在粘贴到本机"
        switch value.phase {
        case .completed: detail.stringValue = "已接收，正在粘贴。"
        case .cancelled: detail.stringValue = "本次粘贴已取消，本机剪贴板仍可使用。"
        default:
            if let percent=value.percent { detail.stringValue = "正在传输：\(percent)%" }
            else if value.bytes>0 { detail.stringValue = "正在接收：\(value.bytes/1024) KB" }
            else { detail.stringValue = "正在准备，请保留当前窗口。" }
        }
        bar.isIndeterminate = value.percent == nil && value.phase != .completed
        if bar.isIndeterminate { bar.startAnimation(nil) }
        else { bar.stopAnimation(nil); bar.doubleValue = Double(value.percent ?? 100) }
    }
    static func selfTest() {
        let app=NSApplication.shared; app.setActivationPolicy(.accessory)
        let before=NSWorkspace.shared.frontmostApplication?.processIdentifier
        let hud=WKPasteProgressHUD()
        hud.update(WKPasteProgress(token:"71.72",remote:false,phase:.started))
        RunLoop.current.run(until:Date().addingTimeInterval(0.35))
        precondition(hud.panel?.isVisible==true && hud.panel?.canBecomeKey==false && hud.panel?.canBecomeMain==false)
        precondition(before==NSWorkspace.shared.frontmostApplication?.processIdentifier,"progress stole destination focus")
        hud.update(WKPasteProgress(token:"71.72",remote:false,phase:.completed,percent:100))
        RunLoop.current.run(until:Date().addingTimeInterval(0.9))
        precondition(hud.panel?.isVisible==false)
        print("PASTE_PROGRESS_HUD_PASS nonactivating=true focus_preserved=true closes_on_complete=true no_input_posted=true")
    }
}

// The GUI owns the lifetime of this helper. It never opens the COM port: the
// native controller remains the sole UART owner and prioritizes keyboard input.
@MainActor
final class WKClipboardProcess {
    var isRunning: Bool { process?.isRunning == true }
    private(set) var directory: URL?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = ""
    var onStatus: ((String) -> Void)?
    var onControl: ((String) -> Void)?
    var onReady: ((Bool) -> Void)?
    var onPeerVersion: ((UInt32) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var onPasteProgress: ((WKPasteProgress) -> Void)?
    private var pasteProgress: WKPasteProgress?

    private func finishProgress(_ token: String? = nil, completed: Bool) {
        guard var value=pasteProgress, token == nil || token == value.token else { return }
        value.phase = completed ? .completed : .cancelled
        if completed { value.percent = 100 }
        pasteProgress = nil; onPasteProgress?(value)
    }

    static func canWithdrawSetup(connected: Bool, peerBuild: UInt32) -> Bool {
        connected && peerBuild >= 16
    }

    func prepare() throws -> URL {
        stop()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wk-clip-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        directory = url
        return url.appendingPathComponent("data.sock")
    }

    func start(executable: URL, socket: URL, ch32Files: String? = nil) throws {
        onPeerVersion?(0)
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable
        child.arguments = ["--role", "host", "--socket", socket.path, "--headless"]
        if let ch32Files { child.arguments! += ["--ch32-files", ch32Files] }
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stdout
        Self.prepareWriter(stdin)
        input = stdin; output = stdout; process = child; buffer = ""
        let diagnosticStream = WKClipboardDiagnosticStream(output: onDiagnostic)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            diagnosticStream.consume(text)
            DispatchQueue.main.async {
                guard let self, self.process === child else { return }
                self.consume(text)
            }
        }
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                self?.onDiagnostic?("WKGUI_EVENT event=EXIT role=HOST pid=\(child.processIdentifier) status=\(child.terminationStatus) reason=\(child.terminationReason == .exit ? "EXIT" : "SIGNAL")")
                guard let self, self.process === child else { return }
                self.output?.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.finishProgress(completed:false)
                self.input = nil
                self.output = nil
                self.onControl?("CLIPBOARD CANCEL 0")
                self.onPeerVersion?(0)
                self.onReady?(false)
                self.onStatus?("剪贴板组件已停止；键鼠仍可使用。")
            }
        }
        do {
            try child.run(); try? stdin.fileHandleForReading.close()
            onDiagnostic?("WKGUI_EVENT event=START role=HOST pid=\(child.processIdentifier)")
        }
        catch { stop(removeDirectory:false); throw error }
        onStatus?("正在连接另一台 Mac 的有线剪贴板组件…")
    }

    func sendIntent(_ line: String) {
        guard Self.validIntent(line), line.utf8.count <= 192,
              !line.contains("\n"), !line.contains("\r"),
              let input, process?.isRunning == true else { return }
        if !Self.writeLine(String(line.dropFirst(2)), to: input) {
            onControl?("CLIPBOARD CANCEL 0")
            onStatus?("剪贴板通道已断开。")
        } else {
            let words=line.split(separator:" ").map(String.init)
            if words.count==4, words[1]=="PASTE", ["IN","OUT"].contains(words[2]), Self.validToken(words[3]) {
                let value=WKPasteProgress(token:words[3],remote:words[2]=="OUT",phase:.started)
                pasteProgress=value; onPasteProgress?(value)
            } else if words.count==7, words[1]=="PASTE" {
                let value=WKPasteProgress(token:words[2],remote:words[3]=="1",phase:.started)
                pasteProgress=value; onPasteProgress?(value)
            } else if words.count==3,words[1]=="CANCEL" {
                finishProgress(words[2]=="0" ? nil : words[2],completed:false)
            }
        }
    }

    static func prepareWriter(_ pipe: Pipe) {
        signal(SIGPIPE, SIG_IGN)
        let fd = pipe.fileHandleForWriting.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    static func writeLine(_ line: String, to pipe: Pipe) -> Bool {
        let bytes = Data((line + "\n").utf8)
        guard bytes.count <= 256 else { return false }
        // Each command is below PIPE_BUF, so it is either written atomically or
        // fails with EAGAIN. Never block the GUI's emergency-return action.
        return bytes.withUnsafeBytes { buffer in
            Darwin.write(pipe.fileHandleForWriting.fileDescriptor, buffer.baseAddress!, buffer.count) == buffer.count
        }
    }

    private func consume(_ text: String) {
        buffer += text
        while let end = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<end])
            buffer.removeSubrange(...end)
            let parts = line.split(separator: " ")
            if line.hasPrefix("WKCLIP_DIAG ") {
                let fields = parts.dropFirst().reduce(into: [String: String]()) { result, token in
                    let pair = token.split(separator: "=", maxSplits: 1)
                    if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
                }
                if var value = pasteProgress, fields["token"] == value.token,
                   fields["event"] == (value.remote ? "BULK_TX" : "BULK_RX"), fields["phase"] == "PROGRESS",
                   let done = UInt64(fields["acked"] ?? ""), let total = UInt64(fields["total"] ?? ""),
                   total > 0, total <= 64 * 1024 * 1024 * 1024, done <= total {
                    value.phase = .transferring; value.bytes = Int(done); value.percent = Int(done * 100 / total)
                    pasteProgress = value; onPasteProgress?(value)
                }
                if fields["event"] == "TX", fields["phase"] == "PROGRESS",
                   let acked = Int(fields["acked"] ?? ""), let total = Int(fields["total"] ?? ""),
                   total > 100, total <= 100_000, acked >= 0, acked <= total {
                    onStatus?("正在通过 USB 传输：\(acked * 100 / total)%；本次粘贴正在等待内容。")
                }
                if var value=pasteProgress,fields["event"]==(value.remote ? "TX":"RX"),
                   ["PROGRESS","COMPLETE"].contains(fields["phase"] ?? ""),
                   let acked=Int(fields["acked"] ?? ""),(101...100_000).contains(acked) {
                    value.phase = .transferring; value.bytes=acked*40
                    if let total=Int(fields["total"] ?? ""),total>=acked,total<=100_000 {
                        value.percent=acked*100/total
                    }
                    pasteProgress=value; onPasteProgress?(value)
                }
                continue
            }
            if parts.count == 2 && parts[0] == "WKCLIP_RESET" && parts[1] == "0" {
                finishProgress(completed:false)
                onControl?("CLIPBOARD STATE 0"); continue
            }
            if parts.count == 2 && parts[0] == "WKCLIP_LINK" && parts[1] == "1" {
                onControl?("CLIPBOARD STATE 1"); continue
            }
            if parts.count == 2, parts[0] == "WKCLIP_ROUTE", Self.validRoute(String(parts[1])) {
                onControl?("CLIPBOARD ROUTE \(parts[1])"); continue
            }
            if parts.count == 4, parts[0] == "WKCLIP_RESULT", Self.validNumber(String(parts[1])),
               parts[2] == "ready", Self.validNumber(String(parts[3])) {
                finishProgress(String(parts[1]), completed: true)
                onControl?("CLIPBOARD RESULT \(parts[1]).ready.\(parts[3])"); continue
            }
            if parts.count == 3, parts[0] == "WKCLIP_RESULT", Self.validNumber(String(parts[1])),
               ["blocked", "cancelled"].contains(String(parts[2])) {
                finishProgress(String(parts[1]), completed: false)
                onControl?("CLIPBOARD RESULT \(parts[1]).\(parts[2])"); continue
            }
            if parts.count == 3 && parts[0] == "WKCLIP_ORIGIN" &&
                ["IN", "OUT"].contains(String(parts[1])) && Self.validToken(String(parts[2])) && !parts[2].contains(".") {
                onControl?("CLIPBOARD ORIGIN_\(parts[1]) \(parts[2])"); continue
            }
            if parts.count == 3, Self.validToken(String(parts[2])) {
                if parts[0] == "WKCLIP_PASTE" {
                    if parts[1] == "READY" {
                        finishProgress(String(parts[2]),completed:true)
                        onControl?("CLIPBOARD PASTE \(parts[2])")
                    } else if parts[1] == "BLOCK" {
                        finishProgress(String(parts[2]),completed:false)
                        onControl?("CLIPBOARD CANCEL \(parts[2])")
                        onStatus?("本次跨机粘贴已取消；本机复制粘贴仍可使用。")
                    }
                    continue
                }
                if parts[0] == "WKCLIP_COPY", parts[1] == "ARMED" {
                    onControl?("CLIPBOARD COPY \(parts[2])")
                    continue
                }
            }
            if line.hasPrefix("WKCLIP_STATUS ") {
                let status = String(line.dropFirst("WKCLIP_STATUS ".count))
                if parts.count >= 2, parts[1] == "PEER_VERSION" {
                    if parts.count == 3, !parts[2].isEmpty, parts[2].utf8.count <= 10,
                       parts[2].utf8.allSatisfy({ (48...57).contains($0) }), let build = UInt32(parts[2]), build <= 1_000_000 {
                        onPeerVersion?(build)
                    }
                    // Version announcements recur with heartbeat and should
                    // never overwrite useful transfer/connection status text.
                    continue
                }
                if status.hasPrefix("READY") { onReady?(true) }
                else if status.hasPrefix("DISCONNECTED") { finishProgress(completed:false); onPeerVersion?(0); onReady?(false) }
                onStatus?(Self.statusText(status))
            } else if line.hasPrefix("WKCLIP_ERROR ") {
                onStatus?(String(line.dropFirst("WKCLIP_ERROR ".count).prefix(240)))
            }
        }
        if buffer.utf8.count > 4096 { buffer = "" }
    }

    static func statusText(_ value: String) -> String {
        if value.hasPrefix("READY") { return "有线剪贴板已连接。" }
        if value.hasPrefix("TRANSFER offered") || value.hasPrefix("TRANSFER file-sending") {
            return "文件入口已就绪，可以按 ⌘V 开始 Finder 拷贝。"
        }
        if value.hasPrefix("TRANSFER file-in-progress") { return "文件复制已开始，请以 Finder 进度为准。" }
        if value.hasPrefix("TRANSFER complete") { return "粘贴内容已就绪。" }
        if value.hasPrefix("TRANSFER") { return "正在通过 USB 传输，请稍候…" }
        if value.contains("paste-not-ready") { return "本次跨机粘贴已取消；本机复制粘贴仍可使用。" }
        if value.contains("over-1MiB") || value.contains("item-too-large") { return "内容超过首版 1 MiB 限制，本次未传输。" }
        if value.contains("single-file-only") || value.contains("regular-file-only") || value.contains("resource-fork") {
            return "首版支持一个普通文件；暂不支持目录、多文件或含资源叉的文件。"
        }
        if value.contains("new-local-copy-wins") { return "检测到新的本机复制，已取消过期传输。" }
        if value.contains("peer-timeout") { return "另一台 Mac 的剪贴板组件未响应，请确认 Companion 仍在运行。" }
        if value.contains("send-timeout") || value.contains("receive-timeout") { return "文件传输超时，请检查组件连接后重新复制。" }
        if value.contains("file-portal-access-denied") { return "Finder 进度需要允许 WiredKVM 访问网络卷；跨机数据仍只走 USB。当前文件需完整接收后粘贴。" }
        if value.contains("file-portal-unavailable") { return "原生文件粘贴入口暂不可用，当前仍可使用原有传输方式。" }
        if value.contains("hid-access-denied") || value.contains("clipboard-write-denied") {
            return "另一台 Mac 尚未允许组件访问，请查看其系统提示。"
        }
        if value.hasPrefix("ERROR") { return "传输未完成，请检查两侧连接后重新复制。" }
        return "等待另一台 Mac 的有线剪贴板组件连接。"
    }

    static func validToken(_ token: String) -> Bool {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        return (1...2).contains(pieces.count) && pieces.allSatisfy {
            !$0.isEmpty && $0.count <= 20 && $0.utf8.allSatisfy { (48...57).contains($0) }
        }
    }

    static func validNumber(_ word: String) -> Bool {
        !word.isEmpty && word.utf8.count <= 20 && word.utf8.allSatisfy { (48...57).contains($0) } && UInt64(word) != nil
    }
    static func validRoute(_ route: String) -> Bool {
        let f=route.split(separator:",",omittingEmptySubsequences:false).map(String.init)
        return f.count==9 && f.allSatisfy(validNumber) && UInt64(f[0])! > 0 &&
            UInt64(f[2])! <= 2 && UInt64(f[7])! <= 1 && UInt64(f[8])! <= 3
    }
    static func validIntent(_ line: String) -> Bool {
        guard !line.contains("\n"), !line.contains("\r") else { return false }
        let f=line.split(separator:" ").map(String.init)
        guard f.count>=2, f[0]=="C" else { return false }
        if f[1]=="CANCEL" { return f.count==3 && validToken(f[2]) }
        if f[1]=="CONTEXT" { return f.count==5 && validNumber(f[2]) && ["0","1"].contains(f[3]) && validNumber(f[4]) }
        if f[1]=="SELECT" { return f.count==7 && validNumber(f[2]) && ["0","1"].contains(f[3]) &&
            ["copy","cut"].contains(f[4]) && validNumber(f[5]) && validNumber(f[6]) }
        if f[1]=="PASTE", f.count==7 { return validNumber(f[2]) && ["0","1"].contains(f[3]) && f[4...6].allSatisfy(validNumber) }
        // Old tests and pre-upgrade producers may send these; version gating
        // still prevents old peers from enabling the v2 clipboard route.
        return (f[1]=="COPY" || f[1]=="PASTE") && f.count==4 && ["IN","OUT"].contains(f[2]) && validToken(f[3])
    }

    func stop(removeDirectory: Bool = true) {
        finishProgress(completed:false)
        onControl?("CLIPBOARD CANCEL 0")
        onPeerVersion?(0)
        onReady?(false)
        let old = process
        process = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        input = nil; output = nil; buffer = ""
        if let old, old.isRunning {
            onDiagnostic?("WKGUI_EVENT event=STOP role=HOST pid=\(old.processIdentifier)")
            old.terminate()
        }
        // Only this randomly-created private runtime directory is removed.
        if removeDirectory {
            if let directory { try? FileManager.default.removeItem(at: directory) }
            directory = nil
        }
    }

    static func selfTest() throws {
        try WKClipboardDiagnostics.selfTest()
        precondition(validToken("12") && validToken("12.34"))
        precondition(!validToken("12..34") && !validToken("12\n34") && !validToken("-1"))
        precondition(validRoute("1,2,0,12,34,0,0,0,1") && !validRoute("1,2,3,12,34,0,0,0,1"))
        precondition(!validRoute("1,2,0,12,34,0,0,0,4") && !validRoute("1,2,0,12,34,0,0,0,1,"))
        precondition(validIntent("C SELECT 2 0 copy 12 1") && validIntent("C PASTE 5 1 2 0 1"))
        precondition(!validIntent("C SELECT 2 2 copy 12 1") && !validIntent("C PASTE 5 1 18446744073709551616 0 1"))
        let bridge = WKClipboardProcess()
        let socket = try bridge.prepare()
        // A failed helper launch must preserve the already-bound native socket
        // directory so a later retry can connect without restarting input.
        do {
            try bridge.start(executable:URL(fileURLWithPath:"/private/tmp/wk-no-helper-"+UUID().uuidString),socket:socket)
            preconditionFailure("nonexistent helper unexpectedly started")
        } catch {
            precondition(bridge.directory?.path==socket.deletingLastPathComponent().path)
            precondition(FileManager.default.fileExists(atPath:socket.deletingLastPathComponent().path))
            precondition(!bridge.isRunning)
        }
        let parent = socket.deletingLastPathComponent()
        let mode = try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue & 0o777 == 0o700)
        precondition(socket.path.utf8.count < 104)
        var controls: [String] = []
        var status = ""
        var peerBuilds: [UInt32] = []
        var ready = false
        bridge.onControl = { controls.append($0) }
        bridge.onStatus = { status = $0 }
        bridge.onPeerVersion = { peerBuilds.append($0) }
        bridge.onReady = { ready = $0 }
        bridge.consume("WKCLIP_ROUTE 1,2,0,12,34,0,0,0,1\nWKCLIP_RESULT 5 ready 17\nWKCLIP_ROUTE 1,2,9,12,34,0,0,0,1\nWKCLIP_RESULT 5 arbitrary\nWKCLIP_RESULT 5 ready\n")
        precondition(controls == ["CLIPBOARD ROUTE 1,2,0,12,34,0,0,0,1", "CLIPBOARD RESULT 5.ready.17"])
        controls.removeAll()
        bridge.consume("WKCLIP_LINK 1\nWKCLIP_ORIGIN OUT 7319\nWKCLIP_ORIGIN IN 8426\nWKCLIP_ORIGIN IN bad\nWKCLIP_RESET 0\n")
        precondition(controls == ["CLIPBOARD STATE 1", "CLIPBOARD ORIGIN_OUT 7319", "CLIPBOARD ORIGIN_IN 8426", "CLIPBOARD STATE 0"])
        controls.removeAll()
        bridge.consume("WKCLIP_COPY AR")
        bridge.consume("MED 12\nWKCLIP_PASTE READY 12.34\nWKCLIP_PASTE BLOCK 12.35\nWKCLIP_PASTE READY broken\n")
        precondition(controls == ["CLIPBOARD COPY 12", "CLIPBOARD PASTE 12.34", "CLIPBOARD CANCEL 12.35"])
        bridge.consume("WKCLIP_DIAG role=host event=TX phase=PROGRESS acked=50 total=200 transfer=7\n")
        precondition(status.contains("25%"))
        var progress:[WKPasteProgress]=[]
        bridge.onPasteProgress = { progress.append($0) }
        bridge.pasteProgress=WKPasteProgress(token:"51.52",remote:true,phase:.started)
        bridge.consume("WKCLIP_DIAG role=host event=TX phase=PROGRESS acked=200 total=1000 transfer=8\n")
        precondition(progress.last?.percent==20 && progress.last?.bytes==8000)
        bridge.consume("WKCLIP_PASTE READY 11.12\n")
        precondition(bridge.pasteProgress?.token=="51.52")
        bridge.consume("WKCLIP_PASTE READY 51.52\n")
        precondition(bridge.pasteProgress==nil && progress.last?.phase == .completed)
        bridge.pasteProgress=WKPasteProgress(token:"61.62",remote:false,phase:.started)
        bridge.consume("WKCLIP_DIAG role=host event=RX phase=PROGRESS acked=500 total=unknown transfer=9\n")
        precondition(progress.last?.percent==nil && progress.last?.bytes==20000)
        bridge.consume("WKCLIP_RESET 0\n")
        precondition(bridge.pasteProgress==nil && progress.last?.phase == .cancelled)
        bridge.pasteProgress = WKPasteProgress(token:"71.72",remote:true,phase:.started)
        bridge.consume("WKCLIP_DIAG role=host event=BULK_TX phase=PROGRESS acked=33554432 total=67108864 transfer=9 token=71.72\n")
        precondition(progress.last?.bytes == 33554432 && progress.last?.percent == 50)
        bridge.consume("WKCLIP_DIAG role=host event=BULK_TX phase=PROGRESS acked=67108864 total=67108864 transfer=8 token=71.70\n")
        precondition(progress.last?.percent == 50)
        bridge.consume("WKCLIP_RESET 0\n")
        print("CLIPBOARD_GUI_PASTE_PROGRESS_PASS outgoing_percent=true incoming_bytes=true stale_token_ignored=true reset_closes=true")
        // Exercise the public sendIntent path with a pipe and a process-state
        // stub. No subprocess is launched and no runtime channel is accessed.
        final class RunningProcessFixture: Process, @unchecked Sendable {
            override var isRunning: Bool { true }
        }
        let intentPipe=Pipe();prepareWriter(intentPipe)
        bridge.input=intentPipe;bridge.process=RunningProcessFixture()
        bridge.sendIntent("C PASTE 77 1 6 0 2")
        precondition(bridge.pasteProgress?.token=="77" && bridge.pasteProgress?.remote==true && progress.last?.phase == .started)
        var commandBytes=[UInt8](repeating:0,count:192)
        let written=Darwin.read(intentPipe.fileHandleForReading.fileDescriptor,&commandBytes,commandBytes.count)
        precondition(written>0 && String(decoding:commandBytes.prefix(written),as:UTF8.self)=="PASTE 77 1 6 0 2\n")
        bridge.consume("WKCLIP_RESULT 76 ready 17\n")
        precondition(bridge.pasteProgress?.token=="77")
        bridge.consume("WKCLIP_RESULT 77 ready 17\n")
        precondition(bridge.pasteProgress==nil && progress.last?.phase == .completed)
        bridge.sendIntent("C PASTE 88 0 7 17 2")
        precondition(bridge.pasteProgress?.token=="88" && bridge.pasteProgress?.remote==false)
        bridge.consume("WKCLIP_RESULT 88 cancelled\n")
        precondition(bridge.pasteProgress==nil && progress.last?.phase == .cancelled)
        bridge.sendIntent("C PASTE 89 2 7 17 2")
        precondition(bridge.pasteProgress==nil,"invalid destination must not create progress")
        bridge.process=nil;bridge.input=nil
        try? intentPipe.fileHandleForWriting.close();try? intentPipe.fileHandleForReading.close()
        print("CLIPBOARD_GUI_V2_INTENT_PROGRESS_PASS pipe_only=true new_format=true stale_result_ignored=true cancelled=true")
        bridge.consume("WKCLIP_STATUS READY mac\nWKCLIP_STATUS PEER_VER")
        precondition(ready && peerBuilds.isEmpty)
        let connectedText = status
        bridge.consume("SION 6\n")
        precondition(peerBuilds == [6] && !canWithdrawSetup(connected: ready, peerBuild: peerBuilds.last!))
        bridge.consume("WKCLIP_STATUS PEER_VERSION 8\n")
        precondition(peerBuilds == [6, 8] && !canWithdrawSetup(connected: ready, peerBuild: peerBuilds.last!))
        for invalid in ["-1", "+8", "8.0", "1000001", "4294967295", "4294967296", "99999999999999999999", "eight", "8 extra", ""] {
            bridge.consume("WKCLIP_STATUS PEER_VERSION \(invalid)\n")
        }
        precondition(peerBuilds == [6, 8] && status == connectedText)
        bridge.consume("WKCLIP_STATUS PEER_VERSION 1000000\nWKCLIP_STATUS PEER_VERSION 0\n")
        precondition(peerBuilds.suffix(2) == [1_000_000, 0])
        precondition(!canWithdrawSetup(connected: true, peerBuild: 0))
        precondition(!canWithdrawSetup(connected: false, peerBuild: 8))
        precondition(!canWithdrawSetup(connected: true, peerBuild: 9))
        precondition(!canWithdrawSetup(connected: true, peerBuild: 10))
        precondition(!canWithdrawSetup(connected: true, peerBuild: 11))
        precondition(!canWithdrawSetup(connected: true, peerBuild: 12))
        precondition(!canWithdrawSetup(connected: true, peerBuild: 15))
        precondition(canWithdrawSetup(connected: true, peerBuild: 16))
        bridge.consume("WKCLIP_STATUS PEER_VERSION 8\nWKCLIP_STATUS DISCONNECTED\n")
        precondition(!ready && peerBuilds.last == 0)
        bridge.consume("WKCLIP_STATUS READY mac\n")
        precondition(ready && !canWithdrawSetup(connected: ready, peerBuild: peerBuilds.last!))
        print("CLIPBOARD_GUI_PEER_VERSION_PASS split=true bounded=true old_peer_keeps_setup=true disconnect_resets=true")
        let pipe = Pipe()
        prepareWriter(pipe)
        var full = false
        for _ in 0..<16384 {
            if !writeLine("CLIPBOARD CANCEL 0", to: pipe) { full = true; break }
        }
        precondition(full, "pipe must fail promptly when the child is not reading")
        try? pipe.fileHandleForReading.close()
        precondition(!writeLine("CLIPBOARD CANCEL 0", to: pipe), "closed pipe must not kill GUI")
        bridge.consume("WKCLIP_STATUS PEER_VERSION 8\n")
        bridge.stop()
        precondition(!ready && peerBuilds.last == 0)
        precondition(!FileManager.default.fileExists(atPath: parent.path))
        print("CLIPBOARD_GUI_BRIDGE_PASS private_directory=true split_lines=true token=true nonblocking=true broken_pipe=true")
    }
}
