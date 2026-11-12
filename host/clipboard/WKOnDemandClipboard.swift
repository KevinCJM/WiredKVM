import AppKit
import Darwin

// WKC3/WKF3 deliberately cannot handshake with the old eager-sync component.
// UART and USB still carry the same opaque 64-byte reports; no firmware change.
final class WKCompanion: NSObject, NSMenuDelegate {
    static let magic = Data("WKC3".utf8)
    static let fileMagic = Data("WKF3".utf8)
    static let build: UInt32 = 16
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
    private var readiness: [WKMessage] = []
    private var peerBulkImages = false
    private let clipboardState = WKClipboardState()
    private struct Origin: Equatable { let side: UInt32; let session, stamp: UInt64 }
    private var localOrigin: Origin?
    private var peerMetadataReady = false
    private var lastRoute = ""
    private struct Decision {
        let id: UInt64, destination: UInt32, sequence: UInt64, revision: UInt64, focus: UInt64
        let deadline: Double
    }
    private var decision: Decision?
    private var highestIntentID: UInt64 = 0
    private var bundleResponse: WKStreamSource?
    private var decodedBundles: [String: WKClipboardBundle] = [:]
    private var preparedBundles: [String: WKClipboardBundle.Prepared] = [:]
    private var bundlePreparing = Set<String>()
    private var bundlePreparationJobs = 0
    private var requiredReady: [String: Set<String>] = [:]
    private var expectedPeerCommit: (id: UInt64, origin: Origin)?
    private var peerCommitReceipt: (id: UInt64, snapshot: WKClipboardState.Snapshot)?
    private struct Departure {
        let nonce: String, sequence: UInt64, focus: UInt64, session: UInt64, stamp: UInt64
        let bookRevision: Int
    }
    private var departure: Departure?
    private var metadataQuery: String?
    private var metadataResponse: WKMessage?
#if WK_TREE
    private var treeJob: WKTreeJob?
    private var offeredTreeURLs: [String: [URL]] = [:]
    private var collectionReady = Set<String>(), completedCollections = Set<String>()
    private var protocolBuild: UInt32 { Self.build }
#else
    private var protocolBuild: UInt32 { Self.build }
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
        var bundleID: String?
        var origin: Origin?
    }
    private struct Request: Codable {
        let source: String, destination: String, originalSide: String, originalSession: String, originalStamp: String
        var origin: Origin? {
            guard let side = UInt32(originalSide), side < 2, let session = UInt64(originalSession), session > 0,
                  let stamp = UInt64(originalStamp), stamp > 0 else { return nil }
            return Origin(side: side, session: session, stamp: stamp)
        }
    }
    private enum Purpose { case prepare(String), content(String), commit(String), offer(String, String), streamOffer(String, String), bundleMetadata(String, String), cancel }
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
    private var lastPortalCounts: [UInt32]?
    private var portalCountsSent = 0
    private var portalCountsSentAt: Double = -10
    private var peerPortalCounts: [UInt32]?
    private static let portalKeys = ["davMetadata", "davMissing", "davWaiting", "davServed", "davFailed", "davMalformed", "davCapacity", "davProxy"]
    private static func portalCounts(_ report: WKReport) -> [UInt32]? {
        guard report.kind == .pong, report.flags == 0x41, report.sequence == 0, report.transfer == 0,
              report.payload.count == 37, report.payload.prefix(5) == Data([0x57,0x4b,0x50,0x53,1]) else { return nil }
        return (0..<WKPortalCounters.count).map { report.payload.readLE(at: 5 + $0 * 4) }
    }
    private func logPortalCounts(_ counts: [UInt32], role: String) {
        guard counts.count == Self.portalKeys.count else { return }
        let fields = Dictionary(uniqueKeysWithValues: zip(Self.portalKeys, counts.map(String.init)))
        if let line = WKMetadata.line(role: role, event: "PORTAL", fields: fields) { log(line) }
    }
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
            if offer.kind == "clipboard-bundle" {
                guard self.lease?.id == offer.nonce, self.lease?.bundleID == id else { return }
                self.imageJob = self.stream?.decodeBundle(file: file) { [weak self] result in
                    guard let self, let lease = self.lease, lease.id == offer.nonce, lease.bundleID == id,
                          self.clipboard.changeCount == lease.revision else { return }
                    self.imageJob = nil
                    switch result {
                    case .success(let bundle): self.decodedBundles[id] = bundle; self.prepareDecodedBundle(id)
                    case .failure: self.discardLease(); self.notifyCancel(offer.nonce); self.status("ERROR bundle-decode-failed")
                    }
                }
                return
            }
            if offer.kind == "png" {
                guard self.lease?.id == offer.nonce, self.lease?.fileID == id else { return }
                self.imageJob = self.stream?.decodeImage(file: file) { [weak self] result in
                    guard let self, let l = self.lease, l.id == offer.nonce, l.fileID == id,
                          self.clipboard.changeCount == l.revision else { return }
                    self.imageJob = nil
                    switch result {
                    case .success(let image):
                        self.decodedImage = (id, image)
                        if self.role == "target" { self.queueReady(nonce: offer.nonce, id: id) }
                    case .failure: self.discardLease(); self.notifyCancel(offer.nonce); self.status("ERROR bulk-image-decode-failed")
                    }
                }
                return
            }
            do { try self.portal?.fulfill(id: id, file: file) }
            catch { self.portal?.fail(id: id); self.status("ERROR stream-file-publish-failed") }
        }
        stream?.onReceiving = { [weak self] id, receiving in
            guard let self, self.streamIncoming[id]?.kind == "file" else { return }
            do { try self.portal?.beginReceiving(id: id, file: receiving) }
            catch { receiving.fail(); self.portal?.fail(id: id) }
        }
#if WK_TREE
        stream?.onManifest = { [weak self] id, manifest in
            guard let self, let offer = self.streamIncoming[id], offer.kind == "collection",
                  let lease = self.lease, lease.id == offer.nonce, lease.fileID == id,
                  self.clipboard.changeCount == lease.revision, let portal = self.portal else { return }
            do {
                self.offeredTreeURLs[id] = try portal.offerTree(offer, manifest: manifest)
                if let bundleID = self.lease?.bundleID { self.prepareDecodedBundle(bundleID) }
                if self.role == "target" { self.queueReady(nonce: offer.nonce, id: id) }
            } catch { self.discardLease(); self.notifyCancel(offer.nonce); self.status("ERROR collection-publish-failed") }
        }
#endif
        stream?.onFailure = { [weak self] id in
            guard let self else { return }
            if let source = self.streamSources.removeValue(forKey: id), ["png", "collection", "clipboard-bundle"].contains(source.offer.kind) {
                if self.paste?.id == source.offer.nonce { self.cancelPaste(notifyPeer: true) }
                else { self.notifyCancel(source.offer.nonce) }
            }
            if let offer = self.streamIncoming.removeValue(forKey: id) {
                if !["png", "clipboard-bundle"].contains(offer.kind) { self.portal?.fail(id: id) }
                if self.lease?.fileID == id || self.lease?.bundleID == id { self.discardLease(); self.cancelPaste(notifyPeer: true); self.notifyCancel(offer.nonce) }
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
            if !["png", "clipboard-bundle"].contains(self.streamSources[id]?.offer.kind ?? "") || self.role != "host" { self.streamSources.removeValue(forKey: id) }
        }
    }

    private func next() -> String { counter &+= 1; return String(counter) }
    private var side: UInt32 { role == "host" ? 0 : 1 }
    private func origin(_ snapshot: WKClipboardState.Snapshot) -> Origin? {
        if snapshot.provenance == .local { return Origin(side: snapshot.side, session: snapshot.session, stamp: snapshot.stamp) }
        if snapshot.provenance == .received { return Origin(side: snapshot.originalSide, session: snapshot.originalSession, stamp: snapshot.originalStamp) }
        return nil
    }
    private func localSnapshot() -> WKClipboardState.Snapshot {
        WKClipboardState.Snapshot(side: side, session: link.session, stamp: UInt64(localState) ?? 0,
            revision: UInt64(max(0, revision)), provenance: localOrigin == nil ? .local : .received,
            originalSide: localOrigin?.side ?? 0, originalSession: localOrigin?.session ?? 0, originalStamp: localOrigin?.stamp ?? 0)
    }
    private func observeLocal(select: Bool = false) {
        guard link.ready else { return }
        _ = clipboardState.observe(localSnapshot(), selectSource: select)
        emitRoute()
    }
    private func emitRoute() {
        guard role == "host" else { return }
        let p = clipboardState.projection, book = clipboardState.snapshot(side: 0), mini = clipboardState.snapshot(side: 1)
        var nativeMask: UInt64 = 0
        for destination: UInt32 in [0, 1] {
            if p.selectedSide == nil || p.selectedSide == destination { nativeMask |= 1 << destination; continue }
            if !p.cutBlocked, let selected = p.selectedSide, let source = clipboardState.snapshot(side: selected),
               let target = clipboardState.snapshot(side: destination), let sourceOrigin = origin(source), origin(target) == sourceOrigin {
                nativeMask |= 1 << destination
            }
        }
        let fields: [UInt64] = [p.generation, p.appliedSequence, UInt64(p.selectedSide ?? 2),
            book?.stamp ?? 0, mini?.stamp ?? 0, book?.originalStamp ?? 0, mini?.originalStamp ?? 0,
            p.cutBlocked ? 1 : 0, nativeMask]
        let line = "WKCLIP_ROUTE " + fields.map(String.init).joined(separator: ",")
        if line != lastRoute { lastRoute = line; reply(line) }
    }
    private func metadataPayload() -> Data {
        let snapshot = localSnapshot()
        var bytes = Data("WKCV".utf8)
        bytes.appendLE(snapshot.stamp); bytes.appendLE(snapshot.revision)
        bytes.append(UInt8(snapshot.provenance.rawValue)); bytes.append(UInt8(snapshot.originalSide))
        bytes.appendLE(snapshot.originalSession); bytes.appendLE(snapshot.originalStamp)
        return bytes
    }
    private func receiveMetadata(_ report: WKReport, resolve: Bool = true) {
        guard report.flags == 0x42, report.kind == .pong, report.session == link.peerSession,
              report.sequence == 0, report.transfer == 0, report.payload.count == 38,
              report.payload.prefix(4) == Data("WKCV".utf8), peerMetadataReady,
              let provenance = WKClipboardState.Provenance(rawValue: UInt32(report.payload[20])) else { return }
        let stamp: UInt64 = report.payload.readLE(at: 4), observed: UInt64 = report.payload.readLE(at: 12)
        guard stamp == UInt64(remoteState) else { return }
        let snapshot = WKClipboardState.Snapshot(side: 1-side, session: link.peerSession, stamp: stamp, revision: observed,
            provenance: provenance, originalSide: UInt32(report.payload[21]),
            originalSession: report.payload.readLE(at: 22), originalStamp: report.payload.readLE(at: 30))
        let previous = clipboardState.snapshot(side: 1-side)
        let changed = previous != nil && previous?.stamp != stamp
        var ownCommit = peerCommitReceipt.map { $0.id == UInt64(paste?.id ?? "0") && $0.snapshot == snapshot } ?? false
        if let expected = expectedPeerCommit, origin(snapshot) == expected.origin {
            ownCommit = clipboardState.commit(id: expected.id, destinationSnapshot: snapshot)
            if ownCommit { expectedPeerCommit = nil; peerCommitReceipt = (expected.id, snapshot) }
        }
        if !ownCommit {
            guard clipboardState.observe(snapshot, selectSource: changed && provenance == .local && clipboardState.projection.contextSide == 1-side) else { return }
        }
        if role == "host" {
            reply("WKCLIP_LINK 1"); emitRoute()
            if !ownCommit, let p = paste, !clipboardState.active(UInt64(p.id) ?? 0) { cancelPaste(notifyPeer: true) }
            if resolve { resolveDecision() }
        }
    }
    private func resolveDecision() {
        guard role == "host", let d = decision else { return }
        if departure != nil, clock() < d.deadline { return }
        if departure != nil { departure = nil; clipboardState.abort(d.id); decision = nil; reply("WKCLIP_RESULT \(d.id) blocked"); return }
        if link.transmitting && clock() < d.deadline { return }
        let targetRevision = d.destination == 0 ? d.revision : (clipboardState.snapshot(side: 1)?.revision ?? 0)
        let plan = clipboardState.plan(id: d.id, destination: d.destination, minSequence: d.sequence,
                                      destinationRevision: targetRevision, focusEpoch: d.focus)
        if (plan.action == .refresh || (plan.action == .blocked && plan.reason == 6)), clock() < d.deadline { return }
        decision = nil
        if plan.action == .native { reply("WKCLIP_RESULT \(d.id) ready \(clipboard.changeCount)"); emitRoute(); return }
        guard plan.action == .transfer, link.ready, peerMetadataReady, !link.transmitting,
              let sourceOrigin = origin(plan.source) else {
            clipboardState.abort(d.id); reply("WKCLIP_RESULT \(d.id) blocked"); emitRoute(); return
        }
        let id = String(d.id), direction = d.destination == 1 ? "OUT" : "IN"
        let p = Paste(token: id, id: id, source: String(plan.source.stamp), direction: direction,
                      revision: revision, deadline: clock() + Self.pasteLifetime)
        paste = p
        if direction == "IN" { lease = Lease(id: id, revision: revision, deadline: p.deadline, origin: sourceOrigin) }
        // WKOD can arrive before its full WKCV observation. Only the Rust
        // plan's pinned peer stamp may authorize Prepare/Pull, never that
        // unpaired advertisement (which could contain a new destination Copy).
        let peerStamp = direction == "OUT" ? plan.destination.stamp : plan.source.stamp
        let request = Request(source: p.source, destination: String(peerStamp), originalSide: String(sourceOrigin.side),
                              originalSession: String(sourceOrigin.session), originalStamp: String(sourceOrigin.stamp))
        do {
            guard let transfer = link.send(try WKMessage(kind: direction == "OUT" ? "prepare" : "pull", nonce: id,
                body: JSONEncoder().encode(request)).encoded()) else { throw WKStreamError.disconnected }
            purposes[transfer] = .prepare(id)
            status("TRANSFER requested " + id)
        } catch { cancelPaste(notifyPeer: true) }
        emitRoute()
    }
    private func prepareDecodedBundle(_ id: String) {
        guard let l = lease, l.bundleID == id, l.revision == clipboard.changeCount,
              let bundle = decodedBundles[id], preparedBundles[id] == nil, !bundlePreparing.contains(id), bundlePreparationJobs < 2 else { return }
        var urls: [URL] = []
        if let fileID = l.fileID {
#if WK_TREE
            if let roots = offeredTreeURLs[fileID] { urls = roots }
            else if let url = offeredURLs[fileID] { urls = [url] }
#else
            if let url = offeredURLs[fileID] { urls = [url] }
#endif
        }
        if bundle.items.contains(where: { $0.representations.contains(where: { $0.kind == .fileURL }) }), urls.isEmpty { return }
        let roots = urls, job = WKStreamFiles.ImageJob()
        imageJob = job; bundlePreparing.insert(id); bundlePreparationJobs += 1
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try bundle.prepare(fileURL: { reference in
                    guard let index = Int(reference), roots.indices.contains(index) else { throw WKStreamError.invalid }
                    return roots[index]
                }, check: { try job.check() })
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.bundlePreparationJobs -= 1
                guard self.lease?.id == l.id, self.lease?.bundleID == id,
                      self.lease?.revision == self.clipboard.changeCount else { return }
                self.bundlePreparing.remove(id); self.imageJob = nil
                switch result {
                case .success(let prepared):
                    self.preparedBundles[id] = prepared; self.decodedBundles.removeValue(forKey: id)
                    if self.role == "target" { self.queueReady(nonce: l.id, id: id) }
                case .failure: self.discardLease(); self.notifyCancel(l.id); self.status("ERROR bundle-prepare-failed")
                }
            }
        }
    }
    private func queueReady(nonce: String, id: String) {
        guard readiness.count < 8, !readiness.contains(where: { $0.nonce == nonce && $0.body == Data(id.utf8) }) else { return }
        readiness.append(WKMessage(kind: "stream-ready", nonce: nonce, body: Data(id.utf8)))
    }
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
        lastPortalCounts = nil; peerPortalCounts = nil; portalCountsSent = 0; portalCountsSentAt = -10
        if let rate = usbLinkRate,
           let line = WKMetadata.line(role: role, event: "TRANSPORT", fields: ["phase":"RESULT","usbMbps":rate.mbps]) { log(line) }
        pendingStreamDiagnostic = nil
        preparing = nil; streamResponse = nil; lastFinishedToken = nil; peerBulkImages = false; imageJob?.cancel(); imageJob = nil; imageReady = nil; decodedImage = nil
        stream?.setEpoch(ready ? (link.session ^ link.peerSession) : 0)
        cancelPaste(notifyPeer: false); discardLease(); response = nil; purposes.removeAll()
        committed = nil; remoteState = "0"; remoteSource = "0"
        decision = nil; peerMetadataReady = false; lastRoute = ""; requiredReady.removeAll(); decodedBundles.removeAll()
        preparedBundles.removeAll(); bundlePreparing.removeAll(); readiness.removeAll(); expectedPeerCommit = nil; peerCommitReceipt = nil
        departure = nil; metadataQuery = nil; metadataResponse = nil
        bundleResponse?.cancel(); bundleResponse = nil
        let observedRevision = clipboard.changeCount
        if observedRevision != revision { localOrigin = nil }
        revision = observedRevision; localState = next(); localSource = localState; lastAdvertisement = -10
        clipboardState.reset(side: side, session: ready ? link.session : 0)
        clipboardState.reset(side: 1-side, session: ready ? link.peerSession : 0)
        observeLocal()
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
        if link.ready, let report = WKReport(data, wireMagic: Self.magic), report.flags == 0x42 {
            receiveMetadata(report); return
        }
        if link.ready, let report = WKReport(data, wireMagic: Self.magic), report.session == link.peerSession,
           let counts = Self.portalCounts(report) {
            if role == "host", counts != peerPortalCounts { logPortalCounts(counts, role: "target") }
            peerPortalCounts = counts; return
        }
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
        guard build == protocolBuild, report.flags & 0x03 == 0x03 else {
            peerBulkImages = false; peerMetadataReady = false
            if role == "host" { reply("WKCLIP_RESET 0") }
            return
        }
        if stream != nil {
            peerBulkImages = (report.payload.readLE(at: 24) as UInt32 == UInt32(WKStreamOffer.maximumImage)) &&
                (report.payload.readLE(at: 28) as UInt32 == 5)
            guard peerBulkImages else {
                peerMetadataReady = false
                if role == "host" { reply("WKCLIP_RESET 0") }
                return
            }
        }
        let state = String(report.payload.readLE(at: 8) as UInt64)
        let source = String(report.payload.readLE(at: 16) as UInt64)
        guard state != "0" else { return }
        peerMetadataReady = true
        remoteState = state; remoteSource = source
        if role == "host" {
            log("WKCLIP_STATUS PEER_VERSION \(build)")
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
        // Diagnostic snapshots are fixed 37-byte keepalives, never a content
        // transaction. At most 64 per connection, at most one per second, and
        // only when changed. Failure/backpressure cannot delay a paste or HID.
        if link.ready, portalCountsSent < 64, now - portalCountsSentAt >= 1,
           let counts = portal?.diagnosticCounts, counts.count == WKPortalCounters.count, counts != lastPortalCounts {
            if role == "host" { logPortalCounts(counts, role: role); lastPortalCounts = counts; portalCountsSent += 1; portalCountsSentAt = now }
            else {
                var payload = Data([0x57,0x4b,0x50,0x53,1]); counts.forEach { payload.appendLE($0) }
                if transport.send(WKReport(kind: .pong, flags: 0x41, session: link.session, payload: payload).encode(wireMagic: Self.magic)) {
                    lastPortalCounts = counts; portalCountsSent += 1; portalCountsSentAt = now
                }
            }
        }
        if link.ready && now - lastAdvertisement >= 0.15 {
            var payload = Data("WKOD".utf8); payload.appendLE(protocolBuild)
            payload.appendLE(UInt64(localState)!); payload.appendLE(UInt64(localSource)!)
            if stream != nil { payload.appendLE(UInt32(WKStreamOffer.maximumImage)); payload.appendLE(UInt32(5)) }
            if transport.send(WKReport(kind: .ping, flags: 0x03, session: link.session, payload: payload).encode(wireMagic: Self.magic)) {
                _ = transport.send(WKReport(kind: .pong, flags: 0x42, session: link.session, payload: metadataPayload()).encode(wireMagic: Self.magic))
                lastAdvertisement = now
            }
        }
        resolveDecision()
        if let id = lease?.bundleID { prepareDecodedBundle(id) }
        if let query = metadataQuery, !link.transmitting,
           let data = try? WKMessage(kind: "metadata-refresh", nonce: query).encoded(), link.send(data) != nil { metadataQuery = nil }
        if let item = metadataResponse, !link.transmitting, let data = try? item.encoded(), link.send(data) != nil { metadataResponse = nil }
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
        if let ready = readiness.first, !link.transmitting, let data = try? ready.encoded(), link.send(data) != nil { readiness.removeFirst() }
        if let source = streamResponse ?? bundleResponse, !link.transmitting {
            if streamResponse?.offer.id == source.offer.id { streamResponse = nil } else { bundleResponse = nil }
            do {
                let metadata = source.bundleMetadata
                let item: WKMessage
                if let metadata { item = WKMessage(kind: "bundle-metadata", nonce: source.offer.nonce, name: source.offer.id, body: metadata) }
                else { item = WKMessage(kind: "stream-offer", nonce: source.offer.nonce, body: try source.offer.encoded()) }
                guard let id = link.send(try item.encoded()) else { throw WKStreamError.disconnected }
                streamSources[source.offer.id] = source
                purposes[id] = metadata == nil ? .streamOffer(source.offer.id, source.offer.nonce) : .bundleMetadata(source.offer.id, source.offer.nonce)
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
        revision = current; committed = nil; localOrigin = nil
        if role == "host" {
            departure = nil
            if let pending = decision {
                decision = nil; clipboardState.abort(pending.id); reply("WKCLIP_RESULT \(pending.id) cancelled")
            }
        }
        if stream != nil {
            imageJob?.cancel(); imageJob = nil
#if WK_TREE
            treeJob?.cancel(); treeJob = nil
#endif
            for (id, source) in streamSources where source.offer.kind == "png" { stream?.cancel(id); streamSources.removeValue(forKey: id) }
        }
        cancelPaste(notifyPeer: true); discardLease(); response = nil; preparing = nil; streamResponse?.cancel(); streamResponse = nil
        localState = next(); localSource = localState; lastAdvertisement = -10
        observeLocal(select: role == "host" && clipboardState.projection.contextSide == side)
        if let id = appliedFileID { portal?.retire(id: id); appliedFileID = nil }
        // Only origin/version metadata leaves this function. No content reads.
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
            if let d = decision, w[1] == "0" || w[1] == String(d.id) {
                clipboardState.abort(d.id); decision = nil; reply("WKCLIP_RESULT \(d.id) cancelled"); emitRoute()
            }
            if w[1] == lastFinishedToken { status("TRANSFER already-completed " + w[1]); return }
            if w[1] == "0" || w[1] == paste?.token { cancelPaste(notifyPeer: true) }; return
        }
        if w.count == 4, w[0] == "CONTEXT", let sequence = UInt64(w[1]), let destination = UInt32(w[2]), let focus = UInt64(w[3]) {
            // Attribute a just-completed Book menu copy to the side being left.
            pollClipboard(clock())
            let oldSide = clipboardState.projection.contextSide
            let oldPeer = clipboardState.snapshot(side: 1)
            if clipboardState.context(sequence: sequence, side: destination, focusEpoch: focus) {
                departure = nil
                if oldSide == 1, destination == 0, let peer = oldPeer {
                    let nonce = next()
                    departure = Departure(nonce: nonce, sequence: sequence, focus: focus, session: peer.session,
                                          stamp: peer.stamp, bookRevision: clipboard.changeCount)
                    metadataQuery = nonce
                }
                if let p = paste, !clipboardState.active(UInt64(p.id) ?? 0) { cancelPaste(notifyPeer: true) }
                if let d = decision { clipboardState.abort(d.id); decision = nil; reply("WKCLIP_RESULT \(d.id) cancelled") }
                emitRoute()
            }
            return
        }
        if w.count == 6, w[0] == "SELECT", let sequence = UInt64(w[1]), let source = UInt32(w[2]),
           ["copy", "cut"].contains(w[3]), let baseline = UInt64(w[4]), let focus = UInt64(w[5]),
           sequence > clipboardState.projection.appliedSequence,
           focus == clipboardState.projection.focusEpoch, source == clipboardState.projection.contextSide {
            departure = nil
            cancelPaste(notifyPeer: true)
            if let d = decision { clipboardState.abort(d.id); decision = nil; reply("WKCLIP_RESULT \(d.id) cancelled") }
            pollClipboard(clock())
            _ = clipboardState.select(sequence: sequence, side: source, cut: w[3] == "cut", baselineStamp: baseline)
            emitRoute(); return
        }
        guard w.count == 6, w[0] == "PASTE", let id = UInt64(w[1]), id > 0, let destination = UInt32(w[2]), destination < 2,
              let sequence = UInt64(w[3]), let destinationRevision = UInt64(w[4]), let focus = UInt64(w[5]) else { return }
        if paste?.id == w[1] || decision?.id == id || lastFinishedToken == w[1] { return }
        guard id > highestIntentID, focus == clipboardState.projection.focusEpoch,
              destination == clipboardState.projection.contextSide else { return }
        highestIntentID = id
        cancelPaste(notifyPeer: true)
        if let old = decision { clipboardState.abort(old.id); reply("WKCLIP_RESULT \(old.id) cancelled") }
        pollClipboard(clock())
        decision = Decision(id: id, destination: destination, sequence: sequence, revision: destinationRevision,
                            focus: focus, deadline: clock() + 0.75)
        metadataQuery = departure?.nonce ?? String(id)
        resolveDecision()
        if decision == nil, metadataQuery == String(id) { metadataQuery = nil }
    }
    private func cancelPaste(notifyPeer: Bool) {
        guard let p = paste else { return }
        clipboardState.abort(UInt64(p.id) ?? 0); expectedPeerCommit = nil; peerCommitReceipt = nil
        paste = nil; reply("WKCLIP_RESULT \(p.token) cancelled"); emitRoute()
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
        paste = nil; lastFinishedToken = p.token; reply("WKCLIP_RESULT \(p.token) ready \(clipboard.changeCount)"); emitRoute()
        peerCommitReceipt = nil
        requiredReady.removeValue(forKey: p.id)
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
        if bundleResponse?.offer.nonce == nonce { bundleResponse?.cancel(); bundleResponse = nil }
        requiredReady.removeValue(forKey: nonce)
        if imageReady?.nonce == nonce { imageReady = nil }
        readiness.removeAll { $0.nonce == nonce }
        for (id, source) in streamSources where source.offer.nonce == nonce {
            stream?.cancel(id); streamSources.removeValue(forKey: id)
#if WK_TREE
            collectionReady.remove(id); completedCollections.remove(id)
#endif
        }
    }
    private var leaseCanCommit: Bool {
        guard let l = lease, let item = l.staged else { return false }
        if let id = l.bundleID, preparedBundles[id] == nil { return false }
        if item.kind == "stream-offer", let offer = try? WKStreamOffer.decode(item.body), offer.clipboardBundle == true, l.bundleID == nil { return false }
        if item.kind == "stream-offer", let offer = try? WKStreamOffer.decode(item.body), offer.kind == "clipboard-bundle" { return l.bundleID != nil }
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
        if let id = lease?.id { readiness.removeAll { $0.nonce == id } }
        if let id = lease?.bundleID {
            decodedBundles.removeValue(forKey: id); preparedBundles.removeValue(forKey: id); bundlePreparing.remove(id)
            if streamIncoming.removeValue(forKey: id) != nil { stream?.cancel(id) }
        }
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
            if item.kind == "metadata-refresh" {
                pollClipboard(clock()); lastAdvertisement = -10
                metadataResponse = WKMessage(kind: "metadata-snapshot", nonce: item.nonce, body: metadataPayload())
                return true
            }
            if item.kind == "metadata-snapshot" {
                guard role == "host", peerMetadataReady, item.nonce == departure?.nonce || item.nonce == decision.map({ String($0.id) }),
                      item.body.count == 38, item.body.prefix(4) == Data("WKCV".utf8) else { return false }
                let stamp: UInt64 = item.body.readLE(at: 4)
                guard stamp >= (UInt64(remoteState) ?? 0) else { return true }
                remoteState = String(stamp); remoteSource = remoteState
                receiveMetadata(WKReport(kind: .pong, flags: 0x42, session: link.peerSession, payload: item.body), resolve: false)
                if let old = departure, old.nonce == item.nonce {
                    departure = nil
                    if clipboard.changeCount == old.bookRevision {
                        _ = clipboardState.confirmDeparture(side: 1, expectedSequence: old.sequence, focusEpoch: old.focus,
                                                            baselineSession: old.session, baselineStamp: old.stamp)
                        emitRoute(); resolveDecision()
                    }
                }
                resolveDecision()
                return true
            }
            if item.kind == "bundle-metadata" {
                guard stream != nil, peerBulkImages, item.body.count <= 128 * 1024,
                      var l = lease, l.id == item.nonce, l.revision == clipboard.changeCount,
                      clock() < l.deadline, let id = item.name, l.bundleID == nil, l.fileID != nil else { return false }
                let bundle = try WKClipboardBundle.decode(item.body)
                // This control message may contain opaque file references only.
                // Media and formatted-content bodies always require Bulk.
                guard bundle.items.allSatisfy({ $0.representations.allSatisfy({ $0.kind == .fileURL }) }) else { return false }
                l.bundleID = id; lease = l; decodedBundles[id] = bundle; prepareDecodedBundle(id)
                return true
            }
            if item.kind == "stream-diagnostic" {
                guard role == "host", let code = String(data: item.body, encoding: .utf8),
                      let line = WKMetadata.line(role: "target", event: "ERROR", fields: ["code": code]) else { return false }
                log(line); return true
            }
            if item.kind == "prepare" || item.kind == "pull" {
                guard role == "target" else { return false }
                pollClipboard(clock())
                let request = try JSONDecoder().decode(Request.self, from: item.body)
                guard request.destination == localState, let sourceOrigin = request.origin else { return false }
                // Retire only uncommitted clipboard preparation. File streams
                // already handed to Finder continue independently.
                var obsolete = Set(requiredReady.filter { !$0.value.isEmpty }.map(\.key))
                if let old = preparing?.nonce { obsolete.insert(old) }
                if let old = bundleResponse?.offer.nonce { obsolete.insert(old) }
                if let old = streamResponse?.offer.nonce { obsolete.insert(old) }
                for source in streamSources.values where ["png", "clipboard-bundle"].contains(source.offer.kind) { obsolete.insert(source.offer.nonce) }
                for old in obsolete where old != item.nonce { cancelTransaction(old) }
                discardLease(); imageJob?.cancel(); imageJob = nil; preparing = nil; streamResponse = nil; response = nil
                if item.kind == "prepare" {
                    lease = Lease(id: item.nonce, revision: revision, deadline: clock() + Self.pasteLifetime, origin: sourceOrigin)
                } else {
                    guard request.source == localSource, localSource != "0", origin(localSnapshot()) == sourceOrigin else { return false }
                    try prepareContent(item.nonce)
                }
                return true
            }
            if item.kind == "stream-ready" {
                guard role == "host", let id = String(data: item.body, encoding: .utf8),
                      let source = streamSources[id], ["png", "collection", "clipboard-bundle"].contains(source.offer.kind), source.offer.nonce == item.nonce,
                      paste?.id == item.nonce else { return false }
#if WK_TREE
                if source.offer.kind == "collection" {
                    if completedCollections.remove(id) != nil { streamSources.removeValue(forKey: id) }
                    else { collectionReady.insert(id) }
                } else { streamSources.removeValue(forKey: id) }
#else
                streamSources.removeValue(forKey: id)
#endif
                requiredReady[item.nonce]?.remove(id)
                if requiredReady[item.nonce]?.isEmpty != false { metadataCompleted(item.nonce, true) }
                return true
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
            // The bundle is a second stream of the same transaction. It carries
            // representations and opaque root references, never file contents.
            if item.kind == "stream-offer", let offer = try? WKStreamOffer.decode(item.body), offer.kind == "clipboard-bundle" {
                guard let stream, stream.isReady, peerBulkImages, var l = lease, l.id == item.nonce,
                      l.revision == clipboard.changeCount, clock() < l.deadline, l.bundleID == nil,
                      streamIncoming[offer.id] == nil, streamIncoming.count < 4 else { return false }
                l.bundleID = offer.id
                if l.staged == nil { l.staged = item }
                lease = l; streamIncoming[offer.id] = offer; stream.expect(offer); receivedCount += 1
                return true
            }
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
            } else if item.kind != "text" { return false }
            l.staged = item; lease = l; receivedCount += 1
            return true
        } catch { status("ERROR \(WKMetadata.errorCode(error))"); return false }
    }
    private func commit(_ id: String) -> Bool {
        guard leaseCanCommit, let l = lease, l.id == id, let item = l.staged,
              l.revision == clipboard.changeCount, clock() < l.deadline else { return false }
        if role == "host", !clipboardState.active(UInt64(id) ?? 0) { return false }
        do {
            var ownRevision: Int
            if let bundleID = l.bundleID, let bundle = preparedBundles[bundleID] {
                ownRevision = try bundle.apply(to: clipboard, expectedChangeCount: l.revision)
                preparedBundles.removeValue(forKey: bundleID)
                if let fileID = l.fileID {
                    if let old = appliedFileID { portal?.retire(id: old) }; appliedFileID = fileID
                }
            } else if item.kind == "text" {
                let bundle = WKClipboardBundle(items: [.init(representations: [.init(kind: .text, body: item.body)])])
                ownRevision = try bundle.prepare().apply(to: clipboard, expectedChangeCount: l.revision)
            } else if let image = decodedImage, image.id == l.fileID {
                try clipboard.applyBulkImage(image.image, expectedChangeCount: l.revision); decodedImage = nil
                ownRevision = clipboard.changeCount
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
                ownRevision = clipboard.changeCount
            } else { _ = try clipboard.apply(item, expectedChangeCount: l.revision); ownRevision = clipboard.changeCount }
            guard clipboard.changeCount == ownRevision else { pollClipboard(clock()); discardLease(); return false }
            revision = ownRevision; localState = next(); localSource = localState; localOrigin = l.origin; lastAdvertisement = -10
            if role == "host" {
                guard clipboardState.commit(id: UInt64(id) ?? 0, destinationSnapshot: localSnapshot()) else { return false }
                emitRoute()
            } else { observeLocal() }
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
        case .bundleMetadata(let file, let nonce):
            if !accepted { streamSources.removeValue(forKey: file); cancelPaste(notifyPeer: true); notifyCancel(nonce) }
            else if role != "host" { streamSources.removeValue(forKey: file) }
        case .offer(let file, let nonce):
            if accepted { bulkQueue.append(file) }
            else { outgoingFiles.removeValue(forKey: file) }
            metadataCompleted(nonce, accepted)
        case .streamOffer(let file, let nonce):
            if accepted, let source = streamSources[file] {
                stream?.send(source)
                if ["png", "collection", "clipboard-bundle"].contains(source.offer.kind) || requiredReady[nonce]?.isEmpty == false { return }
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
        guard accepted, p.revision == clipboard.changeCount, clipboardState.active(UInt64(nonce) ?? 0),
              let data = try? WKMessage(kind: "commit", nonce: nonce).encoded(), let id = link.send(data) else {
            cancelPaste(notifyPeer: true); return
        }
        if let source = clipboardState.projection.selectedSide.flatMap({ clipboardState.snapshot(side: $0) }), let sourceOrigin = origin(source) {
            expectedPeerCommit = (UInt64(nonce) ?? 0, sourceOrigin)
        }
        purposes[id] = .commit(nonce)
    }
    private func sendContent(_ item: WKMessage) {
        do {
            guard item.kind == "text" else { throw WKClipboardError.invalid("bulk-transport-required") }
            guard let id = link.send(try item.encoded()) else { throw WKStreamError.disconnected }
            purposes[id] = .content(item.nonce)
        } catch { cancelPaste(notifyPeer: true); status("ERROR \(WKMetadata.errorCode(error))") }
    }
    private func prepareContent(_ nonce: String) throws {
        let captured = clipboard.changeCount
        let items = clipboard.board.pasteboardItems ?? []
        let richTypes: Set<NSPasteboard.PasteboardType> = [.html, .rtf, .png, .tiff, .fileURL, .init("public.jpeg"), .init("public.heic")]
        let plain = items.count == 1 && items[0].types.contains(.string) && !items[0].types.contains(where: { richTypes.contains($0) })
        if plain {
            guard clipboard.changeCount == captured, let text = items[0].string(forType: .string),
                  clipboard.changeCount == captured else { throw WKClipboardError.invalid("clipboard-changed-during-read") }
            let snapshot = WKMessage(kind: "text", nonce: nonce, body: Data(text.utf8))
            try snapshot.validate()
            response = snapshot
            return
        }
        // No legacy PNG/file snapshot is allowed here: without Bulk, refuse
        // before asking a pasteboard owner to materialize a media body.
        guard stream != nil else { throw WKClipboardError.invalid("bulk-transport-required") }
#if WK_TREE
        let urls = try clipboard.selectedFileURLs()
#else
        let urls = try clipboard.singleFileURL().map { [$0] } ?? []
#endif
        guard let stream, peerBulkImages, stream.isReady, streamSources.count <= 2,
              urls.isEmpty || portalReady else { throw WKStreamError.disconnected }
        guard clipboard.changeCount == captured else { throw WKClipboardError.invalid("clipboard-changed-during-read") }
        preparing = (nonce, captured)
        imageJob?.cancel()
#if WK_TREE
        treeJob?.cancel()
#endif
        imageJob = stream.prepareBundle(clipboard: clipboard, revision: captured, nonce: nonce, files: urls) { [weak self] result in
            guard let self, self.preparing?.nonce == nonce, self.preparing?.revision == captured,
                  self.clipboard.changeCount == captured, self.link.ready else {
                if case .success(let source) = result { source.cancel() }; return
            }
            self.imageJob = nil
            switch result {
            case .failure(let error):
                self.preparing = nil; self.cancelPaste(notifyPeer: true); self.notifyCancel(nonce); self.status("ERROR \(WKMetadata.errorCode(error))")
            case .success(let bundle):
                if urls.isEmpty {
                    self.preparing = nil
                    if self.role == "host" { self.requiredReady[nonce] = [bundle.offer.id] }
                    self.streamResponse = bundle
                    return
                }
#if WK_TREE
                self.treeJob = stream.prepareSelection(urls: urls, nonce: nonce, clipboardBundle: true) { [weak self] result in
                    guard let self, self.preparing?.nonce == nonce, self.preparing?.revision == captured,
                          self.clipboard.changeCount == captured, self.link.ready else {
                        bundle.cancel(); if case .success(let source) = result { source.cancel() }; return
                    }
                    self.preparing = nil; self.treeJob = nil
                    switch result {
                    case .success(let source):
                        bundle.orderForPublication(after: source)
                        var readiness: Set<String> = [bundle.offer.id]
                        if source.offer.kind == "collection" { readiness.insert(source.offer.id) }
                        if self.role == "host" { self.requiredReady[nonce] = readiness }
                        self.streamResponse = source; self.bundleResponse = bundle
                    case .failure:
                        bundle.cancel(); self.cancelPaste(notifyPeer: true); self.notifyCancel(nonce); self.status("ERROR collection-source-unavailable")
                    }
                }
#else
                bundle.cancel(); self.preparing = nil; self.cancelPaste(notifyPeer: true); self.notifyCancel(nonce)
#endif
            }
        }
    }
    private func pumpFiles() {
        guard bulkLink.ready, !bulkLink.transmitting, !bulkQueue.isEmpty else { return }
        let id = bulkQueue.removeFirst()
        guard let item = outgoingFiles[id], let data = try? item.encodedBinary(), let transfer = bulkLink.send(data) else { return }
        bulkPurposes[transfer] = id
    }
    private func receiveFile(_ data: Data) -> Bool {
        // WKF3's historical file messages used HID-sized reports. Build 16
        // never accepts media bodies here, regardless of transport availability.
        return false
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
