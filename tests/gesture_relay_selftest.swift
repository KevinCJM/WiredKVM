import AppKit

@main enum GestureRelaySelfTest {
    static let time: UInt64 = 10_000_000
    static func event(_ type: UInt32 = 29, subtype: Int64 = 8, phase: Int64 = 2) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.type = CGEventType(rawValue: type)!
        event.location = .zero; event.flags = []; event.timestamp = 1
        event.setDoubleValueField(CGEventField(rawValue: 110)!, value: Double(subtype))
        if subtype == 5 { event.setDoubleValueField(CGEventField(rawValue: 114)!, value: 12.5) }
        else if subtype == 8 { event.setDoubleValueField(CGEventField(rawValue: 113)!, value: 0.025) }
        else if subtype == 23 { event.setDoubleValueField(CGEventField(rawValue: 124)!, value: 0.4) }
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        return event
    }
    final class Fixture {
        let receiver = WKGestureReceiver()
        var posted: [CGEvent] = []
        init(access: Bool = true) {
            receiver.access = { access }; receiver.location = { CGPoint(x: 12, y: 34) }
            receiver.post = { [unowned self] in posted.append($0) }
            receiver.connection(true, session: 42)
        }
        func envelope(_ seq: UInt32 = 1, origin: UInt64 = 11, at: UInt64 = time) -> WKGestureEnvelope {
            WKGestureEnvelope(event: event(), origin: origin, sequence: seq, time: at)!
        }
        func deliver(_ e: WKGestureEnvelope, at: UInt64 = time, session: UInt64 = 42) {
            for d in e.reports(session: session) { _ = receiver.receive(d, now: at) }
        }
    }
    static func main() {
        setbuf(stdout, nil)
        var count = 0
        func test(_ name: String, _ f: () -> Void) { f(); count += 1; print("GESTURE_RELAY \(name) PASS") }
        test("native-event-roundtrip-and-bounded-fragmentation") {
            for type: UInt32 in [18, 19, 20, 29, 30, 31] {
                let original = event(type, subtype: type == 30 ? 23 : 8)
                let e = WKGestureEnvelope(event: original, origin: 1, sequence: 1, time: time)!
                let copy = WKGestureEnvelope(e.encode())!.event()!
                precondition(copy.type == original.type)
                for field: UInt32 in [110, 113, 114, 124, 132] {
                    precondition(copy.getDoubleValueField(CGEventField(rawValue: field)!) == original.getDoubleValueField(CGEventField(rawValue: field)!))
                }
                precondition((1...32).contains(e.reports(session: 42).count))
                print("GESTURE_SIZE type=\(type) raw=\(e.rawLength) encoded=\(e.encoded.count) reports=\(e.reports(session: 42).count)")
            }
        }
        test("keyboard-mouse-and-unrecognized-subtypes-rejected") {
            for type: UInt32 in [0, 1, 5, 10, 11, 12, 22] { precondition(!WKGestureEnvelope.allowed(event(type))) }
            precondition(!WKGestureEnvelope.allowed(event(29, subtype: 4)))
            let bad = event(); bad.setDoubleValueField(CGEventField(rawValue: 113)!, value: .nan)
            precondition(!WKGestureEnvelope.allowed(bad))
            for subtype: Int64 in [0, 6, 11, 32] {
                precondition(!WKGestureEnvelope.isRelayGesture(event(29, subtype: subtype)))
            }
            for subtype: Int64 in [5, 8, 16, 22, 23, 61, 62] {
                precondition(WKGestureEnvelope.isRelayGesture(event(29, subtype: subtype)))
            }
        }
        test("complete-event-retargeted-without-posting-real-input") {
            let f = Fixture(); f.deliver(f.envelope())
            precondition(f.posted.count == 1 && f.receiver.submitted == 1)
            precondition(f.posted[0].location == CGPoint(x: 12, y: 34))
            precondition(f.posted[0].timestamp == time * 1000)
            precondition(f.posted[0].getIntegerValueField(.eventSourceUserData) == 0x574b4745)
            precondition(abs(f.posted[0].getDoubleValueField(CGEventField(rawValue: 113)!)-0.025)<0.000001)
        }
        test("fragment-reordering-and-replays") {
            let f = Fixture(), e = Fixture().envelope()
            let packets = e.reports(session: 42)
            for d in packets.reversed() { _ = f.receiver.receive(d, now: time) }
            for d in packets { _ = f.receiver.receive(d, now: time) }
            precondition(f.receiver.submitted == 1)
        }
        test("corrupt-truncated-incomplete-and-wrong-session-rejected") {
            let f = Fixture(); let packets = f.envelope().reports(session: 42)
            for var d in packets { d[25] ^= 1; _ = f.receiver.receive(d, now: time) }
            for d in packets { _ = f.receiver.receive(d.prefix(63), now: time) }
            _ = f.receiver.receive(packets[0], now: time)
            f.receiver.tick(now: time+200_000)
            f.deliver(f.envelope(), session: 43)
            precondition(f.posted.isEmpty)
        }
        test("stale-and-future-events-are-not-replayed") {
            let f = Fixture()
            f.deliver(f.envelope(at: time-200_000)); f.deliver(f.envelope(at: time+60_000))
            precondition(f.posted.isEmpty)
        }
        test("cancel-on-screen-return") {
            let f = Fixture(); f.deliver(f.envelope())
            f.deliver(WKGestureEnvelope(control: 2, origin: 11, sequence: 2, time: time))
            precondition(f.posted.count == 2)
            precondition(f.posted.last!.getIntegerValueField(CGEventField(rawValue: 132)!) == 8)
        }
        test("lease-renewal-and-timeout-cancel") {
            let f = Fixture(); f.deliver(f.envelope())
            f.deliver(WKGestureEnvelope(control: 3, origin: 11, sequence: 2, time: time+400_000), at: time+400_000)
            f.receiver.tick(now: time+800_000); precondition(f.posted.count == 1)
            f.receiver.tick(now: time+1_000_001); precondition(f.posted.count == 2)
        }
        test("permission-and-disconnect-boundaries") {
            let denied = Fixture(access: false); denied.deliver(denied.envelope()); precondition(denied.posted.isEmpty)
            let f = Fixture(); f.deliver(f.envelope()); f.receiver.connection(false, session: 0)
            precondition(f.posted.count == 2)
            f.deliver(f.envelope(2)); precondition(f.posted.count == 2)
        }
        test("capture-incarnation-retires-old-stream") {
            let f = Fixture(); f.deliver(f.envelope())
            f.deliver(f.envelope(1, origin: 12, at: time+1), at: time+1)
            let count = f.receiver.submitted
            f.deliver(f.envelope(2, origin: 11, at: time+2), at: time+2)
            precondition(f.receiver.submitted == count)
        }
        test("acknowledged-template-delta-preserves-native-values") {
            let f = Fixture(), base = Fixture().envelope()
            f.deliver(base.template(id: 71)!)
            precondition(f.posted.isEmpty && f.receiver.templateAcks.0 == 11 && f.receiver.templateAcks.1 == 71)
            let changed = event(); changed.setDoubleValueField(CGEventField(rawValue: 113)!, value: 0.03)
            let full = WKGestureEnvelope(event: changed, origin: 11, sequence: 2, time: time)!
            let delta = full.delta(base: base.raw()!, id: 71)!
            precondition(delta.encoded.count < full.encoded.count)
            precondition(delta.reports(session: 42).count == 1 && delta.reports(session: 42)[0].prefix(4) == WKGestureEnvelope.compactMagic)
            f.deliver(delta)
            precondition(f.receiver.submitted == 1)
            precondition(abs(f.posted[0].getDoubleValueField(CGEventField(rawValue: 113)!)-0.03)<0.000001)
            print("GESTURE_DELTA full=\(full.encoded.count) delta=\(delta.encoded.count) reports=\(delta.reports(session: 42).count)")
        }
        test("lost-or-wrong-template-does-not-post-corrupt-gesture") {
            let f = Fixture(), base = Fixture().envelope()
            let full = WKGestureEnvelope(event: event(), origin: 11, sequence: 2, time: time)!
            let delta = full.delta(base: base.raw()!, id: 71)!
            f.deliver(delta); precondition(f.posted.isEmpty)
            f.deliver(base.template(id: 72)!)
            f.deliver(delta); precondition(f.posted.isEmpty)
            var definition = base.template(id: 71)!; definition.sequence = 3
            f.deliver(definition)
            let newest = WKGestureEnvelope(event: event(), origin: 11, sequence: 4, time: time)!
            f.deliver(newest.delta(base: base.raw()!, id: 71)!); precondition(f.receiver.submitted == 1)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--fixtures") {
            var fixtures: [[String: Any]] = []
            for subtype: Int64 in [5, 8, 16, 22, 23, 61, 62] {
                let e = event(subtype == 23 ? 30 : 29, subtype: subtype)
                fixtures.append(["type": e.type.rawValue, "subtype": subtype, "data": (e.data! as Data).base64EncodedString()])
            }
            try! JSONSerialization.data(withJSONObject: fixtures).write(to: URL(fileURLWithPath: CommandLine.arguments[i+1]))
        }
        print("GESTURE_RELAY_SELF_TEST_PASS count=\(count) no_OS_input_posted=true")
    }
}
