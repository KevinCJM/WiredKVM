import AppKit
import Darwin

@main enum PixelScrollSelfTest {
    static func main() {
        setbuf(stdout, nil)
        var count = 0
        func test(_ name: String, _ f: () -> Void) { f(); count += 1; print("PIXEL_SCROLL \(name) PASS") }
        let receiver = WKScrollReceiver()
        receiver.access = { true }; receiver.connection(true)
        var posted: [WKScrollPacket] = []; receiver.post = { posted.append($0) }
        let now = WKScrollPacket.now()
        func sample(_ sequence: UInt32, origin: UInt64 = 41, time: UInt64? = nil) -> WKScrollPacket {
            var p = WKScrollPacket(kind: .sample, session: receiver.session)
            p.sequence = sequence; p.origin = origin; p.time = time ?? now
            p.vertical = 7; p.horizontal = -3; p.phase = 1
            return p
        }
        test("packet-pixel-phase-flags-roundtrip") {
            var p = sample(1); p.momentum = 2; p.flags = CGEventFlags.maskShift.rawValue
            let q = WKScrollPacket(p.encode())!
            precondition(q.vertical == 7 && q.horizontal == -3 && q.phase == 1 && q.momentum == 2 && q.flags == p.flags)
        }
        test("checksum-truncation-reserved-bounds-validation") {
            var bytes = sample(1).encode(); bytes[20] ^= 1; precondition(WKScrollPacket(bytes) == nil)
            precondition(WKScrollPacket(bytes.prefix(63)) == nil)
            var p = sample(1); p.vertical = Int32.max; precondition(WKScrollPacket(p.encode()) == nil)
            p = sample(1); p.flags = UInt64.max; precondition(WKScrollPacket(p.encode()) == nil)
            p = sample(1); p.phase = 16; precondition(WKScrollPacket(p.encode()) == nil)
            p.phase = 128; precondition(WKScrollPacket(p.encode()) != nil)
            p.momentum = 4; precondition(WKScrollPacket(p.encode()) == nil)
            p = sample(1); p.source = 3; precondition(WKScrollPacket(p.encode()) == nil)
        }
        test("construct-pixel-event-without-posting") {
            var p = sample(1); p.momentum = 2; p.flags = CGEventFlags.maskAlternate.rawValue
            let event = WKScrollReceiver.event(from: p)!
            precondition(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 7)
            precondition(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == -3)
            precondition(event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
            precondition(event.getIntegerValueField(.scrollWheelEventScrollPhase) == 1)
            precondition(event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 2)
            precondition(event.flags == .maskAlternate)
        }
        test("fresh-accepted-and-duplicates-reordering-rejected") {
            _ = receiver.receive(sample(2).encode(), now: now)
            _ = receiver.receive(sample(2).encode(), now: now)
            _ = receiver.receive(sample(1).encode(), now: now)
            precondition(posted.count == 1)
        }
        test("stale-future-wrong-session-and-zero-origin-rejected") {
            let before = posted.count
            _ = receiver.receive(sample(3, time: now-200_000).encode(), now: now)
            _ = receiver.receive(sample(3, time: now+60_000).encode(), now: now)
            var p = sample(3); p.session ^= 1; _ = receiver.receive(p.encode(), now: now)
            _ = receiver.receive(sample(3, origin: 0).encode(), now: now)
            precondition(posted.count == before)
        }
        test("capture-restart-retires-prior-origin") {
            let before = posted.count
            _ = receiver.receive(sample(1, origin: 42).encode(), now: now)
            _ = receiver.receive(sample(4, origin: 41).encode(), now: now)
            precondition(posted.count == before+1)
        }
        test("access-loss-and-disconnect-never-post") {
            let before = posted.count
            receiver.access = { false }; _ = receiver.receive(sample(5, origin: 42).encode(), now: now)
            receiver.connection(false); receiver.access = { true }
            _ = receiver.receive(sample(5, origin: 42).encode(), now: now)
            precondition(posted.count == before)
            receiver.connection(true)
        }
        test("sequence-wrap") {
            let before = posted.count
            _ = receiver.receive(sample(UInt32.max).encode(), now: now)
            _ = receiver.receive(sample(0).encode(), now: now)
            precondition(posted.count == before+2)
        }
        let directory = "/private/tmp/wks-" + UUID().uuidString.prefix(8)
        WKScrollSocket.testDirectory = directory
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let host = WKScrollHost(), client = WKScrollClient()
        var permitted = true
        receiver.access = { permitted }
        let gestures = WKGestureReceiver()
        gestures.access = { permitted }; gestures.location = { .zero }
        var gestureEvents: [CGEvent] = [], gestureFormats: [UInt8] = []
        gestures.post = { gestureEvents.append($0) }
        gestures.connection(true, session: receiver.session)
        receiver.gesturesSupported = true
        receiver.gestureTemplateAcks = { gestures.templateAcks }
        host.sendReport = { data in
            if data.prefix(4) == WKGestureEnvelope.wireMagic && data[5] == 0 && data[7] >= 32 { gestureFormats.append(data[49]) }
            if data.prefix(4) == WKGestureEnvelope.compactMagic { gestureFormats.append(5) }
            if gestures.receive(data) { return true }
            return receiver.receive(data)
        }
        func pump(_ seconds: Double = 0.15) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                receiver.tick { host.receive($0) }
                host.tick()
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            }
        }
        host.start(); client.start()
        defer { client.stop(); host.stop() }
        test("private-socket-capability-handshake") { pump(); precondition(client.ready) }
        test("pixel-event-through-real-private-socket-and-receiver") {
            let before = posted.count
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                            wheel1: 9, wheel2: -4, wheel3: 0)!
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
            e.flags = .maskCommand
            precondition(client.forward(e)); pump(0.02)
            precondition(posted.count == before+1)
            precondition(posted.last!.vertical == 9 && posted.last!.horizontal == -4 &&
                         posted.last!.phase == 2 && posted.last!.momentum == 2 && posted.last!.flags == e.flags.rawValue)
        }
        test("screen-return-sends-cancel-not-extra-motion") {
            client.cancel(); pump(0.02)
            precondition(posted.last!.phase == 8 && posted.last!.momentum == 3 &&
                         posted.last!.vertical == 0 && posted.last!.horizontal == 0)
        }
        test("continuous-mouse-keeps-mouse-source-tag") {
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                            wheel1: 4, wheel2: 0, wheel3: 0)!
            precondition(client.forward(e, source: 1)); pump(0.02)
            precondition(posted.last!.source == 1 && posted.last!.vertical == 4)
        }
        test("second-host-cannot-replace-live-socket") {
            let second = WKScrollHost(); second.start(); second.stop()
            pump(); precondition(client.ready)
        }
        test("host-restart-and-usb-session-reconnect") {
            host.stop(); receiver.connection(false); pump(0.35); precondition(!client.ready)
            host.start(); receiver.connection(true); gestures.connection(true, session: receiver.session)
            pump(); precondition(client.ready)
        }
        test("permission-loss-removes-capability") {
            permitted = false; pump(0.2); precondition(!client.ready)
            permitted = true; pump(0.2); precondition(client.ready)
        }
        test("permission-restore-keeps-sequence-and-posting") {
            let before = posted.count
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                            wheel1: 4, wheel2: 0, wheel3: 0)!
            precondition(client.forward(e)); pump(0.02)
            precondition(posted.count == before+1 && posted.last!.vertical == 4)
        }
        test("native-gesture-private-socket-fragments-template-ack-and-delta") {
            precondition(client.gesturesReady)
            let e = CGEvent(source: nil)!; e.type = CGEventType(rawValue: 29)!
            e.flags = []; e.timestamp = 1; e.location = .zero
            e.setDoubleValueField(CGEventField(rawValue: 110)!, value: 8)
            e.setDoubleValueField(CGEventField(rawValue: 113)!, value: 0.025)
            e.setIntegerValueField(CGEventField(rawValue: 132)!, value: 2)
            precondition(client.forwardGesture(e, source: 2)); pump(0.2)
            precondition(gestureFormats.contains(4) && gestures.submitted == 1)
            e.setDoubleValueField(CGEventField(rawValue: 113)!, value: 0.03)
            precondition(client.forwardGesture(e, source: 2)); pump(0.03)
            precondition(gestureFormats.contains(5) && gestures.submitted == 2)
            precondition(abs(gestureEvents.last!.getDoubleValueField(CGEventField(rawValue: 113)!)-0.03)<0.000001)
            client.cancel(); pump(0.03)
            precondition(gestureEvents.last!.getIntegerValueField(CGEventField(rawValue: 132)!) == 8)
        }
        print("PIXEL_SCROLL_SELF_TEST_PASS count=\(count) no_OS_input_posted=true")
    }
}
