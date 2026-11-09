#!/usr/bin/env bash
# Extra universal artifacts only, for the storage audit. Never start capture.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD="${WK_BUILD_DIR:?Set an isolated completed GUI build directory}"
RUNTIME="$BUILD/capacity-runtime"
mkdir -p "$RUNTIME"
SOURCES=()
for file in WKClipboardProtocol WKOnboarding WKFnKey WKScrollRelay WKGestureRelay WKClipboardContent WKClipboardTransport WKFilePortal WKStreamFiles WKClipboardSelfTest WKFilePipelineSelfTest WKOnDemandClipboard WKCompanionInstall WiredKVMCompanion; do
    SOURCES+=("$ROOT/host/clipboard/$file.swift")
done
for arch in arm64 x86_64; do
    /usr/bin/swiftc -D WK_CH32_TEST -O -parse-as-library -module-cache-path "$BUILD/swift-cache" \
        -target "$arch-apple-macosx13.0" -framework AppKit -framework IOKit \
        "${SOURCES[@]}" "$ROOT/host/gui/WiredKVMClipboard.swift" "$ROOT/host/ch32v407_host.swift" \
        -o "$BUILD/capacity-ch32-host-$arch"
done
/usr/bin/lipo -create "$BUILD/capacity-ch32-host-arm64" "$BUILD/capacity-ch32-host-x86_64" \
    -output "$RUNTIME/wiredkvm-ch32-host"
for name in wiredkvm-native macos-capture wiredkvm-companion; do
    cp "$BUILD/WiredKVM.app/Contents/Resources/Runtime/build/$name" "$RUNTIME/$name"
done
for name in wiredkvm-ch32-host wiredkvm-native macos-capture wiredkvm-companion; do
    /usr/bin/codesign --force --sign - --identifier "com.wiredkvm.capacity.$name" "$RUNTIME/$name"
    /usr/bin/codesign --verify --strict "$RUNTIME/$name"
    /usr/bin/lipo "$RUNTIME/$name" -verify_arch arm64 x86_64
done
echo 'CAPACITY_RUNTIME_BUILD_PASS universal=true not_launched=true'
