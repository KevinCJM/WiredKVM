// Isolated diagnostic: two private pasteboards, temporary files, simulated wire.
// No general pasteboard, NSApplication.run, HID, serial, or installer execution.
import AppKit
import Foundation

final class LatencyTransport: WKTransport {
    var onReport: (Data) -> Void = { _ in }
    var onConnection: (Bool) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    var sendBlock: (Data) -> Bool = { _ in false }
    func start() {}
    func stop() {}
    func tick(_ time: Double) {}
    func send(_ bytes: Data) -> Bool { sendBlock(bytes) }
}

@main enum LatencyProbe {
    struct Flight { let arrival: Double; let destination: Int; let report: Data }
    static func main() throws {
        for delay in [0.005, 0.010, 0.020] {
            for bytes in [24 * 1024, 64 * 1024] {
                for direction in ["OUT", "IN"] {
                    try run(bytes: bytes, delay: delay, direction: direction, dropEvery: 0)
                }
            }
        }
        try run(bytes: 64 * 1024, delay: 0.020, direction: "OUT", dropEvery: 97)
        try run(bytes: 64 * 1024, delay: 0.020, direction: "IN", dropEvery: 97)
    }

    static func run(bytes: Int, delay: Double, direction: String, dropEvery: Int) throws {
        let boardA = NSPasteboard.withUniqueName(), boardB = NSPasteboard.withUniqueName()
        defer { boardA.releaseGlobally(); boardB.releaseGlobally() }
        boardA.clearContents(); boardB.clearContents()
        guard boardA.setString("private A", forType: .string), boardB.setString("private B", forType: .string) else {
            throw WKClipboardError.invalid("private-pasteboard-service-unavailable")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wk-latency-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 37) })
        let fixture = root.appendingPathComponent(bytes == 24576 ? "image-24KiB.png" : "data-64KiB.bin")
        try payload.write(to: fixture)
        let ta = LatencyTransport(), tb = LatencyTransport()
        let a = WKCompanion(role: "host", clipboard: WKClipboard(board: boardA, receiveRoot: root.appendingPathComponent("a")), transport: ta)
        let b = WKCompanion(role: "target", clipboard: WKClipboard(board: boardB, receiveRoot: root.appendingPathComponent("b")), transport: tb)
        var now: Double = 0
        var flights: [Flight] = []
        var wireAvailable = [0.0, 0.0]
        var reportCounts = [0, 0]
        var dataCounts = [0, 0]
        var errors: [String] = []
        var replies: [(Double, String)] = []
        var armed = false
        var copied = false
        var copyAt: Double = 0
        var completeAt: Double?
        var stableAt: Double?
        var transferStart: Double?
        var commands = Set<Int>()
        var sentBytes = 0
        func enqueue(_ source: Int, _ report: Data) -> Bool {
            reportCounts[source] += 1
            if WKReport(report)?.kind == .data {
                dataCounts[source] += 1
                if dropEvery > 0 && dataCounts[source] % dropEvery == 0 { return true }
            }
            // 141 UART bytes/report at 921600, with native's 25% HID reserve.
            let serialTime = 141.0 * 10 / 921600 / 0.75
            let start = max(now, wireAvailable[source])
            wireAvailable[source] = start + serialTime
            flights.append(Flight(arrival: start + serialTime + delay, destination: 1 - source, report: report))
            sentBytes += 64
            return true
        }
        ta.sendBlock = { enqueue(0, $0) }; tb.sendBlock = { enqueue(1, $0) }
        func log(_ source: String, _ line: String) {
            if line.contains("ERROR") && !line.contains("paste-not-ready") { errors.append(source + ":" + line) }
            if line.contains("TRANSFER sending") { transferStart = transferStart ?? now }
            if source == "host" && direction == "OUT" && line == "WKCLIP_STATUS TRANSFER complete 1" { completeAt = now }
            if source == "host" && direction == "IN" && line == "WKCLIP_STATUS TRANSFER complete 1" { completeAt = now }
        }
        a.log = { log("host", $0) }; b.log = { log("target", $0) }
        a.reply = {
            replies.append((now, $0))
            if $0 == "WKCLIP_COPY ARMED 1" { armed = true; copyAt = now + 0.02 }
            if $0.hasPrefix("WKCLIP_PASTE READY") { stableAt = stableAt ?? now }
        }
        b.reply = { _ in }
        a.link.connected(true, at: 0); b.link.connected(true, at: 0)
        var started = false
        var startTime: Double = 0
        for step in 1...12000 {
            now = Double(step) * 0.01
            // Input callbacks/socket delivery run at each 10ms main-loop turn;
            // each report additionally sees the selected 5–20ms one-way delay.
            let due = flights.filter { $0.arrival <= now }.sorted { $0.arrival < $1.arrival }
            flights.removeAll { $0.arrival <= now }
            for flight in due { (flight.destination == 0 ? a.link : b.link).receive(flight.report, at: now) }
            if !started && a.link.ready && b.link.ready {
                started = true; startTime = now
                a.command("COPY \(direction) 1")
            }
            if started && armed && !copied && now >= copyAt {
                let source = direction == "OUT" ? boardA : boardB
                source.clearContents()
                guard source.writeObjects([fixture as NSURL]) else { throw WKClipboardError.invalid("private-source-write-failed") }
                copied = true
            }
            if step % 5 == 0 { a.pollClipboard(now); b.pollClipboard(now) }
            a.link.tick(now); b.link.tick(now)
            if started {
                for second in [1, 5, 10, 20, 40, 60] where now - startTime >= Double(second) && !commands.contains(second) {
                    commands.insert(second); a.command("PASTE \(direction) 1.\(second)")
                }
                if let completeAt, now >= completeAt + 0.1 && !commands.contains(99) {
                    commands.insert(99); a.command("PASTE \(direction) 1.99")
                }
                if stableAt != nil && now - completeAt! > 0.5 { break }
            }
        }
        let receiver = direction == "OUT" ? boardB : boardA
        let url = receiver.string(forType: .fileURL).flatMap(URL.init(string:))
        let received = try url.map { try Data(contentsOf: $0) }
        let ok = received == payload && stableAt != nil && errors.isEmpty
        let checks = replies.filter { $0.1.hasPrefix("WKCLIP_PASTE") }.map { String(format: "%.2fs", $0.0 - startTime) + " " + $0.1 }
        let output: [String: Any] = ["direction": direction, "contentBytes": bytes, "oneWayMs": Int(delay * 1000),
            "dropEveryData": dropEvery, "tickMs": 10, "window": WKLink.window, "ok": ok,
            "completeSeconds": completeAt.map { $0 - startTime } ?? -1,
            "readySeconds": stableAt.map { $0 - startTime } ?? -1,
            "sendingSeconds": transferStart.map { $0 - startTime } ?? -1,
            "reports": reportCounts, "wireReportBytes": sentBytes, "checks": checks, "errors": errors]
        let encoded = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(data: encoded, encoding: .utf8)!)
        if !ok { throw WKClipboardError.invalid("latency-probe-failed") }
    }
}
