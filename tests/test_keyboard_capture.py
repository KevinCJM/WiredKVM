"""Production key forwarding with synthetic events; no event tap or OS input."""
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin', 'macOS key capture only')
class KeyboardCaptureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='wk-keyboard-capture-')
        cls.addClassCleanup(cls.temp.cleanup)
        work = Path(cls.temp.name)
        source = (ROOT / 'host/macos_capture.swift').read_text()
        harness = r'''
if let argument = CommandLine.arguments.firstIndex(of: "--fixture-keyboard") {
    let scenario = CommandLine.arguments[argument + 1]
    let source = CGEventSource(stateID: .privateState)
    activeClient = true
    func key(_ code: Int, _ type: CGEventType = .flagsChanged,
             _ flags: CGEventFlags = [], _ at: UInt64 = 1_000_000_000) -> CGEvent {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code),
                            keyDown: type != .keyUp)!
        event.type = type; event.flags = flags; event.timestamp = at
        forwardKeyboardEvent(type, event: event, keyCode: code)
        return event
    }
    func physical(_ down: Bool, _ at: UInt64, _ keyType: Int = 4) {
        let data = (keyType << 16) | ((down ? 0x0a : 0x0b) << 8)
        let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
            modifierFlags: [], timestamp: Double(at) / 1_000_000_000,
            windowNumber: 0, context: nil, subtype: 8, data1: data, data2: 0)!.cgEvent!
        event.timestamp = at
        let result = eventTapCallback(proxy: OpaquePointer(bitPattern: 1)!,
            type: systemDefinedEvent, event: event, refcon: nil)
        if activeClient && keyType == 4 { precondition(result == nil) }
        else { precondition(result != nil) }
    }
    switch scenario {
    case "shift":
        _ = key(56, .flagsChanged, [.maskShift]); _ = key(56)
        _ = key(60, .flagsChanged, [.maskShift]); _ = key(60)
        _ = key(56, .flagsChanged, [.maskShift])
        _ = key(0, .keyDown, [.maskShift]); _ = key(0, .keyUp, [.maskShift])
        _ = key(56)
    case "fn":
        _ = key(2, .keyDown, [.maskSecondaryFn]) // Ambient Fn is ignored.
        _ = key(2, .keyUp)
        _ = key(63, .flagsChanged, [.maskSecondaryFn])
        _ = key(2, .keyDown, [.maskSecondaryFn]); _ = key(2, .keyUp, [.maskSecondaryFn])
        _ = key(63); _ = key(14, .keyDown); _ = key(14, .keyUp)
    case "caps-physical":
        _ = key(57, .flagsChanged, [.maskAlphaShift])
        physical(true, 1_001_000_000)
        _ = key(57, .flagsChanged, [.maskAlphaShift], 1_002_000_000)
        precondition(capsPhysicalDown)
        physical(false, 1_800_000_000)
        precondition(!capsPhysicalDown)
        flushCapsFallback()
    case "caps-fallback":
        _ = key(57, .flagsChanged, [.maskAlphaShift])
        _ = key(57, .flagsChanged, [.maskAlphaShift])
        flushCapsFallback()
        _ = key(57, .flagsChanged, [], 1_200_000_000)
        flushCapsFallback()
    case "caps-late-physical":
        _ = key(57, .flagsChanged, [.maskAlphaShift]); flushCapsFallback()
        physical(true, 1_001_000_000); physical(false, 1_002_000_000)
    case "caps-retired":
        _ = key(57, .flagsChanged, [.maskAlphaShift])
        resetCapsForwarding(); flushCapsFallback()
    case "local":
        activeClient = false; physical(true, 1_000_000_000); physical(false, 1_010_000_000)
    case "other-system":
        physical(true, 1_000_000_000, 0)
    default: fatalError("unknown keyboard scenario")
    }
    exit(0)
}
'''
        marker = 'if CommandLine.arguments.contains("--self-test-wired-clipboard-intents") {'
        assert marker in source
        fixture = work / 'capture.swift'
        fixture.write_text(source.replace(marker, harness + '\n' + marker, 1))
        cls.binary = work / 'capture'
        built = subprocess.run(['/usr/bin/swiftc', '-O', '-target',
            f'{platform.machine()}-apple-macosx13.0', '-module-cache-path', str(work / 'modules'),
            '-framework', 'ApplicationServices', '-framework', 'Cocoa', str(fixture),
            '-o', str(cls.binary)], capture_output=True, text=True, timeout=90)
        if built.returncode:
            raise AssertionError(built.stderr)

    def events(self, scenario):
        result = subprocess.run([str(self.binary), '--fixture-keyboard', scenario],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def test_standalone_left_right_shift_and_held_shift(self):
        self.assertEqual(self.events('shift'), ['C 2 0', 'C 0 0', 'C 2 0', 'C 0 0',
            'C 2 0', 'T 4 1', 'T 4 0', 'C 0 0'])

    def test_fn_and_ordinary_keys_keep_independent_state(self):
        self.assertEqual(self.events('fn'), ['T 7 1', 'T 7 0', 'C 16 0', 'T 7 1',
            'T 7 0', 'C 0 0', 'T 8 1', 'T 8 0'])

    def test_caps_physical_hold_is_one_press_without_flag_duplicates(self):
        self.assertEqual(self.events('caps-physical'), ['T 57 1', 'T 57 0'])

    def test_caps_flag_only_keyboards_keep_fallback(self):
        self.assertEqual(self.events('caps-fallback'), ['T 57 1', 'T 57 0'] * 2)

    def test_late_caps_physical_pair_does_not_repeat_fallback(self):
        self.assertEqual(self.events('caps-late-physical'), ['T 57 1', 'T 57 0'])

    def test_screen_return_retires_pending_caps_fallback(self):
        self.assertEqual(self.events('caps-retired'), [])

    def test_local_caps_is_never_forwarded_or_swallowed(self):
        self.assertEqual(self.events('local'), [])

    def test_other_system_keys_are_not_swallowed(self):
        self.assertEqual(self.events('other-system'), [])
