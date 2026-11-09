"""Execute capture routing with OS key posting replaced by a recording sink.

This fixture never installs an event tap or injects real input. It compiles a
private copy of the production source and replaces only OS replay/focus access,
so the actual callback, nonce matching, cancellation and timeout decisions run.
"""
from __future__ import annotations
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def replace_function(source, name, body):
    start = source.index('private func ' + name + '(')
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[:opening + 1] + '\n' + body + '\n' + source[end - 1:]


@unittest.skipUnless(sys.platform == 'darwin', 'macOS capture only')
class WiredClipboardCaptureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='wk-wired-routing-')
        cls.addClassCleanup(cls.temp.cleanup)
        path = Path(cls.temp.name)
        source = (ROOT / 'host/macos_capture.swift').read_text()
        source = replace_function(source, 'replayClipboardShortcut', '    fixtureReplays.append(key)')
        source = replace_function(source, 'clipboardPID', '    return fixturePID')
        source = source.replace('private var activeClient = false',
            'private var fixtureRevision = 0\nprivate var fixtureReplays: [Int] = []\nprivate var fixturePID: pid_t = 71\n'
            'private var activeClient = false', 1)
        source = source.replace('NSPasteboard.general.changeCount', 'fixtureRevision')
        marker = '// Safe regression paths below'
        harness = r'''
if CommandLine.arguments.contains("--fixture-routing") {
    precondition(wiredClipboardEnabled)
    receiveClipboardControl("STATE", token: "1")
    let proxy = CGEventTapProxy(bitPattern: 1)!
    let source = CGEventSource(stateID: .privateState)
    let scenario = CommandLine.arguments.last!
    func sample(_ key: Int, _ type: CGEventType = .keyDown,
                _ flags: CGEventFlags = [.maskCommand], repeatKey: Bool = false) -> CGEvent {
        let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: type != .keyUp)!
        e.type = type; e.flags = flags
        e.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return e
    }
    func route(_ event: CGEvent) -> Bool {
        let passed = eventTapCallback(proxy: proxy, type: event.type, event: event, refcon: nil) != nil
        // Represent the application's receipt of an ordinary, passed-through
        // local shortcut in the same sink as a deliberately replayed shortcut.
        if passed && event.type == .keyDown && event.flags.contains(.maskCommand) &&
            event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if key == 8 || key == 9 { fixtureReplays.append(key) }
        }
        return passed
    }
    if scenario == "copy-local-native" {
        precondition(route(sample(8)), "local physical Cmd+C must pass through")
        precondition(clipboardIntents.copy == nil && !consumeClipboardCopyKeyUp)
        precondition(route(sample(8, .keyUp)), "local C key-up must also pass through")
        precondition(fixtureReplays == [8])
    } else if scenario == "copy-remote-cancel" {
        activeClient = true
        precondition(!route(sample(8)), "remote key is forwarded by HID, not passed to Book")
        precondition(clipboardIntents.copy == nil && !consumeClipboardCopyKeyUp)
        precondition(!route(sample(8, .keyUp)))
        receiveClipboardControl("COPY", token: "123")
        precondition(fixtureReplays.isEmpty, "remote copy must never be replayed by clipboard control")
    } else if scenario == "copy-cancel" {
        _ = route(sample(8))
        _ = route(sample(8, .keyUp))
        let pending = clipboardIntents.copy?.token
        _ = route(sample(0, .keyDown, []))
        if let pending { receiveClipboardControl("COPY", token: pending) }
        precondition(fixtureReplays == [8], "copy must execute exactly once despite cancellation")
    } else if scenario == "copy-repeat" {
        _ = route(sample(8))
        let pending = clipboardIntents.copy?.token
        _ = route(sample(8, repeatKey: true))
        if let pending { receiveClipboardControl("COPY", token: pending) }
        precondition(fixtureReplays == [8], "key repeat must not consume the first native copy")
    } else if scenario == "paste-cancel" || scenario == "paste-focus" || scenario == "paste-expired" {
        _ = clipboardIntents.beginCopy(remote: true, pid: 99, now: ProcessInfo.processInfo.systemUptime)
        clipboardIntents.copy = nil
        clipboardIntents.copyToken = "123"
        precondition(!route(sample(9)))
        let pending = clipboardIntents.paste!
        if scenario == "paste-cancel" { _ = route(sample(0, .keyDown, [])) }
        if scenario == "paste-focus" { fixturePID = 72 }
        if scenario == "paste-expired" {
            clipboardIntents.paste = ClipboardShortcut(token: pending.token, remote: pending.remote,
                pid: pending.pid, at: ProcessInfo.processInfo.systemUptime - 181)
        }
        receiveClipboardControl("PASTE", token: pending.token)
        precondition(!fixtureReplays.contains(9), "late paste must not be injected")
    } else if scenario == "paste-token" {
        _ = clipboardIntents.beginCopy(remote: true, pid: 99, now: ProcessInfo.processInfo.systemUptime)
        clipboardIntents.copy = nil
        clipboardIntents.copyToken = "123"
        precondition(!route(sample(9)))
        let pending = clipboardIntents.paste!
        receiveClipboardControl("PASTE", token: "0.0")
        precondition(fixtureReplays.isEmpty)
        receiveClipboardControl("PASTE", token: pending.token)
        receiveClipboardControl("PASTE", token: pending.token)
        precondition(fixtureReplays == [9], "only current paste nonce may inject once")
    } else if scenario == "local-menu-copy" {
        clipboardIntents.copiedRemotely = true; clipboardIntents.copyToken = "321"
        fixtureRevision += 1
        precondition(route(sample(9)), "local menu copy must take priority before helper notices it")
        precondition(fixtureReplays == [9] && clipboardIntents.paste == nil)
    } else if scenario == "offline-native-paste" {
        clipboardIntents.copiedRemotely = true; clipboardIntents.copyToken = "321"
        receiveClipboardControl("STATE", token: "0")
        precondition(route(sample(8)) && route(sample(9)))
        precondition(fixtureReplays == [8,9], "offline component must not intercept native C/V")
    } else if scenario == "same-side-paste" {
        clipboardIntents.copiedRemotely = false; clipboardIntents.copyToken = "321"
        precondition(route(sample(9)))
        activeClient = true
        clipboardIntents.copiedRemotely = true
        precondition(!route(sample(9)))
        precondition(clipboardIntents.paste == nil && !consumeClipboardPasteKeyUp,
                     "mini native paste must use regular HID without an async clipboard request")
    } else if scenario == "paste-native-repeat" {
        clipboardIntents.copiedRemotely = true; clipboardIntents.copyToken = "321"
        precondition(!route(sample(9)))
        let token = clipboardIntents.paste!.token
        _ = route(sample(9,.keyUp))
        receiveClipboardControl("PASTE", token: token)
        precondition(route(sample(9)), "next paste on the same destination must be native")
        precondition(fixtureReplays == [9,9])
    } else { fatalError("unknown scenario") }
    print("WIRED_CLIPBOARD_ROUTING_PASS " + scenario)
    exit(0)
}
'''
        source = source.replace(marker, harness + '\n' + marker, 1)
        fixture = path / 'capture.swift'
        fixture.write_text(source)
        cls.binary = path / 'capture'
        result = subprocess.run(['/usr/bin/swiftc', '-O', '-target',
            f'{platform.machine()}-apple-macosx13.0', '-module-cache-path', str(path / 'modules'),
            '-framework', 'ApplicationServices', '-framework', 'Cocoa', str(fixture),
            '-o', str(cls.binary)], capture_output=True, text=True, timeout=90)
        if result.returncode:
            raise AssertionError(result.stderr)

    def run_scenario(self, scenario):
        env = dict(os.environ, WK_TARGET_ABSOLUTE='1', WK_WIRED_CLIPBOARD='1')
        for key in ('WK_TARGET_IPHONE', 'WK_FILE_TRANSFER', 'WK_CLIPBOARD_SYNC'):
            env.pop(key, None)
        result = subprocess.run([str(self.binary), '--fixture-routing', scenario], env=env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('WIRED_CLIPBOARD_ROUTING_PASS ' + scenario, result.stdout)

    def test_menu_copy_overrides_remote_origin_before_poll(self):
        self.run_scenario('local-menu-copy')

    def test_offline_component_preserves_native_copy_and_paste(self):
        self.run_scenario('offline-native-paste')

    def test_both_sides_native_paste_bypasses_transfer(self):
        self.run_scenario('same-side-paste')

    def test_second_paste_on_destination_is_native(self):
        self.run_scenario('paste-native-repeat')

    def test_copy_survives_next_user_action_and_late_armed(self):
        self.run_scenario('copy-cancel')

    def test_local_physical_copy_and_keyup_pass_through(self):
        self.run_scenario('copy-local-native')

    def test_remote_copy_uses_hid_immediately_without_clipboard_replay(self):
        self.run_scenario('copy-remote-cancel')

    def test_copy_survives_autorepeat(self):
        self.run_scenario('copy-repeat')

    def test_late_paste_is_cancelled_after_another_user_action(self):
        self.run_scenario('paste-cancel')

    def test_late_paste_is_cancelled_after_front_app_changed(self):
        self.run_scenario('paste-focus')

    def test_expired_paste_is_not_injected(self):
        self.run_scenario('paste-expired')

    def test_only_matching_current_paste_token_injects_once(self):
        self.run_scenario('paste-token')


if __name__ == '__main__':
    unittest.main()
