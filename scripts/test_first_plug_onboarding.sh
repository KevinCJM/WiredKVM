#!/usr/bin/env bash
# Offline candidate verification. Local sockets/private pasteboards and mounting
# our own image are required. No install, login registration or device access.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
RUN="${WK_TEST_BUILD_DIR:-$ROOT/build/first-plug-$(date +%Y%m%d-%H%M%S)}"
[[ ! -e "$RUN" ]] || { echo 'Use a fresh regression directory.' >&2; exit 2; }
export PATH="/opt/homebrew/opt/python@3.12/libexec/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"
python3 - "$ROOT" "$RUN" <<'PY'
from pathlib import Path
import hashlib,json,shutil,sys
root,run=map(Path,sys.argv[1:]);src=run/'source';src.mkdir(parents=True)
for n in ['host','native','firmware','scripts','tests','hardware','agent','windows']:
    shutil.copytree(root/n,src/n,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
shutil.copy2(root/'README.md',src/'README.md')
(run/'logs').mkdir();(src/'build/ch32v407').mkdir(parents=True)
(src/'build/ch32v407/sdk').symlink_to(root/'build/ch32v407/sdk',target_is_directory=True)
(run/'source-sha256.json').write_text(json.dumps({str(p.relative_to(src)):hashlib.sha256(p.read_bytes()).hexdigest()
    for p in src.rglob('*') if p.is_file() and 'build' not in p.relative_to(src).parts},indent=2)+'\n')
print('ISOLATED_ONBOARDING_REGRESSION',run)
PY
cd "$RUN/source"
export WK_BUILD_DIR="$PWD/build"
export WK_NATIVE_TEST_CLIENT="$WK_BUILD_DIR/wiredkvm-native"
export WK_GUI_TEST_APP="$WK_BUILD_DIR/WiredKVM.app"
bash scripts/build.sh gui > "$RUN/logs/mac-build.log" 2>&1
bash scripts/build_ch32v407.sh > "$RUN/logs/firmware-build.log" 2>&1
python3 scripts/verify_ch32v407_build.py > "$RUN/logs/firmware-verify.json"
bash scripts/build_dual_setup.sh > "$RUN/logs/dual-setup-build.log" 2>&1
mkdir -p "$RUN/tests"
CFLAGS=(-std=c11 -O1 -g -fsanitize=address,undefined -Wall -Wextra -Werror -Ifirmware/ch32v407 -Ifirmware/main)
for test in setup_msc setup_asset; do
    /usr/bin/clang "${CFLAGS[@]}" firmware/ch32v407/setup_msc.c firmware/ch32v407/bridge.c \
        firmware/main/wire_protocol.c "tests/${test}_test.c" -o "$RUN/tests/$test"
done
"$RUN/tests/setup_msc" > "$RUN/logs/setup-core.log"
"$RUN/tests/setup_asset" "$WK_BUILD_DIR/dual-setup/flash-setup.bin" > "$RUN/logs/setup-actual-asset.log"
/usr/bin/swiftc -O -parse-as-library -module-cache-path "$WK_BUILD_DIR/swift-cache" \
    -framework AppKit -framework IOKit -framework ServiceManagement \
    host/clipboard/WKOnboarding.swift tests/onboarding_selftest.swift -o "$RUN/tests/onboarding"
"$RUN/tests/onboarding" > "$RUN/logs/onboarding-policy.log"
"$WK_BUILD_DIR/wiredkvm-companion" --self-test > "$RUN/logs/companion.log" 2>&1
"$WK_GUI_TEST_APP/Contents/MacOS/WiredKVM" --self-test-paste-progress > "$RUN/logs/progress.log"
for flag in --self-test-wired-clipboard-intents --self-test-gesture-pacing; do
    "$WK_BUILD_DIR/macos-capture" "$flag" > "$RUN/logs/capture${flag}.log"
done
bash scripts/test_ch32v407_core.sh > "$RUN/logs/bridge-core.log" 2>&1
bash scripts/build_ch32v407_tests.sh > "$RUN/logs/stream-build.log" 2>&1
for flag in --quick --pipeline --images --cancel; do
    "$PWD/build/ch32v407/tests/stream-test" "$flag" > "$RUN/logs/stream${flag}.log" 2>&1
done
python3 - "$RUN" <<'PY' > "$RUN/logs/python.log" 2>&1
import sys,unittest,json,time
from pathlib import Path
run=Path(sys.argv[1]);sys.path.insert(0,'tests')
names=['test_protocol','test_firmware_absolute','test_live_hid_replies','test_native_absolute',
 'test_clipboard_channel_firmware','test_fn_metadata','test_clipboard_native','test_keyboard_capture',
 'test_trackpad_scroll','test_wired_clipboard_capture','test_file_transfer_capture','test_hotplug',
 'test_discovery','test_stage2_return','test_clipboard_cancel','test_setup_native','test_exchange_native',
 'test_gui_product','test_flash_setup','test_onboarding_pack']
t=time.monotonic();suite=unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromName(n) for n in names)
r=unittest.TextTestRunner(verbosity=2).run(suite)
(run/'python-results.json').write_text(json.dumps(dict(tests=r.testsRun,seconds=time.monotonic()-t,
 failures=[(str(t),s) for t,s in r.failures],errors=[(str(t),s) for t,s in r.errors],skipped=[(str(t),s) for t,s in r.skipped]),indent=2)+'\n')
raise SystemExit(0 if r.wasSuccessful() else 1)
PY
echo "FIRST_PLUG_OFFLINE_PASS $RUN (not physical USB, login/Gatekeeper/Finder acceptance)"
