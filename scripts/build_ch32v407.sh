#!/usr/bin/env bash
# Build only. Does not open USB, modify a running application, or flash hardware.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD="$ROOT/build/ch32v407"
PREFIX="${WK_RISCV_PREFIX:-$HOME/.local/share/esp32-agent/idf-tools/tools/riscv32-esp-elf/esp-15.2.0_20251204/riscv32-esp-elf/bin/riscv32-esp-elf-}"
if [[ ! -x "${PREFIX}gcc" ]]; then
    echo 'Set WK_RISCV_PREFIX to a RISC-V GCC toolchain prefix.' >&2; exit 2
fi
[[ -f "$BUILD/sdk/manifest.json" ]] || python3 "$ROOT/scripts/fetch_ch32v407_sdk.py"
python3 "$ROOT/scripts/prepare_ch32v407_sdk.py"
SDK="$BUILD/sdk-patched/EVT/EXAM"
USB="$SDK/USBHS/Dual_device/cdc_transfer"
mkdir -p "$BUILD/obj"
INCLUDES=(-I"$ROOT/firmware/ch32v407" -I"$ROOT/firmware/main" -I"$SDK/SRC/Core" -I"$SDK/SRC/Debug"
    -I"$SDK/SRC/Peripheral/inc" -I"$USB/board" -I"$USB/usb_driver/include" -I"$USB/usb_driver/port")
FLAGS=(-march=rv32imac_zicsr_zifencei -mabi=ilp32 -mcmodel=medany -msmall-data-limit=0
    -Os -g3 -ffunction-sections -fdata-sections -fno-common -fno-strict-aliasing)
SOURCES=("$ROOT/firmware/ch32v407/bridge.c" "$ROOT/firmware/ch32v407/main.c" "$ROOT/firmware/ch32v407/descriptors.c" "$ROOT/firmware/ch32v407/newlib_context.c"
    "$ROOT/firmware/ch32v407/setup_msc.c" "$ROOT/firmware/ch32v407/setup_flash.c"
    "$ROOT/firmware/main/wire_protocol.c" "$SDK/SRC/Startup/startup_ch32v4x7.S"
    "$USB/board/system_ch32v4x7.c" "$USB/usb_driver/src/usbd_driver_core.c"
    "$USB/usb_driver/port/usbhs1_dcp.c" "$USB/usb_driver/port/usbhs2_dcp.c"
    "$SDK/SRC/Peripheral/src/ch32v4x7_rcc.c" "$SDK/SRC/Peripheral/src/ch32v4x7_gpio.c" "$SDK/SRC/Peripheral/src/ch32v4x7_spi.c")
OBJECTS=()
for source in "${SOURCES[@]}"; do
    obj="$BUILD/obj/$(basename "$source").o"
    "${PREFIX}gcc" "${FLAGS[@]}" "${INCLUDES[@]}" -c "$source" -o "$obj"
    OBJECTS+=("$obj")
done
"${PREFIX}gcc" "${FLAGS[@]}" -nostartfiles --specs=nosys.specs "${OBJECTS[@]}" \
    -Wl,--gc-sections,-Map,"$BUILD/wiredkvm-ch32v407.map" -T "$SDK/SRC/Ld/Link.ld" \
    -o "$BUILD/wiredkvm-ch32v407.elf"
"${PREFIX}objcopy" -O binary "$BUILD/wiredkvm-ch32v407.elf" "$BUILD/wiredkvm-ch32v407.bin"
"${PREFIX}size" "$BUILD/wiredkvm-ch32v407.elf"
"${PREFIX}gcc" --version | head -1
echo 'BUILD_OK: CH32V407 firmware; no hardware was accessed.'
