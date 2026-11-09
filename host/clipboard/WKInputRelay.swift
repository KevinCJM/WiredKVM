import AppKit
import Darwin

// A separate runtime for native pointer input. It never creates a pasteboard,
// clipboard link, file portal, file stream, installer or clipboard command reader.
// Existing target companions advertise WKSC capabilities before clipboard pairing,
// so the host can use this mode without upgrading the target component.
final class WKInputRelay {
    enum Role: String { case host, target }
    let role: Role
    private let transport: WKTransport
    private let host: WKScrollHost
    private let scroll: WKScrollReceiver
    private let gestures: WKGestureReceiver
    private let clock: () -> Double
    private let log: (String) -> Void
    private var timer: Timer?
    private var signals: [DispatchSourceSignal] = []
    private(set) var running = false
    private var connected = false
    private var wasReady = false
    private var lastGestureCount: UInt32 = 0
    private var countLoggedAt = -Double.infinity
    private var lastError: String?
    var onTerminate: () -> Void = {}

    init(role: Role, transport: WKTransport,
         host: WKScrollHost = WKScrollHost(), scroll: WKScrollReceiver = WKScrollReceiver(),
         gestures: WKGestureReceiver = WKGestureReceiver(),
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         log: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
        self.role = role; self.transport = transport; self.host = host
        self.scroll = scroll; self.gestures = gestures; self.clock = clock; self.log = log
        host.sendReport = { [weak self] in self?.send($0) ?? false }
        scroll.gesturesSupported = (13...26).contains(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        scroll.gestureCount = { [weak gestures] in gestures?.submitted ?? 0 }
        scroll.gestureTemplateAcks = { [weak gestures] in gestures?.templateAcks ?? (0, 0, 0) }
        transport.onReport = { [weak self] in self?.receive($0) }
        transport.onConnection = { [weak self] in self?.connection($0) }
        transport.onError = { [weak self] code in
            guard let self, self.running else { return }
            // Transport errors are enums/numbers, never clipboard/file metadata.
            let prefixes = ["hid-access-denied-", "hid-device-open-denied-", "hid-write-failed-"]
            let named: Set<String> = ["invalid-private-socket-path", "socket-create-failed", "socket-nonblocking-failed"]
            let safe = named.contains(code) || prefixes.contains { prefix in
                code.hasPrefix(prefix) && Int64(code.dropFirst(prefix.count)) != nil
            }
            let value = safe ? code : "transport-error"
            if self.lastError != value { self.lastError = value; self.log("WKINPUT_ERROR role=\(self.role.rawValue) code=\(value)") }
        }
    }

    // Framing and CRC are checked before any input handler. Clipboard WKC1,
    // files WKF2, setup and Fn reports are deliberately outside this runtime.
    static func accepts(_ data: Data) -> Bool {
        guard data.count == 64 else { return false }
        if data.prefix(4) == WKScrollPacket.magic { return WKScrollPacket(data) != nil }
        guard data.prefix(4) == WKGestureEnvelope.wireMagic || data.prefix(4) == WKGestureEnvelope.compactMagic else { return false }
        let checksum = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[60 + $1]) << (8 * $1) }
        return checksum == WKScrollPacket.checksum(data.prefix(60))
    }

    func start(automaticTick: Bool = true, handleSignals: Bool = true) {
        guard !running else { return }; running = true
        if role == .host { host.start() }
        transport.start()
        if automaticTick {
            let next = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in self?.tick() }
            timer = next; RunLoop.main.add(next, forMode: .common)
        }
        if handleSignals {
            for number in [SIGTERM, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { [weak self] in
                    guard let self else { return }; self.stop(); self.onTerminate()
                }
                signals.append(source); source.resume()
            }
        }
        log("WKINPUT_STARTED role=\(role.rawValue) clipboard=0 files=0")
    }

    func stop() {
        guard running else { return }; running = false
        timer?.invalidate(); timer = nil
        signals.forEach { $0.cancel() }; signals.removeAll()
        host.disconnected(); host.stop()
        scroll.connection(false); gestures.connection(false, session: 0)
        connected = false; transport.stop()
        if wasReady { wasReady = false; log("WKCLIP_DIAG role=\(role.rawValue) event=PIXEL_SCROLL_READY ready=0") }
        log("WKINPUT_STOPPED role=\(role.rawValue)")
    }

    private func connection(_ ready: Bool) {
        guard running else { return }; connected = ready; lastError = nil
        host.disconnected()
        if role == .target {
            scroll.connection(ready); gestures.connection(ready, session: scroll.session)
        }
        log("WKINPUT_CONNECTION role=\(role.rawValue) ready=\(ready ? 1 : 0)")
    }

    private func send(_ data: Data) -> Bool {
        guard running, connected, Self.accepts(data) else { return false }
        if let unix = transport as? WKUnixTransport { return unix.sendRealtime(data) }
        return transport.send(data)
    }

    private func receive(_ data: Data) {
        guard running, connected, Self.accepts(data) else { return }
        if role == .host {
            // The target only sends capability/ack state for native input.
            guard let packet = WKScrollPacket(data), packet.kind == .capability else { return }
            _ = host.receive(data)
        } else {
            if gestures.receive(data) { return }
            _ = scroll.receive(data)
        }
    }

    func tick() {
        guard running else { return }
        let now = clock(); transport.tick(now)
        if role == .host {
            host.tick()
            if host.ready != wasReady {
                wasReady = host.ready
                log("WKCLIP_DIAG role=host event=PIXEL_SCROLL_READY ready=\(wasReady ? 1 : 0)")
            }
            if host.peerGesturesSubmitted != lastGestureCount && now - countLoggedAt >= 1 {
                lastGestureCount = host.peerGesturesSubmitted; countLoggedAt = now
                log("WKCLIP_DIAG role=host event=GESTURE_PEER_SUBMITTED accepted=\(lastGestureCount)")
            }
        } else {
            gestures.tick()
            scroll.tick { [weak self] in self?.send($0) ?? false }
        }
    }
    deinit { stop() }
}
