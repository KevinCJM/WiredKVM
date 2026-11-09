#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD="$ROOT/build/ch32v407/tests"
mkdir -p "$BUILD"
for name in bridge protocol sim; do
    case "$name" in bridge) src="$ROOT/firmware/ch32v407/bridge.c";; protocol) src="$ROOT/firmware/main/wire_protocol.c";; sim) src="$ROOT/tests/ch32v407_sim.c";; esac
    clang -std=c11 -O2 -Wall -Wextra -Werror -I"$ROOT/firmware/ch32v407" -I"$ROOT/firmware/main" -c "$src" -o "$BUILD/$name.o"
done
SOURCES=()
for file in WKClipboardProtocol WKOnboarding WKFnKey WKScrollRelay WKGestureRelay WKClipboardContent WKClipboardTransport WKFilePortal WKStreamFiles WKClipboardSelfTest WKFilePipelineSelfTest WKFilePortalSelfTest WKOnDemandClipboard WKCompanionInstall WiredKVMCompanion; do
    SOURCES+=("$ROOT/host/clipboard/$file.swift")
done
swiftc -D WK_CH32_TEST -O -parse-as-library -module-cache-path "$ROOT/build/ch32v407/macos/swift-cache" \
    -framework AppKit -framework IOKit -import-objc-header "$ROOT/tests/ch32v407_sim.h" \
    "${SOURCES[@]}" "$ROOT/tests/ch32v407_stream_test.swift" "$BUILD/bridge.o" "$BUILD/protocol.o" "$BUILD/sim.o" \
    -o "$BUILD/stream-test"
echo 'BUILD_OK: isolated stream test; no physical devices or system clipboard accessed.'
