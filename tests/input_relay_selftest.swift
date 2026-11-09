import AppKit
import Darwin

private final class InputOnlyTransport: WKTransport {
    var onReport: (Data) -> Void = { _ in }
    var onConnection: (Bool) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    var sent: [Data] = []
    var starts = 0, stops = 0
    func start() { starts += 1; onConnection(true) }
    func tick(_ time: Double) {}
    func send(_ bytes: Data) -> Bool { sent.append(bytes); return true }
    func stop() { stops += 1; onConnection(false) }
}

// Build this with only protocol/transport/scroll/gesture/input-relay sources.
// WKClipboard, WKCompanion, WKLink instances, file portals and NSPasteboard are
// absent. All event-post hooks point to arrays; no real input is injected.
@main enum InputRelaySelfTest {
    static func main() {
        setbuf(stdout, nil)
        var count = 0
        func test(_ name: String, _ body: () -> Void) {
            body(); count += 1; print("INPUT_RELAY \(name) PASS")
        }
        let wire = InputOnlyTransport(), scroll = WKScrollReceiver(), gesture = WKGestureReceiver()
        var samples: [WKScrollPacket] = [], events: [CGEvent] = [], logs: [String] = []
        scroll.access = { true }; scroll.post = { samples.append($0) }
        gesture.access = { true }; gesture.location = { .zero }; gesture.post = { events.append($0) }
        let relay = WKInputRelay(role: .target, transport: wire, scroll: scroll, gestures: gesture, log: { logs.append($0) })
        relay.start(automaticTick: false, handleSignals: false)
        test("capability-without-clipboard-handshake") {
            relay.tick()
            precondition(wire.starts == 1 && wire.sent.count == 1)
            let capability = WKScrollPacket(wire.sent[0])!
            precondition(capability.kind == .capability && capability.session == scroll.session)
            precondition(capability.features & 1 != 0)
        }
        test("ignore-clipboard-files-fn-and-unknown-reports") {
            let before = wire.sent.count
            for magic in ["WKC1", "WKF2", "WKFN", "WKBC", "JUNK"] {
                var data = Data(repeating: 0, count: 64); data.replaceSubrange(0..<4, with: Data(magic.utf8))
                precondition(!WKInputRelay.accepts(data)); wire.onReport(data)
            }
            precondition(samples.isEmpty && events.isEmpty && wire.sent.count == before)
        }
        var sample = WKScrollPacket(kind: .sample, session: scroll.session)
        sample.source = 2; sample.origin = 84; sample.sequence = 1
        sample.time = WKScrollPacket.now(); sample.vertical = -9; sample.horizontal = 3; sample.phase = 1
        test("scroll-keeps-pixel-sign-and-phase") {
            precondition(WKInputRelay.accepts(sample.encode()))
            wire.onReport(sample.encode())
            precondition(samples.count == 1 && samples[0].vertical == -9 && samples[0].horizontal == 3 && samples[0].phase == 1)
        }
        test("corrupt-and-truncated-input-never-posts") {
            let before = samples.count
            var corrupt = sample.encode(); corrupt[20] ^= 1
            precondition(!WKInputRelay.accepts(corrupt)); wire.onReport(corrupt)
            precondition(!WKInputRelay.accepts(Data(sample.encode().prefix(63))))
            wire.onReport(Data(sample.encode().prefix(63)))
            precondition(samples.count == before)
        }
        test("gesture-decodes-only-to-memory") {
            let event = CGEvent(source: nil)!
            event.type = CGEventType(rawValue: 30)!
            event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
            event.setIntegerValueField(CGEventField(rawValue: 132)!, value: 1)
            event.setDoubleValueField(CGEventField(rawValue: 124)!, value: 0.25)
            let envelope = WKGestureEnvelope(event: event, origin: 9, sequence: 1, time: WKScrollPacket.now())!
            let reports = envelope.reports(session: scroll.session)
            precondition(!reports.isEmpty)
            for report in reports { precondition(WKInputRelay.accepts(report)); wire.onReport(report) }
            precondition(events.count == 1 && events[0].type.rawValue == 30)
        }
        test("disconnect-cancels-active-gesture-and-rejects-old-session") {
            let before = events.count
            wire.onConnection(false)
            precondition(events.count == before + 1)
            precondition(events.last!.getIntegerValueField(CGEventField(rawValue: 132)!) == 8)
            wire.onReport(sample.encode()); precondition(samples.count == 1)
            wire.onConnection(true); wire.onReport(sample.encode()); precondition(samples.count == 1)
        }
        test("stop-is-idempotent-no-late-posts") {
            relay.stop(); relay.stop(); let posted = events.count
            relay.tick(); wire.onReport(sample.encode())
            precondition(!relay.running && wire.stops == 1 && events.count == posted)
        }

        // Private socket endpoint only; retain the unique scratch directory for
        // inspection. Never recursively delete a test path.
        let directory = "/private/tmp/wki-" + String(UUID().uuidString.prefix(8))
        WKScrollSocket.testDirectory = directory
        let hostWire = InputOnlyTransport(), host = WKScrollHost()
        let hostRelay = WKInputRelay(role: .host, transport: hostWire, host: host, log: { logs.append($0) })
        hostRelay.start(automaticTick: false, handleSignals: false)
        test("host-negotiates-existing-target-without-content-link") {
            var capability = WKScrollPacket(kind: .capability, session: 67)
            capability.time = WKScrollPacket.now(); capability.features = 3; capability.sequence = 12
            hostWire.onReport(capability.encode()); hostRelay.tick()
            precondition(host.ready && host.peerGesturesSubmitted == 12)
            precondition(hostWire.sent.isEmpty)
            precondition(logs.contains { $0.contains("PIXEL_SCROLL_READY ready=1") })
            precondition(logs.contains { $0.contains("GESTURE_PEER_SUBMITTED accepted=12") })
        }
        test("host-rejects-wrong-direction-and-invalid-capability") {
            hostWire.onReport(sample.encode())
            var malformed = WKScrollPacket(kind: .capability, session: 70).encode(); malformed[60] ^= 1
            hostWire.onReport(malformed)
            precondition(host.peerGesturesSubmitted == 12)
        }
        test("host-stop-releases-own-endpoint-and-keeps-other-files") {
            let sentinel = URL(fileURLWithPath: directory).appendingPathComponent("keep.txt")
            try! Data("keep".utf8).write(to: sentinel)
            hostRelay.stop(); precondition(!host.ready && hostWire.stops == 1)
            precondition(try! String(contentsOf: sentinel, encoding: .utf8) == "keep")
            precondition(!FileManager.default.fileExists(atPath: WKScrollSocket.serverPath))
            precondition(FileManager.default.fileExists(atPath: directory))
        }
        print("INPUT_RELAY_SELF_TEST_PASS tests=\(count) real_events=0 clipboard_instances=0 scratch_retained=\(directory)")
    }
}
