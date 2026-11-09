#!/usr/bin/env bash
# Offline protocol regression. No device access, EventTap, general pasteboard,
# mount, install, or firmware flashing. Private pasteboards need a GUI login.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD="$ROOT/build/ch32v407"
cd "$ROOT"
mkdir -p "$BUILD"
export PATH="/opt/homebrew/opt/python@3.12/libexec/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"
export WK_NATIVE_TEST_CLIENT="$BUILD/macos/wiredkvm-native"
bash scripts/build_ch32v407.sh > "$BUILD/bulk-v5-firmware-build.log" 2>&1
python3 scripts/verify_ch32v407_build.py > "$BUILD/bulk-v5-firmware-verify.log"
bash scripts/build_ch32v407_macos.sh > "$BUILD/bulk-v5-host-build.log" 2>&1
bash scripts/test_ch32v407_core.sh > "$BUILD/bulk-v5-core.log" 2>&1
bash scripts/build_ch32v407_tests.sh > "$BUILD/bulk-v5-tests-build.log" 2>&1
# Explicit 1 GiB per direction default; --large requires >16.5 GiB free.
SIZE=--gib
if [[ "${WK_CH32_FULL_SIZE:-0}" == 1 ]]; then SIZE=--large; fi
"$BUILD/tests/stream-test" "$SIZE" --result "$BUILD/bulk-v5-size.json" > "$BUILD/bulk-v5-size.log" 2>&1 &
stream_pid=$!
trap 'for child in $(jobs -pr); do if [[ "$child" == "$stream_pid" ]]; then kill "$child" 2>/dev/null || true; fi; done' EXIT
python3 - <<'PY' > "$BUILD/bulk-v5-native-regression.log" 2>&1
import sys, unittest
sys.path.insert(0, 'tests')
loader = unittest.TestLoader()
suite = unittest.TestSuite(loader.loadTestsFromName(name) for name in [
    'test_native_absolute', 'test_clipboard_native', 'test_keyboard_capture',
    'test_trackpad_scroll', 'test_wired_clipboard_capture', 'test_fn_metadata'])
r = unittest.TextTestRunner(verbosity=2).run(suite)
raise SystemExit(0 if r.wasSuccessful() else 1)
PY
wait "$stream_pid"
trap - EXIT
for mode in cancel image-bounds images pipeline portal http; do
    "$BUILD/tests/stream-test" "--$mode" > "$BUILD/bulk-v5-$mode.log" 2>&1
done
"$BUILD/macos/wiredkvm-companion" --self-test > "$BUILD/bulk-v5-companion-selftest.log" 2>&1
"$BUILD/macos/wiredkvm-ch32-host" --self-test > "$BUILD/bulk-v5-gui-selftest.log" 2>&1
echo 'CH32_BULK_V5_OFFLINE_PASS (not physical USB, latency, Finder or PCBA acceptance)'
