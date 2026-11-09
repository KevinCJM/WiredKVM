#!/usr/bin/env bash
# Reuse sibling ESPEmulator's validated ESP-IDF environment and binary.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
MODE="${1:-sim}"
BUILD_DIR="${WK_BUILD_DIR:-$ROOT/build}"
case "$MODE" in sim|live|usb|board|installer|exchange|macmac|flashsetup|macos|native|gui|companion|file-clipboard|clipboard-native) ;; *) echo "Usage: bash scripts/build.sh [sim|live|usb|board|installer|exchange|macmac|flashsetup|macos|native|gui|companion|file-clipboard]" >&2; exit 2 ;; esac

if [[ "$MODE" == companion ]]; then
    mkdir -p "$BUILD_DIR"
    # Exercise the installer's real codesign invocation, not only a shell
    # verification that could conceal a broken in-app requirement argument.
    /usr/bin/swiftc -module-cache-path "$BUILD_DIR/swift-cache" -O -framework AppKit \
        "$ROOT/host/clipboard/WKCompanionInstall.swift" "$ROOT/tests/companion_install_selftest.swift" \
        -o "$BUILD_DIR/companion-install-selftest"
    "$BUILD_DIR/companion-install-selftest"
    SOURCES=("$ROOT/host/clipboard/WKClipboardProtocol.swift"
        "$ROOT/host/clipboard/WKOnboarding.swift"
        "$ROOT/host/clipboard/WKFnKey.swift"
        "$ROOT/host/clipboard/WKScrollRelay.swift"
        "$ROOT/host/clipboard/WKGestureRelay.swift"
        "$ROOT/host/clipboard/WKStreamFiles.swift"
        "$ROOT/host/clipboard/WKClipboardContent.swift"
        "$ROOT/host/clipboard/WKClipboardTransport.swift"
        "$ROOT/host/clipboard/WKFilePortal.swift"
        "$ROOT/host/clipboard/WKClipboardSelfTest.swift"
        "$ROOT/host/clipboard/WKFilePipelineSelfTest.swift"
        "$ROOT/host/clipboard/WKOnDemandClipboard.swift"
        "$ROOT/host/clipboard/WKCompanionInstall.swift"
        "$ROOT/host/clipboard/WiredKVMCompanion.swift")
    for arch in arm64 x86_64; do
        /usr/bin/swiftc -module-cache-path "$BUILD_DIR/swift-cache" -O -parse-as-library \
            -target "$arch-apple-macosx13.0" -framework AppKit -framework IOKit -lcompression \
            "${SOURCES[@]}" -o "$BUILD_DIR/wiredkvm-companion-$arch"
    done
    /usr/bin/lipo -create "$BUILD_DIR/wiredkvm-companion-arm64" \
        "$BUILD_DIR/wiredkvm-companion-x86_64" -output "$BUILD_DIR/wiredkvm-companion"
    /usr/bin/codesign --force --sign - --identifier com.wiredkvm.companion.tool "$BUILD_DIR/wiredkvm-companion"
    COMPANION="$BUILD_DIR/WiredKVM Companion.app"
    mkdir -p "$COMPANION/Contents/MacOS"
    cp "$BUILD_DIR/wiredkvm-companion" "$COMPANION/Contents/MacOS/WiredKVMCompanion"
    cp "$ROOT/host/gui/Companion-Info.plist" "$COMPANION/Contents/Info.plist"
    /usr/bin/codesign --force --sign - --identifier com.wiredkvm.companion "$COMPANION"
    /usr/bin/codesign --verify --deep --strict -R '=identifier "com.wiredkvm.companion"' "$COMPANION"
    # A distinct installer identity lets Launch Services open the NEW installer
    # while the previous companion with its own bundle ID is still running.
    INSTALLER="$BUILD_DIR/安装 WiredKVM Companion.app"
    mkdir -p "$INSTALLER/Contents/MacOS" "$INSTALLER/Contents/Resources"
    cp "$BUILD_DIR/wiredkvm-companion" "$INSTALLER/Contents/MacOS/WiredKVMCompanion"
    /usr/bin/ditto "$COMPANION" "$INSTALLER/Contents/Resources/WiredKVM Companion.app"
    /usr/bin/python3 - "$COMPANION/Contents/Info.plist" "$INSTALLER/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
p = plistlib.loads(Path(sys.argv[1]).read_bytes())
p['CFBundleIdentifier'] = 'com.wiredkvm.setup'
p['CFBundleName'] = p['CFBundleDisplayName'] = '安装 WiredKVM Companion'
Path(sys.argv[2]).write_bytes(plistlib.dumps(p))
PY
    /usr/bin/codesign --force --sign - --identifier com.wiredkvm.setup "$INSTALLER"
    /usr/bin/codesign --verify --deep --strict -R '=identifier "com.wiredkvm.setup"' "$INSTALLER"
    echo "BUILD_OK COMPANION=$COMPANION universal arm64+x86_64 (not launched)"
    exit
fi

if [[ "$MODE" == gui ]]; then
    # Build only: NEVER launch a system EventTap, mouse capture, or login item.
    bash "$ROOT/scripts/build.sh" native
    bash "$ROOT/scripts/build.sh" macos
    bash "$ROOT/scripts/build.sh" companion
    bash "$ROOT/scripts/build_macmac_setup.sh"
    APP="$BUILD_DIR/WiredKVM.app"
    RUNTIME="$APP/Contents/Resources/Runtime"
    mkdir -p "$APP/Contents/MacOS" "$RUNTIME/build" "$APP/Contents"
    NATIVE_ARCH="$(/usr/bin/uname -m)"
    if [[ "$NATIVE_ARCH" == arm64 ]]; then OTHER_ARCH=x86_64; else OTHER_ARCH=arm64; fi
    /usr/bin/swiftc -module-cache-path "$BUILD_DIR/swift-cache" -O -parse-as-library -target "$NATIVE_ARCH-apple-macosx13.0" \
        -framework AppKit -framework SwiftUI -framework ServiceManagement \
        -framework ApplicationServices -framework IOKit \
        "$ROOT/host/clipboard/WKOnboarding.swift" "$ROOT/host/gui/WiredKVMCore.swift" "$ROOT/host/gui/WiredKVMExchange.swift" "$ROOT/host/gui/WiredKVMTransferMedia.swift" \
        "$ROOT/host/gui/WiredKVMFileTransfer.swift" "$ROOT/host/gui/WiredKVMClipboard.swift" "$ROOT/host/gui/WiredKVMMenu.swift" \
        -o "$BUILD_DIR/WiredKVM-gui-$NATIVE_ARCH"
    /usr/bin/swiftc -module-cache-path "$BUILD_DIR/swift-cache" -O -parse-as-library -target "$OTHER_ARCH-apple-macosx13.0" \
        -framework AppKit -framework SwiftUI -framework ServiceManagement \
        -framework ApplicationServices -framework IOKit \
        "$ROOT/host/clipboard/WKOnboarding.swift" "$ROOT/host/gui/WiredKVMCore.swift" "$ROOT/host/gui/WiredKVMExchange.swift" "$ROOT/host/gui/WiredKVMTransferMedia.swift" \
        "$ROOT/host/gui/WiredKVMFileTransfer.swift" "$ROOT/host/gui/WiredKVMClipboard.swift" "$ROOT/host/gui/WiredKVMMenu.swift" \
        -o "$BUILD_DIR/WiredKVM-gui-$OTHER_ARCH"
    /usr/bin/lipo -create "$BUILD_DIR/WiredKVM-gui-$NATIVE_ARCH" \
        "$BUILD_DIR/WiredKVM-gui-$OTHER_ARCH" -output "$APP/Contents/MacOS/WiredKVM"
    /usr/bin/clang++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror \
        -target "$OTHER_ARCH-apple-macosx13.0" \
        "$ROOT/native/wiredkvm.cpp" -o "$BUILD_DIR/wiredkvm-native-$OTHER_ARCH"
    /usr/bin/swiftc -module-cache-path "$BUILD_DIR/swift-cache" -O -target "$OTHER_ARCH-apple-macosx13.0" \
        -framework ApplicationServices -framework Cocoa -framework IOKit \
        -D WK_PIXEL_SCROLL "$BUILD_DIR/capture-source/main.swift" \
        "$ROOT/host/clipboard/WKScrollRelay.swift" "$ROOT/host/clipboard/WKGestureRelay.swift" \
        "$ROOT/host/WKPointingSource.swift" -lcompression -o "$BUILD_DIR/macos-capture-$OTHER_ARCH"
    /usr/bin/lipo -create "$BUILD_DIR/wiredkvm-native" \
        "$BUILD_DIR/wiredkvm-native-$OTHER_ARCH" -output "$RUNTIME/build/wiredkvm-native"
    /usr/bin/lipo -create "$BUILD_DIR/macos-capture" \
        "$BUILD_DIR/macos-capture-$OTHER_ARCH" -output "$RUNTIME/build/macos-capture"
    cp "$ROOT/host/gui/Info.plist" "$APP/Contents/Info.plist"
    cp "$BUILD_DIR/wiredkvm-companion" "$RUNTIME/build/wiredkvm-companion"
    /usr/bin/ditto "$BUILD_DIR/WiredKVM Companion.app" "$APP/Contents/Resources/WiredKVM Companion.app"
    mkdir -p "$APP/Contents/Resources/Setup"
    cp "$BUILD_DIR/setup/setup.img" "$APP/Contents/Resources/Setup/setup.img"
    # Bind the bundle identity before macOS records Accessibility permission.
    # Linker-only signatures leave TCC identifying the GUI as a raw executable.
    /usr/bin/codesign --force --sign - --identifier com.wiredkvm.native "$RUNTIME/build/wiredkvm-native"
    /usr/bin/codesign --force --sign - --identifier com.wiredkvm.capture "$RUNTIME/build/macos-capture"
    /usr/bin/codesign --force --sign - --identifier com.wiredkvm.menu "$APP"
    /usr/bin/codesign --verify --deep --strict "$APP"
    echo "BUILD_OK GUI=$APP universal arm64+x86_64 (not launched)"
    exit
fi

if [[ "$MODE" == clipboard-native ]]; then
    mkdir -p "$BUILD_DIR"
    /usr/bin/swiftc -module-cache-path "$BUILD_DIR/swift-cache" -O -framework AppKit \
        "$ROOT/agent/clipboard_native.swift" -o "$BUILD_DIR/clipboard-native"
    echo "BUILD_OK CLIPBOARD_NATIVE=$BUILD_DIR/clipboard-native"
    exit
fi

if [[ "$MODE" == file-clipboard ]]; then
    mkdir -p "$BUILD_DIR"
    /usr/bin/swiftc -module-cache-path "$BUILD_DIR/swift-cache" -O -framework AppKit \
        "$ROOT/host/macos_file_clipboard.swift" -o "$BUILD_DIR/macos-file-clipboard"
    echo "BUILD_OK FILE_CLIPBOARD=$BUILD_DIR/macos-file-clipboard"
    exit
fi

if [[ "$MODE" == native ]]; then
    mkdir -p "$BUILD_DIR"
    /usr/bin/clang++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror \
        -mmacosx-version-min=13.0 \
        "$ROOT/native/wiredkvm.cpp" -o "$BUILD_DIR/wiredkvm-native"
    echo "BUILD_OK NATIVE=$BUILD_DIR/wiredkvm-native"
    exit
fi

if [[ "$MODE" == macos ]]; then
    mkdir -p "$BUILD_DIR/capture-source"
    cp "$ROOT/host/macos_capture.swift" "$BUILD_DIR/capture-source/main.swift"
    /usr/bin/swiftc -module-cache-path "$BUILD_DIR/swift-cache" -O -target "$(/usr/bin/uname -m)-apple-macosx13.0" \
        -framework ApplicationServices -framework Cocoa -framework IOKit \
        -D WK_PIXEL_SCROLL "$BUILD_DIR/capture-source/main.swift" \
        "$ROOT/host/clipboard/WKScrollRelay.swift" "$ROOT/host/clipboard/WKGestureRelay.swift" \
        "$ROOT/host/WKPointingSource.swift" -lcompression -o "$BUILD_DIR/macos-capture"
    echo "BUILD_OK MACOS=$BUILD_DIR/macos-capture"
    exit
fi

if [[ "$MODE" == installer ]]; then
    # Build-only. NEVER flash hardware as part of this command.
    bash "$ROOT/scripts/build.sh" gui
    mkdir -p "$BUILD_DIR/installer"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
        "$BUILD_DIR/WiredKVM.app" "$BUILD_DIR/installer/installer_mac.zip"
    zip_bytes="$(/usr/bin/stat -f%z "$BUILD_DIR/installer/installer_mac.zip")"
    if [[ "$zip_bytes" -lt 100 || "$zip_bytes" -gt 6291456 ]]; then
        echo "Installer bundle must be 100 bytes .. 6 MiB; got $zip_bytes" >&2; exit 2
    fi
    echo "INSTALLER_PACKAGE_MAC_DEV_ZIP_BYTES=$zip_bytes"
fi

EMULATOR_ROOT="$ROOT/../ESPEmulator"
[[ -f "$EMULATOR_ROOT/scripts/env.sh" ]] || { echo "Missing sibling ESPEmulator" >&2; exit 1; }
source "$EMULATOR_ROOT/scripts/env.sh"

BUILD_PROJECT="$ESP32_AGENT_ROOT/workspaces/wiredkvm-$MODE"
mkdir -p "$BUILD_PROJECT"
rsync -a --delete --exclude 'build/' --exclude 'sdkconfig' --exclude 'sdkconfig.old' \
    "$ROOT/firmware/" "$BUILD_PROJECT/"

if [[ "$MODE" == usb || "$MODE" == board || "$MODE" == installer || "$MODE" == exchange || "$MODE" == macmac || "$MODE" == flashsetup ]]; then
    cp "$BUILD_PROJECT/main/idf_component.usb.yml" "$BUILD_PROJECT/main/idf_component.yml"
    # Hardware runs TinyUSB on native USB-OTG; the emulator cannot simulate this.
    printf '\nCONFIG_WIREDKVM_USB_HID=y\nCONFIG_TINYUSB_HID_COUNT=2\n' >> "$BUILD_PROJECT/sdkconfig.defaults"
    if [[ "$MODE" == board || "$MODE" == installer || "$MODE" == exchange || "$MODE" == macmac || "$MODE" == flashsetup ]]; then
        # CH343 COM uses UART0 GPIO43/44. Reserve its serial bytes for WK1
        # frames; application and bootloader logs would corrupt the protocol.
        cat >> "$BUILD_PROJECT/sdkconfig.defaults" <<'WK_BOARD_CONFIG'
CONFIG_WIREDKVM_BOARD_COM_UART0=y
CONFIG_ESP_CONSOLE_NONE=y
CONFIG_ESP_CONSOLE_SECONDARY_NONE=y
CONFIG_LOG_DEFAULT_LEVEL_NONE=y
CONFIG_BOOTLOADER_LOG_LEVEL_NONE=y
CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y
CONFIG_ESPTOOLPY_FLASHMODE_DIO=y
CONFIG_ESPTOOLPY_FLASHFREQ_40M=y
WK_BOARD_CONFIG
    fi
    if [[ "$MODE" == installer ]]; then
        # Installer profile has its own 16MiB partition layout, not for N4/N8!
        cat >> "$BUILD_PROJECT/sdkconfig.defaults" <<'WK_INSTALLER_CONFIG'
CONFIG_WIREDKVM_INSTALLER_STORAGE=y
CONFIG_TINYUSB_MSC_ENABLED=y
CONFIG_TINYUSB_MSC_BUFSIZE=4096
CONFIG_WL_SECTOR_SIZE_4096=y
CONFIG_PARTITION_TABLE_CUSTOM=y
CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="partitions_installer.csv"
WK_INSTALLER_CONFIG
        cp "$BUILD_DIR/installer/installer_mac.zip" "$BUILD_PROJECT/main/installer_mac.zip"
    fi
    if [[ "$MODE" == exchange || "$MODE" == macmac || "$MODE" == flashsetup ]]; then
        # Same flash layout as the deployed installer image. Normal MSC blocks
        # live on the Book; flashsetup adds a read-only board image backend.
        # Neither runtime backend formats or writes the installer partition.
        cat >> "$BUILD_PROJECT/sdkconfig.defaults" <<'WK_EXCHANGE_CONFIG'
CONFIG_WIREDKVM_EXCHANGE_STORAGE=y
CONFIG_WIREDKVM_INSTALLER_STORAGE=n
CONFIG_TINYUSB_MSC_ENABLED=n
CONFIG_PARTITION_TABLE_CUSTOM=y
CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="partitions_installer.csv"
WK_EXCHANGE_CONFIG
    fi
    if [[ "$MODE" == macmac || "$MODE" == flashsetup ]]; then
        printf '\nCONFIG_WIREDKVM_CLIPBOARD_CHANNEL=y\nCONFIG_TINYUSB_HID_COUNT=3\n' >> "$BUILD_PROJECT/sdkconfig.defaults"
    fi
    if [[ "$MODE" == flashsetup ]]; then
        printf '\nCONFIG_WIREDKVM_FLASH_SETUP=y\n' >> "$BUILD_PROJECT/sdkconfig.defaults"
    fi
    # Reconcile an existing generated sdkconfig from a previous build;
    # sdkconfig.defaults is only applied when sdkconfig is created initially.
    if [[ -f "$BUILD_PROJECT/sdkconfig" ]]; then
        sed -i '' 's/^CONFIG_TINYUSB_HID_COUNT=[0-9][0-9]*$/CONFIG_TINYUSB_HID_COUNT=2/' "$BUILD_PROJECT/sdkconfig"
        if [[ "$MODE" == macmac || "$MODE" == flashsetup ]]; then
            sed -i '' 's/^CONFIG_TINYUSB_HID_COUNT=2$/CONFIG_TINYUSB_HID_COUNT=3/' "$BUILD_PROJECT/sdkconfig"
        fi
    fi
    if [[ "$MODE" == board || "$MODE" == installer || "$MODE" == exchange || "$MODE" == macmac || "$MODE" == flashsetup ]] && [[ -f "$BUILD_PROJECT/sdkconfig" ]]; then
        # Existing IDF sdkconfig will not re-apply defaults after first build.
        # TinyUSB needs native USB PHY; do not enable secondary JTAG console.
        sed -i '' \
            -e 's/^# CONFIG_ESP_CONSOLE_SECONDARY_NONE is not set$/CONFIG_ESP_CONSOLE_SECONDARY_NONE=y/' \
            -e 's/^CONFIG_ESP_CONSOLE_SECONDARY_USB_SERIAL_JTAG=y$/# CONFIG_ESP_CONSOLE_SECONDARY_USB_SERIAL_JTAG is not set/' \
            -e 's/^CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG_ENABLED=y$/# CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG_ENABLED is not set/' \
            "$BUILD_PROJECT/sdkconfig"
    fi
    # The installed IDF Python has no PySocks. For registry access, avoid a
    # SOCKS proxy only if the required Python support is absent. No global changes.
    if [[ "${ALL_PROXY:-}" == socks* ]] && ! python -c 'import socks' >/dev/null 2>&1; then
        unset ALL_PROXY all_proxy
    fi
else
    if [[ "$MODE" == live ]]; then
        printf '\nCONFIG_WIREDKVM_SIM_RELAY=y\n' >> "$BUILD_PROJECT/sdkconfig.defaults"
    fi
    [[ ! -e "$BUILD_PROJECT/main/idf_component.yml" ]] || {
        echo "Unexpected simulator TinyUSB manifest" >&2
        exit 1
    }
fi

cd "$BUILD_PROJECT"
if [[ "$MODE" == installer && -f sdkconfig ]]; then
    for key in CONFIG_TINYUSB_MSC_ENABLED=y CONFIG_WIREDKVM_INSTALLER_STORAGE=y CONFIG_PARTITION_TABLE_CUSTOM=y; do
        if ! grep -qx "$key" sdkconfig; then
            echo "Installer sdkconfig is stale ($key missing). Review generated workspace configuration first." >&2
            exit 3
        fi
    done
fi
if [[ ( "$MODE" == exchange || "$MODE" == macmac || "$MODE" == flashsetup ) && -f sdkconfig ]]; then
    for key in 'CONFIG_WIREDKVM_EXCHANGE_STORAGE=y' 'CONFIG_PARTITION_TABLE_CUSTOM=y' \
        'CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="partitions_installer.csv"'; do
        if ! rg -F -x -q "$key" sdkconfig; then
            echo "Exchange sdkconfig is stale ($key missing). Review generated workspace configuration first." >&2
            exit 3
        fi
    done
    if rg -q '^(CONFIG_WIREDKVM_INSTALLER_STORAGE|CONFIG_TINYUSB_MSC_ENABLED)=y$' sdkconfig; then
        echo "Exchange sdkconfig incorrectly enables local-flash MSC. Review generated configuration first." >&2
        exit 3
    fi
fi
if [[ ( "$MODE" == macmac || "$MODE" == flashsetup ) && -f sdkconfig ]]; then
    for key in 'CONFIG_WIREDKVM_CLIPBOARD_CHANNEL=y' 'CONFIG_TINYUSB_HID_COUNT=3'; do
        rg -F -x -q "$key" sdkconfig || { echo "Mac clipboard sdkconfig stale: $key" >&2; exit 3; }
    done
fi
if [[ "$MODE" == flashsetup && -f sdkconfig ]] && ! rg -F -x -q 'CONFIG_WIREDKVM_FLASH_SETUP=y' sdkconfig; then
    echo "Flash setup sdkconfig is stale; review generated configuration first." >&2
    exit 3
fi
if [[ ! -f sdkconfig ]]; then
    # Avoid set-target's fullclean when a previous configuration was interrupted.
    idf.py -DIDF_TARGET=esp32s3 build
else
    idf.py build
fi
idf.py merge-bin -o merged_flash.bin
echo "BUILD_OK MODE=$MODE ELF=$BUILD_PROJECT/build/wiredkvm.elf"
echo "BUILD_OK MODE=$MODE FLASH=$BUILD_PROJECT/build/merged_flash.bin"
