import AppKit
import Darwin

// WKC3/WKF3 deliberately cannot handshake with the old eager-sync component.
// UART and USB still carry the same opaque 64-byte reports; no firmware change.
final class WKCompanion: NSObject, NSMenuDelegate {
    static let magic = Data("WKC3".utf8)
    static let fileMagic = Data("WKF3".utf8)
    static let build: UInt32 = 12
    static let pasteLifetime: Double = 180
    let link: WKLink
    let bulkLink = WKLink(wireMagic: fileMagic)
    let clipboard: WKClipboard
    let transport: WKTransport
    let role: String
    private let portal: WKFilePortalServing?
    private let stream: WKStreamFiles?
    private let pixelScrollEnabled: Bool
    private let scrollHost = WKScrollHost()
    private let scrollReceiver = WKScrollReceiver()
    private let gestureReceiver = WKGestureReceiver()
    private var scrollWasReady = false
    private var lastGestureCount: UInt32 = 0
    private var gestureCountLoggedAt: Double = -10
    private var streamSources: [String: WKStreamSource] = [:]
    private var streamIncoming: [String: WKStreamOffer] = [:]
    private var preparing: (nonce: String, revision: Int)?
    private var streamResponse: WKStreamSource?
    private var pendingStreamDiagnostic: String?
    private var imageJob: WKStreamFiles.ImageJob?
    private var decodedImage: (id: String, image: WKBulkImage)?
    private var imageReady: WKMessage?
    private var peerBulkImages = false
#if WK_TREE
    private var treeJob: WKTreeJob?
    private var offeredTreeURLs: [String: [URL]] = [:]
    private var collectionReady = Set<String>(), completedCollections = Set<String>()
    private var protocolBuild: UInt32 { stream == nil ? Self.build : 15 }
#else
    private var protocolBuild: UInt32 { stream == nil ? Self.build : 14 }
#endif
    private let clock: () -> Double
    private var revision: Int
    private var counter = UInt64.random(in: 1...UInt64(UInt32.max))
    private var localState = "0"
    private var localSource = "0"
    private var remoteState = "0"
    private var remoteSource = "0"
    private var lastAdvertisement: Double = -10
    private var portalReady = false
    private var bulkPhysical = false
    private var timer: Timer?
    private var signals: [DispatchSourceSignal] = []
    private var stdinBuffer = Data()
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenuItem?
    private let fnKey = WKFnKey()
    private var setupLease: WKSetupLease?
    private struct Paste {
        let token: String, id: String, source: String, direction: String
        let revision: Int, deadline: Double
    }
    private struct Lease {
        let id: String, revision: Int, deadline: Double
        var staged: WKMessage?
        var fileID: String?
    }
    private struct Request: Codable { let source: String, destination: String }
    private enum Purpose { case prepare(String), content(String), commit(String), offer(String, String), streamOffer(String, String), cancel }
    private var lastFinishedToken: String?
    private var paste: Paste?
    private var lease: Lease?
    private var response: WKMessage?
    private var purposes: [UInt32: Purpose] = [:]
    private var committed: (id: String, revision: Int)?
    private var outgoingFiles: [String: WKMessage] = [:]
    private var incomingFiles: [String: WKFileOffer] = [:]
    private var bulkQueue: [String] = []
    private var bulkPurposes: [UInt32: String] = [:]
    private var appliedFileID: String?
    var reply: (String) -> Void = wkReply
    var log: (String) -> Void = wkLog
    var receivedCount = 0
    // Production injects identity-bound discovery. Offline fixtures inject a
    // fixed rate; the coordinator never enumerates devices on its own.
    var usbLinkRateProvider: (() -> WKUSBDiscovery.Rate)?
    private var usbLinkRate: WKUSBDiscovery.Rate?
    private var usbRateAnnouncements = 0
    private var usbRateAnnouncedAt: Double = -10
    private var peerUSBRate: WKUSBDiscovery.Rate?
    private static func usbRate(_ report: WKReport) -> WKUSBDiscovery.Rate? {
        guard report.kind == .pong, report.flags == 0x40, report.sequence == 0, report.transfer == 0,
              report.payload.count == 6, report.payload.prefix(5) == Data([0x57,0x4b,0x55,0x53,1]) else { return nil }
        return WKUSBDiscovery.Rate(rawValue: report.payload[5])
    }

    init(role: String, clipboard: WKClipboard, transport: WKTransport,
         link: WKLink = WKLink(wireMagic: WKCompanion.magic), portal: WKFilePortalServing? = nil,
         stream: WKStreamFiles? = nil,
         pixelScrollEnabled: Bool = false,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.role = role; self.clipboard = clipboard; self.transport = transport
        self.link = link; self.portal = portal; self.stream = stream; self.clock = clock
        self.pixelScrollEnabled = pixelScrollEnabled
        revision = clipboard.changeCount
        super.init()
#if !WK_PORTABLE
        if pixelScrollEnabled && stream != nil { setupLease = WKSetupLease(role: role) { [weak transport] bytes in
            if let unix = transport as? WKUnixTransport { return unix.sendRealtime(bytes) }
            return transport?.send(bytes) ?? false
        } }
#endif
        scrollHost.sendReport = { [weak transport] data in
            if let unix = transport as? WKUnixTransport { return unix.sendRealtime(data) }
            return transport?.send(data) ?? false
        }
        scrollReceiver.onScroll = { [weak self] in self?.fnKey.cancelTap() }
        gestureReceiver.onGesture = { [weak self] in self?.fnKey.cancelTap() }
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        scrollReceiver.gesturesSupported = (13...26).contains(os)
        scrollReceiver.gestureCount = { [weak self] in self?.gestureReceiver.submitted ?? 0 }
        scrollReceiver.gestureTemplateAcks = { [weak self] in self?.gestureReceiver.templateAcks ?? (0, 0, 0) }
        localState = next()
        link.sendReport = { [weak transport] in transport?.send($0) ?? false }
        link.receiveMessage = { [weak self] in self?.receive($0) ?? false }
        link.revalidateMessage = { [weak self] data in
            guard let self, let item = try? WKMessage.decode(data), item.kind == "commit" else { return nil }
            return self.committed?.id == item.nonce && self.committed?.revision == self.clipboard.changeCount
        }
        link.onCompletion = { [weak self] in self?.completed($0, $1) }
        link.onReady = { [weak self] in self?.connectionChanged($0) }
        link.onError = { [weak self] in self?.status("ERROR \($0)") }
        link.onProgress = { [weak self] in self?.progress($0, bulk: false) }
        bulkLink.sendReport = { [weak transport] in transport?.send($0) ?? false }
        bulkLink.receiveMessage = { [weak self] in self?.receiveFile($0) ?? false }
        bulkLink.onCompletion = { [weak self] id, accepted in
            guard let self, let file = self.bulkPurposes.removeValue(forKey: id) else { return }
            self.outgoingFiles.removeValue(forKey: file)
            self.status(accepted ? "TRANSFER complete" : "ERROR transfer-rejected-or-interrupted")
        }
        bulkLink.onReady = { [weak self] ready in if !ready { self?.failFiles() } }
        bulkLink.onError = { [weak self] _ in self?.failIncomingFiles() }
        bulkLink.onProgress = { [weak self] in self?.progress($0, bulk: true) }
        transport.onReport = { [weak self] data in self?.report(data) }
        transport.onConnection = { [weak self] ready in
            guard let self else { return }
            if self.role != "host" { self.fnKey.connection(ready) }
            if self.pixelScrollEnabled {
                if self.role == "host" { self.scrollHost.disconnected() }
                else {
                    self.scrollReceiver.connection(ready)
                    self.gestureReceiver.connection(ready, session: self.scrollReceiver.session)
                }
            }
            self.link.connected(ready, at: self.clock())
        }
        transport.onError = { [weak self] in self?.status("ERROR \($0)") }
        stream?.onControl = { [weak self] data in
            guard let self else { return }
            if let unix = self.transport as? WKUnixTransport { _ = unix.sendRealtime(data) }
            else { _ = self.transport.send(data) }
        }
        stream?.onDiagnostic = { [weak self] code in
            guard let self, self.role == "target", WKMetadata.safeCode(code) else { return }
            self.pendingStreamDiagnostic = code // one bounded, payload-free peer error
        }
        stream?.onProgress = { [weak self] id, done, total in
            guard let self, let offer = self.streamSources[id]?.offer ?? self.streamIncoming[id] else { return }
            let event = self.streamSources[id] != nil ? "BULK_TX" : "BULK_RX"
            if let line = WKMetadata.line(role: self.role, event: event, fields: ["phase":"PROGRESS", "transfer":String(offer.generation),
                "acked":String(done), "total":String(total), "nonce":offer.nonce]) { self.log(line) }
        }
        stream?.onFile = { [weak self] id, file in
            guard let self, let offer = self.streamIncoming.removeValue(forKey: id) else { return }
            if let line=WKMetadata.line(role:self.role,event:"BULK_RX",fields:["phase":"COMPLETE","acked":String(file.size),"total":String(file.size),"transfer":String(offer.generation),"nonce":offer.nonce]){self.log(line)}
            if offer.kind == "png" {
                guard self.lease?.id == offer.nonce, self.lease?.fileID == id else { return }
                self.imageJob = self.stream?.decodeImage(file: file) { [weak self] result in
                    guard let self, let l = self.lease, l.id == offer.nonce, l.fileID == id,
                          self.clipboard.changeCount == l.revision else { return }
                    self.imageJob = nil
                    switch result {
                    case .success(let image):
                        self.decodedImage = (id, image)
                        if self.role == "target" { self.imageReady = WKMessage(kind: "stream-ready", nonce: offer.nonce, body: Data(id.utf8)) }
                    case .failure: self.discardLease(); self.notifyCancel(offer.nonce); self.status("ERROR bulk-image-decode-failed")
                    }
                }
                return
            }
            do { try self.portal?.fulfill(id: id, file: file) }
            catch { self.portal?.fail(id: id); self.status("ERROR stream-file-publish-failed") }
        }
#if WK_TREE
        stream?.onManifest = { [weak self] id, manifest in
            guard let self, let offer = self.streamIncoming[id], offer.kind == "collection",
                  let lease = self.lease, lease.id == offer.nonce, lease.fileID == id,
                  self.clipboard.changeCount == lease.revision, let portal = self.portal else { return }
            do {
                self.offeredTreeURLs[id] = try portal.offerTree(offer, manifest: manifest)
                if self.role == "target" { self.imageReady = WKMessage(kind: "stream-ready", nonce: offer.nonce, body: Data(id.utf8)) }
            } catch { self.discardLease(); self.notifyCancel(offer.nonce); self.status("ERROR collection-publish-failed") }
        }
#endif
        stream?.onFailure = { [weak self] id in
            guard let self else { return }
            if let source = self.streamSources.removeValue(forKey: id), ["png", "collection"].contains(source.offer.kind) {
                if self.paste?.id == source.offer.nonce { self.cancelPaste(notifyPeer: true) }
                else { self.notifyCancel(source.offer.nonce) }
            }
            if let offer = self.streamIncoming.removeValue(forKey: id) {
                if offer.kind != "png" { self.portal?.fail(id: id) }
                if self.lease?.fileID == id { self.discardLease(); self.cancelPaste(notifyPeer: true); self.notifyCancel(offer.nonce) }
            }
#if WK_TREE
            self.collectionReady.remove(id); self.completedCollections.remove(id)
#endif
            self.status("ERROR stream-file-interrupted")
        }
        stream?.onComplete = { [weak self] id in
            guard let self else { return }
            if let offer=self.streamSources[id]?.offer,
               let line=WKMetadata.line(role:self.role,event:"BULK_TX",fields:["phase":"COMPLETE","acked":String(offer.size),"total":String(offer.size),"transfer":String(offer.generation),"nonce":offer.nonce]){self.log(line)}
#if WK_TREE
            if self.role == "host", self.streamSources[id]?.offer.kind == "collection" {
                if self.collectionReady.remove(id) != nil { self.streamSources.removeValue(forKey: id) }
                else { self.completedCollections.insert(id) }
                return
            }
#endif
            if self.streamSources[id]?.offer.kind != "png" || self.role != "host" { self.streamSources.removeValue(forKey: id) }
        }
    }

    private func next() -> String { counter &+= 1; return String(counter) }
    private func status(_ value: String) {
        if value.hasPrefix("ERROR "), let line = WKMetadata.line(role: role, event: "ERROR",
            fields: ["code": String(value.dropFirst(6))]) { log(line) }
        log("WKCLIP_STATUS " + value)
        statusMenu?.title = "WiredKVM 剪贴板：" + (value.hasPrefix("READY") ? "有线连接 · 按需粘贴" : value)
    }
    private func progress(_ value: WKTransferProgress, bulk: Bool) {
        if let line = WKMetadata.line(role: role, event: (bulk ? "FILE_" : "") + value.direction.rawValue,
            fields: ["phase": value.phase.rawValue, "transfer": String(value.transfer),
                     "acked": String(value.acknowledged), "total": value.total.map(String.init) ?? "unknown"]) { log(line) }
    }
    func start(headless: Bool) {
        if !headless {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.button?.title = "⇄"
            let menu = NSMenu(); menu.delegate = self; statusMenu = NSMenuItem(title: "WiredKVM 剪贴板：等待连线", action: nil, keyEquivalent: "")
            menu.addItem(statusMenu!); menu.addItem(.separator())
            if pixelScrollEnabled && role != "host" {
                let scrollItem = NSMenuItem(title: "启用平滑滚动与多指手势…", action: #selector(requestScrollAccess), keyEquivalent: "")
                scrollItem.target = self; menu.addItem(scrollItem); menu.addItem(.separator())
            }
#if WK_PORTABLE
            menu.insertItem(NSMenuItem(title: "临时运行 · 不安装 · 不设开机启动", action: nil, keyEquivalent: ""), at: 0)
            let item = NSMenuItem(title: "结束 WiredKVM 临时会话", action: #selector(quit), keyEquivalent: "q")
#else
            let item = NSMenuItem(title: "退出 WiredKVM 剪贴板", action: #selector(quit), keyEquivalent: "q")
            if role == "target" {
                let setup = NSMenuItem(title: "首次设置与权限检查…", action: #selector(showFirstRun), keyEquivalent: "")
                setup.target = self; menu.addItem(setup)
                let login = NSMenuItem(title: "登录时自动运行", action: #selector(toggleLogin), keyEquivalent: "")
                login.target = self; menu.addItem(login)
            }
#endif
            item.target = self; menu.addItem(item); statusItem?.menu = menu
        }
        if role == "host" { _ = fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK) }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.quit() }; source.resume(); signals.append(source)
        }
        startPortal(); stream?.start(); transport.start()
        if pixelScrollEnabled && role == "host" { scrollHost.start() }
        if pixelScrollEnabled && role != "host" && !headless {
#if !WK_PORTABLE
            // Request once after Launch Services has entered the application's
            // runloop. Installation/launch must not wait on the permission UI.
            let key = "WiredKVMPixelScrollPermissionAskedV1"
            if !UserDefaults.standard.bool(forKey: key) {
                UserDefaults.standard.set(true, forKey: key)
                DispatchQueue.main.async { [weak self] in self?.requestScrollAccess() }
            }
#endif
            // Portable sessions request permissions only from the visible
            // menu action. They do not write the installed app's defaults.
        }
        timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            guard let self else { return }; self.readCommands(); self.tick(self.clock())
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    @objc func quit() {
        stop { NSApplication.shared.terminate(nil) }
    }
    func stop(completion: @escaping () -> Void) {
        timer?.invalidate(); timer = nil; gestureReceiver.cancel(); scrollHost.stop(); transport.stop(); stream?.stop()
        for source in signals { source.cancel() }; signals.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }; statusItem = nil
        if let portal { portal.stop(completion: completion) } else { completion() }
    }
#if !WK_PORTABLE
    @objc private func toggleLogin() {
        Task { @MainActor in
            do { try WKLoginItem.setEnabled(!WKLoginItem.isEnabled) }
            catch { self.status("ERROR login-item-failed") }
        }
    }
    @objc private func showFirstRun() {
        Task { @MainActor in WKFirstRunWindow.shared(role: "target").show() }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        Task { @MainActor in
            for item in menu.items where item.action == #selector(self.toggleLogin) {
                item.state = WKLoginItem.isEnabled ? .on : .off
            }
        }
    }
#endif
    @objc private func requestScrollAccess() {
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
    }
    func startPortal() {
        portal?.start { [weak self] result in
            guard let self else { return }
            if case .success = result { self.portalReady = true }
            else { self.status("ERROR file-portal-unavailable") }
            self.updateBulk()
        }
    }
    private func updateBulk() {
        let enabled = portalReady && link.ready
        if enabled != bulkPhysical { bulkPhysical = enabled; bulkLink.connected(enabled, at: clock()) }
    }
    private func connectionChanged(_ ready: Bool) {
        usbLinkRate = ready ? usbLinkRateProvider?() : nil
        usbRateAnnouncements = 0; usbRateAnnouncedAt = -10; peerUSBRate = nil
        if let rate = usbLinkRate,
           let line = WKMetadata.line(role: role, event: "TRANSPORT", fields: ["phase":"RESULT","usbMbps":rate.mbps]) { log(line) }
        pendingStreamDiagnostic = nil
        preparing = nil; streamResponse = nil; lastFinishedToken = nil; peerBulkImages = false; imageJob?.cancel(); imageJob = nil; imageReady = nil; decodedImage = nil
        stream?.setEpoch(ready ? (link.session ^ link.peerSession) : 0)
        cancelPaste(notifyPeer: false); discardLease(); response = nil; purposes.removeAll()
        committed = nil; remoteState = "0"; remoteSource = "0"; localSource = "0"
        revision = clipboard.changeCount; localState = next(); lastAdvertisement = -10
        if role == "host" { reply("WKCLIP_RESET 0"); log("WKCLIP_STATUS PEER_VERSION 0") }
        if !ready { failFiles() }
        updateBulk(); status(ready ? "READY \(role)" : "DISCONNECTED")
    }
    private func report(_ data: Data) {
        if stream != nil, let control = WKBulkControl(data) {
            guard link.ready, control.epoch == (link.session ^ link.peerSession) else { return }
            if control.kind == .pasteCancel {
                let nonce = String(control.generation)
                if committed?.id == nonce { status("TRANSFER already-completed " + nonce) }
                else if paste?.id == nonce { cancelPaste(notifyPeer: false) }
                else { cancelTransaction(nonce) }
                return
            }
            stream?.control(data); return
        }
        if pixelScrollEnabled {
            if role == "host", scrollHost.receive(data) { return }
            if role != "host", gestureReceiver.receive(data) { return }
            if role != "host", scrollReceiver.receive(data) { return }
        }
        if role != "host", fnKey.receive(data, at: clock()) { return }
        if data.prefix(4) == Self.fileMagic { bulkLink.receive(data, at: clock()); return }
        link.receive(data, at: clock())
        if link.ready, let report = WKReport(data, wireMagic: Self.magic), report.session == link.peerSession,
           let rate = Self.usbRate(report) {
            if role == "host", rate != peerUSBRate,
               let line = WKMetadata.line(role: "target", event: "TRANSPORT", fields: ["phase":"RESULT","usbMbps":rate.mbps]) { log(line) }
            peerUSBRate = rate; return
        }
        guard link.ready, let report = WKReport(data, wireMagic: Self.magic), report.kind == .ping,
              report.session == link.peerSession, report.payload.count == (stream == nil ? 24 : 32),
              report.payload.prefix(4) == Data("WKOD".utf8) else { return }
        let build: UInt32 = report.payload.readLE(at: 4)
        guard build == protocolBuild else { peerBulkImages = false; return }
        if stream != nil {
            peerBulkImages = (report.payload.readLE(at: 24) as UInt32 == UInt32(WKStreamOffer.maximumImage)) &&
                (report.payload.readLE(at: 28) as UInt32 == 5)
            guard peerBulkImages else { return }
        }
        let state = String(report.payload.readLE(at: 8) as UInt64)
        let source = String(report.payload.readLE(at: 16) as UInt64)
        guard state != "0" else { return }
        let changed = source != remoteSource
        remoteState = state; remoteSource = source
        if role == "host" {
            log("WKCLIP_STATUS PEER_VERSION \(build)")
            reply("WKCLIP_LINK 1")
            if changed && source != "0" { reply("WKCLIP_ORIGIN IN \(source)") }
            if let p = paste, p.direction == "IN", source != p.source { cancelPaste(notifyPeer: true) }
        }
    }
    func tick(_ now: Double) {
        if pixelScrollEnabled {
            if role == "host" {
                scrollHost.tick()
                if scrollHost.ready != scrollWasReady {
                    scrollWasReady = scrollHost.ready
                    log("WKCLIP_DIAG role=host event=PIXEL_SCROLL_READY ready=\(scrollWasReady ? 1 : 0)")
                }
                if scrollHost.peerGesturesSubmitted != lastGestureCount && now - gestureCountLoggedAt >= 1 {
                    lastGestureCount = scrollHost.peerGesturesSubmitted; gestureCountLoggedAt = now
                    log("WKCLIP_DIAG role=host event=GESTURE_PEER_SUBMITTED accepted=\(lastGestureCount)")
                }
            }
            else {
                gestureReceiver.tick()
                scrollReceiver.tick { [weak transport] in transport?.send($0) ?? false }
            }
        }
        if role != "host" { fnKey.tick(now) }
        transport.tick(now); setupLease?.tick(now); pollClipboard(now)
        link.tick(now); bulkLink.tick(now)
        // A bounded extension of pong; older peers treat it as a keepalive.
        // No extra content transaction or image/file bytes enter this channel.
        if link.ready, let rate = usbLinkRate, usbRateAnnouncements < 3, now-usbRateAnnouncedAt >= 1,
           transport.send(WKReport(kind: .pong, flags: 0x40, session: link.session, payload: Data([0x57,0x4b,0x55,0x53,1,rate.rawValue])).encode(wireMagic: Self.magic)) {
            usbRateAnnouncements += 1; usbRateAnnouncedAt = now
        }
        if portalReady && portal?.isAvailable != true { portalReady = false; updateBulk(); failIncomingFiles() }
        if link.ready && now - lastAdvertisement >= 0.15 {
            var payload = Data("WKOD".utf8); payload.appendLE(protocolBuild)
            payload.appendLE(UInt64(localState)!); payload.appendLE(UInt64(localSource)!)
            if stream != nil { payload.appendLE(UInt32(WKStreamOffer.maximumImage)); payload.appendLE(UInt32(5)) }
            if transport.send(WKReport(kind: .ping, session: link.session, payload: payload).encode(wireMagic: Self.magic)) {
                lastAdvertisement = now
            }
        }
        if let p = paste, now >= p.deadline { cancelPaste(notifyPeer: true) }
        if let l = lease, now >= l.deadline { discardLease() }
        if let code = pendingStreamDiagnostic, link.ready, !link.transmitting {
            if let bytes = try? WKMessage(kind: "stream-diagnostic", nonce: "1", body: Data(code.utf8)).encoded(),
               link.send(bytes) != nil { pendingStreamDiagnostic = nil }
        }
        if let item = response, !link.transmitting { response = nil; sendContent(item) }
        if let ready = imageReady, !link.transmitting {
            if let data = try? ready.encoded(), link.send(data) != nil { imageReady = nil }
        }
        if let source = streamResponse, !link.transmitting {
            streamResponse = nil
            do {
                let item = WKMessage(kind: "stream-offer", nonce: source.offer.nonce, body: try source.offer.encoded())
                guard let id = link.send(try item.encoded()) else { throw WKStreamError.disconnected }
                streamSources[source.offer.id] = source; purposes[id] = .streamOffer(source.offer.id, source.offer.nonce)
            } catch { cancelPaste(notifyPeer: true); status("ERROR stream-offer-failed") }
        }
        // IN data is staged by the transport callback, then committed only on
        // this main-thread turn after the current local revision is checked.
        if let p = paste, p.direction == "IN", lease?.staged != nil, leaseCanCommit {
            if commit(p.id) { finishPaste(p) } else { cancelPaste(notifyPeer: true) }
        }
        pumpFiles()
    }
    func pollClipboard(_ now: Double) {
        let current = clipboard.changeCount
        guard current != revision else { return }
        revision = current; committed = nil
        if stream != nil {
            imageJob?.cancel(); imageJob = nil
#if WK_TREE
            treeJob?.cancel(); treeJob = nil
#endif
            for (id, source) in streamSources where source.offer.kind == "png" { stream?.cancel(id); streamSources.removeValue(forKey: id) }
        }
        cancelPaste(notifyPeer: true); discardLease(); response = nil; preparing = nil; streamResponse?.cancel(); streamResponse = nil
        localState = next(); localSource = localState; lastAdvertisement = -10
        if let id = appliedFileID { portal?.retire(id: id); appliedFileID = nil }
        // Only origin/version metadata leaves this function. No content reads.
        if role == "host" { reply("WKCLIP_ORIGIN OUT \(localSource)") }
        if let line = WKMetadata.line(role: role, event: "COPY",
            fields: ["direction": role == "host" ? "OUT" : "IN", "nonce": localSource, "revision": String(revision)]) { log(line) }
    }
    private func readCommands() {
        guard role == "host" else { return }
        var bytes = [UInt8](repeating: 0, count: 1024)
        for _ in 0..<4 {
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 { quit(); return }; if count < 0 { break }
            stdinBuffer.append(contentsOf: bytes.prefix(count))
            if stdinBuffer.count > 8192 { stdinBuffer.removeAll(); cancelPaste(notifyPeer: true); return }
            while let end = stdinBuffer.firstIndex(of: 10) {
                let line = String(decoding: stdinBuffer[..<end], as: UTF8.self)
                stdinBuffer.removeSubrange(...end); command(line)
            }
        }
    }
    func command(_ line: String) {
        guard role == "host" else { return }
        let w = line.split(separator: " ").map(String.init)
        if w.count == 2 && w[0] == "CANCEL" {
            if w[1] == lastFinishedToken { status("TRANSFER already-completed " + w[1]); return }
            if w[1] == "0" || w[1] == paste?.token { cancelPaste(notifyPeer: true) }; return
        }
        // Copy is already being delivered natively by capture. Never arm/replay
        // it, and never read its contents. Revision polling supplies provenance.
        if w.first == "COPY" { return }
        guard w.count == 3, w[0] == "PASTE", ["IN", "OUT"].contains(w[1]) else { return }
        let token = w[2], parts = token.split(separator: ".").map(String.init)
        guard parts.count == 2, parts.allSatisfy(WKMessage.validNonce), !parts.contains("0") else { return }
        pollClipboard(clock())
        if paste?.token == token { return } // same V intent: do not restart or reset deadline
        cancelPaste(notifyPeer: true)
        guard link.ready, remoteState != "0", !link.transmitting,
              parts[0] == (w[1] == "OUT" ? localSource : remoteSource) else {
            reply("WKCLIP_PASTE BLOCK \(token)"); return
        }
        let p = Paste(token: token, id: parts[1], source: parts[0], direction: w[1],
                      revision: revision, deadline: clock() + Self.pasteLifetime)
        paste = p
        if p.direction == "IN" { lease = Lease(id: p.id, revision: revision, deadline: p.deadline) }
        let request = Request(source: p.source, destination: remoteState)
        do {
            let data = try JSONEncoder().encode(request)
            guard let id = link.send(try WKMessage(kind: p.direction == "OUT" ? "prepare" : "pull", nonce: p.id, body: data).encoded()) else {
                cancelPaste(notifyPeer: false); return
            }
            purposes[id] = .prepare(p.id)
            status("TRANSFER requested \(p.id)")
        } catch { cancelPaste(notifyPeer: false) }
    }
    private func cancelPaste(notifyPeer: Bool) {
        guard let p = paste else { return }
        paste = nil; reply("WKCLIP_PASTE BLOCK \(p.token)")
        if lease?.id == p.id { discardLease() }
        cancelTransaction(p.id)
        if stream != nil {
            // Clear the obsolete metadata sender, then use a priority control
            // record. A new V can start immediately; no cancel message body wait.
            link.cancelOutgoing()
            if notifyPeer { notifyCancel(p.id) }
            return
        }
        if notifyPeer, link.ready, let data = try? WKMessage(kind: "cancel", nonce: p.id).encoded(), let id = link.send(data) {
            purposes[id] = .cancel
        }
    }
    private func notifyCancel(_ nonce: String) {
        guard stream != nil, link.ready, let value = UInt64(nonce) else { return }
        let c = WKBulkControl(kind: .pasteCancel, origin: role == "host" ? 0 : 1,
            epoch: link.session ^ link.peerSession, generation: value)
        if let unix = transport as? WKUnixTransport { _ = unix.sendRealtime(c.encode()) }
        else { _ = transport.send(c.encode()) }
    }
    private func finishPaste(_ p: Paste) {
        guard paste?.token == p.token else { return }
        paste = nil; lastFinishedToken = p.token; reply("WKCLIP_PASTE READY \(p.token)")
        let pending=streamSources.values.contains{$0.offer.nonce==p.id&&$0.offer.kind != "png"} || streamIncoming.values.contains{$0.nonce==p.id&&$0.kind != "png"}
        status("TRANSFER \(pending ? "file-in-progress" : "complete") \(p.id)")
    }
    private func cancelTransaction(_ nonce: String) {
        if lease?.id == nonce { discardLease() }
        if preparing?.nonce == nonce {
            preparing = nil; imageJob?.cancel(); imageJob = nil
#if WK_TREE
            treeJob?.cancel(); treeJob = nil
#endif
        }
        if response?.nonce == nonce { response = nil }
        if streamResponse?.offer.nonce == nonce { streamResponse?.cancel(); streamResponse = nil }
        if imageReady?.nonce == nonce { imageReady = nil }
        for (id, source) in streamSources where source.offer.nonce == nonce {
            stream?.cancel(id); streamSources.removeValue(forKey: id)
#if WK_TREE
            collectionReady.remove(id); completedCollections.remove(id)
#endif
        }
    }
    private var leaseCanCommit: Bool {
        guard let l = lease, let item = l.staged else { return false }
        if item.kind == "stream-offer", let offer = try? WKStreamOffer.decode(item.body), offer.kind == "png" {
            return decodedImage?.id == offer.id
        }
#if WK_TREE
        if item.kind == "stream-offer", let offer = try? WKStreamOffer.decode(item.body), offer.kind == "collection" {
            return offeredTreeURLs[offer.id] != nil
        }
#endif
        return true
    }
    private func discardLease() {
        imageJob?.cancel(); imageJob = nil; decodedImage = nil; imageReady = nil
        if let id = lease?.fileID {
            portal?.fail(id: id); portal?.retire(id: id)
            incomingFiles.removeValue(forKey: id); offeredURLs.removeValue(forKey: id)
#if WK_TREE
            offeredTreeURLs.removeValue(forKey: id)
#endif
            if streamIncoming.removeValue(forKey: id) != nil { stream?.cancel(id) }
        }
        lease = nil
    }
    private func receive(_ data: Data) -> Bool {
        do {
            let item = try WKMessage.decode(data)
            guard item.nonce != "0" else { return false }
            if item.kind == "stream-diagnostic" {
                guard role == "host", let code = String(data: item.body, encoding: .utf8),
                      let line = WKMetadata.line(role: "target", event: "ERROR", fields: ["code": code]) else { return false }
                log(line); return true
            }
            if item.kind == "prepare" || item.kind == "pull" {
                guard role == "target" else { return false }
                pollClipboard(clock())
                let request = try JSONDecoder().decode(Request.self, from: item.body)
                guard request.destination == localState else { return false }
                discardLease(); imageJob?.cancel(); imageJob = nil; preparing = nil; streamResponse = nil; response = nil
                for (id, source) in streamSources where source.offer.kind == "png" {
                    stream?.cancel(id); streamSources.removeValue(forKey: id)
                }
                if item.kind == "prepare" {
                    lease = Lease(id: item.nonce, revision: revision, deadline: clock() + Self.pasteLifetime)
                } else {
                    guard request.source == localSource, localSource != "0" else { return false }
                    try prepareContent(item.nonce)
                }
                return true
            }
            if item.kind == "stream-ready" {
                guard role == "host", let id = String(data: item.body, encoding: .utf8),
                      let source = streamSources[id], ["png", "collection"].contains(source.offer.kind), source.offer.nonce == item.nonce,
                      paste?.id == item.nonce else { return false }
#if WK_TREE
                if source.offer.kind == "collection" {
                    if completedCollections.remove(id) != nil { streamSources.removeValue(forKey: id) }
                    else { collectionReady.insert(id) }
                } else { streamSources.removeValue(forKey: id) }
#else
                streamSources.removeValue(forKey: id)
#endif
                metadataCompleted(item.nonce, true); return true
            }
            if item.kind == "cancel" {
                if stream != nil { cancelTransaction(item.nonce) }
                if paste?.id == item.nonce { cancelPaste(notifyPeer: false) }
                if lease?.id == item.nonce { discardLease() }
                if response?.nonce == item.nonce { response = nil }
                if preparing?.nonce == item.nonce { preparing = nil }
                if streamResponse?.offer.nonce == item.nonce { streamResponse = nil }
                return true
            }
            if item.kind == "commit" { return role == "target" && commit(item.nonce) }
            guard var l = lease, l.id == item.nonce, l.revision == clipboard.changeCount,
                  clock() < l.deadline, l.staged == nil else { return false }
            if item.kind == "stream-offer" {
                guard let stream, stream.isReady, peerBulkImages, streamIncoming.count < 4 else { return false }
                let offer = try WKStreamOffer.decode(item.body)
                guard streamIncoming[offer.id] == nil else { return false }
                if offer.kind == "file" {
                    guard portalReady, let portal else { return false }
                    offeredURLs[offer.id] = try portal.offerStream(offer)
                }
                streamIncoming[offer.id] = offer; l.fileID = offer.id; stream.expect(offer)
            } else if stream != nil && ["png", "file", "file-offer"].contains(item.kind) { return false
            } else if item.kind == "file-offer" {
                guard portalReady, bulkLink.ready, let portal, incomingFiles.count < 8 else { return false }
                let offer = try WKFileOffer.decode(item.body)
                guard incomingFiles[offer.id] == nil else { return false }
                offeredURLs[offer.id] = try portal.offer(id: offer.id, name: offer.name, size: offer.size, sha256: offer.sha256)
                incomingFiles[offer.id] = offer; l.fileID = offer.id
            } else if !["text", "png", "file"].contains(item.kind) { return false }
            l.staged = item; lease = l; receivedCount += 1
            return true
        } catch { status("ERROR \(WKMetadata.errorCode(error))"); return false }
    }
    private func commit(_ id: String) -> Bool {
        guard leaseCanCommit, let l = lease, l.id == id, let item = l.staged,
              l.revision == clipboard.changeCount, clock() < l.deadline else { return false }
        do {
            if let image = decodedImage, image.id == l.fileID {
                try clipboard.applyBulkImage(image.image, expectedChangeCount: l.revision); decodedImage = nil
            } else if let fileID = l.fileID {
                // The URL has already been reserved; offer() is not called twice.
#if WK_TREE
                if let urls = offeredTreeURLs[fileID] { try clipboard.applyFileURLs(urls, expectedChangeCount: l.revision) }
                else {
                    guard let url = offeredURLs[fileID] else { return false }
                    try clipboard.applyFileURL(url, expectedChangeCount: l.revision)
                }
#else
                guard let url = offeredURLs[fileID] else { return false }
                try clipboard.applyFileURL(url, expectedChangeCount: l.revision)
#endif
                if let old = appliedFileID { self.portal?.retire(id: old) }; appliedFileID = fileID
            } else { _ = try clipboard.apply(item, expectedChangeCount: l.revision) }
            revision = clipboard.changeCount; localState = next(); localSource = "0"; lastAdvertisement = -10
            committed = (id, revision); lease = nil
            if let fileID = l.fileID { offeredURLs.removeValue(forKey: fileID) }
#if WK_TREE
            if let fileID = l.fileID { offeredTreeURLs.removeValue(forKey: fileID) }
#endif
            if let line = WKMetadata.line(role: role, event: "APPLY", fields: ["nonce": id, "revision": String(revision)]) { log(line) }
            return true
        } catch { status("ERROR \(WKMetadata.errorCode(error))"); discardLease(); return false }
    }
    private var offeredURLs: [String: URL] = [:]
    private func completed(_ id: UInt32, _ accepted: Bool) {
        guard let purpose = purposes.removeValue(forKey: id) else { return }
        switch purpose {
        case .prepare(let nonce):
            guard let p = paste, p.id == nonce else { return }
            guard accepted, p.revision == clipboard.changeCount else { cancelPaste(notifyPeer: true); return }
            if p.direction == "OUT" {
                do {
                    guard p.source == localSource else { throw WKClipboardError.invalid("unsupported-content") }
                    try prepareContent(nonce)
                } catch { cancelPaste(notifyPeer: true); status("ERROR \(WKMetadata.errorCode(error))") }
            }
        case .content(let nonce): metadataCompleted(nonce, accepted)
        case .offer(let file, let nonce):
            if accepted { bulkQueue.append(file) }
            else { outgoingFiles.removeValue(forKey: file) }
            metadataCompleted(nonce, accepted)
        case .streamOffer(let file, let nonce):
            if accepted, let source = streamSources[file] {
                stream?.send(source)
                if ["png", "collection"].contains(source.offer.kind) { return } // decoded image or verified manifest precedes commit
            } else { streamSources.removeValue(forKey: file); notifyCancel(nonce) }
            metadataCompleted(nonce, accepted)
        case .commit(let nonce):
            guard let p = paste, p.id == nonce else { return }
            if accepted && p.revision == clipboard.changeCount { finishPaste(p) }
            else { cancelPaste(notifyPeer: true) }
        case .cancel: break
        }
    }
    private func metadataCompleted(_ nonce: String, _ accepted: Bool) {
        guard role == "host", let p = paste, p.id == nonce else { return }
        guard accepted, p.revision == clipboard.changeCount,
              let data = try? WKMessage(kind: "commit", nonce: nonce).encoded(), let id = link.send(data) else {
            cancelPaste(notifyPeer: true); return
        }
        purposes[id] = .commit(nonce)
    }
    private func sendContent(_ item: WKMessage) {
        do {
            if stream != nil && ["png", "file"].contains(item.kind) { throw WKStreamError.invalid }
            if item.kind == "file", portalReady, bulkLink.ready, let name = item.name {
                guard outgoingFiles.count < 8 else { throw WKClipboardError.invalid("file-transfer-queue-full") }
                let offer = WKFileOffer(name: name, size: item.size, sha256: item.sha256, nonce: item.nonce)
                var body = item; body.fileID = offer.id
                let data = try WKMessage(kind: "file-offer", nonce: item.nonce, body: offer.encoded()).encoded()
                guard let id = link.send(data) else { throw WKClipboardError.invalid("file-portal-unavailable") }
                outgoingFiles[offer.id] = body; purposes[id] = .offer(offer.id, item.nonce)
            } else if let id = link.send(try item.encoded()) { purposes[id] = .content(item.nonce) }
        } catch { cancelPaste(notifyPeer: true); status("ERROR \(WKMetadata.errorCode(error))") }
    }
    private func prepareContent(_ nonce: String) throws {
#if WK_TREE
        let urls = try clipboard.selectedFileURLs()
        if let stream, !urls.isEmpty {
            guard portalReady, stream.isReady, streamSources.count < 4 else { throw WKStreamError.capacity }
            let captured = clipboard.changeCount; preparing = (nonce, captured); treeJob?.cancel()
            treeJob = stream.prepareSelection(urls: urls, nonce: nonce) { [weak self] result in
                guard let self, self.preparing?.nonce == nonce, self.preparing?.revision == captured,
                      self.clipboard.changeCount == captured, self.link.ready else {
                    if case .success(let source) = result { source.cancel() }; return
                }
                self.preparing = nil; self.treeJob = nil
                switch result {
                case .success(let source): self.streamResponse = source
                case .failure: self.cancelPaste(notifyPeer: true); self.notifyCancel(nonce); self.status("ERROR collection-source-unavailable")
                }
            }
            return
        }
#endif
        if let stream, let url = try clipboard.singleFileURL() {
            guard portalReady, stream.isReady, streamSources.count < 4 else { throw WKStreamError.capacity }
            let captured = clipboard.changeCount; preparing = (nonce, captured)
            stream.prepare(url: url, nonce: nonce) { [weak self] result in
                guard let self, self.preparing?.nonce == nonce, self.preparing?.revision == captured,
                      self.clipboard.changeCount == captured, self.link.ready else { return }
                self.preparing = nil
                switch result {
                case .success(let source): self.streamResponse = source
                case .failure:
                    self.cancelPaste(notifyPeer: true)
                    if let data = try? WKMessage(kind: "cancel", nonce: nonce).encoded(), let id = self.link.send(data) { self.purposes[id] = .cancel }
                    self.status("ERROR stream-source-unavailable")
                }
            }
        } else if let stream, clipboard.hasImage {
            guard peerBulkImages, stream.isReady else { throw WKStreamError.disconnected }
            let captured = clipboard.changeCount; preparing = (nonce, captured)
            imageJob?.cancel()
            imageJob = stream.prepareImage(clipboard: clipboard, revision: captured, nonce: nonce) { [weak self] result in
                guard let self, self.preparing?.nonce == nonce, self.preparing?.revision == captured,
                      self.clipboard.changeCount == captured, self.link.ready else { return }
                self.preparing = nil; self.imageJob = nil
                switch result {
                case .success(let source): self.streamResponse = source
                case .failure(let error): self.cancelPaste(notifyPeer: true); self.notifyCancel(nonce); self.status("ERROR \(WKMetadata.errorCode(error))")
                }
            }
        } else {
            guard let snapshot = try clipboard.snapshot(nonce: nonce) else { throw WKClipboardError.invalid("unsupported-content") }
            response = snapshot
        }
    }
    private func pumpFiles() {
        guard bulkLink.ready, !bulkLink.transmitting, !bulkQueue.isEmpty else { return }
        let id = bulkQueue.removeFirst()
        guard let item = outgoingFiles[id], let data = try? item.encodedBinary(), let transfer = bulkLink.send(data) else { return }
        bulkPurposes[transfer] = id
    }
    private func receiveFile(_ data: Data) -> Bool {
        do {
            let item = try WKMessage.decode(data)
            guard item.kind == "file", let id = item.fileID, let offer = incomingFiles[id], portalReady else { return false }
            guard item.nonce == offer.nonce, item.name == offer.name, item.size == offer.size,
                  item.sha256 == offer.sha256 else {
                portal?.fail(id: id); incomingFiles.removeValue(forKey: id)
                if lease?.fileID == id { discardLease() }
                return false
            }
            try portal?.fulfill(id: id, data: item.body)
            incomingFiles.removeValue(forKey: id)
            return true
        } catch { failIncomingFiles(); return false }
    }
    private func failIncomingFiles() {
        for id in streamIncoming.keys { portal?.fail(id: id); stream?.cancel(id) }
        streamIncoming.removeAll()
        for id in incomingFiles.keys { portal?.fail(id: id) }
        incomingFiles.removeAll(); offeredURLs.removeAll()
#if WK_TREE
        offeredTreeURLs.removeAll()
#endif
    }
    private func failFiles() {
#if WK_TREE
        treeJob?.cancel(); treeJob = nil
        collectionReady.removeAll(); completedCollections.removeAll()
#endif
        for id in streamSources.keys { stream?.cancel(id) }
        streamSources.removeAll(); preparing = nil; streamResponse = nil
        failIncomingFiles(); outgoingFiles.removeAll(); bulkQueue.removeAll(); bulkPurposes.removeAll()
    }
}
