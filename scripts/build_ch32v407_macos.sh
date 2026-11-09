#!/usr/bin/env bash
# Isolated build only. The installed ESP32 controller and its permissions stay unchanged.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export WK_BUILD_DIR="$ROOT/build/ch32v407/macos"
bash "$ROOT/scripts/build.sh" native
bash "$ROOT/scripts/build.sh" macos
bash "$ROOT/scripts/build.sh" companion
SOURCES=()
for file in WKClipboardProtocol WKOnboarding WKFnKey WKScrollRelay WKGestureRelay WKClipboardContent WKClipboardTransport WKFilePortal WKStreamFiles WKClipboardSelfTest WKFilePipelineSelfTest WKOnDemandClipboard WKCompanionInstall WiredKVMCompanion; do
    SOURCES+=("$ROOT/host/clipboard/$file.swift")
done
swiftc -D WK_CH32_TEST -O -parse-as-library -module-cache-path "$WK_BUILD_DIR/swift-cache" \
    -target "$(uname -m)-apple-macosx13.0" -framework AppKit -framework IOKit \
    "${SOURCES[@]}" "$ROOT/host/gui/WiredKVMClipboard.swift" "$ROOT/host/ch32v407_host.swift" \
    -o "$WK_BUILD_DIR/wiredkvm-ch32-host"
echo 'BUILD_OK: CH32 Mac host launcher and target companion (not launched).'
