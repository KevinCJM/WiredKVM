import Foundation
import Darwin

struct WKExchangeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct WKExchangeReply {
    let state: String
    let bytes: UInt64
    let detail: String

    init(_ line: String) throws {
        let fields = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard fields.count >= 2, fields[0] == "OK" else {
            throw WKExchangeError(message: WKExchangeReply.explain(line))
        }
        state = String(fields[1])
        bytes = fields.count > 2 ? UInt64(fields[2]) ?? 0 : 0
        detail = fields.dropFirst(3).joined(separator: " ")
    }

    static func explain(_ text: String) -> String {
        if text.contains("CAP_UNSUPPORTED") { return "板上固件尚未支持交换盘，请先更新固件。" }
        if text.contains("IMAGE_BUSY") { return "交换盘仍被使用，已保留原状态；请关闭盘内文件后重试。" }
        if text.contains("IMAGE_IO_FAILED") { return "Book 磁盘读写失败；请检查剩余空间，交换盘文件已保留。" }
        if text.contains("IMAGE_CHANGED") || text.contains("DIRTY_MARKER_INVALID") {
            return "未归还交换盘的文件或状态不匹配；已停止操作并保留数据。"
        }
        if text.contains("DIRTY") || text.contains("REMOTE") || text.contains("EJECT") {
            return "请先在 mini 的 Finder 中推出 WIREDKVM 交换盘，再在 Book 打开。"
        }
        if text.contains("OFFLINE") || text.contains("UNAVAILABLE") {
            return "交换盘尚未连接；请保持两侧 USB 接好并开始控制。"
        }
        return "交换盘操作未完成：" + String(text.prefix(180))
    }
}

// All USB serial traffic stays in the existing native controller. This client
// only requests ownership changes through its private local Unix socket.
struct WKExchangeDisk {
    static let capacity: Int64 = 256 * 1024 * 1024
    let directory: URL
    let socketURL: URL
    var imageURL: URL { directory.appendingPathComponent("exchange.img") }
    var mountURL: URL { directory.appendingPathComponent("Book") }

    init(directory: URL? = nil, socketURL: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                in: .userDomainMask)[0].appendingPathComponent("WiredKVM/Exchange", isDirectory: true)
        self.socketURL = socketURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("wiredkvm-exchange.sock")
    }

    var controllerArguments: [String] {
        ["--exchange-image", imageURL.path, "--exchange-socket", socketURL.path]
    }

    func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else {
            throw WKExchangeError(message: "交换盘目录不是当前用户的普通目录。")
        }
    }

    func request(_ command: String, timeout: TimeInterval = 3) throws -> WKExchangeReply {
        guard ["STATUS", "STATUS2", "LOCAL", "PUBLISH"].contains(command) else {
            throw WKExchangeError(message: "未知交换盘操作")
        }
        var address = sockaddr_un()
        let path = Array(socketURL.path.utf8) + [UInt8(0)]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw WKExchangeError(message: "本机交换盘通信路径过长")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.copyBytes(from: path)
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WKExchangeError(message: "无法创建本机通信接口") }
        defer { Darwin.close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout.size(ofValue: limit)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout.size(ofValue: limit)))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw WKExchangeError(message: "交换盘服务未连接，请先开始控制。")
        }
        let data = Array((command + "\n").utf8)
        let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard sent == data.count else { throw WKExchangeError(message: "交换盘请求发送失败") }
        var output = [UInt8]()
        var part = [UInt8](repeating: 0, count: 512)
        while output.count < 2048 {
            let count = Darwin.read(fd, &part, part.count)
            guard count > 0 else { throw WKExchangeError(message: "交换盘操作超时或连接已关闭") }
            output.append(contentsOf: part.prefix(count))
            if let newline = output.firstIndex(of: 10) {
                return try WKExchangeReply(String(decoding: output[..<newline], as: UTF8.self))
            }
        }
        throw WKExchangeError(message: "交换盘响应异常")
    }

    // Process arguments are passed directly, never through a shell. Formatting
    // is only allowed for a newly-created temporary image owned by this call.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 45) throws -> Data {
        guard timeout.isFinite, timeout > 0 else {
            throw WKExchangeError(message: "交换盘操作超时设置无效")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let output = Pipe()
        task.standardOutput = output
        let errors = Pipe()
        task.standardError = errors
        let readers = [output.fileHandleForReading, errors.fileHandleForReading]
        defer {
            for handle in readers { try? handle.close() }
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
        }
        for handle in readers {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw WKExchangeError(message: "无法读取交换盘工具输出")
            }
        }
        try task.run()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        var descriptors = readers.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
        var streams = [Data(), Data()]
        var bytes = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var stoppingAt: TimeInterval?
        var killedAt: TimeInterval?
        var failure: String?
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if failure == nil, now >= deadline {
                failure = "交换盘操作超时，尚未确认完成；请保留镜像并稍后重试。"
            }
            if failure != nil {
                if !task.isRunning { break }
                if stoppingAt == nil {
                    task.terminate()
                    stoppingAt = now
                } else if killedAt == nil, now - stoppingAt! >= 0.5 {
                    // Only this Process's still-running child is signalled.
                    _ = Darwin.kill(task.processIdentifier, SIGKILL)
                    killedAt = now
                } else if let killedAt, now - killedAt >= 1 { break }
            } else if !task.isRunning, descriptors.allSatisfy({ $0.fd < 0 }) { break }

            let ready = Darwin.poll(&descriptors, nfds_t(descriptors.count), 50)
            if ready < 0 {
                if errno != EINTR { failure = "读取交换盘工具输出失败，尚未确认操作完成。" }
                continue
            }
            for index in descriptors.indices where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                // Bound each drain so continuous output cannot starve timeout handling.
                for _ in 0..<32 {
                    let count = Darwin.read(descriptors[index].fd, &bytes, bytes.count)
                    if count > 0 {
                        streams[index].append(contentsOf: bytes.prefix(count))
                        if index == 1, streams[index].count > 65536 {
                            streams[index].removeFirst(streams[index].count - 65536)
                        }
                    } else if count == 0 {
                        descriptors[index].fd = -1
                        break
                    } else if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    else if errno != EINTR {
                        failure = "读取交换盘工具输出失败，尚未确认操作完成。"
                        descriptors[index].fd = -1
                        break
                    }
                }
            }
        }
        if let failure { throw WKExchangeError(message: failure) }
        task.waitUntilExit() // Already exited; never wait indefinitely after a timeout.
        guard task.terminationStatus == 0 else {
            let message = String(decoding: streams[1], as: UTF8.self)
            throw WKExchangeError(message: "交换盘操作失败：" + String(message.suffix(220)))
        }
        return streams[0]
    }

    struct Attachment {
        let device: String
        let mount: URL?
    }

    static func attachment(in data: Data, image: URL) throws -> Attachment? {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any], let images = plist["images"] as? [[String: Any]] else {
            throw WKExchangeError(message: "无法识别系统磁盘状态")
        }
        let expected = image.standardizedFileURL.resolvingSymlinksInPath().path
        let matches = images.filter { entry in
            guard let path = entry["image-path"] as? String else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == expected
        }
        guard matches.count <= 1 else { throw WKExchangeError(message: "交换盘有重复挂载，请先推出") }
        guard let match = matches.first, let entities = match["system-entities"] as? [[String: Any]] else {
            return nil
        }
        guard let device = entities.compactMap({ $0["dev-entry"] as? String }).first(where: {
            $0.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil
        }) else { throw WKExchangeError(message: "无法确认交换盘设备，未执行磁盘操作") }
        let mounted = entities.compactMap { $0["mount-point"] as? String }.first
        return Attachment(device: device, mount: mounted.map { URL(fileURLWithPath: $0) })
    }

    static func currentAttachment(_ image: URL) throws -> Attachment? {
        try attachment(in: run("/usr/bin/hdiutil", ["info", "-plist"]), image: image)
    }

    static func newlyAttachedDevice(_ data: Data) throws -> String {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any], let entities = plist["system-entities"] as? [[String: Any]] else {
            throw WKExchangeError(message: "无法识别新建镜像设备，未格式化")
        }
        let devices = entities.compactMap { $0["dev-entry"] as? String }.filter {
            $0.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil
        }
        guard devices.count == 1, entities.allSatisfy({ $0["mount-point"] == nil }) else {
            throw WKExchangeError(message: "新建镜像设备状态异常，未格式化")
        }
        return devices[0]
    }

    func ensureImage() throws {
        try prepareDirectory()
        var existing = stat()
        if lstat(imageURL.path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_uid == getuid(),
                  existing.st_size == Self.capacity else {
                throw WKExchangeError(message: "现有交换盘格式或容量异常；已保留文件，未重新格式化。")
            }
            return
        }
        guard errno == ENOENT else { throw WKExchangeError(message: "无法读取现有交换盘状态") }
        if FileManager.default.fileExists(atPath: imageURL.path + ".remote_dirty") {
            throw WKExchangeError(message: "未归还的交换盘文件缺失；已停止创建，避免覆盖传输状态。")
        }
        let staging = directory.appendingPathComponent("creating-\(UUID().uuidString).img")
        let fd = Darwin.open(staging.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw WKExchangeError(message: "无法创建交换盘文件") }
        let sized = ftruncate(fd, off_t(Self.capacity)) == 0 && fsync(fd) == 0
        Darwin.close(fd)
        guard sized else { throw WKExchangeError(message: "交换盘空间分配失败，未发布给 mini") }
        do {
            let receipt = try Self.run("/usr/bin/hdiutil", ["attach", "-nomount", "-plist", "-imagekey",
                              "diskimage-class=CRawDiskImage", staging.path])
            let createdDevice = try Self.newlyAttachedDevice(receipt)
            guard let attached = try Self.currentAttachment(staging),
                  attached.device == createdDevice, attached.mount == nil else {
                throw WKExchangeError(message: "无法确认新建镜像对应的设备，未格式化")
            }
            let rawDevice = attached.device.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
            _ = try Self.run("/sbin/newfs_msdos", ["-F", "16", "-v", "WIREDKVM", rawDevice])
            _ = try Self.run("/usr/bin/hdiutil", ["detach", attached.device])
            guard try Self.currentAttachment(staging) == nil else {
                throw WKExchangeError(message: "新建交换盘仍在使用，未发布")
            }
            try FileManager.default.moveItem(at: staging, to: imageURL)
        } catch {
            // Never unlink an image while its block device could still be live.
            if let attached = try? Self.currentAttachment(staging) {
                _ = try? Self.run("/usr/bin/hdiutil", ["detach", attached.device])
            }
            do {
                if try Self.currentAttachment(staging) == nil {
                    try? FileManager.default.removeItem(at: staging)
                }
            } catch { /* Unknown attachment state: keep the image. */ }
            throw error
        }
    }

    func openOnBook() throws -> URL {
        let reply = try request("LOCAL")
        guard reply.state == "LOCAL" else { throw WKExchangeError(message: "请先在 mini 推出交换盘") }
        try ensureImage()
        if let attached = try Self.currentAttachment(imageURL) {
            guard let mount = attached.mount else { throw WKExchangeError(message: "交换盘已连接但尚未挂载") }
            return mount
        }
        try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        _ = try Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-plist", "-imagekey",
                            "diskimage-class=CRawDiskImage", "-mountpoint", mountURL.path, imageURL.path])
        guard let mounted = try Self.currentAttachment(imageURL)?.mount else {
            throw WKExchangeError(message: "交换盘挂载未完成")
        }
        return mounted
    }

    func publishToMini() throws -> WKExchangeReply {
        try ensureImage()
        if let attached = try Self.currentAttachment(imageURL) {
            // A busy volume must remain local. Never force-detach user data.
            _ = try Self.run("/usr/bin/hdiutil", ["detach", attached.device])
        }
        guard try Self.currentAttachment(imageURL) == nil else {
            throw WKExchangeError(message: "Book 仍在使用交换盘，未交给 mini")
        }
        return try request("PUBLISH")
    }

    static func selfTest() throws {
        let image = URL(fileURLWithPath: "/tmp/our-exchange.img")
        let plist: [String: Any] = ["images": [
            ["image-path": "/tmp/someone-elses.img", "system-entities": [["dev-entry": "/dev/disk6"]]],
            ["image-path": image.path, "system-entities": [["dev-entry": "/dev/disk8"],
                ["dev-entry": "/dev/disk8s1", "mount-point": "/Volumes/WIREDKVM"]]]
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let found = try attachment(in: data, image: image)
        precondition(found?.device == "/dev/disk8" && found?.mount?.path == "/Volumes/WIREDKVM")
        let missing = try attachment(in: data, image: URL(fileURLWithPath: "/tmp/missing.img"))
        precondition(missing == nil)
        let status = try WKExchangeReply("OK EJECTED 268435456\n")
        precondition(status.state == "EJECTED" && status.bytes == UInt64(capacity))
        do { _ = try WKExchangeReply("ERR REMOTE_DIRTY"); preconditionFailure("accepted error") }
        catch is WKExchangeError { }
        print("GUI_EXCHANGE_SELF_TEST_PASS")
    }
}
