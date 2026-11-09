import AppKit
#if !WK_PORTABLE
import ServiceManagement
#endif
import IOKit
import IOKit.serial
import Darwin

// Each USB role is usable before the other computer has any application.
// Development VID/PIDs are deliberately restricted, not shipping identities.
enum WKUSBDiscovery {
    // The native-touch prototype retains our private clipboard collection and
    // serial. Never match an ordinary Apple trackpad by VID/PID alone.
    static let targetIdentities: [(vendor: Int, product: Int)] = [(0x1a86, 0x4071), (0x05ac, 0x0265)]
    struct Port: Equatable {
        let path: String, serial: String
        let product: Int, interface: Int
        var role: String { product == 0x4070 ? "host" : "target" }
        // CDC ACM is a two-interface function. macOS can publish the serial
        // child below either the control or data interface of that function.
        var function: Int { role == "host" ? interface / 2 * 2 : 3 }
    }
    static func accepts(vendor: Int, product: Int, serial: String, interface: Int) -> Bool {
        serial == "CH32V407-DoNotShip" &&
            ((vendor == 0x1a86 && product == 0x4070 && (0...3).contains(interface)) ||
             (targetIdentities.contains { $0.vendor == vendor && $0.product == product } && [3, 4].contains(interface)))
    }
    static func ports() -> [Port] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [Port] = []
        while true {
            let entry = IOIteratorNext(iterator); if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            func property(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            guard let path = property(kIOCalloutDeviceKey) as? String, path.hasPrefix("/dev/cu."),
                  let vendor = property("idVendor") as? Int, let product = property("idProduct") as? Int,
                  let serial = property("USB Serial Number") as? String, let interface = property("bInterfaceNumber") as? Int,
                  accepts(vendor: vendor, product: product, serial: serial, interface: interface) else { continue }
            found.append(Port(path: path, serial: serial, product: product, interface: interface))
        }
        return found
    }
    static func unique(role: String, files: Bool, inventory: [Port]? = nil) -> String? {
        let interface = role == "host" ? (files ? 2 : 0) : 3
        let paths = Set((inventory ?? ports()).filter { $0.role == role && $0.function == interface }.map(\.path))
        return paths.count == 1 ? paths.first : nil
    }
}

// WKI1 local-port presence is not clipboard data and never crosses the bridge.
// Presence suppresses an unpublished disk; hide is sent only after local unmount.
enum WKSetupPacket {
    static func crc(_ bytes: Data) -> UInt32 {
        var value: UInt32 = .max
        for byte in bytes { value ^= UInt32(byte); for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb88320 : value >> 1 } }
        return ~value
    }
    static func encode(role: String, hide: Bool, sequence: UInt32) -> Data {
        var result = Data("WKI1".utf8); result.append(contentsOf: [1, role == "host" ? 0 : 1, hide ? 2 : 1, 0])
        for i in 0..<4 { result.append(UInt8(truncatingIfNeeded: sequence >> (i*8))) }
        result.append(Data(repeating: 0, count: 48))
        let checksum = crc(result); for i in 0..<4 { result.append(UInt8(truncatingIfNeeded: checksum >> (i*8))) }
        return result
    }
}

#if !WK_PORTABLE
@MainActor enum WKLoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var description: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已启用，登录后自动运行"
        case .requiresApproval: return "需要在系统设置中允许登录时运行"
        case .notRegistered: return "未启用登录自启"
        default: return "登录项不可用，请从本机 Applications 打开程序"
        }
    }
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
    }
    // A reconnect or installer reuse must not override a user's later choice.
    static func configureOnce(defaults: UserDefaults = .standard, register: (() throws -> Void)? = nil) -> String? {
        let key = "WiredKVMFirstRunLoginAttemptedV1"
        guard !defaults.bool(forKey: key) else { return nil }
        defaults.set(true, forKey: key)
        do { if let register { try register() } else { try setEnabled(true) }; return nil } catch { return error.localizedDescription }
    }
}

@MainActor final class WKFirstRunWindow: NSObject, NSWindowDelegate {
    private static var instances: [String: WKFirstRunWindow] = [:]
    static func shared(role: String) -> WKFirstRunWindow {
        if let value = instances[role] { return value }
        let value = WKFirstRunWindow(role: role); instances[role] = value; return value
    }
    private var window: NSWindow?
    private var timer: Timer?
    private let status = NSTextField(wrappingLabelWithString: "")
    private let role: String
    private let finishButton = NSButton(title: "稍后设置", target: nil, action: nil)
    private var loginError: String?
    init(role: String) { self.role = role; super.init() }
    func show() {
        if let window { refresh(); beginRefresh(); window.makeKeyAndOrderFront(nil); return }
        loginError = WKLoginItem.configureOnce()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = role == "host" ? "WiredKVM · 主控首次设置" : "WiredKVM · 被控首次设置"
        window.delegate = self
        let help = NSTextField(wrappingLabelWithString: "安装只需一次。完成系统权限确认后，程序登录时自动运行，插入连接线自动连接。\n可随时在菜单中关闭登录自启或退出程序。")
        help.frame = NSRect(x: 24, y: 180, width: 472, height: 75)
        status.frame = NSRect(x: 24, y: 90, width: 472, height: 80)
        let permissions = NSButton(title: "打开辅助功能设置", target: self, action: #selector(openPermissions))
        permissions.frame = NSRect(x: 22, y: 35, width: 180, height: 34)
        let login = NSButton(title: "检查登录自启", target: self, action: #selector(openLogin))
        login.frame = NSRect(x: 210, y: 35, width: 140, height: 34)
        let close = finishButton; close.target = self; close.action = #selector(closeWindow)
        close.frame = NSRect(x: 382, y: 35, width: 110, height: 34)
        for view in [help, status, permissions, login, close] { window.contentView?.addSubview(view) }
        self.window = window; refresh(); window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        beginRefresh()
    }
    private func beginRefresh() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }
    private func refresh() {
        let permission = AXIsProcessTrusted() && (role == "host" || CGPreflightPostEventAccess())
        status.stringValue = "辅助功能：" + (permission ? "已允许" : "需要在系统设置中允许") +
            "\n登录自启：" + WKLoginItem.description + (loginError.map { "\n" + $0 } ?? "")
        finishButton.title = permission && WKLoginItem.isEnabled ? "完成" : "稍后设置"
    }
    @objc private func openPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if role == "target" && !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    @objc private func openLogin() {
        do { try WKLoginItem.setEnabled(true); loginError = nil } catch { loginError = error.localizedDescription }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        refresh()
    }
    @objc private func closeWindow() { window?.close(); timer?.invalidate(); timer = nil }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }
}

#endif

enum WKFirstRunDefaults {
    static func prepareInputPolicy(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o022 == 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(EACCES)) }
        let path = directory.appendingPathComponent("input-mode.json").path
        let fd = Darwin.open(path, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC, 0o600)
        if fd < 0 {
            if errno == EEXIST { return } // Preserve the user's prior choice, including legacy mode.
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(fd) }
        let data = Data("{\"mode\":\"gestures\"}\n".utf8)
        let wrote = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if wrote != data.count { _ = Darwin.unlink(path); throw NSError(domain:NSPOSIXErrorDomain,code:Int(EIO)) }
    }
}

// Deterministic policy: wait for the installed companion to start; offer once
// per connection, never repeatedly stop a working controller or reopen a disk.
struct WKSetupOfferPolicy {
    private(set) var began: Double?
    private(set) var offered = false
    private(set) var ready = false
    mutating func reset(at time: Double?) { began = time; offered = false; ready = false }
    mutating func observe(connected: Bool, compatible: Bool) { if connected && compatible { ready = true } }
    mutating func shouldOffer(at time: Double, enabled: Bool, paused: Bool) -> Bool {
        guard enabled, !paused, !ready, !offered, let began, time-began >= 5 else { return false }
        offered = true; return true
    }
}

final class WKSetupLease {
    let role: String
    private let send: (Data) -> Bool
    private var sequence: UInt32 = 0
    private var next: Double = 0
    private var checking = false
    private var safeToHide = false
    private let unmount: (String) -> Bool
    init(role: String, send: @escaping (Data) -> Bool, unmount: ((String) -> Bool)? = nil) {
        self.role = role; self.send = send; self.unmount = unmount ?? Self.unmountOwnSetup
    }
    func tick(_ now: Double) {
        guard now >= next else { return }; next = now + 1
        sequence &+= 1
        _ = send(WKSetupPacket.encode(role: role, hide: safeToHide, sequence: sequence))
        guard !checking else { return }; checking = true
        let role = role, unmount = unmount
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let safe = unmount(role)
            DispatchQueue.main.async { [weak self] in self?.safeToHide = safe; self?.checking = false }
        }
    }
    private static func ownedDisk(_ bsd: String, role: String) -> Bool {
        guard bsd.hasPrefix("disk"), bsd.utf8.allSatisfy({ (48...57).contains($0) || [100,105,115,107].contains($0) }) else { return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        guard service != 0 else { return false }; defer { IOObjectRelease(service) }
        func property(_ key: String) -> Any? {
            IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        }
        return property("idVendor") as? Int == 0x1a86 && property("idProduct") as? Int == (role == "host" ? 0x4070 : 0x4071) &&
            property("USB Serial Number") as? String == "CH32V407-DoNotShip"
    }
    // Normal unmount of this role's own identified MSC only. No force, ejecting
    // the composite USB parent, arbitrary volume names, or target-machine access.
    private static func unmountOwnSetup(role: String) -> Bool {
        guard let volumes = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") else { return false }
        var safe = true
        for name in volumes where name == "WiredKVM Setup" || name.hasPrefix("WiredKVM Setup ") {
            let url = URL(fileURLWithPath: "/Volumes").appendingPathComponent(name)
            var fs = statfs(); guard statfs(url.path, &fs) == 0 else { continue }
            let device = withUnsafeBytes(of: &fs.f_mntfromname) { bytes in String(cString: bytes.bindMemory(to: CChar.self).baseAddress!) }
            let bsd = String(device.split(separator: "/").last ?? "")
            guard ownedDisk(bsd, role: role) else { continue }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = ["unmount", device]; process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do {
                try process.run(); let end = Date().addingTimeInterval(5)
                while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { process.terminate(); safe = false }
                else if process.terminationStatus != 0 { safe = false }
            } catch { safe = false }
        }
        return safe
    }
}
