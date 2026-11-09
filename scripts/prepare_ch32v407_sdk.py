#!/usr/bin/env python3
"""Apply explicit, checked patches to a copy of the verified vendor sources."""
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build/ch32v407'
SRC = BUILD / 'sdk'
DST = BUILD / 'sdk-patched'
EXAMPLE = Path('EVT/EXAM/USBHS/Dual_device/cdc_transfer')


def replace(path, before, after):
    content = path.read_text()
    if content.count(before) != 1:
        raise RuntimeError(f'Upstream patch context changed: {path.name}: {before[:60]}')
    path.write_text(content.replace(before, after))


def main():
    manifest = json.loads((SRC / 'manifest.json').read_text())
    for item in manifest['files']:
        source = SRC / item['path']
        if hashlib.sha256(source.read_bytes()).hexdigest() != item['sha256']:
            raise RuntimeError(f'Unverified SDK source: {source}')
        dest = DST / item['path']; dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, dest)
    cfg = DST / EXAMPLE / 'usb_driver/include/usb_config.h'
    for level in ['INFO', 'WARNING', 'ERROR']:
        replace(cfg, f'#define USB_DRIVER_LOG_{level}_EN', f'/* USB_DRIVER_LOG_{level}_EN disabled: no synchronous USB logging */')
    for port in [1, 2]:
        f = DST / EXAMPLE / f'usb_driver/port/usbhs{port}_dcp.c'
        replace(f, '#include <string.h>', '#include <string.h>\n#include <stdint.h>\nextern uint32_t wk407_now_ms(void);\nextern void wk407_reset_begin(unsigned);')
        replace(f, f'    uint8_t status = USBHS{port}D->INT_ST;', f'''    uint8_t status = USBHS{port}D->INT_ST;
    /* Keep the vendor 10ms reset settling period without blocking either port. */
    static uint32_t reset_at;
    static int reset_pending;
    if (flag & USBHS_UDIF_BUS_RST) {{
        if (!reset_pending) {{ reset_pending=1; reset_at=wk407_now_ms(); wk407_reset_begin({port-1}); }}
        if ((uint32_t)(wk407_now_ms()-reset_at)<10) return;
        reset_pending=0;
        e.e=USBD_EVENT_RESET;
        e.reset.link_speed=(USBHS{port}D->MIS_ST & USBHS_UDMS_HS_MOD)?USB_SPEED_HIGH:USB_SPEED_FULL;
        usbd_event_handle(&usbhs{port}d_handle,&e);
        USBHS{port}D->INT_FG=USBHS_UDIF_BUS_RST;
        return;
    }}''')
        replace(f, '        Delay_Ms(10);', '        /* Reset is handled above with a per-port deadline. */')
        replace(f, '        while (!(RCC->CTLR & RCC_USBHSPLLRDY));', '''        unsigned timeout=2000000;
        while (!(RCC->CTLR & RCC_USBHSPLLRDY) && --timeout) {}
        if (!timeout) return USB_RST_FAILED;''')
        # Enable/init and interrupt_ctrl(TRUE) both remain in the polling domain.
        text = f.read_text().replace(f'NVIC_EnableIRQ(USBHS{port}_IRQn);', f'NVIC_DisableIRQ(USBHS{port}_IRQn); /* polling owner */')
        # The shared PLL must remain on when only one controller closes.
        before = f'    RCC_UTMI{port}cmd(DISABLE);\n    RCC->CTLR &= ~RCC_USBHSPLLON;'
        if text.count(before) != 1: raise RuntimeError('clock patch context changed')
        text = text.replace(before, f'    RCC_UTMI{port}cmd(DISABLE);\n    /* Common PLL remains enabled for the other controller. */')
        f.write_text(text)
    # Normal RISC-V code, no proprietary fast-interrupt prologues.
    startup = DST / 'EVT/EXAM/SRC/Startup/startup_ch32v4x7.S'
    replace(startup, '    li t0, 0x07', '    li t0, 0x00')
    replace(startup, 'li t0, 0x688', 'li t0, 0x1800')
    linker = DST / 'EVT/EXAM/SRC/Ld/Link.ld'
    replace(linker, '__stack_size = 2048;', '__stack_size = 8192;')
    print('SDK patches applied: polling, deferred reset, shared PLL, no USB logging, 8KiB stack')


if __name__ == '__main__': main()
