import Foundation
import Carbon

// Fn-only vendor metadata. Ordinary HID remains authoritative for hold/combos.
// No keyboard hook, pasteboard access, hotkey remapping, or preference writes.
final class WKFnKey {
    struct Event {
        let phase: UInt8, eligible: Bool, epoch: UInt32, press: UInt32
        let at: UInt64, held: UInt32
        init?(_ data: Data) {
            guard data.count == 64, data.prefix(4) == Data("WKFN".utf8), data[4] == 1,
                  (1...3).contains(data[5]), data[6] <= 1, data[7] == 0,
                  data[28..<60].allSatisfy({ $0 == 0 }),
                  Self.crc(data.prefix(60)) == (data.readLE(at: 60) as UInt32) else { return nil }
            phase = data[5]; eligible = data[6] == 1
            epoch = data.readLE(at: 8); press = data.readLE(at: 12)
            at = data.readLE(at: 16); held = data.readLE(at: 24)
            guard epoch != 0, press != 0, phase == 2 || held == 0 else { return nil }
        }
        static func crc(_ bytes: Data) -> UInt32 {
            var result: UInt32 = 0xffffffff
            for byte in bytes {
                result ^= UInt32(byte)
                for _ in 0..<8 { result = (result >> 1) ^ (result & 1 == 1 ? 0xedb88320 : 0) }
            }
            return ~result
        }
    }
    private struct Press {
        let epoch: UInt32, id: UInt32, at: UInt64, received: Double, source: String
    }
    private let current: () -> String?
    private let mode: () -> Int?
    private let selectNext: () -> Bool
    private var connected = false
    private var press: Press?
    private var pending: (press: Press, deadline: Double)?
    private var history: [(at: Double, source: String)] = []
    private var lastSample: Double = -.infinity
    private var lastEvent: (epoch: UInt32, id: UInt32, phase: UInt8)?
    private var newest: (epoch: UInt32, press: UInt32)?

    init(current: @escaping () -> String? = WKFnKey.currentSource,
         mode: @escaping () -> Int? = WKFnKey.actionMode,
         selectNext: @escaping () -> Bool = WKFnKey.selectNextSource) {
        self.current = current; self.mode = mode; self.selectNext = selectNext
    }
    func connection(_ connected: Bool) {
        self.connected = connected; press = nil; pending = nil
        history.removeAll(); lastSample = -.infinity; lastEvent = nil
        newest = nil
    }
    func cancelTap() { press = nil; pending = nil }
    private func sample(_ now: Double) {
        if now - lastSample >= 0.01 {
            lastSample = now
            if let source = current() {
                history.append((now, source))
                if history.count > 64 { history.removeFirst(history.count - 64) }
            }
        }
        if let p = press, now - p.received > 5 { press = nil }
    }
    func tick(_ now: Double) {
        guard connected else { return }
        sample(now)
        guard let action = pending, now >= action.deadline else { return }
        pending = nil
        guard mode() == 1, current() == action.press.source,
              !history.contains(where: { $0.at >= action.press.received - 0.05 && $0.source != action.press.source }) else { return }
        _ = selectNext()
    }
    @discardableResult func receive(_ data: Data, at now: Double) -> Bool {
        guard data.prefix(4) == Data("WKFN".utf8) else { return false }
        guard connected, let event = Event(data) else { return true }
        sample(now) // Process a queued cancel/new press before any deferred action.
        if let last = lastEvent, last.epoch == event.epoch, last.id == event.press,
           last.phase == event.phase { return true }
        lastEvent = (event.epoch, event.press, event.phase)
        if event.phase == 3 { press = nil; pending = nil; return true }
        if event.phase == 1 {
            if let newest, newest.epoch == event.epoch, event.press <= newest.press { return true }
            newest = (event.epoch, event.press)
            press = nil; pending = nil
            // Use the source immediately before the physical press as baseline;
            // a native action arriving before this metadata must not run twice.
            let source = history.last(where: { $0.at <= now - 0.05 })?.source ?? current()
            if event.eligible, mode() == 1, let source {
                press = Press(epoch: event.epoch, id: event.press, at: event.at, received: now, source: source)
            }
        } else {
            defer { press = nil }
            guard let p = press, p.epoch == event.epoch, p.id == event.press,
                  event.eligible, event.at >= p.at,
                  (event.at - p.at) / 1000 == UInt64(event.held),
                  (40...300).contains(event.held), (0...0.8).contains(now - p.received),
                  abs(now - p.received - Double(event.held) / 1000) < 0.15 else { return true }
            pending = (p, now + 0.03) // Give native macOS handling first chance.
        }
        return true
    }

    static func actionMode() -> Int? {
        (CFPreferencesCopyAppValue("AppleFnUsageType" as CFString,
                                  "com.apple.HIToolbox" as CFString) as? NSNumber)?.intValue
    }
    private static func sourceID(_ source: TISInputSource) -> String? {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
    static func currentSource() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return sourceID(source)
    }
    static func selectNextSource() -> Bool {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any,
                      kTISPropertyInputSourceIsEnabled as String: true,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let all = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let current = currentSource(), let index = all.firstIndex(where: { sourceID($0) == current }), all.count > 1 else { return false }
        let next = all[(index + 1) % all.count]
        return TISSelectInputSource(next) == noErr && currentSource() == sourceID(next)
    }
}
