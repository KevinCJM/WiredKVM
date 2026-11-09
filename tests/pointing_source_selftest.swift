import Foundation
import CoreGraphics

@main enum PointingSourceSelfTest {
    static func main() {
        if CommandLine.arguments.contains("--inventory") {
            for d in WKPointingSource.readDevices() { print("kind=\(d.kind.rawValue) product=\(d.product) transport=\(d.transport)") }
            return
        }
        var count = 0
        func test(_ name: String, _ f: () -> Void) { f(); count += 1; print("POINTING_SOURCE \(name) PASS") }
        func device(_ kind: WKPointingSource.Kind) -> WKPointingSource.Device {
            WKPointingSource.Device(id: kind == .trackpad ? 1 : 2, kind: kind, product: "fixture", transport: "USB")
        }
        test("built-in-and-external-apple-trackpads") {
            for p in ["Apple Internal Keyboard / Trackpad", "Magic Trackpad"] {
                precondition(WKPointingSource.kind(product: p, transport: "SPI", vendor: 0x05ac, page: 1, usage: 2) == .trackpad)
            }
            precondition(WKPointingSource.kind(product: "HID Touchpad", transport: "USB", vendor: 1, page: 13, usage: 5) == .trackpad)
        }
        test("magic-mouse-and-generic-wheel-remain-mice") {
            for p in ["Magic Mouse", "USB Optical Mouse", "Logitech MX"] {
                precondition(WKPointingSource.kind(product: p, transport: "Bluetooth", vendor: 0x05ac, page: 1, usage: 2) == .mouse)
            }
        }
        test("exclude-keyboard-vendor-interface-and-virtual-kvm") {
            precondition(WKPointingSource.kind(product: "Apple Internal Keyboard / Trackpad", transport: "SPI", vendor: 0x05ac, page: 1, usage: 6) == .unknown)
            precondition(WKPointingSource.kind(product: "Apple Internal Keyboard / Trackpad", transport: "SPI", vendor: 0x05ac, page: 65280, usage: 11) == .unknown)
            precondition(WKPointingSource.kind(product: "WiredKVM Absolute Mouse", transport: "USB", vendor: 0, page: 1, usage: 2) == .unknown)
        }
        let source = WKPointingSource()
        var inventory = [device(.trackpad)]
        source.scan = { inventory }; source.refresh(at: 1)
        test("one-physical-class") {
            precondition(source.soleKind == .trackpad)
            precondition(source.scroll(continuous: true, phase: 2, momentum: 0, at: 1) == .trackpad)
            precondition(source.scroll(continuous: false, phase: 0, momentum: 0, at: 1.01) == .mouse)
        }
        test("hotplug-refresh-and-mixed-device-ambiguity") {
            inventory.append(device(.mouse)); source.refresh(at: 2)
            precondition(source.soleKind == .unknown)
            precondition(source.scroll(continuous: true, phase: 0, momentum: 0, at: 2) == .unknown)
        }
        test("actual-sender-wins-over-connected-device-presence") {
            precondition(source.scroll(continuous: true, phase: 0, momentum: 0, at: 2.1, source: .mouse) == .mouse)
            precondition(source.scroll(continuous: true, phase: 0, momentum: 0, at: 2.2, source: .trackpad) == .trackpad)
            source.resetGesture()
        }
        test("registry-sender-resolution-cache-and-invalidation") {
            let event = CGEvent(source: nil)!
            event.setIntegerValueField(CGEventField(rawValue: 87)!, value: 123)
            var calls = 0
            source.resolve = { id in calls += 1; precondition(id == 123); return .mouse }
            precondition(source.hardwareSource(event) == .mouse)
            precondition(source.hardwareSource(event) == .mouse && calls == 1)
            precondition(source.gesture(event) == .mouse)
            source.refresh(at: 3)
            precondition(source.hardwareSource(event) == .mouse && calls == 2)
            event.setIntegerValueField(CGEventField(rawValue: 87)!, value: 0)
            precondition(source.hardwareSource(event) == .unknown)
            precondition(source.gesture(event) == .unknown) // Mixed devices: no guess.
        }
        test("trackpad-maybegin-then-scroll-and-momentum") {
            precondition(source.scroll(continuous: true, phase: 128, momentum: 0, at: 3) == .trackpad)
            precondition(source.scroll(continuous: true, phase: 1, momentum: 0, at: 3.01) == .trackpad)
            precondition(source.scroll(continuous: true, phase: 2, momentum: 0, at: 3.02) == .trackpad)
            precondition(source.scroll(continuous: true, phase: 4, momentum: 0, at: 3.03) == .trackpad)
            precondition(source.scroll(continuous: true, phase: 0, momentum: 1, at: 3.04) == .trackpad)
        }
        test("mouse-wheel-during-trackpad-momentum") {
            precondition(source.scroll(continuous: false, phase: 0, momentum: 0, at: 3.05) == .mouse)
            precondition(source.scroll(continuous: true, phase: 0, momentum: 2, at: 3.06) == .trackpad)
            precondition(source.scroll(continuous: true, phase: 0, momentum: 3, at: 3.07) == .trackpad)
            precondition(source.scroll(continuous: true, phase: 0, momentum: 0, at: 3.08) == .unknown)
        }
        test("screen-return-and-timeout-retire-old-gesture") {
            _ = source.scroll(continuous: true, phase: 128, momentum: 0, at: 4)
            source.resetGesture()
            precondition(source.scroll(continuous: true, phase: 0, momentum: 2, at: 4.01) == .unknown)
            _ = source.scroll(continuous: true, phase: 128, momentum: 0, at: 5)
            precondition(source.scroll(continuous: true, phase: 0, momentum: 2, at: 6) == .unknown)
        }
        test("mac-mini-with-only-magic-mouse-is-not-a-trackpad") {
            inventory = [device(.mouse)]; source.refresh(at: 7)
            precondition(source.scroll(continuous: true, phase: 0, momentum: 0, at: 7) == .mouse)
            precondition(source.scroll(continuous: true, phase: 0, momentum: 2, at: 7.01) == .mouse)
        }
        print("POINTING_SOURCE_SELF_TEST_PASS count=\(count)")
    }
}
