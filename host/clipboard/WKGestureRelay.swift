import AppKit
import Compression

private extension Data {
    mutating func wgPut<T: FixedWidthInteger>(_ value: T, at: Int) {
        for i in 0..<MemoryLayout<T>.size { self[at+i] = UInt8(truncatingIfNeeded: value >> (8*i)) }
    }
    func wgGet<T: FixedWidthInteger>(_ at: Int) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size { value |= T(truncatingIfNeeded: self[at+i]) << (8*i) }
        return value
    }
}

// Complete, independently compressed Quartz gesture events. Only gesture types
// are allowed; keyboard/mouse events and clipboard bytes never enter this path.
struct WKGestureEnvelope {
    static let maximumRaw = 8192
    static let maximumEncoded = 1120
    static let localMagic = Data("WKGL".utf8)
    static let wireMagic = Data("WKG1".utf8)
    static let compactMagic = Data("WKG2".utf8)
    var time: UInt64
    var origin: UInt64
    var sequence: UInt32
    var rawLength: Int
    var eventType: UInt8
    var format: UInt8 // 0 raw, 1 zlib, 2 cancel, 3 lease, 4 template, 5 template delta
    var source: UInt8 = 2 // 1 mouse (e.g. native Magic Mouse gestures), 2 trackpad
    var encoded: Data
    static let eventTypes: Set<UInt32> = [18, 19, 20, 29, 30, 31]

    static func isRelayGesture(_ event: CGEvent) -> Bool {
        guard allowed(event), let kind = subtype(event) else { return false }
        if event.type.rawValue == 29 { return [5, 8, 16, 22, 23, 61, 62].contains(kind) }
        if event.type.rawValue == 30 { return kind == 23 }
        return true
    }

    static func subtype(_ event: CGEvent) -> Int? {
        let allowed: Set<Int> = [0, 5, 8, 11, 16, 22, 23, 61, 62]
        let field = CGEventField(rawValue: 110)!
        let integer = event.getIntegerValueField(field)
        if integer >= 0 && integer <= 62 && allowed.contains(Int(integer)) { return Int(integer) }
        let number = event.getDoubleValueField(field)
        if number.isFinite && (0...62).contains(number) && number.rounded() == number && allowed.contains(Int(number)) { return Int(number) }
        return nil
    }
    static func allowed(_ event: CGEvent) -> Bool {
        guard eventTypes.contains(event.type.rawValue), let kind = subtype(event) else { return false }
        // Private gesture fields share storage: magnification and rotation
        // must only be interpreted for their corresponding gesture subtype.
        let fields = kind == 8 ? [113] : kind == 5 ? [114] : kind == 23 ? [124, 129, 130] : []
        for field in fields {
            let value = event.getDoubleValueField(CGEventField(rawValue: UInt32(field))!)
            if !value.isFinite || abs(value) > 1_000_000 { return false }
        }
        return true
    }
    static func compress(_ raw: Data) -> Data? {
        guard !raw.isEmpty, raw.count <= maximumRaw else { return nil }
        var buffer = [UInt8](repeating: 0, count: maximumRaw + 256)
        let length = raw.withUnsafeBytes { p in
            compression_encode_buffer(&buffer, buffer.count, p.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
        }
        return length > 0 ? Data(buffer.prefix(length)) : nil
    }
    init?(event: CGEvent, origin: UInt64, sequence: UInt32, time: UInt64) {
        guard Self.allowed(event), let data = event.data else { return nil }
        let raw = data as Data
        guard !raw.isEmpty, raw.count <= Self.maximumRaw else { return nil }
        self.time = time; self.origin = origin; self.sequence = sequence
        self.rawLength = raw.count; self.eventType = UInt8(event.type.rawValue)
        if let compressed = Self.compress(raw), compressed.count < raw.count { format = 1; encoded = compressed }
        else { format = 0; encoded = raw }
        guard encoded.count <= Self.maximumEncoded else { return nil }
    }
    init(control: UInt8, origin: UInt64, sequence: UInt32, time: UInt64) {
        self.time = time; self.origin = origin; self.sequence = sequence
        rawLength = 0; eventType = 0; format = control; encoded = Data()
    }
    func encode() -> Data {
        var d = Data(repeating: 0, count: 32)
        d.wgPut(time, at: 0); d.wgPut(origin, at: 8); d.wgPut(sequence, at: 16)
        d.wgPut(UInt16(rawLength), at: 20); d.wgPut(UInt16(encoded.count), at: 22)
        d[24] = eventType; d[25] = format; d[26] = source; d.append(encoded)
        d.wgPut(WKScrollPacket.checksum(d.prefix(28) + d.dropFirst(32)), at: 28)
        return d
    }
    init?(_ d: Data) {
        guard d.count >= 32, (1...2).contains(d[26]), d[27] == 0,
              d.wgGet(28) as UInt32 == WKScrollPacket.checksum(d.prefix(28) + d.dropFirst(32)) else { return nil }
        time = d.wgGet(0); origin = d.wgGet(8); sequence = d.wgGet(16)
        rawLength = Int(d.wgGet(20) as UInt16); let length = Int(d.wgGet(22) as UInt16)
        eventType = d[24]; format = d[25]; source = d[26]; encoded = Data(d.dropFirst(32))
        guard origin != 0, length == encoded.count, length <= Self.maximumEncoded else { return nil }
        if format == 2 || format == 3 {
            guard rawLength == 0, length == 0, eventType == 0 else { return nil }
        } else {
            guard [0, 1, 4, 5].contains(format), Self.eventTypes.contains(UInt32(eventType)), rawLength > 0, rawLength <= Self.maximumRaw,
                  !encoded.isEmpty, format != 0 || rawLength == encoded.count else { return nil }
            if format >= 4 && encoded.count < 5 { return nil }
        }
    }
    var templateID: UInt32? { (format == 4 || format == 5) && encoded.count >= 4 ? encoded.wgGet(0) : nil }
    func raw(base: Data? = nil) -> Data? {
        guard format == 0 || format == 1 || format == 4 || format == 5 else { return nil }
        let data: Data
        if format != 0 {
            let payload = format >= 4 ? Data(encoded.dropFirst(4)) : encoded
            var buffer = [UInt8](repeating: 0, count: rawLength)
            let length = payload.withUnsafeBytes { p in
                compression_decode_buffer(&buffer, buffer.count, p.bindMemory(to: UInt8.self).baseAddress!, payload.count, nil, COMPRESSION_ZLIB)
            }
            guard length == rawLength else { return nil }
            if format == 5 {
                guard let base else { return nil }
                for i in buffer.indices { buffer[i] ^= i < base.count ? base[i] : 0 }
            }
            data = Data(buffer)
        } else { data = encoded }
        return data
    }
    func event(base: Data? = nil) -> CGEvent? {
        guard let data = raw(base: base) else { return nil }
        guard let event = CGEvent(withDataAllocator: nil, data: data as CFData),
              event.type.rawValue == UInt32(eventType), Self.allowed(event) else { return nil }
        return event
    }
    func template(id: UInt32) -> Self? {
        guard let raw = raw(), let compressed = Self.compress(raw), compressed.count+4 <= Self.maximumEncoded else { return nil }
        var result = self; result.format = 4; result.encoded = Data(repeating: 0, count: 4)
        result.encoded.wgPut(id, at: 0); result.encoded.append(compressed); return result
    }
    func delta(base: Data, id: UInt32) -> Self? {
        guard let raw = raw() else { return nil }
        var difference = raw
        for i in raw.indices { difference[i] ^= i < base.count ? base[i] : 0 }
        guard let compressed = Self.compress(difference), compressed.count+4 < encoded.count else { return nil }
        var result = self; result.format = 5; result.encoded = Data(repeating: 0, count: 4)
        result.encoded.wgPut(id, at: 0); result.encoded.append(compressed); return result
    }
    func local(session: UInt64) -> Data {
        var d = Self.localMagic; d.append(Data(repeating: 0, count: 8))
        d.wgPut(session, at: 4); d.append(encode()); return d
    }
    static func local(_ data: Data) -> (UInt64, Self)? {
        guard data.count >= 44, data.prefix(4) == localMagic,
              let body = Self(Data(data.dropFirst(12))) else { return nil }
        return (data.wgGet(4), body)
    }
    func reports(session: UInt64) -> [Data] {
        if format == 5, let templateID, encoded.count > 4, encoded.count-4 <= 28 {
            let payload = encoded.dropFirst(4)
            var d = Data(repeating: 0, count: 64); d.replaceSubrange(0..<4, with: Self.compactMagic)
            d[4] = UInt8(payload.count); d[5] = source; d.wgPut(UInt16(rawLength), at: 6)
            d.wgPut(session, at: 8); d.wgPut(sequence, at: 16); d.wgPut(templateID, at: 20)
            d.wgPut(time, at: 24); d.replaceSubrange(32..<(32+payload.count), with: payload)
            d.wgPut(WKScrollPacket.checksum(d.prefix(60)), at: 60); return [d]
        }
        let body = encode(); let count = (body.count + 35) / 36
        guard count > 0, count <= 32 else { return [] }
        return (0..<count).map { index in
            let chunk = body[(index*36)..<min(body.count, (index+1)*36)]
            var d = Data(repeating: 0, count: 64); d.replaceSubrange(0..<4, with: Self.wireMagic)
            d[4] = 1; d[5] = UInt8(index); d[6] = UInt8(count); d[7] = UInt8(chunk.count)
            d.wgPut(session, at: 8); d.wgPut(sequence, at: 16)
            d.wgPut(UInt32(truncatingIfNeeded: origin), at: 20)
            d.replaceSubrange(24..<(24+chunk.count), with: chunk)
            d.wgPut(WKScrollPacket.checksum(d.prefix(60)), at: 60); return d
        }
    }
}

final class WKGestureReceiver {
    private struct Key: Hashable { let origin: UInt32, id: UInt32 }
    private struct Assembly { let count: Int, began: UInt64; var chunks: [Int: Data] = [:] }
    private var assemblies: [Key: Assembly] = [:]
    private var session: UInt64 = 0, origin: UInt64 = 0, activity: UInt64 = 0
    private var sequence: UInt32?
    private var retired: [UInt64] = []
    private var active: CGEvent?
    private var templates: [UInt8: (id: UInt32, data: Data)] = [:]
    var templateAcks: (UInt64, UInt32, UInt32) { (origin, templates[29]?.id ?? 0, templates[30]?.id ?? 0) }
    private(set) var submitted: UInt32 = 0
    var access: () -> Bool = { CGPreflightPostEventAccess() }
    var post: (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }
    var location: () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero }
    var onGesture: () -> Void = {}

    func connection(_ ready: Bool, session: UInt64) {
        cancel(); self.session = ready ? session : 0
        assemblies.removeAll(); origin = 0; sequence = nil; retired.removeAll()
        templates.removeAll()
    }
    func cancel() {
        if let event = active?.copy(), access() {
            if WKGestureEnvelope.subtype(event) == 0 && event.type.rawValue != 29 { event.type = CGEventType(rawValue: 20)! }
            event.setIntegerValueField(CGEventField(rawValue: 132)!, value: 8)
            event.setIntegerValueField(CGEventField(rawValue: 134)!, value: 8)
            event.timestamp = WKScrollPacket.now() * 1000
            post(event)
        }
        active = nil
    }
    func tick(now: UInt64 = WKScrollPacket.now()) {
        assemblies = assemblies.filter { now >= $0.value.began && now - $0.value.began < 100_000 }
        if active != nil && now >= activity && now - activity > 500_000 { cancel() }
    }
    func receive(_ data: Data, now: UInt64 = WKScrollPacket.now()) -> Bool {
        if data.prefix(4) == WKGestureEnvelope.compactMagic { return receiveCompact(data, now: now) }
        guard data.prefix(4) == WKGestureEnvelope.wireMagic else { return false }
        guard session != 0, access(), data.count == 64, data[4] == 1,
              data.wgGet(8) as UInt64 == session,
              data.wgGet(60) as UInt32 == WKScrollPacket.checksum(data.prefix(60)) else { return true }
        let index = Int(data[5]), count = Int(data[6]), length = Int(data[7])
        guard (1...32).contains(count), index < count, (1...36).contains(length),
              (index == count-1 || length == 36), data[(24+length)..<60].allSatisfy({ $0 == 0 }) else { return true }
        let id: UInt32 = data.wgGet(16)
        let tag: UInt32 = data.wgGet(20)
        let key = Key(origin: tag, id: id)
        if assemblies[key] == nil {
            if assemblies.count >= 4, let old = assemblies.min(by: { $0.value.began < $1.value.began })?.key { assemblies.removeValue(forKey: old) }
            assemblies[key] = Assembly(count: count, began: now)
        }
        guard var assembly = assemblies[key], assembly.count == count,
              now >= assembly.began, now - assembly.began < 100_000 else { assemblies.removeValue(forKey: key); return true }
        let chunk = Data(data[24..<(24+length)])
        if let old = assembly.chunks[index], old != chunk { assemblies.removeValue(forKey: key); return true }
        assembly.chunks[index] = chunk; assemblies[key] = assembly
        guard assembly.chunks.count == count else { return true }
        assemblies.removeValue(forKey: key)
        let body = (0..<count).reduce(into: Data()) { $0.append(assembly.chunks[$1]!) }
        guard let envelope = WKGestureEnvelope(body), envelope.sequence == id, UInt32(truncatingIfNeeded: envelope.origin) == tag else { return true }
        return accept(envelope, now: now)
    }
    private func receiveCompact(_ d: Data, now: UInt64) -> Bool {
        guard session != 0, access(), d.count == 64, (1...28).contains(d[4]), (1...2).contains(d[5]),
              d.wgGet(8) as UInt64 == session,
              d.wgGet(60) as UInt32 == WKScrollPacket.checksum(d.prefix(60)),
              d[(32+Int(d[4]))..<60].allSatisfy({ $0 == 0 }) else { return true }
        let id: UInt32 = d.wgGet(20)
        let matches = templates.filter { $0.value.id == id }
        let length = Int(d.wgGet(6) as UInt16)
        guard origin != 0, matches.count == 1, let type = matches.first?.key,
              (1...WKGestureEnvelope.maximumRaw).contains(length) else { return true }
        var envelope = WKGestureEnvelope(control: 3, origin: origin, sequence: d.wgGet(16), time: d.wgGet(24))
        envelope.format = 5; envelope.rawLength = length; envelope.source = d[5]; envelope.eventType = type
        envelope.encoded = Data(repeating: 0, count: 4); envelope.encoded.wgPut(id, at: 0)
        envelope.encoded.append(d[32..<(32+Int(d[4]))])
        return accept(envelope, now: now)
    }
    private func accept(_ envelope: WKGestureEnvelope, now: UInt64) -> Bool {
        guard envelope.time <= now &+ 50_000, envelope.time > now || now - envelope.time < 150_000 else { return true }
        let id = envelope.sequence
        if envelope.origin != origin {
            guard !retired.contains(envelope.origin) else { return true }
            if origin != 0 && envelope.time < activity { return true }
            cancel()
            if origin != 0 { retired.append(origin); if retired.count > 8 { retired.removeFirst() } }
            origin = envelope.origin; sequence = nil; templates.removeAll()
        }
        if let previous = sequence {
            let difference = id &- previous
            guard difference > 0 && difference < 0x8000_0000 else { return true }
        }
        if envelope.format == 2 { sequence = id; cancel(); return true }
        if envelope.format == 3 { sequence = id; activity = now; return true }
        if envelope.format == 4 {
            guard [29, 30].contains(envelope.eventType), let key = envelope.templateID, key != 0,
                  let raw = envelope.raw(), envelope.event() != nil else { return true }
            templates[envelope.eventType] = (key, raw); sequence = id; return true
        }
        var base: Data?
        if envelope.format == 5 {
            guard let stored = templates[envelope.eventType], stored.id == envelope.templateID else { return true }
            base = stored.data
        }
        guard let event = envelope.event(base: base) else { return true }
        sequence = id; activity = now
        event.location = location(); event.timestamp = now * 1000
        event.setIntegerValueField(.eventSourceUserData, value: 0x574b4745)
        // A source Mac's registry/device IDs have no meaning on another Mac.
        event.setIntegerValueField(CGEventField(rawValue: 87)!, value: 0)
        event.setIntegerValueField(CGEventField(rawValue: 111)!, value: 0)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 0)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: 0)
        onGesture(); post(event); submitted &+= 1
        let subtype = WKGestureEnvelope.subtype(event)
        let phase = event.getIntegerValueField(CGEventField(rawValue: 132)!)
        if event.type.rawValue == 20 || subtype == 62 || phase & 12 != 0 || (phase == 0 && (subtype == 16 || subtype == 22 || event.type.rawValue == 31)) { active = nil }
        else if subtype != 11 && (subtype != 0 || event.type.rawValue != 29) { active = event.copy() }
        return true
    }
}
