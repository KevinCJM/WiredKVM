"""Capture-to-relay regression; private events only, no EventTap or USB access.

Builds and fixtures are retained. No recursive cleanup runs on success/failure.
The injected fixture overrides only its policy/socket paths and receiver posts.
"""
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

HARNESS = r'''
if CommandLine.arguments.contains("--fixture-independent-input") {
    let env = ProcessInfo.processInfo.environment
    precondition(wiredInputEnabled == (env["WK_TEST_EXPECT_INPUT"] == "1"))
    precondition(wiredClipboardEnabled == (env["WK_TEST_EXPECT_CLIPBOARD"] == "1"))
    WKScrollSocket.testDirectory = env["WK_TEST_SOCKET"]!
    let host = WKScrollHost(), receiver = WKScrollReceiver(), gestures = WKGestureReceiver()
    let targetAvailable = env["WK_TEST_TARGET_AVAILABLE"] != "0"
    var scrolls: [WKScrollPacket] = [], postedGestures: [CGEvent] = []
    receiver.access = { true }; receiver.post = { scrolls.append($0) }
    receiver.gesturesSupported = true
    gestures.access = { true }; gestures.location = { .zero }
    gestures.post = { postedGestures.append($0) }
    receiver.connection(targetAvailable); gestures.connection(targetAvailable, session: receiver.session)
    receiver.gestureTemplateAcks = { gestures.templateAcks }
    host.sendReport = { d in
        if gestures.receive(d) { return true }
        return receiver.receive(d)
    }
    func pump(_ seconds: Double = 0.025) {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            receiver.tick { host.receive($0) }; host.tick()
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
    }
    func scroll(_ value: Int32, _ horizontal: Int32, sender: Int64, continuous: Bool = true) -> CGEvent {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                        wheelCount: 2, wheel1: value, wheel2: horizontal, wheel3: 0)!
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: continuous ? 1 : 0)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 3)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -2)
        if continuous {
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(value))
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(horizontal))
        }
        e.setIntegerValueField(CGEventField(rawValue: 87)!, value: sender)
        return e
    }
    func dock(_ phase: Int64, _ progress: Double) -> CGEvent {
        let e = CGEvent(source: nil)!
        e.type = CGEventType(rawValue: 30)!
        e.setDoubleValueField(CGEventField(rawValue: 110)!, value: 23)
        e.setDoubleValueField(CGEventField(rawValue: 124)!, value: progress)
        e.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        e.setIntegerValueField(CGEventField(rawValue: 87)!, value: 111)
        return e
    }
    pointingSource.scan = { [
        WKPointingSource.Device(id: 111, kind: .trackpad, product: "fixture trackpad", transport: "SPI"),
        WKPointingSource.Device(id: 222, kind: .mouse, product: "fixture mouse", transport: "USB")
    ] }
    pointingSource.resolve = { $0 == 111 ? .trackpad : ($0 == 222 ? .mouse : .unknown) }
    pointingSource.refresh()
    let proxy = OpaquePointer(bitPattern: 1)!
    activeClient = false
    let localScroll = scroll(12, -4, sender: 111)
    precondition(eventTapCallback(proxy: proxy, type: .scrollWheel, event: localScroll, refcon: nil) != nil)
    let localGesture = dock(2, 0.4)
    precondition(gestureTapCallback(proxy: proxy, type: localGesture.type, event: localGesture, refcon: nil) != nil)
    // No native clipboard interception is introduced by enabling input alone.
    if !wiredClipboardEnabled {
        for key: CGKeyCode in [8, 9] {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
                e.flags = .maskCommand
                precondition(eventTapCallback(proxy: proxy, type: down ? .keyDown : .keyUp, event: e, refcon: nil) != nil)
            }
        }
    }
    precondition(scrolls.isEmpty && postedGestures.isEmpty)
    host.start(); refreshNativeInputPolicy(); pump(0.18)
    let relayExpected = wiredInputEnabled && nativeInputPolicy.pixelEnabled && targetAvailable
    precondition(pixelScroll.ready == relayExpected)
    if !targetAvailable {
        // Production WK_PIXEL_SCROLL build, but no target capability packets:
        // small real-valued deltas use only the HID fallback, without a peer.
        activeClient = true
        for index in 1...24 {
            let e = scroll(1, -1, sender: 111)
            e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
            e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0.25)
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -0.25)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: index == 1 ? 1 : 2)
            e.timestamp = UInt64(1_000_000_000 + index * 10_000_000)
            print("FALLBACK_SAMPLE \(index)")
            forwardScrollEvent(e)
        }
        let end = scroll(0, 0, sender: 111)
        end.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        end.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
        end.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
        forwardScrollEvent(end)
        // Continuous mouse and unidentified source keep the old integer path.
        forwardScrollEvent(scroll(7, 2, sender: 222))
        pointingSource.resetGesture()
        forwardScrollEvent(scroll(7, 2, sender: 999))
        precondition(scrolls.isEmpty && postedGestures.isEmpty)
        print("INPUT_RELAY_NO_TARGET_PASS fractional_hid=true mouse_unknown_unchanged=true")
    }
    if relayExpected {
        activeClient = true
        for (value, horizontal): (Int32, Int32) in [(12, -4), (-9, 3)] {
            let before = scrolls.count
            forwardScrollEvent(scroll(value, horizontal, sender: 111)); pump()
            fputs("FIXTURE_TRACKPAD received=\(scrolls.count - before) vertical=\(scrolls.last?.vertical ?? 0) horizontal=\(scrolls.last?.horizontal ?? 0) expected=\(value),\(horizontal)\n", stderr)
            precondition(scrolls.count == before + 1)
            precondition(scrolls.last!.vertical == value && scrolls.last!.horizontal == horizontal)
            precondition(scrolls.last!.source == 2)
        }
        let beforeMouse = scrolls.count
        forwardScrollEvent(scroll(7, 2, sender: 222)); pump()
        precondition(scrolls.count == beforeMouse + 1 && scrolls.last!.source == 1)
        precondition(scrolls.last!.vertical == 7 && scrolls.last!.horizontal == 2)
        // A discrete wheel retains HID detents and never enters the pixel relay.
        let beforeWheel = scrolls.count
        forwardScrollEvent(scroll(7, 2, sender: 222, continuous: false)); pump()
        precondition(scrolls.count == beforeWheel)
        // Unknown high-resolution sources in a mixed-device session are not
        // guessed to be a trackpad. This path retains the HID fallback.
        pointingSource.resetGesture()
        let beforeUnknown = scrolls.count
        forwardScrollEvent(scroll(7, 2, sender: 999)); pump()
        precondition(scrolls.count == beforeUnknown)
        if !wiredClipboardEnabled {
            clipboardIntents.copy = ClipboardShortcut(token: "41", remote: true, pid: 7, at: 10)
            clipboardIntents.paste = ClipboardShortcut(token: "42", remote: true, pid: 7, at: 10)
        }
        for (phase, progress): (Int64, Double) in [(1, 0), (2, 0.4), (4, 1)] {
            let e = dock(phase, progress)
            precondition(gestureTapCallback(proxy: proxy, type: e.type, event: e, refcon: nil) == nil)
            pump()
        }
        precondition(postedGestures.count == 3)
        precondition(postedGestures.map { $0.getIntegerValueField(CGEventField(rawValue: 132)!) } == [1, 2, 4])
        precondition(abs(postedGestures[1].getDoubleValueField(CGEventField(rawValue: 124)!) - 0.4) < 0.0001)
        if !wiredClipboardEnabled {
            precondition(clipboardIntents.copy?.token == "41" && clipboardIntents.paste?.token == "42")
        }
        // A new gesture is canceled promptly without posting real OS input.
        let e = dock(1, 0)
        _ = gestureTapCallback(proxy: proxy, type: e.type, event: e, refcon: nil); pump()
        gesturePacer.cancel(); pixelScroll.cancel(); pump()
        precondition(postedGestures.last!.getIntegerValueField(CGEventField(rawValue: 132)!) == 8)
        print("INPUT_RELAY_NATIVE_PASS source_tags=true pixel_signs=true dock_phases=true cancel=true")
    }
    pixelScroll.stop(); host.stop()
    print("INPUT_RELAY_POLICY_PASS input=\(wiredInputEnabled) clipboard=\(wiredClipboardEnabled) relay=\(relayExpected) local_passthrough=true no_OS_input_posted=true")
    exit(0)
}
'''


@unittest.skipUnless(sys.platform == "darwin", "macOS capture only")
class IndependentInputTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # mkdtemp returns an owned path. Retain it, including failures. No
        # TemporaryDirectory/destructor or Swift recursive remove is used.
        cls.work = Path(tempfile.mkdtemp(prefix="wk-input-", dir="/private/tmp"))
        source = (ROOT / "host/macos_capture.swift").read_text()
        marker = 'if CommandLine.arguments.contains("--self-test-gesture-pacing") {'
        assert source.count(marker) == 1
        declaration = "private let nativeInputPolicy = WKNativeInputPolicy()"
        assert source.count(declaration) == 1
        source = source.replace(declaration, 'private let nativeInputPolicy = WKNativeInputPolicy(path: ProcessInfo.processInfo.environment["WK_TEST_POLICY"]!)')
        fixture = cls.work / "main.swift"
        fixture.write_text(source.replace(marker, HARNESS + "\n" + marker, 1))
        cls.binary = cls.work / "capture-fixture"
        result = subprocess.run([
            "/usr/bin/swiftc", "-O", "-D", "WK_PIXEL_SCROLL", "-D", "WK_SCROLL_TESTS",
            "-target", f"{platform.machine()}-apple-macosx13.0",
            "-module-cache-path", str(cls.work / "modules"),
            "-framework", "ApplicationServices", "-framework", "Cocoa", "-framework", "IOKit", "-lcompression",
            str(fixture), str(ROOT / "host/WKPointingSource.swift"),
            str(ROOT / "host/clipboard/WKScrollRelay.swift"), str(ROOT / "host/clipboard/WKGestureRelay.swift"),
            "-o", str(cls.binary),
        ], capture_output=True, text=True, timeout=120)
        (cls.work / "compile.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise AssertionError(result.stderr)
        print(f"INPUT_RELAY_FIXTURES_RETAINED {cls.work}")

    def run_fixture(self, input_enabled, clipboard=False, absolute=True, iphone=False, mode="gestures", inverted=False, target=True):
        case = Path(tempfile.mkdtemp(prefix="case-", dir=self.work))
        policy = case / "policy.json"
        policy.write_text(json.dumps({"mode": mode})); policy.chmod(0o600)
        env = dict(os.environ)
        for key in ["WK_FILE_TRANSFER", "WK_TRACKPAD_SCROLL_SCALE"]:
            env.pop(key, None)
        expected = absolute and not iphone
        env.update(WK_WIRED_INPUT=str(int(input_enabled)), WK_WIRED_CLIPBOARD=str(int(clipboard)),
                   WK_TARGET_ABSOLUTE=str(int(absolute)), WK_TARGET_IPHONE=str(int(iphone)),
                   WK_INVERT_SCROLL=str(int(inverted)), WK_TEST_POLICY=str(policy),
                   WK_TEST_SOCKET=str(case / "socket"),
                   WK_TEST_TARGET_AVAILABLE=str(int(target)),
                   WK_TEST_EXPECT_INPUT=str(int(expected and (input_enabled or clipboard))),
                   WK_TEST_EXPECT_CLIPBOARD=str(int(expected and clipboard)))
        result = subprocess.run([str(self.binary), "--fixture-independent-input"], env=env,
                                capture_output=True, text=True, timeout=15)
        (case / "run.log").write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("local_passthrough=true no_OS_input_posted=true", result.stdout)
        if expected and (input_enabled or clipboard) and mode != "legacy" and target:
            self.assertIn("INPUT_RELAY_NATIVE_PASS", result.stdout)
            wheel = "W -3 2" if inverted else "W 3 -2"
            self.assertEqual(result.stdout.splitlines().count(wheel), 2)
        if not target:
            self.assertIn("INPUT_RELAY_NO_TARGET_PASS", result.stdout)
            lines = result.stdout.splitlines()
            wheel_lines = [line for line in lines if line.startswith('W ')]
            self.assertEqual(wheel_lines, (["W -1 1"] * 2 + ["W -3 2"] * 2) if inverted
                             else (["W 1 -1"] * 2 + ["W 3 -2"] * 2))
            first = next(i for i, line in enumerate(lines) if line.startswith('W '))
            self.assertEqual(lines[first - 1], "FALLBACK_SAMPLE 6")
        if not clipboard:
            self.assertFalse(any(x.startswith("C ") for x in result.stdout.splitlines()), result.stdout)

    def test_input_only_preserves_local_clipboard_and_source_types(self):
        self.run_fixture(True)

    def test_legacy_clipboard_launch_retains_native_input(self):
        self.run_fixture(False, clipboard=True)

    def test_hid_inversion_does_not_reverse_native_pixel_deltas(self):
        self.run_fixture(True, inverted=True)

    def test_disabled_input_does_not_start_relay(self):
        self.run_fixture(False)

    def test_no_target_capability_preserves_short_scroll_and_device_types(self):
        self.run_fixture(True, target=False)
        self.run_fixture(True, target=False, inverted=True)

    def test_legacy_policy_remains_opt_out(self):
        self.run_fixture(True, mode="legacy")

    def test_iphone_and_non_absolute_do_not_enable_native_mac_input(self):
        self.run_fixture(True, iphone=True)
        self.run_fixture(True, absolute=False)


if __name__ == "__main__":
    unittest.main()
