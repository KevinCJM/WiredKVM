import Foundation
import IOKit
import CoreGraphics
import Darwin

// Keep clipboard and HID usable while native input is validated independently.
// Missing/invalid policy is a safe legacy mode, never implicit experimental input.
final class WKNativeInputPolicy {
    enum Mode: String, Decodable { case legacy, pixel, gestures }
    private struct Configuration: Decodable { let mode: Mode }
    private(set) var mode: Mode = .legacy
    private var checkedAt = -Double.infinity
    let path: String
    init(path: String = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WiredKVM/input-mode.json").path) { self.path = path }
    var pixelEnabled: Bool { mode != .legacy }
    var gesturesEnabled: Bool { mode == .gestures }
    static func decode(_ data: Data) -> Mode {
        guard data.count <= 512 else { return .legacy }
        return (try? JSONDecoder().decode(Configuration.self, from: data).mode) ?? .legacy
    }
    @discardableResult func refresh(at time: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard time - checkedAt >= 1 else { return false }; checkedAt = time
        var next: Mode = .legacy
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
            defer { Darwin.close(fd) }
            var info = stat()
            if fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
               info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 512 {
                var bytes = [UInt8](repeating: 0, count: 513)
                let n = Darwin.read(fd, &bytes, bytes.count)
                if n == info.st_size { next = Self.decode(Data(bytes.prefix(n))) }
            }
        }
        let changed = next != mode; mode = next; return changed
    }
}

// Device presence is a hint; a trackpad gesture's MayBegin phase is stronger
// evidence. Continuous scrolling alone cannot distinguish a Magic Mouse.
final class WKPointingSource {
    enum Kind: String { case mouse, trackpad, unknown }
    struct Device {
        var id: UInt64
        var kind: Kind
        var product: String
        var transport: String
    }
    private(set) var devices: [Device] = []
    private var trackpadGesture = false
    private var gestureAt = -Double.infinity
    private var scannedAt = -Double.infinity
    private var origins: [UInt64: Kind] = [:]
    var scan: () -> [Device] = WKPointingSource.readDevices
    var resolve: (UInt64) -> Kind = WKPointingSource.readOrigin

    func refresh(at time: Double = ProcessInfo.processInfo.systemUptime) {
        guard time - scannedAt >= 1 else { return }
        scannedAt = time; devices = scan(); origins.removeAll()
    }
    var soleKind: Kind {
        let kinds = Set(devices.map(\.kind).filter { $0 != .unknown })
        return kinds.count == 1 ? kinds.first! : .unknown
    }
    func resetGesture() { trackpadGesture = false; gestureAt = -.infinity }
    func hardwareSource(_ event: CGEvent) -> Kind {
        // Sender registry ID is an undocumented Quartz field, so accept it
        // only when it resolves to an actual pointer service in IORegistry.
        guard let field = CGEventField(rawValue: 87) else { return .unknown }
        let sender = UInt64(bitPattern: event.getIntegerValueField(field))
        guard sender != 0 else { return .unknown }
        if let kind = origins[sender] { return kind }
        let kind = resolve(sender)
        if origins.count >= 16 { origins.removeAll() }
        origins[sender] = kind
        return kind
    }
    func scroll(_ event: CGEvent) -> Kind {
        scroll(continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
               phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
               momentum: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
               source: hardwareSource(event))
    }
    func gesture(_ event: CGEvent) -> Kind {
        let direct = hardwareSource(event)
        if direct != .unknown { return direct }
        let now = ProcessInfo.processInfo.systemUptime
        if trackpadGesture && now >= gestureAt && now - gestureAt < 0.5 { return .trackpad }
        return soleKind
    }
    func scroll(continuous: Bool, phase: Int64, momentum: Int64,
                at time: Double = ProcessInfo.processInfo.systemUptime, source: Kind = .unknown) -> Kind {
        if time - gestureAt > 0.5 || time < gestureAt { resetGesture() }
        if source != .unknown {
            if source == .trackpad { trackpadGesture = true; gestureAt = time }
            return source
        }
        // Apple documents that a Magic Mouse never emits trackpad MayBegin.
        if continuous && phase & 128 != 0 {
            trackpadGesture = true; gestureAt = time; return .trackpad
        }
        if !continuous { return .mouse }
        if trackpadGesture && (phase != 0 || momentum != 0) {
            gestureAt = time
            if phase & 8 != 0 || momentum == 3 { trackpadGesture = false }
            return .trackpad
        }
        // In mixed-device sessions, do not label a high-resolution mouse or a
        // partially observed gesture as a trackpad without evidence.
        return soleKind
    }
    static func kind(product: String, transport: String, vendor: Int,
                     page: Int, usage: Int) -> Kind {
        if transport.lowercased() == "virtual" || product.lowercased().contains("wiredkvm") { return .unknown }
        if page == 13 && usage == 5 { return .trackpad }
        if page == 1 && usage == 2 {
            if vendor == 0x05ac && product.lowercased().contains("trackpad") { return .trackpad }
            return .mouse
        }
        return .unknown
    }
    static func readDevices() -> [Device] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [Device] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            let product = property("Product") as? String ?? ""
            let transport = property("Transport") as? String ?? ""
            let vendor = (property("VendorID") as? NSNumber)?.intValue ?? 0
            let page = (property("PrimaryUsagePage") as? NSNumber)?.intValue ?? 0
            let usage = (property("PrimaryUsage") as? NSNumber)?.intValue ?? 0
            let kind = kind(product: product, transport: transport, vendor: vendor, page: page, usage: usage)
            if kind != .unknown {
                var id: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS {
                    result.append(Device(id: id, kind: kind, product: product, transport: transport))
                }
            }
        }
        return result
    }
    static func readOrigin(_ sender: UInt64) -> Kind {
        var service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(sender))
        for _ in 0..<8 {
            if service == 0 { break }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            let value = kind(product: property("Product") as? String ?? "",
                transport: property("Transport") as? String ?? "",
                vendor: (property("VendorID") as? NSNumber)?.intValue ?? 0,
                page: (property("PrimaryUsagePage") as? NSNumber)?.intValue ?? 0,
                usage: (property("PrimaryUsage") as? NSNumber)?.intValue ?? 0)
            if value != .unknown { IOObjectRelease(service); return value }
            var parent: io_registry_entry_t = 0
            _ = IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent)
            IOObjectRelease(service); service = parent
        }
        if service != 0 { IOObjectRelease(service) }
        return .unknown
    }
}
