#!/usr/bin/env bash
# Build a NEW, read-only setup image. Never mount, publish, or touch exchange.img.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD_DIR="${WK_BUILD_DIR:-$ROOT/build/macmac-clipboard}"
COMPANION="$BUILD_DIR/安装 WiredKVM Companion.app"
test -d "$COMPANION" || { echo "Build companion first." >&2; exit 2; }
STAGING="$(mktemp -d "$BUILD_DIR/setup-stage.XXXXXX")"
trap 'rm -rf -- "$STAGING"' EXIT
mkdir -p "$BUILD_DIR/setup"
/usr/bin/ditto "$COMPANION" "$STAGING/安装 WiredKVM Companion.app"
cat > "$STAGING/开始使用.txt" <<'GUIDE'
WiredKVM 有线剪贴板 · Mac ↔ Mac

打开同一窗口中的“安装 WiredKVM Companion”。
组件会自动复制到本机用户的 Applications 目录，并在菜单栏显示 ⇄。
如 macOS 首次询问是否打开或允许访问，请按系统提示确认。
平滑滚动与多指手势需要在系统“辅助功能”中允许 WiredKVM Companion。
未授权时仍可使用 USB 键鼠与有线剪贴板。

连接成功后，Book 会自动撤下这个只读安装盘。
之后使用普通 ⌘C / ⌘V，文字、PNG、单个普通文件通过 USB 传输。
首版每项内容不超过 1 MiB；目录、多文件、资源叉和跨机剪切暂不支持。
两端新版连接后，单文件可直接按 ⌘V，由 Finder 显示复制进度。

跨机数据只走 USB，不使用 Wi-Fi 或蓝牙。
文件通过本机隐藏只读入口接入 Finder；不会弹出日常交换盘。
首次设置会注册可关闭的登录自启；如系统要求确认，请按提示允许。
不安装系统守护程序；升级会保留旧版副本。关闭自启后，重新插线不会擅自开启它。
当前是开发测试版本，正式分发仍需 Developer ID 签名、公证和兼容验证。
GUIDE
/usr/bin/hdiutil makehybrid -hfs -hfs-volume-name 'WiredKVM Setup' \
    -hfs-openfolder "$STAGING" -o "$BUILD_DIR/setup/setup-candidate.dmg" "$STAGING" -ov
# makehybrid produces a raw sector image (possibly appending .iso); native
# supplies it read-only. No UDIF wrapper may be streamed to USB mass storage.
mv "$BUILD_DIR/setup/setup-candidate.dmg" "$BUILD_DIR/setup/setup.img"
/usr/bin/python3 - "$BUILD_DIR/setup/setup.img" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
n = p.stat().st_size
assert n > 512 and n % 512 == 0 and n <= 32 * 1024 * 1024, n
with p.open('rb') as f:
    f.seek(1024)
    signature = f.read(2)
# Hybrid HFS images can include an Apple partition map, so hdiutil imageinfo
# below is the authoritative filesystem inspection, not this offset alone.
print(f'SETUP_IMAGE_BYTES={n} HFS_SIGNATURE_AT_1024={signature.hex()}')
PY
/usr/bin/python3 "$ROOT/scripts/verify_macmac_setup.py" --prepare
/usr/bin/hdiutil imageinfo "$BUILD_DIR/setup/setup.img" > "$BUILD_DIR/setup/imageinfo.txt"
/usr/bin/shasum -a 256 "$BUILD_DIR/setup/setup.img" > "$BUILD_DIR/setup/setup.sha256"
echo "BUILD_OK SETUP=$BUILD_DIR/setup/setup.img (signature checked; verification mount detached; not published)"
