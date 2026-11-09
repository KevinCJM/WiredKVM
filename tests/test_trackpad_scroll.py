"""Actual capture serializer with private Quartz events; never posts OS input."""
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin', 'macOS capture only')
class TrackpadScrollTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Retain exact owned fixtures; no recursive cleanup in capture tests.
        work = Path(tempfile.mkdtemp(prefix='wk-trackpad-', dir='/private/tmp'))
        cls.work = work
        source = (ROOT / 'host/macos_capture.swift').read_text()
        harness = r'''
if let i = CommandLine.arguments.firstIndex(of: "--fixture-scroll") {
    let scenario = CommandLine.arguments[i + 1]
    let source = CGEventSource(stateID: .privateState)
    var at: UInt64 = 1_000_000_000
    var sampleIndex = 0
    func sample(_ v: Double, _ h: Double = 0, continuous: Bool = true,
                began: Bool = false, phase: Int64? = nil, gap: UInt64 = 10_000_000) {
        sampleIndex += 1
        if scenario == "precision" || scenario == "first" { print("S \(sampleIndex)") }
        let event = CGEvent(scrollWheelEvent2Source: source, units: .line,
            wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(v))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(h))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: v)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: h)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase ?? (began ? 1 : 2))
        at += gap; event.timestamp = at
        if scenario == "local" {
            activeClient = false
            let result = eventTapCallback(proxy: OpaquePointer(bitPattern: 1)!,
                type: .scrollWheel, event: event, refcon: nil)
            precondition(result != nil)
        } else { forwardScrollEvent(event) }
    }
    switch scenario {
    case "small": for _ in 0..<8 { sample(1, -1) }
    case "first": for _ in 0..<8 { sample(1, -1) }
    case "precision": for _ in 0..<24 { sample(0.25, -0.25) }
    case "rounding-debt": sample(2); sample(0, phase: 4); sample(1); sample(1); sample(2)
    case "reverse-tie": sample(2); sample(-2)
    case "subthreshold": sample(0.25); sample(0, phase: 4); sample(0, phase: 8)
    case "nonfinite":
        for v in [Double.nan, Double.infinity, -Double.infinity] {
            let result = trackpadScroll.convertPrecise(v, v, at: at, began: false)
            precondition(result.0 == 0 && result.1 == 0)
        }
    case "wheel": sample(3, -2, continuous: false); sample(-500, 500, continuous: false)
    case "reverse": sample(3); for _ in 0..<4 { sample(-1) }
    case "gesture": sample(3); sample(1, began: true); sample(3)
    case "idle": sample(3); sample(1, gap: 600_000_000); sample(3)
    case "device": sample(3); sample(1, continuous: false); sample(1); sample(3)
    case "reset": sample(3); trackpadScroll.reset(); sample(1); sample(3)
    case "large":
        let (v, h) = trackpadScroll.convert(Int.max, Int.min, at: at, began: false)
        print("W \(forwardedScrollDelta(v)) \(forwardedScrollDelta(h))")
        sample(500, -500)
    case "default": for _ in 0..<100 { sample(1, -1) }
    case "local": sample(8, -8)
    default: fatalError("unknown fixture")
    }
    exit(0)
}
'''
        marker = 'if CommandLine.arguments.contains("--self-test-wired-clipboard-intents") {'
        assert marker in source
        fixture = work / 'capture.swift'
        fixture.write_text(source.replace(marker, harness + '\n' + marker, 1))
        cls.binary = work / 'capture'
        result = subprocess.run(['/usr/bin/swiftc', '-O', '-target',
            f'{platform.machine()}-apple-macosx13.0', '-module-cache-path', str(work / 'modules'),
            '-framework', 'ApplicationServices', '-framework', 'Cocoa', str(fixture),
            '-o', str(cls.binary)], capture_output=True, text=True, timeout=90)
        if result.returncode:
            raise AssertionError(result.stderr)

    def events(self, scenario, scale='0.25', inverted=False, iphone=False, all_lines=False):
        env = dict(os.environ, WK_TRACKPAD_SCROLL_SCALE=scale,
                   WK_INVERT_SCROLL='1' if inverted else '0')
        env['WK_TARGET_IPHONE'] = '1' if iphone else '0'
        result = subprocess.run([str(self.binary), '--fixture-scroll', scenario],
                                env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        return lines if all_lines else [line for line in lines if line.startswith('W ')]

    def test_small_moves_accumulate_on_both_axes(self):
        self.assertEqual(self.events('small'), ['W 1 -1'] * 2)

    def test_wheel_mouse_keeps_original_amount_and_clamp(self):
        self.assertEqual(self.events('wheel'), ['W 3 -2', 'W -127 127'])

    def test_reverse_discards_old_fraction(self):
        self.assertEqual(self.events('reverse'), ['W 1 0', 'W -1 0'])
        self.assertEqual(self.events('reverse-tie'), ['W 1 0', 'W -1 0'])

    def test_fraction_retires_at_gesture_idle_device_or_screen_boundary(self):
        for scenario in ['gesture', 'idle', 'reset']:
            with self.subTest(scenario=scenario):
                self.assertEqual(self.events(scenario), ['W 1 0', 'W 1 0'])
        self.assertEqual(self.events('device'), ['W 1 0', 'W 1 0', 'W 1 0'])

    def test_fractional_quartz_motion_no_longer_disappears(self):
        lines = self.events('precision', scale='', all_lines=True)
        self.assertEqual([x for x in lines if x.startswith('W ')], ['W 1 -1'] * 2)
        first = next(i for i, line in enumerate(lines) if line.startswith('W '))
        self.assertEqual(lines[first - 1], 'S 6')
        print('SCROLL_FIRST_RESPONSE fractional_input=0.25 scale=0.35 old=none new_sample=6')

    def test_first_detent_responds_earlier_without_total_gain_change(self):
        lines = self.events('first', all_lines=True)
        first = next(i for i, line in enumerate(lines) if line.startswith('W '))
        self.assertEqual(lines[first - 1], 'S 2')
        self.assertEqual([x for x in lines if x.startswith('W ')], ['W 1 -1'] * 2)
        print('SCROLL_FIRST_RESPONSE input=1 scale=0.25 old_sample=4 new_sample=2')

    def test_signed_rounding_debt_does_not_look_like_direction_reversal(self):
        self.assertEqual(self.events('rounding-debt'), ['W 1 0', 'W 1 0'])

    def test_zero_end_and_invalid_values_do_not_invent_motion(self):
        self.assertEqual(self.events('subthreshold'), [])
        self.assertEqual(self.events('nonfinite'), [])

    def test_iphone_keeps_legacy_integer_truncation(self):
        self.assertEqual(self.events('reverse', iphone=True), ['W -1 0'])
        self.assertEqual(self.events('gesture', iphone=True), ['W 1 0'])
        self.assertEqual(self.events('precision', iphone=True), [])

    def test_direction_inversion_still_applies_to_both_axes(self):
        self.assertEqual(self.events('small', inverted=True), ['W -1 1'] * 2)

    def test_extreme_deltas_are_bounded_without_integer_overflow(self):
        self.assertEqual(self.events('large'), ['W 127 -127', 'W 125 -125'])

    def test_desktop_default_reduces_total_to_about_35_percent(self):
        events = self.events('default', scale='')
        self.assertIn(sum(int(x.split()[1]) for x in events), [34, 35])
        self.assertEqual(sum(int(x.split()[2]) for x in events),
                         -sum(int(x.split()[1]) for x in events))

    def test_invalid_scale_uses_safe_default(self):
        expected = self.events('default', scale='')
        for value in ['nan', 'inf', '0', '-1', '2.1', 'abc']:
            with self.subTest(value=value):
                self.assertEqual(self.events('default', scale=value), expected)

    def test_book_local_scroll_is_never_forwarded_or_swallowed(self):
        self.assertEqual(self.events('local'), [])


if __name__ == '__main__':
    unittest.main()
