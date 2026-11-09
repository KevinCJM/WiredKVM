#!/usr/bin/env bash
# Completed isolated GUI build -> one compressed, signed, two-role boot image.
# Does not install, change login items, publish MSC, or flash any device.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD="${WK_BUILD_DIR:?Set the isolated completed GUI build directory}"
OUT="$BUILD/dual-setup"
[[ ! -e "$OUT" ]] || { echo 'Choose a fresh build directory; old artifacts retained.' >&2; exit 2; }
mkdir -p "$OUT/payloads" "$OUT/staging"
/usr/bin/ditto "$BUILD/WiredKVM.app" "$OUT/payloads/WiredKVM.app"
/usr/bin/ditto "$BUILD/WiredKVM Companion.app" "$OUT/payloads/WiredKVM Companion.app"
# CH32's autonomous MSC supplies installation resources. Never recursively
# include the old ESP32 setup image inside the new setup image.
/usr/bin/python3 - "$OUT/payloads/WiredKVM.app/Contents/Resources/Setup" <<'PY'
import pathlib,shutil,sys
p=pathlib.Path(sys.argv[1]); assert 'dual-setup/payloads/WiredKVM.app/' in str(p)
if p.exists(): shutil.rmtree(p)
PY
/usr/bin/codesign --force --sign - --identifier com.wiredkvm.menu "$OUT/payloads/WiredKVM.app"
for app in 'WiredKVM.app' 'WiredKVM Companion.app'; do
    /usr/bin/codesign --verify --strict --deep "$OUT/payloads/$app"
done
# A global LZMA dictionary shares identical signed helper binaries between the
# two apps. Extraction uses macOS's bundled libarchive, no Python dependency.
/usr/bin/tar -cJf "$OUT/applications.tar.xz" -C "$OUT/payloads" 'WiredKVM.app' 'WiredKVM Companion.app'
APP="$OUT/staging/安装 WiredKVM.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
    /usr/bin/swiftc -O -parse-as-library -target "$arch-apple-macosx13.0" -module-cache-path "$BUILD/swift-cache" \
        -framework AppKit -framework IOKit -framework ServiceManagement \
        "$ROOT/host/clipboard/WKOnboarding.swift" "$ROOT/host/clipboard/WKCompanionInstall.swift" \
        "$ROOT/host/setup/WiredKVMSetup.swift" -o "$OUT/setup-$arch"
done
/usr/bin/lipo -create "$OUT/setup-arm64" "$OUT/setup-x86_64" -output "$APP/Contents/MacOS/WiredKVMSetup"
cp "$OUT/applications.tar.xz" "$APP/Contents/Resources/applications.tar.xz"
/usr/bin/python3 - "$APP" "$ROOT/host/gui/Info.plist" <<'PY'
import pathlib,plistlib,hashlib,sys
p=pathlib.Path(sys.argv[1]); info=plistlib.loads(pathlib.Path(sys.argv[2]).read_bytes())
info.update(CFBundleIdentifier='com.wiredkvm.onboarding',CFBundleExecutable='WiredKVMSetup',
            CFBundleName='安装 WiredKVM',CFBundleDisplayName='安装 WiredKVM',LSUIElement=False,
            WKPayloadSHA256=hashlib.sha256((p/'Contents/Resources/applications.tar.xz').read_bytes()).hexdigest())
(p/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
/usr/bin/codesign --force --sign - --identifier com.wiredkvm.onboarding "$APP"
/usr/bin/codesign --verify --strict --deep "$APP"
cat > "$OUT/staging/开始使用.txt" <<'TXT'
双击“安装 WiredKVM”。安装器会识别本机连接的是主控侧还是被控侧，安装对应程序。
只需首次安装并确认 macOS 权限；程序会注册可关闭的登录自启，以后插线自动连接。
主控完成首次设置后，即可先用 USB 键鼠控制另一台电脑，再打开它的安装器。
跨机数据只经过连接线；本机复制粘贴保持原生。
本开发版本尚未获得 Developer ID 公证；正式产品须完成签名、公证和实板验证。
TXT
/usr/bin/hdiutil makehybrid -hfs -hfs-volume-name 'WiredKVM Setup' -hfs-openfolder "$OUT/staging" \
    -o "$OUT/setup.dmg" "$OUT/staging" -ov > "$OUT/image-build.log"
mv "$OUT/setup.dmg" "$OUT/setup.img"
python3 "$ROOT/scripts/verify_dual_setup.py" "$OUT"
python3 "$ROOT/scripts/pack_dual_setup.py" "$OUT/setup.img" "$OUT/flash-setup.bin"
echo "DUAL_SETUP_BUILD_PASS $OUT (not installed, launched, published or flashed)"
