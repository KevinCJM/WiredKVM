#!/usr/bin/env bash
# Full offline/hardware-free regression after SDK preparation. Does NOT start
# capture, touch the general clipboard, mount a disk, install, or flash.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD="$ROOT/build/ch32v407"
mkdir -p "$BUILD"
# Test processes exchange monotonic timestamps. Use the same real interpreter
# for the parent and fake capture, not a wrapper with a per-process time origin.
export PATH="/opt/homebrew/opt/python@3.12/libexec/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"
PYTHON="${WK_TEST_PYTHON:-python3}"
bash "$ROOT/scripts/build_ch32v407.sh" > "$BUILD/firmware-build.log" 2>&1
"$PYTHON" "$ROOT/scripts/verify_ch32v407_build.py" > "$BUILD/firmware-verify.log"
bash "$ROOT/scripts/build_ch32v407_macos.sh" > "$BUILD/host-build.log" 2>&1
bash "$ROOT/scripts/test_ch32v407_core.sh" > "$BUILD/core-test.log" 2>&1
bash "$ROOT/scripts/build_ch32v407_tests.sh" > "$BUILD/test-build.log" 2>&1
export WK_NATIVE_TEST_CLIENT="$BUILD/macos/wiredkvm-native"
"$BUILD/tests/stream-test" --large --result "$BUILD/stream-large.json" > "$BUILD/stream-large.log" 2>&1 &
stream_test_pid=$!
under_load_ok=0
"$PYTHON" -m unittest discover -s "$ROOT/tests" -p test_native_absolute.py > "$BUILD/native-under-file-load.log" 2>&1 && under_load_ok=1
wait "$stream_test_pid"
[[ "$under_load_ok" == 1 ]]
"$BUILD/tests/stream-test" --pipeline > "$BUILD/stream-pipeline.log" 2>&1
"$BUILD/tests/stream-test" --portal > "$BUILD/portal-test.log" 2>&1
"$BUILD/tests/stream-test" --http --result "$BUILD/stream-http.json" > "$BUILD/stream-http.log" 2>&1
"$BUILD/macos/wiredkvm-companion" --self-test > "$BUILD/companion-selftest.log" 2>&1
for suite in test_native_absolute.py test_clipboard_native.py; do
    "$PYTHON" -m unittest discover -s "$ROOT/tests" -p "$suite" > "$BUILD/$suite.log" 2>&1
done
echo "CH32_ALL_TESTS_PASS: logs in $BUILD (no physical USB proof)"
