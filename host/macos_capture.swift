/*
 * Opt-in macOS key/mouse capture for the WiredKVM proof of concept.
 * Prints human-readable events on stdout; host/bridge.py adds CRC/sequence
 * and forwards them over USB-UART. Does not run unless explicitly launched.
 *
 * Keyboard: USB 6-key rollover, Fn tracked from physical key-63 flagsChanged.
 * Physical key mapping; optional Mac gesture relay; Ctrl+Option+F12 toggles.
 */
import Cocoa
import ApplicationServices
import Darwin

private var activeClient = false
private var buttons = 0
private var lastSentModifiers = 0
private var physicalFnDown = false
private let systemDefinedEvent = CGEventType(rawValue: 14)!
private var capsPhysicalDown = false
private var capsLastPhysicalAt: UInt64?
private var capsLastFallbackAt: UInt64?
private var capsLastLockFlag: (locked: Bool, at: UInt64)?
private var capsPending: (flags: CGEventFlags, at: UInt64)?
private var capsGeneration = 0
private var tapPort: CFMachPort?
private var pointerDetached = false
private var pointerHidden = false
private var pinnedPosition: CGPoint?
private var pinCorrectionCount = 0
private var appCursorHidden = false
private var consumeSwitchKeyUp = false
private var consumeEmergencyKeyUp = false
private var consumePasteKeyUp = false
// Legacy network-stage clipboard tracking. Physical USB HID forwards native
// shortcuts only; it does not transfer clipboard data between computers.
private var remoteClipboardIsSource = false
// Change-count only: detect local Finder menu/context-menu copies without
// reading private clipboard bytes until the user explicitly requests paste.
private var bookPasteboardRevision = NSPasteboard.general.changeCount
private var lastSwitchAt = CFAbsoluteTimeGetCurrent() - 10
private var lastLinkSignal = CFAbsoluteTimeGetCurrent()
private let linkWatchdogSeconds: CFAbsoluteTime = 0.9
// iPhone accepts HID Command+V; it cannot receive Mac mini's assisted paste.
private let iphoneHIDMode = ProcessInfo.processInfo.environment["WK_TARGET_IPHONE"] == "1"
private let desktopAbsoluteMode = !iphoneHIDMode &&
    ProcessInfo.processInfo.environment["WK_TARGET_ABSOLUTE"] == "1"
// File routing is opt-in and independent of the legacy assisted-paste path.
private let fileTransferEnabled = desktopAbsoluteMode &&
    ProcessInfo.processInfo.environment["WK_FILE_TRANSFER"] == "1"
private let fileTransferSyntheticMarker: Int64 = 0x574b4654
private var fileTransferBusy = false
// Do not offer another intent until native acknowledges the previous lease is
// idle. Cancellation and stdin control delivery run asynchronously: an old
// FILE BUSY 0 must never be able to clear a newer transaction's capture state.
private var fileTransferWaitingForIdle = false
private var consumeFilePasteKeyUp = false
private let wiredClipboardEnabled = desktopAbsoluteMode &&
    ProcessInfo.processInfo.environment["WK_WIRED_CLIPBOARD"] == "1"
// Native input has its own transport switch. Enabling scrolling/gestures must
// not opt into clipboard interception; old clipboard-enabled launches retain
// their existing native-input behavior.
private let wiredInputEnabled = desktopAbsoluteMode &&
    (ProcessInfo.processInfo.environment["WK_WIRED_INPUT"] == "1" || wiredClipboardEnabled)
private var clipboardPeerReady = false
private var wiredBookRevision = NSPasteboard.general.changeCount
private var remoteMenuReturnRevision: Int?
private var consumeClipboardCopyKeyUp = false
private var consumeClipboardPasteKeyUp = false
private let clipboardSyntheticMarker: Int64 = 0x574b434c

private struct ClipboardShortcut {
    let token: String
    let remote: Bool
    let pid: pid_t
    let at: TimeInterval
    func valid(remote: Bool, pid: pid_t, now: TimeInterval) -> Bool {
        self.remote == remote && (remote || self.pid == pid) &&
            now >= at && now - at <= 180
    }
}
private struct ClipboardIntents {
    var sequence: UInt64 = UInt64.random(in: 1...UInt64(UInt32.max))
    var copiedRemotely: Bool?
    var copyToken = "0"
    var cut = false
    var copy: ClipboardShortcut?
    var paste: ClipboardShortcut?
    mutating func next() -> String { sequence &+= 1; return String(sequence) }
    mutating func beginCopy(remote: Bool, pid: pid_t, now: TimeInterval) -> String {
        copiedRemotely = remote; cut = false
        let token = next()
        copyToken = "0"
        copy = nil
        paste = nil
        return token
    }
    mutating func beginPaste(remote: Bool, pid: pid_t, now: TimeInterval) -> String? {
        guard let source = copiedRemotely, source != remote, copyToken != "0" else { return nil }
        let token = copyToken + "." + next()
        paste = ClipboardShortcut(token: token, remote: remote, pid: pid, at: now)
        return token
    }
}
private var clipboardIntents = ClipboardIntents()

private func clipboardPID() -> pid_t {
    NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
}
private func clipboardIntent(_ line: String) { print("C " + line); fflush(stdout) }

private func cancelClipboardShortcut(_ reason: String = "other") {
    if let pending = clipboardIntents.paste {
        // Fixed reason codes only; no key values, clipboard bytes or app names.
        fputs("WKCLIP_DIAG role=host event=PASTE phase=CANCEL code=capture-\(reason) token=\(pending.token)\n", stderr)
        clipboardIntent("CANCEL " + pending.token)
    }
    clipboardIntents.copy = nil
    clipboardIntents.paste = nil
}

// Only invoked for a fresh, explicit user's shortcut after its data handshake.
// The remote path uses the existing HID channel; the local path is tagged so
// the event tap cannot interpret the replay as another clipboard intent.
private func replayClipboardShortcut(key: Int) {
    if activeClient {
        let physicalFlags = CGEventSource.flagsState(.combinedSessionState)
        sendModifiers(.maskCommand)
        if let hid = macToHID[key] { emit("T", hid, 1); emit("T", hid, 0) }
        sendModifiers(physicalFlags)
    } else {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: false) else { return }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: clipboardSyntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}

private func receiveClipboardControl(_ operation: String, token: String) {
    guard wiredClipboardEnabled else { return }
    if operation == "STATE" {
        clipboardPeerReady = token == "1"
        if !clipboardPeerReady {
            cancelClipboardShortcut("peer"); clipboardIntents.copiedRemotely = nil; clipboardIntents.copyToken = "0"
        }
        return
    }
    if operation == "ORIGIN_IN" || operation == "ORIGIN_OUT" {
        let remote = operation == "ORIGIN_IN"
        let lateMenuCopy = remote && remoteMenuReturnRevision == NSPasteboard.general.changeCount
        guard token != "0", remote == activeClient || clipboardIntents.copiedRemotely == remote || lateMenuCopy else { return }
        // A destination menu copy takes precedence even if its metadata arrives
        // just after V. Replay that V only while its original focus is valid.
        let pending = clipboardIntents.paste
        cancelClipboardShortcut("origin")
        if !remote { wiredBookRevision = NSPasteboard.general.changeCount; remoteMenuReturnRevision = nil }
        clipboardIntents.copiedRemotely = remote; clipboardIntents.copyToken = token
        if let pending, pending.remote == remote,
           pending.valid(remote: activeClient, pid: clipboardPID(), now: ProcessInfo.processInfo.systemUptime) {
            replayClipboardShortcut(key: 9)
        }
        return
    }
    if operation == "CANCEL" {
        if let pending = clipboardIntents.paste, token == "0" || pending.token == token {
            fputs("WKCLIP_DIAG role=host event=PASTE phase=CANCEL code=capture-helper-block token=\(pending.token)\n", stderr)
        }
        if token == "0" {
            clipboardPeerReady = false; clipboardIntents.copiedRemotely = nil; clipboardIntents.copyToken = "0"
            clipboardIntents.paste = nil
        } else if clipboardIntents.paste?.token == token { clipboardIntents.paste = nil }
        return
    }
    guard operation == "PASTE", let pending = clipboardIntents.paste, pending.token == token else { return }
    clipboardIntents.paste = nil
    guard pending.valid(remote: activeClient, pid: clipboardPID(), now: ProcessInfo.processInfo.systemUptime) else {
        clipboardIntent("CANCEL " + token); return
    }
    wiredBookRevision = NSPasteboard.general.changeCount
    clipboardIntents.copiedRemotely = activeClient; clipboardIntents.copyToken = "0"
    replayClipboardShortcut(key: 9)
}

private func clipboardTimeout() {
    guard wiredClipboardEnabled else { return }
    if let pending = clipboardIntents.paste,
       !pending.valid(remote: activeClient, pid: clipboardPID(), now: ProcessInfo.processInfo.systemUptime) {
        cancelClipboardShortcut("focus-or-expiry")
    }
}

private func requestClipboardShortcut(keyCode: Int, flags: CGEventFlags, repeatKey: Bool) -> Bool {
    guard wiredClipboardEnabled else { return false }
    if plainCommand(keyCode, expected: 8, flags: flags) {
        if !repeatKey {
            cancelClipboardShortcut("copy")
            _ = clipboardIntents.beginCopy(remote: activeClient, pid: clipboardPID(), now: ProcessInfo.processInfo.systemUptime)
            if !activeClient { wiredBookRevision = NSPasteboard.general.changeCount; remoteMenuReturnRevision = nil }
        }
        // Physical Cmd+C and its key-up always follow the normal native/HID
        // path. They never depend on the peer, serial link, or a replay timer.
        return false
    }
    if plainCommand(keyCode, expected: 9, flags: flags) {
        if repeatKey && consumeClipboardPasteKeyUp { return true }
        if !activeClient && NSPasteboard.general.changeCount != wiredBookRevision {
            wiredBookRevision = NSPasteboard.general.changeCount
            remoteMenuReturnRevision = nil
            clipboardIntents.copiedRemotely = false; clipboardIntents.copyToken = "0"
        }
        guard clipboardPeerReady,
              let token = clipboardIntents.beginPaste(remote: activeClient, pid: clipboardPID(),
                                                       now: ProcessInfo.processInfo.systemUptime) else { return false }
        consumeClipboardPasteKeyUp = true
        if clipboardIntents.cut { clipboardIntents.paste = nil }
        else { clipboardIntent("PASTE \(activeClient ? "OUT" : "IN") \(token)") }
        return true
    }
    return false
}

// Change-count provenance only. No clipboard objects or file contents are read
// until the user actually requests a cross-machine paste.
private struct FileTransferIntentState {
    enum Origin { case unknown, book, remote, cut }
    var origin: Origin = .unknown
    var revision: Int
    var copiedAt: TimeInterval = 0
    var bookCopyPending = false
    static let lifetime: TimeInterval = 120

    mutating func observe(revision current: Int, now: TimeInterval) {
        if current != revision {
            revision = current
            // A Cmd+X must never become a file-copy intent merely because it
            // changed the clipboard. A later explicit Cmd+C can reset it.
            if origin != .cut {
                origin = .book
                copiedAt = now
                bookCopyPending = false
            }
        }
        if now - copiedAt > Self.lifetime || now < copiedAt {
            origin = .unknown
            bookCopyPending = false
        }
    }

    mutating func noteCopy(remote: Bool, cut: Bool, revision current: Int,
                           now: TimeInterval) {
        revision = current
        copiedAt = now
        origin = cut ? .cut : (remote ? .remote : .book)
        // The local Cmd+C has not reached its app yet. Do not send the old
        // clipboard if that app does not produce a new revision.
        bookCopyPending = !remote && !cut
    }

    mutating func direction(remote: Bool, revision current: Int, now: TimeInterval,
                            bookFinder: Bool, singleBookFile: () -> Bool) -> String? {
        observe(revision: current, now: now)
        if remote && origin == .book && !bookCopyPending && singleBookFile() {
            return "OUT"
        }
        if !remote && origin == .remote && bookFinder { return "IN" }
        return nil
    }

    mutating func consumed() { origin = .unknown; bookCopyPending = false }
}
private var fileTransferIntent = FileTransferIntentState(revision: NSPasteboard.general.changeCount)
private let mouseSpeed: Double = {
    let parsed = Double(ProcessInfo.processInfo.environment["WK_MOUSE_SPEED"] ?? "1") ?? 1
    return parsed.isFinite && (0.5...2.0).contains(parsed) ? parsed : 1
}()
private let invertScroll = ProcessInfo.processInfo.environment["WK_INVERT_SCROLL"] == "1"
// A trackpad's continuous deltas were previously replayed as full mouse-wheel
// detents, then accelerated again by the receiving OS. Keep wheel mice intact.
private let trackpadScrollScale: Double = {
    let fallback = iphoneHIDMode ? 1.0 : 0.35
    let parsed = Double(ProcessInfo.processInfo.environment["WK_TRACKPAD_SCROLL_SCALE"] ?? "")
    return parsed.map { $0.isFinite && (0.1...2.0).contains($0) ? $0 : fallback } ?? fallback
}()
private struct TrackpadScrollAccumulator {
    private var vertical = 0.0
    private var horizontal = 0.0
    private var verticalDirection = 0
    private var horizontalDirection = 0
    private var timestamp: UInt64?

    mutating func reset() {
        vertical = 0; horizontal = 0
        verticalDirection = 0; horizontalDirection = 0; timestamp = nil
    }

    private mutating func axis(_ raw: Int, remainder: inout Double) -> Int {
        // Reversing direction must respond immediately, without first paying
        // back a fractional detent from the previous direction.
        if (raw > 0 && remainder < 0) || (raw < 0 && remainder > 0) { remainder = 0 }
        let total = Double(raw) * trackpadScrollScale + remainder
        let bounded = max(-127.0, min(127.0, total))
        let ticks = Int(bounded) // Retain fractions instead of rounding each event.
        remainder = bounded - Double(ticks)
        return ticks
    }

    mutating func convert(_ v: Int, _ h: Int, at: UInt64, began: Bool) -> (Int, Int) {
        if began || timestamp.map({ at < $0 || at - $0 > 500_000_000 }) == true { reset() }
        timestamp = at
        // Work on local copies to avoid overlapping access to this value type.
        var vr = vertical, hr = horizontal
        let result = (axis(v, remainder: &vr), axis(h, remainder: &hr))
        vertical = vr; horizontal = hr
        return result
    }

    private func preciseAxis(_ raw: Double, remainder: inout Double, direction: inout Int) -> Int {
        // A zero/end packet must never turn rounding debt into phantom motion.
        guard raw.isFinite, raw != 0 else { return 0 }
        let nextDirection = raw > 0 ? 1 : -1
        if direction != 0 && direction != nextDirection { remainder = 0 }
        direction = nextDirection
        let total = raw * trackpadScrollScale + remainder
        let bounded = max(-127.0, min(127.0, total))
        // Nearest quantization halves the first-detent threshold. Keep the
        // signed error: it can oppose the input even without a direction change.
        let ticks = Int(bounded.rounded())
        remainder = bounded - Double(ticks)
        return ticks
    }

    mutating func convertPrecise(_ v: Double, _ h: Double, at: UInt64, began: Bool) -> (Int, Int) {
        if began || timestamp.map({ at < $0 || at - $0 > 500_000_000 }) == true { reset() }
        timestamp = at
        var vr = vertical, hr = horizontal
        var vd = verticalDirection, hd = horizontalDirection
        let result = (preciseAxis(v, remainder: &vr, direction: &vd),
                      preciseAxis(h, remainder: &hr, direction: &hd))
        vertical = vr; horizontal = hr; verticalDirection = vd; horizontalDirection = hd
        return result
    }
}
private var trackpadScroll = TrackpadScrollAccumulator()
#if WK_PIXEL_SCROLL
// Quartz can emit >200 gesture updates/s. Keep complete begin/end ordering,
// merge delta gestures, and retain the latest absolute Dock progress at 60 Hz.
private final class CaptureGesturePacer {
    private struct Pending { var event: CGEvent; let source: UInt8; let order: UInt64 }
    private let clock: () -> UInt64
    private let send: (CGEvent, UInt8) -> Bool
    private let timed: Bool
    private let interval: UInt64 = 16_667
    private var last: [UInt32: UInt64] = [:]
    private var pending: [UInt32: Pending] = [:]
    private var order: UInt64 = 0
    private var timer: DispatchSourceTimer?
    init(clock: @escaping () -> UInt64 = WKScrollPacket.now, timed: Bool = true,
         send: @escaping (CGEvent, UInt8) -> Bool) { self.clock = clock; self.timed = timed; self.send = send }
    private func key(_ event: CGEvent) -> UInt32 { event.type.rawValue << 8 | UInt32(WKGestureEnvelope.subtype(event) ?? 0) }
    @discardableResult private func deliver(_ event: CGEvent, _ source: UInt8) -> Bool {
        last[key(event)] = clock(); return send(event, source)
    }
    @discardableResult func submit(_ event: CGEvent, source: UInt8) -> Bool {
        let kind = WKGestureEnvelope.subtype(event), phase = event.getIntegerValueField(CGEventField(rawValue: 132)!)
        let k = key(event), now = clock()
        guard phase == 2 && (kind == 5 || kind == 8 || (event.type.rawValue == 30 && kind == 23)) else {
            flushAll(); return deliver(event, source)
        }
        if let previous = pending[k], previous.source != source || previous.event.flags != event.flags { flushAll() }
        if pending[k] == nil, last[k] == nil || (now >= last[k]! && now-last[k]! >= interval) { return deliver(event, source) }
        guard let copy = event.copy() else { return false }
        if let previous = pending[k] {
            if kind == 8 {
                let f = CGEventField(rawValue: 113)!
                copy.setDoubleValueField(f, value: (1+previous.event.getDoubleValueField(f)) * (1+copy.getDoubleValueField(f))-1)
            } else if kind == 5 {
                let f = CGEventField(rawValue: 114)!
                copy.setDoubleValueField(f, value: previous.event.getDoubleValueField(f)+copy.getDoubleValueField(f))
            }
        }
        order &+= 1; pending[k] = Pending(event: copy, source: source, order: order)
        if timed && timer == nil {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + .milliseconds(4), repeating: .milliseconds(4))
            t.setEventHandler { [weak self] in self?.flushDue() }; timer=t; t.resume()
        }
        return true
    }
    func flushDue() {
        let now=clock()
        for (k,p) in pending.sorted(by: { $0.value.order < $1.value.order }) {
            if last[k] == nil || (now >= last[k]! && now-last[k]! >= interval) { pending.removeValue(forKey:k); _=deliver(p.event,p.source) }
        }
        if pending.isEmpty { timer?.cancel(); timer=nil }
    }
    func flushAll() {
        let entries=pending.sorted { $0.value.order < $1.value.order }; pending.removeAll()
        for (_,p) in entries { _=deliver(p.event,p.source) }
        timer?.cancel(); timer=nil
    }
    func cancel() { pending.removeAll(); last.removeAll(); timer?.cancel(); timer=nil }
    deinit { cancel() }
}
private let pixelScroll = WKScrollClient()
private let gesturePacer = CaptureGesturePacer { pixelScroll.forwardGesture($0, source:$1) }
private let pointingSource = WKPointingSource()
private let nativeInputPolicy = WKNativeInputPolicy()
private var pixelScrollGesture: Bool?
private var pixelScrollAt: UInt64 = 0
private var gestureTapPort: CFMachPort?
private var gestureNoticeAt = -Double.infinity
private var lastPointingKind: WKPointingSource.Kind = .unknown
private func refreshNativeInputPolicy() {
    guard nativeInputPolicy.refresh() else { return }
    gesturePacer.cancel(); pixelScroll.stop(); pixelScrollGesture = nil; trackpadScroll.reset()
    if wiredInputEnabled && nativeInputPolicy.pixelEnabled { pixelScroll.start() }
    fputs("WKCLIP_DIAG role=host event=NATIVE_INPUT_MODE code=\(nativeInputPolicy.mode.rawValue) ready=1\n", stderr)
}
private func notePointingKind(_ kind: WKPointingSource.Kind) {
    guard kind != .unknown, kind != lastPointingKind else { return }
    lastPointingKind = kind
    fputs("WKCLIP_DIAG role=host event=POINTING_SOURCE code=\(kind.rawValue) ready=1\n", stderr)
}
private func normalizedGesture(_ event: CGEvent) -> CGEvent? {
    guard let copy = event.copy() else { return nil }
    // Receiver supplies its own time/cursor. Foreign process/window identities
    // are invalid on mini; removing them also reduces per-frame transport bytes.
    copy.timestamp = 1; copy.location = .zero
    for f: UInt32 in [39,40,41,87,91,92] { copy.setIntegerValueField(CGEventField(rawValue:f)!, value:0) }
    if physicalFnDown { copy.flags.insert(.maskSecondaryFn) }
    else { copy.flags.remove(.maskSecondaryFn) }
    return copy
}

private func gestureTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                                event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        gesturePacer.cancel(); pixelScroll.cancel()
        if activeClient { restoreLocalPointer(); emit("R") }
        if let tap = gestureTapPort { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard activeClient, desktopAbsoluteMode, !iphoneHIDMode else { return Unmanaged.passUnretained(event) }
    if event.getIntegerValueField(.eventSourceUserData) == 0x574b4745 { return Unmanaged.passUnretained(event) }
#if WK_RAW_TOUCH
    if rawTouch.enabled && pointingSource.gesture(event) == .trackpad {return nil}
#endif
    guard nativeInputPolicy.gesturesEnabled, WKGestureEnvelope.isRelayGesture(event) else { return nil }
    let source = pointingSource.gesture(event)
    notePointingKind(source)
    cancelFileTransfer()
    if wiredClipboardEnabled { cancelClipboardShortcut("gesture") }
    let forwardedEvent = normalizedGesture(event)
    let forwarded = wiredInputEnabled && nativeInputPolicy.gesturesEnabled && source != .unknown && forwardedEvent != nil &&
        WKGestureEnvelope.isRelayGesture(forwardedEvent!) &&
        pixelScroll.gesturesReady && gesturePacer.submit(forwardedEvent!, source: source == .mouse ? 1 : 2)
    let now = ProcessInfo.processInfo.systemUptime
    if now - gestureNoticeAt >= 1 {
        gestureNoticeAt = now
        fputs("WKCLIP_DIAG role=host event=GESTURE_CAPTURED token=\(type.rawValue) ready=\(forwarded ? 1 : 0)\n", stderr)
    }
    // While controlling mini, a missing/unsupported gesture path must not
    // unexpectedly zoom a Book window or switch Book's desktop.
    return nil
}
#endif
#if WK_RAW_TOUCH
private let rawTouch = WKRawTouch { row in print(row);fflush(stdout) }
#endif
private let clientLabel = iphoneHIDMode ? "iPhone" : "Mac mini"
// Physical placement is independent of the target OS / clipboard behavior.
private let targetPositionIsLeft: Bool = {
    switch ProcessInfo.processInfo.environment["WK_TARGET_POSITION"] {
    case "left": return true
    case "right": return false
    default: return iphoneHIDMode // iPhone left, desktop right by default.
    }
}()

private func normalizeY(_ y: CGFloat, _ bounds: CGRect) -> Int {
    guard bounds.height > 1 else { return 5000 }
    let fraction = (y - bounds.minY) / (bounds.height - 1)
    return max(0, min(10000, Int((fraction * 10000).rounded())))
}

private func localPointerPosition(_ fraction: Int?,
                                  bounds: CGRect = CGDisplayBounds(CGMainDisplayID())) -> CGPoint {
    let y: CGFloat
    if let fraction {
        y = bounds.minY + CGFloat(max(0, min(10000, fraction))) / 10000 * (bounds.height - 1)
    } else {
        y = CGEvent(source: nil)?.location.y ?? bounds.midY
    }
    let x = targetPositionIsLeft ? bounds.minX + 16 : bounds.maxX - 16
    return CGPoint(x: x, y: min(max(y, bounds.minY), bounds.maxY - 1))
}

private func restoreLocalPointer(_ fraction: Int? = nil) {
    if wiredClipboardEnabled && activeClient { remoteMenuReturnRevision = NSPasteboard.general.changeCount }
    if wiredClipboardEnabled { cancelClipboardShortcut("screen-return") }
    if pointerDetached {
        _ = CGAssociateMouseAndMouseCursorPosition(1)
        pointerDetached = false
    }
    if activeClient || fraction != nil {
        _ = CGWarpMouseCursorPosition(localPointerPosition(fraction))
    }
    if appCursorHidden {
        NSCursor.unhide()
        appCursorHidden = false
    }
    if pointerHidden {
        _ = CGDisplayShowCursor(kCGNullDirectDisplay)
        pointerHidden = false
    }
#if WK_RAW_TOUCH
    rawTouch.setRemote(false)
#endif
    activeClient = false
    buttons = 0
    consumePasteKeyUp = false
    // Preserve the last copy source across screen changes. A fresh local
    // Cmd+C/X or Finder menu Copy can replace a previous Mini source.
    lastSentModifiers = 0
    physicalFnDown = false
    resetCapsForwarding()
    trackpadScroll.reset()
#if WK_PIXEL_SCROLL
    gesturePacer.cancel(); pixelScroll.cancel(); pixelScrollGesture = nil
    pointingSource.resetGesture()
#endif
    pinnedPosition = nil
    lastSwitchAt = CFAbsoluteTimeGetCurrent()
}

private func enterClient(_ y: CGFloat) {
    guard !activeClient else { return }
    resetCapsForwarding()
    trackpadScroll.reset()
#if WK_PIXEL_SCROLL
    gesturePacer.cancel()
    pixelScrollGesture = nil
    pointingSource.resetGesture()
#endif
    if wiredClipboardEnabled { cancelClipboardShortcut("screen-enter") }
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let fraction = normalizeY(y, bounds)
    activeClient = true
#if WK_RAW_TOUCH
    rawTouch.setRemote(true)
#endif
    let revision = NSPasteboard.general.changeCount
    if revision != bookPasteboardRevision {
        remoteClipboardIsSource = false // Book copied through a menu or another app.
    }
    bookPasteboardRevision = revision
    lastSwitchAt = CFAbsoluteTimeGetCurrent()
    lastLinkSignal = lastSwitchAt

    // Pin the MacBook cursor at the configured edge of the target display.
    // while forwarding relative HID deltas to the remote target.
    let anchor = localPointerPosition(fraction)
    pinnedPosition = anchor
    _ = CGWarpMouseCursorPosition(anchor)
    let detached = CGAssociateMouseAndMouseCursorPosition(0)
    pointerDetached = detached == .success
    if !pointerDetached {
        fputs("WiredKVM warning: MacBook pointer detach failed\n", stderr)
    }
    // CGDisplayHideCursor normally requires a foreground application. Keep
    // an AppKit hide request too, and suppress HID mouse events at their
    // earliest interception point so the Book cursor cannot follow movements.
    pointerHidden = CGDisplayHideCursor(kCGNullDirectDisplay) == .success
    NSCursor.hide()
    appCursorHidden = true

    emitEntryMetadata(bounds: bounds, fraction: fraction)
    let direction = targetPositionIsLeft ? "LEFT" : "RIGHT"
    fputs("WiredKVM: MacBook \(direction) -> \(clientLabel) HID\n", stderr)
}

private func checkLinkWatchdog(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
    guard (activeClient || fileTransferBusy) && now - lastLinkSignal > linkWatchdogSeconds else { return }
    cancelFileTransfer()
    // Local fail-safe: even if Python/ESP32/TCP never report an error,
    // immediately stop intercepting the MacBook keyboard and trackpad.
    restoreLocalPointer()
    buttons = 0
    emit("R")
    fputs("WiredKVM: LOCAL_LINK_TIMEOUT; mouse and keyboard returned to MacBook\n", stderr)
}

private func toggleClient() {
    if activeClient {
        restoreLocalPointer()
        lastSentModifiers = 0
        physicalFnDown = false
        buttons = 0
        emit("R")
        fputs("WiredKVM: switched to MacBook (manual)\n", stderr)
    } else {
        enterClient(CGEvent(source: nil)?.location.y ??
                    CGDisplayBounds(CGMainDisplayID()).midY)
    }
}

private let macToHID: [Int: Int] = [
    0: 0x04, 1: 0x16, 2: 0x07, 3: 0x09, 4: 0x0B, 5: 0x0A, 6: 0x1D,
    7: 0x1B, 8: 0x06, 9: 0x19, 11: 0x05, 12: 0x14, 13: 0x1A,
    14: 0x08, 15: 0x15, 16: 0x1C, 17: 0x17, 18: 0x1E, 19: 0x1F,
    20: 0x20, 21: 0x21, 22: 0x23, 23: 0x22, 24: 0x2E, 25: 0x26,
    26: 0x24, 27: 0x2D, 28: 0x25, 29: 0x27, 30: 0x30, 31: 0x12,
    32: 0x18, 33: 0x2F, 34: 0x0C, 35: 0x13, 37: 0x0F, 38: 0x0D,
    39: 0x34, 40: 0x0E, 41: 0x33, 42: 0x31, 43: 0x36, 44: 0x38,
    45: 0x11, 46: 0x10, 47: 0x37, 49: 0x2C, 50: 0x35, 36: 0x28,
    48: 0x2B, 51: 0x2A, 53: 0x29, 123: 0x50, 124: 0x4F,
    125: 0x51, 126: 0x52,
    // macOS F1..F12 virtual key codes to USB HID usages 0x3A..0x45.
    122: 0x3A, 120: 0x3B, 99: 0x3C, 118: 0x3D, 96: 0x3E,
    97: 0x3F, 98: 0x40, 100: 0x41, 101: 0x42, 109: 0x43,
    103: 0x44, 111: 0x45,
    // Caps Lock (physical transitions with a flags-only fallback), navigation.
    57: 0x39, 117: 0x4C, 115: 0x4A, 119: 0x4D,
    116: 0x4B, 121: 0x4E, 114: 0x49,
    // Numeric keypad key positions.
    82: 0x62, 83: 0x59, 84: 0x5A, 85: 0x5B, 86: 0x5C,
    87: 0x5D, 88: 0x5E, 89: 0x5F, 91: 0x60, 92: 0x61,
    65: 0x63, 67: 0x55, 69: 0x57, 75: 0x54, 78: 0x56,
    76: 0x58, 81: 0x67,
]

private func emit(_ type: String, _ a: Int = 0, _ b: Int = 0) {
    print("\(type) \(a) \(b)")
    fflush(stdout)
}

private func emitEntryMetadata(bounds: CGRect, fraction: Int) {
    emit("R")
    if desktopAbsoluteMode {
        // This is the Book's control plane, not a remote display-size query.
        emit("D", Int(bounds.width.rounded()), Int(bounds.height.rounded()))
    }
    emit("E", fraction, 0)
}

private func clamp(_ value: Int) -> Int {
    return max(-127, min(127, value))
}

private func scaledMouseDelta(_ raw: Int) -> Int {
    // Only remote HID movement is scaled. Local screen-edge capture uses raw CGEvent deltas.
    return clamp(Int((Double(raw) * mouseSpeed).rounded()))
}

private func modMask(_ flags: CGEventFlags) -> Int {
    var result = 0
    if flags.contains(.maskControl) { result |= 1 }
    if flags.contains(.maskShift) { result |= 2 }
    if flags.contains(.maskAlternate) { result |= 4 }
    if flags.contains(.maskCommand) { result |= 8 }
    // Do NOT blindly copy maskSecondaryFn from a CGEvent: on some macOS
    // sessions the ambient Fn mask stays set even while Fn is not pressed.
    // Trust an explicit physical Fn flagsChanged (key code 63) instead.
    if physicalFnDown { result |= 16 }
    return result
}

private func sendModifiers(_ flags: CGEventFlags) {
    let value = modMask(flags)
    if value != lastSentModifiers {
        emit("C", value, 0)
        lastSentModifiers = value
    }
}

private func resetCapsForwarding() {
    capsGeneration += 1 // Retire delayed fallbacks from the previous screen.
    capsPending = nil
    capsPhysicalDown = false
    capsLastPhysicalAt = nil
    capsLastFallbackAt = nil
    capsLastLockFlag = nil
}

private func nearCapsEvent(_ at: UInt64, _ previous: UInt64?) -> Bool {
    guard let previous else { return false }
    let delta = at >= previous ? at - previous : previous - at
    return delta < 50_000_000 // Pair the two representations of one press.
}

private func flushCapsFallback() {
    guard let pending = capsPending else { return }
    capsPending = nil
    capsGeneration += 1
    capsLastFallbackAt = pending.at
    sendModifiers(pending.flags)
    emit("T", 0x39, 1)
    emit("T", 0x39, 0)
}

private func forwardCapsFlag(_ event: CGEvent) {
    let locked = event.flags.contains(.maskAlphaShift)
    if let previous = capsLastLockFlag, previous.locked == locked,
       nearCapsEvent(event.timestamp, previous.at) { return }
    capsLastLockFlag = (locked, event.timestamp)
    guard !capsPhysicalDown, !nearCapsEvent(event.timestamp, capsLastPhysicalAt) else { return }
    flushCapsFallback()
    capsPending = (event.flags, event.timestamp)
    capsGeneration += 1
    let generation = capsGeneration
    // macOS also reports Caps Lock's physical press/release as NX_SYSDEFINED.
    // Give that pair priority; keyboards exposing only flags retain a tap.
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) {
        if activeClient && capsGeneration == generation { flushCapsFallback() }
    }
}

private func forwardCapsPhysical(down: Bool, event: CGEvent) {
    capsPending = nil
    capsGeneration += 1
    capsLastPhysicalAt = event.timestamp
    sendModifiers(event.flags)
    if down {
        guard !capsPhysicalDown, !nearCapsEvent(event.timestamp, capsLastFallbackAt) else { return }
        capsPhysicalDown = true
        emit("T", 0x39, 1)
    } else if capsPhysicalDown {
        capsPhysicalDown = false
        emit("T", 0x39, 0)
    }
}

private func capsPhysicalState(_ event: CGEvent) -> Bool? {
    guard let native = NSEvent(cgEvent: event), native.subtype.rawValue == 8 else { return nil }
    let data = UInt32(truncatingIfNeeded: native.data1)
    guard data >> 16 == 4 else { return nil } // NX_KEYTYPE_CAPS_LOCK, not a media key.
    switch (data >> 8) & 0xff {
    case 0x0a: return true
    case 0x0b: return false
    default: return nil
    }
}

private func buttonIndex(_ type: CGEventType, _ event: CGEvent) -> Int {
    switch type {
    case .leftMouseDown, .leftMouseUp, .leftMouseDragged: return 0
    case .rightMouseDown, .rightMouseUp, .rightMouseDragged: return 1
    default: return Int(event.getIntegerValueField(.mouseEventButtonNumber))
    }
}

private func forwardMouseButton(_ type: CGEventType, event: CGEvent) {
    let index = buttonIndex(type, event)
    guard index >= 0 && index < 5 else { return }
    let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    if down { buttons |= 1 << index } else { buttons &= ~(1 << index) }
    emit("B", buttons, 0)
}

// Serialize only: synthetic regression events never warp or post real input.
private func forwardMouseMotion(_ type: CGEventType, event: CGEvent) {
    if type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
        let index = buttonIndex(type, event)
        if index >= 0 && index < 5 && buttons & (1 << index) == 0 {
            // A press may have occurred locally before the edge handoff.
            // The drag itself proves that this button is still held.
            buttons |= 1 << index
            emit("B", buttons, 0)
        }
    }
    let dx = scaledMouseDelta(Int(event.getIntegerValueField(.mouseEventDeltaX)))
    let dy = scaledMouseDelta(Int(event.getIntegerValueField(.mouseEventDeltaY)))
    if dx != 0 || dy != 0 { emit("M", dx, dy) }
}

private func forwardedScrollDelta(_ raw: Int) -> Int {
    let adjusted = invertScroll ? (raw == Int.min ? Int.max : -raw) : raw
    return clamp(adjusted)
}

private func forwardScrollEvent(_ event: CGEvent) {
    let vertical = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
    let horizontal = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
    let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
    var trackpad = continuous
#if WK_PIXEL_SCROLL
    var source: WKPointingSource.Kind = .unknown
    if desktopAbsoluteMode && !iphoneHIDMode {
        source = pointingSource.scroll(event)
        notePointingKind(source)
        trackpad = continuous && source == .trackpad
    }
#if WK_RAW_TOUCH
    // Mouse wheel is always legacy. Raw trackpad contacts must not also become
    // quantized wheel ticks or Book-generated momentum on mini.
    if source == .trackpad && rawTouch.enabled {trackpadScroll.reset();return}
#endif

    if continuous && source != .unknown && desktopAbsoluteMode && !iphoneHIDMode && wiredInputEnabled && nativeInputPolicy.pixelEnabled {
        let began = event.getIntegerValueField(.scrollWheelEventScrollPhase) & 1 != 0
        let now = WKScrollPacket.now()
        if began || pixelScrollGesture == nil || now &- pixelScrollAt > 500_000 {
            pixelScrollGesture = pixelScroll.ready
        }
        pixelScrollAt = now
        if pixelScrollGesture == true {
            if pixelScroll.forward(event, source: source == .mouse ? 1 : 2) { trackpadScroll.reset(); return }
            gesturePacer.cancel(); pixelScroll.cancel(); pixelScrollGesture = false
        }
    } else { pixelScrollGesture = nil }
#endif
    let scaled: (Int, Int)
    if trackpad {
        let began = event.getIntegerValueField(.scrollWheelEventScrollPhase) & 1 != 0
        if iphoneHIDMode {
            scaled = trackpadScroll.convert(vertical, horizontal, at: event.timestamp, began: began)
        } else {
            // Quartz converts 16.16 to Double here. Reading integer DeltaAxis
            // first loses small trackpad motion before our HID quantization.
            scaled = trackpadScroll.convertPrecise(
                event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
                at: event.timestamp, began: began)
        }
    } else {
        trackpadScroll.reset()
        scaled = (vertical, horizontal)
    }
    let vert = forwardedScrollDelta(scaled.0)
    let horiz = forwardedScrollDelta(scaled.1)
    if vert != 0 || horiz != 0 { emit("W", vert, horiz) }
}

// Shared by the physical event tap and a safe synthetic-event unit test.
// This function only serializes events; it never posts a Quartz keyboard event.
private func forwardKeyboardEvent(_ type: CGEventType, event: CGEvent, keyCode: Int) {
    if keyCode == 57 && (type == .keyDown || type == .keyUp) {
        forwardCapsPhysical(down: type == .keyDown, event: event)
        return
    }
    if !(type == .flagsChanged && keyCode == 57) { flushCapsFallback() }
    switch type {
    case .keyDown:
        if let hidKey = macToHID[keyCode] {
            sendModifiers(event.flags)
            let repeatValue = event.getIntegerValueField(.keyboardEventAutorepeat)
            emit("T", hidKey, repeatValue != 0 ? 2 : 1)
        }
    case .keyUp:
        if let hidKey = macToHID[keyCode] {
            sendModifiers(event.flags)
            emit("T", hidKey, 0)
        }
    case .flagsChanged:
        if keyCode == 63 {
            physicalFnDown = event.flags.contains(.maskSecondaryFn)
        } else if keyCode == 57 {
            forwardCapsFlag(event)
        }
        sendModifiers(event.flags)
    default:
        break
    }
}

private func isPasteShortcut(keyCode: Int, flags: CGEventFlags) -> Bool {
    return activeClient && keyCode == 9 &&
        flags.contains(.maskControl) &&
        flags.contains(.maskAlternate) &&
        flags.contains(.maskShift)
}

// Standard macOS Cmd+V: only the unmodified Command shortcut is intercepted.
// Cmd+Shift+V, Cmd+Option+V, and other variations retain normal remote behavior.
private func isPlainCommandPaste(keyCode: Int, flags: CGEventFlags) -> Bool {
    return activeClient && keyCode == 9 &&
        flags.contains(.maskCommand) &&
        !flags.contains(.maskShift) &&
        !flags.contains(.maskAlternate) &&
        !flags.contains(.maskControl)
}

// Clipboard-native sync is active only after the authenticated WK2 link is up.
// With sync enabled, normal Cmd+V must reach the destination application.
private let nativeClipboardSync = ProcessInfo.processInfo.environment["WK_CLIPBOARD_SYNC"] == "1"

private func shouldRequestWiredPaste(keyCode: Int, flags: CGEventFlags) -> Bool {
    if iphoneHIDMode || desktopAbsoluteMode { return false }
    return isPasteShortcut(keyCode: keyCode, flags: flags) ||
        (!nativeClipboardSync && isPlainCommandPaste(keyCode: keyCode, flags: flags) &&
         !remoteClipboardIsSource)
}

private func plainCommand(_ keyCode: Int, expected: Int, flags: CGEventFlags) -> Bool {
    keyCode == expected && flags.contains(.maskCommand) &&
        !flags.contains(.maskAlternate) && !flags.contains(.maskControl) &&
        !flags.contains(.maskShift)
}

private func singleRegularFile(_ urls: [URL]) -> Bool {
    guard urls.count == 1, let url = urls.first, url.isFileURL else { return false }
    // Metadata only, at explicit paste. Do not dereference symlinks or treat
    // packages/directories as the initial single ordinary file prototype.
    var info = stat()
    return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
}

private func singleBookFile(on pasteboard: NSPasteboard) -> Bool {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options),
          objects.count == 1, let url = objects.first as? URL else { return false }
    return singleRegularFile([url])
}

private func emitFile(_ command: String) {
    print("F \(command)")
    fflush(stdout)
}

private func cancelFileTransfer() {
    guard fileTransferEnabled && fileTransferBusy else { return }
    fileTransferBusy = false
    fileTransferIntent.consumed()
    lastSentModifiers = 0 // Native cancellation releases its keyboard state.
    emitFile("CANCEL")
}

private func beginFileTransferRequest() -> Bool {
    guard fileTransferEnabled, !fileTransferBusy, !fileTransferWaitingForIdle else { return false }
    consumeFilePasteKeyUp = true
    fileTransferBusy = true
    fileTransferWaitingForIdle = true
    resetCapsForwarding()
    fileTransferIntent.consumed()
    lastSentModifiers = 0 // Native begins with a release report.
    return true
}

private func receiveFileBusy(_ busy: Bool) {
    guard fileTransferEnabled else { return }
    if busy {
        // Capture already marked its request busy. Never resurrect a request
        // cancelled while native's BUSY 1 was in flight.
        if fileTransferBusy { lastSentModifiers = 0 }
    } else {
        // Native emits this once after its busy-to-idle transition. The next
        // request cannot start until this callback has run on the main queue.
        fileTransferBusy = false
        fileTransferWaitingForIdle = false
        lastSentModifiers = 0
    }
}

private func requestFilePaste(keyCode: Int, flags: CGEventFlags,
                              autorepeat: Bool) -> Bool {
    guard fileTransferEnabled,
          plainCommand(keyCode, expected: 9, flags: flags), !autorepeat else { return false }
    if fileTransferWaitingForIdle {
        // Never let a rapid retry fall through as a native paste of stale
        // clipboard contents while the previous macro is still being cancelled.
        // Do not consume newly observed copy provenance; it can be used again
        // after native has explicitly acknowledged idle.
        consumeFilePasteKeyUp = true
        fputs("WiredKVM: previous file transfer is still ending; this paste was not sent.\n", stderr)
        return true
    }
    guard !fileTransferBusy else { return false }
    let pasteboard = NSPasteboard.general
    let revision = pasteboard.changeCount
    guard revision >= 0 else { return false }
    let finder = !activeClient &&
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    guard let direction = fileTransferIntent.direction(remote: activeClient,
            revision: revision, now: ProcessInfo.processInfo.systemUptime,
            bookFinder: finder, singleBookFile: { singleBookFile(on: pasteboard) }),
          pasteboard.changeCount == revision else { return false }
    guard beginFileTransferRequest() else { return false }
    emitFile("PASTE \(direction) \(revision)")
    return true
}

private func cancelsFileTransfer(_ type: CGEventType, event: CGEvent) -> Bool {
    switch type {
    case .keyDown, .keyUp, .leftMouseDown, .leftMouseUp,
         .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
         .scrollWheel:
        return true
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
        return event.getIntegerValueField(.mouseEventDeltaX) != 0 ||
            event.getIntegerValueField(.mouseEventDeltaY) != 0
    default: return false
    }
}

// Ordinary Copy/Cut is never intercepted. We only remember which machine
// received it, allowing the next ordinary Paste to select its data route.
// macOS uses Command; the future Windows source adapter maps Ctrl+C/X/V to
// these same copy/cut/paste operations, not to macOS-specific keycodes.
private func noteCopyOrCut(_ type: CGEventType, keyCode: Int,
                           flags: CGEventFlags) {
    guard type == .keyDown && (keyCode == 8 || keyCode == 7) &&
        flags.contains(.maskCommand) && !flags.contains(.maskAlternate) &&
        !flags.contains(.maskControl) && !flags.contains(.maskShift) else { return }
    remoteClipboardIsSource = activeClient
    if wiredClipboardEnabled && keyCode == 7 {
        clipboardIntents.copiedRemotely = activeClient
        clipboardIntents.cut = true
    }
    if fileTransferEnabled {
        fileTransferIntent.noteCopy(remote: activeClient, cut: keyCode == 7,
            revision: NSPasteboard.general.changeCount,
            now: ProcessInfo.processInfo.systemUptime)
    }
}

// Unlike Ctrl+Option+F12, this chord only RETURNS to the MacBook.
// It works on keyboards where F12 requires holding the hardware Fn key.
private func isEmergencyReturnShortcut(keyCode: Int, flags: CGEventFlags) -> Bool {
    return (activeClient || (fileTransferEnabled && fileTransferBusy)) && keyCode == 53 &&
        flags.contains(.maskControl) && flags.contains(.maskAlternate) &&
        !flags.contains(.maskCommand)
}

// Target side is configurable; iPhone left and Mac mini right remain defaults.
private func entersClientAtEdge(x: CGFloat, dx: Int, bounds: CGRect) -> Bool {
    if targetPositionIsLeft { return dx < 0 && x <= bounds.minX + 4 }
    return dx > 0 && x >= bounds.maxX - 4
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                              event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if fileTransferEnabled &&
        event.getIntegerValueField(.eventSourceUserData) == fileTransferSyntheticMarker {
        return Unmanaged.passUnretained(event)
    }
    if wiredClipboardEnabled && event.getIntegerValueField(.eventSourceUserData) == clipboardSyntheticMarker {
        return Unmanaged.passUnretained(event)
    }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        cancelFileTransfer()
        cancelClipboardShortcut("tap-interrupted")
        // Never leave the remote computer active when the blocking tap
        // temporarily fails; restore local pointer ownership first.
        if activeClient {
            restoreLocalPointer()
            emit("R")
            fputs("WiredKVM: HID tap interrupted; returned to MacBook\n", stderr)
        }
        if let tap = tapPort { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    if type == systemDefinedEvent {
        guard activeClient, let down = capsPhysicalState(event) else {
            return Unmanaged.passUnretained(event)
        }
        if down { cancelFileTransfer(); cancelClipboardShortcut("caps") }
        forwardCapsPhysical(down: down, event: event)
        return nil
    }
#if WK_PIXEL_SCROLL
    if desktopAbsoluteMode && !iphoneHIDMode && [CGEventType.mouseMoved, .leftMouseDragged,
        .rightMouseDragged, .otherMouseDragged, .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(type) {
        let direct = pointingSource.hardwareSource(event)
        notePointingKind(direct == .unknown ? pointingSource.soleKind : direct)
    }
#endif

    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    if type == .keyUp && keyCode == 8 && consumeClipboardCopyKeyUp {
        consumeClipboardCopyKeyUp = false
        return nil
    }
    if type == .keyUp && keyCode == 9 && consumeClipboardPasteKeyUp {
        consumeClipboardPasteKeyUp = false
        return nil
    }
    // An auto-repeat belongs to the initiating paste. Consume it BEFORE the
    // ordinary-input cancellation path, keeping exactly one pending request.
    if type == .keyDown && keyCode == 9 && consumeClipboardPasteKeyUp &&
        event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
    if wiredClipboardEnabled && type != .flagsChanged && cancelsFileTransfer(type, event: event) {
        let repeatCopy = type == .keyDown && keyCode == 8 && consumeClipboardCopyKeyUp &&
            event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if !repeatCopy {
            if type == .mouseMoved && buttons == 0 {
                // Plain pointer motion does not alter the copy selection.
                // Pointer motion alone keeps the pending paste; clicks, typing,
                // focus changes and screen switching still cancel it.
            } else { cancelClipboardShortcut("input-\(type.rawValue)") }
        }
    }
    // Keep a swallowed paste key-up paired even after cancellation/return.
    if type == .keyUp && keyCode == 9 && consumeFilePasteKeyUp {
        consumeFilePasteKeyUp = false
        return nil
    }
    if type == .keyDown && keyCode == 9 && consumeFilePasteKeyUp &&
        event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
    if type == .keyUp && keyCode == 111 && consumeSwitchKeyUp {
        consumeSwitchKeyUp = false
        return nil
    }
    if type == .keyUp && keyCode == 53 && consumeEmergencyKeyUp {
        consumeEmergencyKeyUp = false
        return nil
    }
    // Emergency local return, independent of Function/F12 keyboard settings.
    if isEmergencyReturnShortcut(keyCode: keyCode, flags: event.flags) &&
        (type == .keyDown || type == .keyUp) {
        if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return nil
        }
        if type == .keyDown {
            consumeEmergencyKeyUp = true
            cancelFileTransfer()
            if activeClient { toggleClient() } // Local transfers must not enter mini.
        }
        return nil
    }
    if fileTransferBusy {
        // Modifier changes alone do not start another action. Suppress their
        // remote reports while native owns the keyboard; local OS still sees
        // its physical modifier releases. A subsequent key/mouse action cancels
        // before following the normal route with its current modifier flags.
        if type == .flagsChanged {
            return activeClient ? nil : Unmanaged.passUnretained(event)
        }
        if cancelsFileTransfer(type, event: event) { cancelFileTransfer() }
    }
    // Copy/Cut always reach their application; only remember provenance.
    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
        noteCopyOrCut(type, keyCode: keyCode, flags: event.flags)
    }
    if type == .keyDown && requestClipboardShortcut(keyCode: keyCode, flags: event.flags,
        repeatKey: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) { return nil }
    if type == .keyDown && requestFilePaste(keyCode: keyCode, flags: event.flags,
            autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) {
        return nil
    }
    // Explicit Ctrl+Option+Shift+V OR ordinary Cmd+V from MacBook's copied
    // content. The latter suppresses Apple's Universal Clipboard invocation
    // on Mini by NOT emitting a V key into its system keyboard. If the Mini
    // previously received Cmd+C/X, ordinary Cmd+V remains a native Mini paste.
    if type == .keyUp && keyCode == 9 && consumePasteKeyUp {
        consumePasteKeyUp = false
        return nil
    }
    if shouldRequestWiredPaste(keyCode: keyCode, flags: event.flags)
        && (type == .keyDown || type == .keyUp) {
        if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return nil
        }
        if type == .keyDown {
            consumePasteKeyUp = true
            emit("V")
        }
        return nil
    }
    if keyCode == 111 && event.flags.contains(.maskControl)
        && event.flags.contains(.maskAlternate) &&
        (type == .keyDown || type == .keyUp) {
        if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return nil
        }
        if type == .keyDown {
            consumeSwitchKeyUp = true
            toggleClient()
        }
        return nil
    }

    let rawDX = Int(event.getIntegerValueField(.mouseEventDeltaX))
    let dx = clamp(rawDX)
    let mouseType = type == .mouseMoved || type == .leftMouseDragged ||
                    type == .rightMouseDragged || type == .otherMouseDragged

    // Move off the configured MacBook edge to enter the remote target.
    // Hold a short cooldown after returning to avoid instant re-entry.
    if !activeClient && mouseType &&
        CFAbsoluteTimeGetCurrent() - lastSwitchAt > 0.55 &&
        entersClientAtEdge(x: event.location.x, dx: dx,
                           bounds: CGDisplayBounds(CGMainDisplayID())) {
        enterClient(event.location.y)
    }

    if !activeClient { return Unmanaged.passUnretained(event) }

    if mouseType {
        // The Quartz disassociate/hide APIs are documented as effective only
        // for the foreground app, but our capture helper runs in background.
        // A HID tap returning nil does not always prevent cursor-location
        // updates. Re-pin the *local* cursor on each remote movement. The
        // original deltas are captured BEFORE the warp and sent to the mini.
        if let anchor = pinnedPosition, event.location != anchor {
            _ = CGWarpMouseCursorPosition(anchor)
            pinCorrectionCount += 1
        }
        forwardMouseMotion(type, event: event)
        return nil
    }
    switch type {
    case .leftMouseDown, .rightMouseDown, .otherMouseDown,
         .leftMouseUp, .rightMouseUp, .otherMouseUp:
        forwardMouseButton(type, event: event)
        return nil
    case .scrollWheel:
        forwardScrollEvent(event)
        return nil
    case .keyDown, .keyUp, .flagsChanged:
        forwardKeyboardEvent(type, event: event, keyCode: keyCode)
        return nil
    default:
        return Unmanaged.passUnretained(event)
    }
}

// Safe regression paths below never install an EventTap, post OS input, read
// general clipboard objects, or move either computer's pointer.
#if WK_PIXEL_SCROLL
if CommandLine.arguments.contains("--self-test-gesture-pacing") {
    var now: UInt64 = 100_000
    var sent: [CGEvent] = []
    let pacer = CaptureGesturePacer(clock: { now }, timed: false) { e,_ in sent.append(e.copy()!); return true }
    func event(_ kind: Int, _ phase: Int, _ value: Double) -> CGEvent {
        let e=CGEvent(source:nil)!;e.type=CGEventType(rawValue:kind == 23 ? 30 : 29)!
        e.setDoubleValueField(CGEventField(rawValue:110)!,value:Double(kind))
        e.setIntegerValueField(CGEventField(rawValue:132)!,value:Int64(phase))
        e.setDoubleValueField(CGEventField(rawValue:UInt32(kind == 23 ? 124 : kind == 5 ? 114 : 113))!,value:value)
        return e
    }
    _=pacer.submit(event(23,1,0),source:2)
    now+=4_000;_=pacer.submit(event(23,2,0.2),source:2)
    now+=4_000;_=pacer.submit(event(23,2,0.7),source:2)
    now+=1_000;_=pacer.submit(event(23,4,0.7),source:2)
    precondition(sent.map{$0.getIntegerValueField(CGEventField(rawValue:132)!)} == [1,2,4])
    precondition(abs(sent[1].getDoubleValueField(CGEventField(rawValue:124)!)-0.7)<0.00001)
    pacer.cancel();sent.removeAll();now+=100_000
    _=pacer.submit(event(8,1,0),source:2)
    now+=1_000;_=pacer.submit(event(8,2,0.1),source:2)
    now+=1_000;_=pacer.submit(event(8,2,0.2),source:2)
    _=pacer.submit(event(8,4,0),source:2)
    precondition(sent.count==3 && abs(sent[1].getDoubleValueField(CGEventField(rawValue:113)!)-0.32)<0.00001)
    pacer.cancel();sent.removeAll();now+=100_000
    _=pacer.submit(event(5,1,0),source:2)
    now+=1_000;_=pacer.submit(event(5,2,2),source:2)
    now+=1_000;_=pacer.submit(event(5,2,3),source:2)
    _=pacer.submit(event(5,4,0),source:2)
    precondition(sent.count==3 && sent[1].getDoubleValueField(CGEventField(rawValue:114)!)==5)
    pacer.cancel();sent.removeAll();now+=100_000
    _=pacer.submit(event(23,1,0),source:2)
    for i in 1...24 { now+=4_167;_=pacer.submit(event(23,2,Double(i)/24),source:2);pacer.flushDue() }
    _=pacer.submit(event(23,4,1),source:2)
    precondition(sent.count<=9 && sent.last!.getIntegerValueField(CGEventField(rawValue:132)!)==4)
    pacer.cancel();sent.removeAll();now+=100_000
    _=pacer.submit(event(23,1,0),source:2);now+=1_000;_=pacer.submit(event(23,2,0.5),source:2)
    pacer.cancel();now+=100_000;pacer.flushDue();precondition(sent.count==1)
    var timedEvents: [CGEvent] = []
    let timed = CaptureGesturePacer { e,_ in timedEvents.append(e.copy()!); return true }
    _=timed.submit(event(23,1,0),source:2)
    for i in 1...24 {
        _=timed.submit(event(23,2,Double(i)/24),source:2)
        RunLoop.main.run(until:Date().addingTimeInterval(0.0042))
    }
    _=timed.submit(event(23,4,1),source:2);timed.cancel()
    precondition(timedEvents.count>=3 && timedEvents.count<=12)
    precondition(timedEvents.last!.getIntegerValueField(CGEventField(rawValue:132)!)==4)
    print("CAPTURE_GESTURE_PACING_PASS phases_preserved=true dock_latest=true pinch_product=true rotation_sum=true bounded_rate=true cancellation=true no_OS_input_posted=true")
    exit(0)
}
if CommandLine.arguments.contains("--self-test-gesture-routing") {
    let event = CGEvent(source: nil)!
    event.type = CGEventType(rawValue: 29)!
    event.flags = [.maskShift, .maskSecondaryFn]
    event.timestamp = 12345; event.location = CGPoint(x:20,y:30)
    event.setIntegerValueField(.eventTargetUnixProcessID,value:777)
    event.setIntegerValueField(.eventTargetProcessSerialNumber,value:888)
    event.setDoubleValueField(CGEventField(rawValue:110)!,value:8)
    event.setDoubleValueField(CGEventField(rawValue:113)!,value:0.025)
    event.setIntegerValueField(CGEventField(rawValue:132)!,value:2)
    physicalFnDown = false
    let copy = normalizedGesture(event)!
    precondition(copy.flags.contains(.maskShift) && !copy.flags.contains(.maskSecondaryFn))
    precondition(event.flags.contains(.maskSecondaryFn))
    precondition(copy.timestamp==1 && copy.location == .zero)
    precondition(copy.getIntegerValueField(.eventTargetUnixProcessID)==0 && copy.getIntegerValueField(.eventTargetProcessSerialNumber)==0)
    precondition(event.getIntegerValueField(.eventTargetUnixProcessID)==777 && event.timestamp==12345)
    precondition(abs(copy.getDoubleValueField(CGEventField(rawValue:113)!)-0.025)<0.00001)
    precondition(copy.getIntegerValueField(CGEventField(rawValue:132)!)==2)
    physicalFnDown = true
    precondition(normalizedGesture(event)!.flags.contains(.maskSecondaryFn))
    activeClient = false
    precondition(gestureTapCallback(proxy: OpaquePointer(bitPattern: 1)!, type: event.type, event: event, refcon: nil) != nil)
    if desktopAbsoluteMode {
        activeClient = true
        clipboardIntents.copy = ClipboardShortcut(token: "41", remote: true, pid: 7, at: 10)
        clipboardIntents.paste = ClipboardShortcut(token: "42", remote: true, pid: 7, at: 10)
        precondition(gestureTapCallback(proxy: OpaquePointer(bitPattern: 1)!, type: event.type, event: event, refcon: nil) == nil)
        precondition(clipboardIntents.copy?.token == "41" && clipboardIntents.paste?.token == "42")
    }
    print("CAPTURE_GESTURE_ROUTING_SELF_TEST_PASS no_OS_input_posted=true")
    exit(0)
}
#endif

if CommandLine.arguments.contains("--self-test-wired-clipboard-intents") {
    var intents = ClipboardIntents(sequence: 100)
    let first = intents.beginCopy(remote: false, pid: 7, now: 10)
    precondition(first == "101")
    intents.copyToken = first
    precondition(intents.beginPaste(remote: false, pid: 7, now: 10.1) == nil)
    let paste = intents.beginPaste(remote: true, pid: 8, now: 10.2)!
    precondition(paste == "101.102")
    precondition(intents.paste!.valid(remote: true, pid: 99, now: 10.3))
    precondition(!intents.paste!.valid(remote: false, pid: 8, now: 10.3))
    precondition(!intents.paste!.valid(remote: true, pid: 8, now: 191.1))
    let nextPaste = intents.beginPaste(remote: true, pid: 8, now: 11.2)!
    precondition(nextPaste != paste)
    let second = intents.beginCopy(remote: true, pid: 8, now: 12)
    precondition(second != first && intents.paste == nil)
    intents.copyToken = second
    _ = intents.beginPaste(remote: false, pid: 7, now: 12.2)
    precondition(!intents.paste!.valid(remote: false, pid: 8, now: 12.3))
    precondition(intents.paste!.valid(remote: false, pid: 7, now: 12.3))
    print("CAPTURE_WIRED_CLIPBOARD_PASS nonce=true direction=true focus=true expiry=true native_same_side=true")
    exit(0)
}
if CommandLine.arguments.contains("--self-test-clipboard-event-routing") {
    precondition(wiredClipboardEnabled)
    let source = CGEventSource(stateID: .privateState)
    let proxy = CGEventTapProxy(bitPattern: 1)!
    func event(_ key: Int, _ type: CGEventType, _ flags: CGEventFlags = []) -> CGEvent {
        let result = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: type != .keyUp)!
        result.type = type; result.flags = flags; return result
    }
    func route(_ sample: CGEvent) -> Bool {
        eventTapCallback(proxy:proxy,type:sample.type,event:sample,refcon:nil) != nil
    }
    activeClient = false
    clipboardIntents.paste = ClipboardShortcut(token:"91.92",remote:false,pid:clipboardPID(),at:ProcessInfo.processInfo.systemUptime)
    consumeClipboardPasteKeyUp = true
    let repeated = event(9,.keyDown,[.maskCommand])
    repeated.setIntegerValueField(.keyboardEventAutorepeat,value:1)
    precondition(!route(repeated) && clipboardIntents.paste?.token == "91.92")
    precondition(!route(event(9,.keyUp,[.maskCommand])) && clipboardIntents.paste?.token == "91.92")
    precondition(route(event(55,.flagsChanged)) && clipboardIntents.paste?.token == "91.92")
    precondition(route(event(0,.keyDown)) && clipboardIntents.paste == nil)
    print("CAPTURE_CLIPBOARD_EVENT_ROUTING_PASS repeat_keeps_one_request=true release_preserved=true new_input_cancels=true no_OS_input_posted=true")
    exit(0)
}
if CommandLine.arguments.contains("--self-test-file-intents") {
    var state = FileTransferIntentState(revision: 10)
    var inspected = 0
    func file() -> Bool { inspected += 1; return true }
    precondition(state.direction(remote: true, revision: 10, now: 100,
                                  bookFinder: false, singleBookFile: file) == nil)
    precondition(inspected == 0)
    state.noteCopy(remote: false, cut: false, revision: 10, now: 100)
    precondition(state.direction(remote: true, revision: 10, now: 101,
                                  bookFinder: false, singleBookFile: file) == nil)
    precondition(inspected == 0) // Failed local copy must not send stale contents.
    precondition(state.direction(remote: true, revision: 11, now: 102,
                                  bookFinder: false, singleBookFile: file) == "OUT")
    state.consumed()
    precondition(state.direction(remote: true, revision: 11, now: 103,
                                  bookFinder: false, singleBookFile: file) == nil)
    // Menu/context copy changes revision without passing a Cmd+C event.
    precondition(state.direction(remote: true, revision: 12, now: 104,
                                  bookFinder: false, singleBookFile: file) == "OUT")
    state.noteCopy(remote: true, cut: false, revision: 12, now: 110)
    precondition(state.direction(remote: true, revision: 12, now: 111,
                                  bookFinder: false, singleBookFile: file) == nil)
    precondition(state.direction(remote: false, revision: 12, now: 111,
                                  bookFinder: false, singleBookFile: file) == nil)
    precondition(state.direction(remote: false, revision: 12, now: 112,
                                  bookFinder: true, singleBookFile: file) == "IN")
    // A local clipboard change invalidates previously observed remote copy.
    precondition(state.direction(remote: false, revision: 13, now: 113,
                                  bookFinder: true, singleBookFile: file) == nil)
    state.noteCopy(remote: true, cut: false, revision: 13, now: 120)
    precondition(state.direction(remote: false, revision: 13, now: 241,
                                  bookFinder: true, singleBookFile: file) == nil)
    state.noteCopy(remote: false, cut: true, revision: 13, now: 250)
    precondition(state.direction(remote: true, revision: 14, now: 251,
                                  bookFinder: false, singleBookFile: file) == nil)
    state.noteCopy(remote: true, cut: true, revision: 14, now: 252)
    precondition(state.direction(remote: false, revision: 14, now: 253,
                                  bookFinder: true, singleBookFile: file) == nil)
    for modifiers: CGEventFlags in [[.maskCommand, .maskShift],
            [.maskCommand, .maskAlternate], [.maskCommand, .maskControl], []] {
        precondition(!plainCommand(9, expected: 9, flags: modifiers))
    }
    precondition(plainCommand(9, expected: 9, flags: [.maskCommand]))
    precondition(!plainCommand(8, expected: 9, flags: [.maskCommand]))
    print("FILE_INTENTS_PASS enabled=\(fileTransferEnabled) expiry=true revision=true cut_passthrough=true")
    exit(0)
}

if CommandLine.arguments.contains("--self-test-file-pasteboard") {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("wk-file-capture-" + UUID().uuidString)
    try fm.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: directory) }
    let regular = directory.appendingPathComponent("one file.txt")
    let other = directory.appendingPathComponent("other.txt")
    let symlink = directory.appendingPathComponent("link.txt")
    try Data("test".utf8).write(to: regular)
    try Data("other".utf8).write(to: other)
    try fm.createSymbolicLink(at: symlink, withDestinationURL: regular)
    precondition(singleRegularFile([regular]))
    precondition(!singleRegularFile([regular, other]))
    precondition(!singleRegularFile([directory]))
    precondition(!singleRegularFile([symlink]))
    precondition(!singleRegularFile([directory.appendingPathComponent("missing")]))
    precondition(!singleRegularFile([]))
    precondition(!singleRegularFile([URL(string: "https://example.invalid/file")!]))
    print("FILE_PASTEBOARD_PASS single_regular=true multi_directory_link_text_rejected=true")
    exit(0)
}

if CommandLine.arguments.contains("--self-test-file-idle-handshake") {
    precondition(fileTransferEnabled)
    activeClient = false
    precondition(beginFileTransferRequest())
    precondition(fileTransferBusy && fileTransferWaitingForIdle)
    cancelFileTransfer()
    precondition(!fileTransferBusy && fileTransferWaitingForIdle)
    // Old native BUSY 1 arrives after the physical cancellation.
    receiveFileBusy(true)
    precondition(!fileTransferBusy && fileTransferWaitingForIdle)
    precondition(!beginFileTransferRequest())
    // A new copy can be recorded, but its paste must wait for old BUSY 0.
    fileTransferIntent.noteCopy(remote: true, cut: false, revision: 41, now: 100)
    precondition(requestFilePaste(keyCode: 9, flags: [.maskCommand], autorepeat: false))
    precondition(!fileTransferBusy && fileTransferWaitingForIdle && consumeFilePasteKeyUp)
    precondition(fileTransferIntent.origin == .remote)
    precondition(!requestFilePaste(keyCode: 9, flags: [.maskCommand, .maskAlternate], autorepeat: false))
    // The actual native idle acknowledgement is the only reopening boundary.
    receiveFileBusy(false)
    precondition(!fileTransferWaitingForIdle && !fileTransferBusy)
    precondition(fileTransferIntent.origin == .remote)
    precondition(beginFileTransferRequest())
    receiveFileBusy(true)
    precondition(fileTransferWaitingForIdle && fileTransferBusy)
    // Normal completion also closes the handshake, ready for the next intent.
    receiveFileBusy(false)
    precondition(!fileTransferWaitingForIdle && !fileTransferBusy)
    print("FILE_IDLE_HANDSHAKE_PASS retry_waits=true stale_busy_not_resurrected=true")
    exit(0)
}

if CommandLine.arguments.contains("--self-test-file-event-routing") {
    precondition(fileTransferEnabled)
    let source = CGEventSource(stateID: .privateState)
    let proxy = CGEventTapProxy(bitPattern: 1)!
    func event(_ key: Int, _ type: CGEventType, _ flags: CGEventFlags = []) -> CGEvent {
        let result = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: type != .keyUp)!
        result.type = type; result.flags = flags
        return result
    }
    func route(_ sample: CGEvent) -> Bool {
        eventTapCallback(proxy: proxy, type: sample.type, event: sample, refcon: nil) != nil
    }
    activeClient = false
    fileTransferBusy = true
    consumeFilePasteKeyUp = true
    precondition(!route(event(9, .keyUp, [.maskCommand])))
    precondition(fileTransferBusy && !consumeFilePasteKeyUp)
    precondition(route(event(55, .flagsChanged)))
    precondition(fileTransferBusy) // Originating modifier release isn't another action.
    let synthetic = event(9, .keyDown, [.maskCommand])
    synthetic.setIntegerValueField(.eventSourceUserData, value: fileTransferSyntheticMarker)
    precondition(route(synthetic) && fileTransferBusy)
    // Ordinary local input cancels and still reaches the local application.
    precondition(route(event(0, .keyDown)))
    precondition(!fileTransferBusy)
    fileTransferBusy = true
    precondition(!route(event(53, .keyDown, [.maskControl, .maskAlternate])))
    precondition(!fileTransferBusy && !activeClient && consumeEmergencyKeyUp)
    precondition(!route(event(53, .keyUp)))
    // Repeat of the initiating paste is swallowed, even after cancel.
    consumeFilePasteKeyUp = true
    let repeated = event(9, .keyDown, [.maskCommand])
    repeated.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    precondition(!route(repeated))
    precondition(!route(event(9, .keyUp)))
    print("FILE_EVENT_ROUTING_PASS release_pair=true synthetic_bypass=true local_cancel=true")
    exit(0)
}

if CommandLine.arguments.contains("--self-test-clipboard-shortcut") {
    if iphoneHIDMode || desktopAbsoluteMode {
        activeClient = true
        precondition(!shouldRequestWiredPaste(keyCode: 9, flags: [.maskCommand]))
        precondition(!shouldRequestWiredPaste(keyCode: 9,
                                        flags: [.maskControl, .maskAlternate, .maskShift]))
        let marker = iphoneHIDMode ? "CAPTURE_IPHONE_SHORTCUT_SELF_TEST_PASS" :
            "CAPTURE_ABSOLUTE_SHORTCUT_SELF_TEST_PASS"
        print("\(marker) native_cmd_v=true no_agent_paste=true")
        exit(0)
    }
    // Pure state check: never install a tap, hide the cursor, touch the
    // real clipboard, or inject any keyboard event.
    let explicit: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
    let normal: CGEventFlags = [.maskCommand]
    activeClient = false
    remoteClipboardIsSource = false
    assert(!shouldRequestWiredPaste(keyCode: 9, flags: explicit))
    assert(!shouldRequestWiredPaste(keyCode: 9, flags: normal))
    activeClient = true
    if nativeClipboardSync {
        assert(!shouldRequestWiredPaste(keyCode: 9, flags: normal))
        assert(shouldRequestWiredPaste(keyCode: 9, flags: explicit))
        noteCopyOrCut(.keyDown, keyCode: 8, flags: normal)
        assert(!shouldRequestWiredPaste(keyCode: 9, flags: normal))
        print("CAPTURE_CLIPBOARD_SYNC_SHORTCUT_SELF_TEST_PASS native_cmd_v=true forced_paste=true")
        exit(0)
    }
    // Remote Cmd+V after copying locally on the MacBook must use the
    // USB-C bulk/text WiredKVM route (not Apple Universal Clipboard).
    assert(shouldRequestWiredPaste(keyCode: 9, flags: normal))
    assert(shouldRequestWiredPaste(keyCode: 9, flags: explicit))
    assert(!shouldRequestWiredPaste(keyCode: 9,
                                    flags: [.maskCommand, .maskShift]))
    assert(!shouldRequestWiredPaste(keyCode: 9,
                                    flags: [.maskCommand, .maskAlternate]))
    assert(!shouldRequestWiredPaste(keyCode: 8, flags: normal))
    // Mini ordinary Cmd+C retains native Mini clipboard paste on Mini.
    noteCopyOrCut(.keyDown, keyCode: 8, flags: normal)
    assert(remoteClipboardIsSource)
    assert(!shouldRequestWiredPaste(keyCode: 9, flags: normal))
    assert(shouldRequestWiredPaste(keyCode: 9, flags: explicit))
    // Mini source survives leaving and re-entering the remote screen.
    activeClient = false
    activeClient = true
    assert(remoteClipboardIsSource)
    assert(!shouldRequestWiredPaste(keyCode: 9, flags: normal))
    // Book Cmd+C is native and marks Book as the next wired paste source.
    activeClient = false
    noteCopyOrCut(.keyDown, keyCode: 8, flags: normal)
    assert(!remoteClipboardIsSource)
    activeClient = true
    assert(shouldRequestWiredPaste(keyCode: 9, flags: normal))
    // Same behavior for ordinary Book text Cmd+X.
    noteCopyOrCut(.keyDown, keyCode: 7, flags: normal)
    assert(remoteClipboardIsSource)
    activeClient = false
    noteCopyOrCut(.keyDown, keyCode: 7, flags: normal)
    assert(!remoteClipboardIsSource)
    activeClient = true
    assert(shouldRequestWiredPaste(keyCode: 9, flags: normal))
    // Key-up and nonstandard modified copy shortcuts must not change origin.
    noteCopyOrCut(.keyUp, keyCode: 8, flags: normal)
    noteCopyOrCut(.keyDown, keyCode: 8, flags: [.maskCommand, .maskShift])
    assert(!remoteClipboardIsSource)
    activeClient = false
    print("CAPTURE_CLIPBOARD_HOTKEY_SELF_TEST_PASS remote_only=true " +
          "book_cmd_c_x_native=true wired_cmd_v=true mini_cmd_c_x_v_native=true " +
          "origin_persists_across_switch=true")
    exit(0)
}

// Run this from Terminal if another capture instance crashed while the
// MacBook pointer was detached or hidden. Does not install an EventTap.
if CommandLine.arguments.contains("--recover-pointer") {
    let associated = CGAssociateMouseAndMouseCursorPosition(1)
    let shown = CGDisplayShowCursor(kCGNullDirectDisplay)
    NSCursor.unhide()
    print("POINTER_RECOVERY_ASSOC=\(associated.rawValue) SHOW=\(shown.rawValue)")
    exit(associated == .success && shown == .success ? 0 : 1)
}

// Pure shortcut predicate test: never captures/warps the real pointer.
if CommandLine.arguments.contains("--self-test-return-shortcut") {
    activeClient = true
    precondition(isEmergencyReturnShortcut(keyCode: 53, flags: [.maskControl, .maskAlternate]))
    precondition(!isEmergencyReturnShortcut(keyCode: 53, flags: [.maskControl]))
    precondition(!isEmergencyReturnShortcut(keyCode: 53, flags: [.maskAlternate]))
    precondition(!isEmergencyReturnShortcut(keyCode: 53,
                                           flags: [.maskControl, .maskAlternate, .maskCommand]))
    precondition(!isEmergencyReturnShortcut(keyCode: 111, flags: [.maskControl, .maskAlternate]))
    activeClient = false
    precondition(!isEmergencyReturnShortcut(keyCode: 53, flags: [.maskControl, .maskAlternate]))
    print("CAPTURE_EMERGENCY_RETURN_SHORTCUT_PASS remote_only=true ctrl_option_escape=true")
    exit(0)
}

// Pure side-selection regression: does not install an EventTap or move cursor.
if CommandLine.arguments.contains("--self-test-mouse-speed") {
    precondition(scaledMouseDelta(0) == 0)
    precondition(scaledMouseDelta(500) == 127)
    precondition(scaledMouseDelta(-500) == -127)
    precondition(scaledMouseDelta(20) == clamp(Int((20.0 * mouseSpeed).rounded())))
    print("CAPTURE_MOUSE_SPEED_SELF_TEST_PASS speed=\(mouseSpeed)")
    exit(0)
}

if CommandLine.arguments.contains("--self-test-entry-metadata") {
    // Use two distinct local displays to check fresh metadata on every entry.
    emitEntryMetadata(bounds: CGRect(x: 120, y: 80, width: 1440, height: 900), fraction: 6250)
    emitEntryMetadata(bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440), fraction: 2500)
    print("CAPTURE_ENTRY_METADATA_SELF_TEST_PASS absolute=\(desktopAbsoluteMode)")
    exit(0)
}

if CommandLine.arguments.contains("--self-test-screen-side") {
    let bounds = CGRect(x: 120, y: 80, width: 1920, height: 1080)
    let atLeft = bounds.minX + 1
    let atRight = bounds.maxX - 1
    // precondition stays active in the optimized (-O) release build.
    precondition(entersClientAtEdge(x: targetPositionIsLeft ? atLeft : atRight,
                                    dx: targetPositionIsLeft ? -10 : 10, bounds: bounds))
    precondition(!entersClientAtEdge(x: targetPositionIsLeft ? atRight : atLeft,
                                     dx: targetPositionIsLeft ? 10 : -10, bounds: bounds))
    precondition(!entersClientAtEdge(x: targetPositionIsLeft ? atLeft : atRight,
                                     dx: targetPositionIsLeft ? 10 : -10, bounds: bounds))
    precondition(localPointerPosition(5000, bounds: bounds).x ==
                 (targetPositionIsLeft ? bounds.minX + 16 : bounds.maxX - 16))
    for fraction in [0, 2500, 5000, 7500, 10000] {
        let point = localPointerPosition(fraction, bounds: bounds)
        precondition(abs(normalizeY(point.y, bounds) - fraction) <= 1)
        precondition(point.x == (targetPositionIsLeft ? bounds.minX + 16 : bounds.maxX - 16))
    }
    print("CAPTURE_SCREEN_SIDE_PASS target=\(clientLabel) entry=\(targetPositionIsLeft ? "LEFT" : "RIGHT")")
    exit(0)
}

if CommandLine.arguments.contains("--check-permission") {
    let allowed = AXIsProcessTrusted()
    print("ACCESSIBILITY_TRUSTED=\(allowed)")
    exit(allowed ? 0 : 2)
}

if CommandLine.arguments.contains("--request-permission") {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let allowed = AXIsProcessTrustedWithOptions(options)
    print("ACCESSIBILITY_TRUSTED=\(allowed)")
    exit(allowed ? 0 : 2)
}

if CommandLine.arguments.contains("--self-test") {
    assert(macToHID[0] == 4 && macToHID[36] == 0x28)
    assert(macToHID[111] == 0x45 && macToHID[122] == 0x3A)
    assert(macToHID[115] == 0x4A && macToHID[117] == 0x4C)
    physicalFnDown = false
    assert(modMask([.maskSecondaryFn]) == 0) // inherited OS Fn is ignored
    physicalFnDown = true
    assert(modMask([]) == 16) // captured physical Fn is preserved
    physicalFnDown = false
    assert(clamp(500) == 127 && clamp(-500) == -127)
    let rect = CGDisplayBounds(CGMainDisplayID())
    assert(normalizeY(rect.minY, rect) == 0)
    assert(normalizeY(rect.maxY - 1, rect) == 10000)
    emit("M", 25, -12)
    emit("C", 2, 0)
    emit("T", 4, 1)
    emit("T", 4, 0)
    emit("C", 0, 0)
    emit("R")
    exit(0)
}

// Test actual keyboard event serialization without posting ANY OS input.
// Validate the source of D/E/Fn/F1 and a Control+Command+A sequence safely.
if CommandLine.arguments.contains("--self-test-key-events") {
    physicalFnDown = false
    lastSentModifiers = 0
    let source = CGEventSource(stateID: .privateState)
    func sample(_ key: Int, _ type: CGEventType, _ flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: CGKeyCode(key), keyDown: type != .keyUp) else {
            fatalError("Failed to construct Quartz test event")
        }
        event.type = type
        event.flags = flags
        forwardKeyboardEvent(type, event: event, keyCode: key)
    }
    // Global Fn can be spuriously set: plain D/E must NOT become Fn+D/E.
    sample(2, .keyDown, [.maskSecondaryFn]) // D
    sample(14, .keyDown, [.maskSecondaryFn]) // E
    sample(59, .flagsChanged, [.maskControl])
    sample(55, .flagsChanged, [.maskControl, .maskCommand])
    sample(0, .keyDown, [.maskControl, .maskCommand])
    sample(0, .keyUp, [.maskControl, .maskCommand])
    sample(55, .flagsChanged, [.maskControl])
    sample(59, .flagsChanged, [])
    sample(63, .flagsChanged, [.maskSecondaryFn]) // physical Fn down
    sample(2, .keyDown, [.maskSecondaryFn])      // genuine Fn+D
    sample(63, .flagsChanged, [])                // physical Fn up
    sample(14, .keyDown, [])                    // plain E again
    sample(122, .keyDown, [])                   // F1 -> HID 0x3A
    exit(0)
}

if CommandLine.arguments.contains("--self-test-mouse-drag") {
    let source = CGEventSource(stateID: .privateState)
    func sample(_ type: CGEventType, _ dx: Int = 0, _ dy: Int = 0, button: Int = 0) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: .zero, mouseButton: .left) else {
            fatalError("Failed to construct Quartz mouse test event")
        }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            forwardMouseMotion(type, event: event)
        default:
            forwardMouseButton(type, event: event)
        }
    }
    buttons = 0
    print("CASE normal-left")
    sample(.leftMouseDown)
    sample(.leftMouseDragged, 10, 0)
    sample(.leftMouseDragged, 7, -2)
    sample(.leftMouseUp)
    precondition(buttons == 0)
    print("CASE held-before-handoff")
    sample(.leftMouseDragged, 4, 3)
    sample(.leftMouseDragged, 2, -1)
    sample(.leftMouseUp)
    precondition(buttons == 0)
    print("CASE left-right-chord")
    sample(.leftMouseDown)
    sample(.rightMouseDragged, 5, 0)
    sample(.rightMouseUp)
    sample(.leftMouseDragged, 6, 0)
    sample(.leftMouseUp)
    precondition(buttons == 0)
    print("CASE other-button")
    sample(.otherMouseDragged, 1, 1, button: 3)
    sample(.otherMouseUp, button: 3)
    precondition(buttons == 0)
    print("CASE unsupported-button")
    sample(.otherMouseDragged, 1, -1, button: 6)
    sample(.otherMouseUp, button: 6)
    precondition(buttons == 0)
    print("CAPTURE_MOUSE_DRAG_SELF_TEST_PASS")
    exit(0)
}

if CommandLine.arguments.contains("--self-test-scroll") {
    let source = CGEventSource(stateID: .privateState)
    guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line,
                              wheelCount: 2, wheel1: 3, wheel2: -2, wheel3: 0) else {
        fatalError("Failed to construct Quartz scroll test event")
    }
    forwardScrollEvent(event)
    event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -500)
    event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 500)
    forwardScrollEvent(event)
    event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
    event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
    forwardScrollEvent(event)
    precondition(forwardedScrollDelta(Int.min) == (invertScroll ? 127 : -127))
    print("CAPTURE_SCROLL_SELF_TEST_PASS inverted=\(invertScroll)")
    exit(0)
}

// An opt-in 200ms test of cursor disassociation, visibility, and restoration.
// Restores the original MacBook pointer position before returning.
if CommandLine.arguments.contains("--self-test-cursor") {
    let before = CGEvent(source: nil)?.location ?? CGPoint.zero
    enterClient(before.y)
    let wasDetached = pointerDetached
    let wasHidden = pointerHidden
    Thread.sleep(forTimeInterval: 0.2)
    restoreLocalPointer()
    _ = CGWarpMouseCursorPosition(before)
    print("CURSOR_LOCK_DETACHED=\(wasDetached) HIDDEN=\(wasHidden)")
    print("CURSOR_REPIN_ENABLED=true")
    print("CURSOR_RESTORED=true")
    exit(wasDetached ? 0 : 1)
}

if iphoneHIDMode {
    fputs("WiredKVM iPhone HID mode: Ctrl+Option+F12 toggles; Ctrl+Option+Escape RETURNS to MacBook; Cmd+V is sent as HID.\n", stderr)
} else if fileTransferEnabled {
    fputs("WiredKVM single-file prototype: observed cross-machine Cmd+C/V uses Book-side Finder transfer; Ctrl+Option+Escape cancels from either screen.\n", stderr)
} else if desktopAbsoluteMode {
    fputs("WiredKVM USB HID mode: Ctrl+Option+F12 toggles; Ctrl+Option+Escape RETURNS to MacBook; Cmd+V uses the Mac mini clipboard, without cross-computer clipboard transfer.\n", stderr)
} else {
    fputs("WiredKVM active: Ctrl+Option+F12 toggles; Ctrl+Option+Escape RETURNS to MacBook; remote Cmd+V pastes over USB-C.\n", stderr)
}
guard AXIsProcessTrusted() else {
    fputs("ERROR: Grant Accessibility to the macos-capture binary or its terminal in System Settings.\n", stderr)
    exit(2)
}

let selectedEvents: [CGEventType] = [
    .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
    .otherMouseDown, .otherMouseUp, .scrollWheel,
    .keyDown, .keyUp, .flagsChanged,
    systemDefinedEvent,
]
let mask: CGEventMask = selectedEvents.reduce(0) {
    $0 | (CGEventMask(1) << $1.rawValue)
}

guard let tap = CGEvent.tapCreate(
    tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
    eventsOfInterest: mask, callback: eventTapCallback, userInfo: nil
) else {
    fputs("ERROR: CGEventTap could not be created. Check Input Monitoring permissions.\n", stderr)
    exit(3)
}
tapPort = tap
#if WK_PIXEL_SCROLL
if desktopAbsoluteMode && !iphoneHIDMode {
    pointingSource.refresh()
    nativeInputPolicy.refresh()
    if wiredInputEnabled && nativeInputPolicy.pixelEnabled { pixelScroll.start() }
    let gestureMask = WKGestureEnvelope.eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
    gestureTapPort = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
        options: .defaultTap, eventsOfInterest: gestureMask, callback: gestureTapCallback, userInfo: nil)
    if let gestureTapPort {
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gestureTapPort, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: gestureTapPort, enable: true)
    }
    fputs("WKCLIP_DIAG role=host event=GESTURE_CAPTURE_READY ready=\(gestureTapPort == nil ? 0 : 1)\n", stderr)
}
#endif
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

#if WK_RAW_TOUCH
if let helper=ProcessInfo.processInfo.environment["WK_RAW_TOUCH_HELPER"] {
    do {try rawTouch.start(path:helper)}catch {fputs("RAW_TOUCH_HELPER_FAILED \(error)\n",stderr)}
}
#endif
// The controller sends LINK repeatedly only while the authenticated
// wired connection is healthy. This monitor runs on the capture process's
// own runloop, independently of network I/O and controller termination.
let linkTimer = DispatchSource.makeTimerSource(queue: .main)
linkTimer.schedule(deadline: .now() + .milliseconds(100),
                   repeating: .milliseconds(100), leeway: .milliseconds(20))
linkTimer.setEventHandler {
    checkLinkWatchdog(); clipboardTimeout()
#if WK_PIXEL_SCROLL
    if desktopAbsoluteMode && !iphoneHIDMode { pointingSource.refresh(); refreshNativeInputPolicy() }
#endif
}
linkTimer.resume()

// Mac mini left-edge feedback may carry a normalized Y position.
DispatchQueue.global(qos: .userInitiated).async {
    while let command = readLine(strippingNewline: true) {
        let pieces = command.split(separator: " ")
#if WK_RAW_TOUCH
        if pieces.count==2 && pieces[0]=="TOUCH_READY" {
            let ready=pieces[1]=="1";DispatchQueue.main.async {rawTouch.setHardware(ready)};continue
        }
#endif
        if command == "LINK" {
            DispatchQueue.main.async { lastLinkSignal = CFAbsoluteTimeGetCurrent() }
        } else if pieces.count == 3 && pieces[0] == "CLIPBOARD" {
            let operation = String(pieces[1]), token = String(pieces[2])
            if ["COPY", "PASTE", "CANCEL", "STATE", "ORIGIN_IN", "ORIGIN_OUT"].contains(operation) {
                DispatchQueue.main.async { receiveClipboardControl(operation, token: token) }
            }
        } else if command == "FILE BUSY 1" {
            DispatchQueue.main.async { receiveFileBusy(true) }
        } else if command == "FILE BUSY 0" {
            DispatchQueue.main.async { receiveFileBusy(false) }
        } else if command == "SWITCH" {
            DispatchQueue.main.async { cancelFileTransfer(); toggleClient() }
        } else if command == "PASTE" {
            DispatchQueue.main.async {
                if activeClient { emit("V") }
            }
        } else if pieces.first == "RETURN" {
            let fraction = pieces.count == 2 ? Int(pieces[1]) : nil
            DispatchQueue.main.async {
                guard activeClient else { return }
                restoreLocalPointer(fraction)
                lastSentModifiers = 0
                physicalFnDown = false
                buttons = 0
                emit("R")
                let returnEdge = targetPositionIsLeft ? "LEFT" : "RIGHT"
                fputs("WiredKVM: \(clientLabel) returned -> MacBook \(returnEdge) edge\n", stderr)
            }
        }
    }
    // Parent process terminated or closed stdin without a clean EXIT.
    DispatchQueue.main.async {
        cancelFileTransfer()
        if activeClient {
            restoreLocalPointer()
            buttons = 0
            emit("R")
        }
        fputs("WiredKVM: capture stdin closed; local pointer restored\n", stderr)
        CFRunLoopStop(CFRunLoopGetMain())
    }
}

// On a controller shutdown the cursor must be re-associated and shown.
// Avoid the default SIGTERM teardown while the cursor is still detached.
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler {
    cancelFileTransfer()
    restoreLocalPointer()
    CFRunLoopStop(CFRunLoopGetMain())
}
term.resume()
atexit {
#if WK_RAW_TOUCH
    rawTouch.stop()
#endif
#if WK_PIXEL_SCROLL
    gesturePacer.cancel(); pixelScroll.stop()
#endif
    if pointerDetached { _ = CGAssociateMouseAndMouseCursorPosition(1) }
    if appCursorHidden { NSCursor.unhide() }
    if pointerHidden { _ = CGDisplayShowCursor(kCGNullDirectDisplay) }
}
CFRunLoopRun()
restoreLocalPointer()
