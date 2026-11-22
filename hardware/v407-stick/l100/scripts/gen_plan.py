#!/usr/bin/env python3
"""Generate the schematic plan (parts, wires, labels, flags, NC, notes) for WiredKVM-V407-Stick-L100 (CH32V407VET6, LQFP100).

Source of truth for placement geometry. Pin offsets come from the live library probe
(evidence/04-probe-parts.json). Units: schematic raw (0.01 inch), y up, 5-raw grid.
The intended netlist lives in netlist_truth.py and is checked against the EDA netlist
after apply; this file only draws.
"""
import json, math, pathlib, sys

W = pathlib.Path(__file__).resolve().parent.parent
probe = json.load(open(W / "evidence/04-probe-parts.json"))["value"]["parts"]
# LQFP100 variant: U1 symbol geometry comes from its own probe of CH32V407VET6 (C54937001)
probe["MCU"] = json.load(open(W / "evidence/31-probe-mcu-lqfp100.json"))["value"]["parts"]["MCU"]
# 8 MiB flash P25Q64SH-SSH-IR (C18185312): same footprint as the old BY25Q32ESTIG, different symbol geometry
probe["FLASH"] = json.load(open(W / "evidence/31-probe-flash-p25q64.json"))["value"]["parts"]["FLASH"]
dev = json.load(open(W / "scripts/devices.json"))["devices"]
PROJECT_LIB = json.load(open(W / "scripts/devices.json")).get("projectLibraryDevices", {})


class Page:
    def __init__(self, name):
        self.name = name
        self.parts, self.wires, self.labels, self.flags, self.nc, self.texts = [], [], [], [], [], []
        self.pins = {}  # (ref, num) -> (x, y, rot)

    # --- parts -------------------------------------------------------------
    def part(self, ref, kind, x, y, rot=0, mirror=False, bom=True):
        # Parts whose footprint was edited in the project library must be placed from the project library:
        # placing the system-library version pops a blocking "other version in project library" dialog.
        src = PROJECT_LIB.get(kind)
        self.parts.append(dict(ref=ref, kind=kind, dev=src or dev[kind], lib="project" if src else "system", x=x, y=y, rot=rot, mirror=mirror, bom=bom))
        for q in probe[kind]["pins"]:
            px, py, pr = q["x"], q["y"], q["rot"]
            if mirror:
                px, pr = -px, (180 - pr) % 360
            if rot == 90:
                px, py = py, -px
            elif rot == 180:
                px, py = -px, -py
            elif rot == 270:
                px, py = -py, px
            pr = (pr - rot) % 360
            self.pins[(ref, q["n"])] = (x + px, y + py, pr)

    def P(self, pin):
        ref, num = pin.split(".", 1)
        return self.pins[(ref, num)]

    # --- primitives --------------------------------------------------------
    def wire(self, *pts):
        flat = [c for p in pts for c in p]
        assert all(v % 5 == 0 for v in flat), flat
        for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
            assert x1 == x2 or y1 == y2, ("diagonal", pts)
        self.wires.append(flat)

    def label(self, x, y, net):
        self.labels.append(dict(x=x, y=y, net=net))

    def gnd(self, x, y, rot=0):
        self.flags.append(dict(kind="Ground", net="GND", x=x, y=y, rot=rot))

    def pwr(self, x, y, net="3V3", rot=0):
        self.flags.append(dict(kind="Power", net=net, x=x, y=y, rot=rot))

    def text(self, x, y, s, size=None, bold=False):
        self.texts.append(dict(x=x, y=y, s=s, size=size, bold=bold))

    # --- helpers -----------------------------------------------------------
    def stub(self, pin, net, length=None):
        """Horizontal labelled stub leaving a left/right pointing pin."""
        x, y, r = self.P(pin)
        assert r in (0, 180), (pin, r)
        if length is None:
            length = max(40, 10 * math.ceil((4.6 * len(net) + 14) / 10))
        d = 1 if r == 0 else -1
        self.wire((x, y), (x + d * length, y))
        self.label(x + 5 if d == 1 else x - length + 5, y, net)

    def gnd_stub(self, pin, length=20):
        """Stub then a sideways ground flag (symbol continues away from the pin)."""
        x, y, r = self.P(pin)
        assert r in (0, 180), (pin, r)
        d = 1 if r == 0 else -1
        if length:
            self.wire((x, y), (x + d * length, y))
        self.gnd(x + d * length, y, 270 if d == 1 else 90)

    def no_connect(self, *pins):
        for p in pins:
            self.P(p)
            self.nc.append(p)

    def hang(self, ref, kind, x, rail_y, net_top_wire=True):
        """Vertical 2-pin part hanging below a horizontal wire at rail_y; bottom pin to GND flag.
        Returns nothing; pin 1 is the top pin for every 2-pin library symbol at rot 90."""
        half = abs(probe[kind]["pins"][0]["x"])
        cy = rail_y - 5 - half
        self.part(ref, kind, x, cy, 90)
        tx, ty, _ = self.P(ref + ".1")
        bx, by, _ = self.P(ref + ".2")
        assert ty > by, (ref, ty, by)
        self.wire((x, rail_y), (tx, ty))
        self.gnd(bx, by, 0)

    def dump(self):
        return dict(name=self.name, parts=self.parts, wires=self.wires, labels=self.labels, flags=self.flags,
                    nc=self.nc, texts=self.texts,
                    expect=[dict(ref=r, n=n, x=x, y=y, rot=rot) for (r, n), (x, y, rot) in self.pins.items()])


# =============================== PAGE 1: MCU =================================
# U1 (LQFP100 symbol, 610 raw tall) takes the left third of the sheet, clear of the title block (x >= 462, y <= 180);
# every other block sits to its right.
p1 = Page("MCU")
UX, UY = 300, 470
p1.part("U1", "MCU", UX, UY)
left = {12: "OSC_IN", 13: "OSC_OUT", 21: "3V3", 20: "GND", 14: "NRST", 6: "3V3", 48: "P48_VDD18", 94: "BOOT0",
        29: "FLASH_CS", 30: "FLASH_SCK", 31: "FLASH_MISO", 32: "FLASH_MOSI", 68: "UART_TX", 69: "UART_RX",
        70: "USB1_DM", 71: "USB1_DP", 72: "SWDIO", 76: "SWCLK"}
right = {83: "LED", 33: "VBUS2_DET", 93: "USB2_DP", 92: "USB2_DM", 37: "BOOT1"}
for n, net in {**left, **right}.items():
    p1.stub(f"U1.{n}", net, 60)
top3v3, vss = [11, 28, 46, 75, 100, 22], [10, 27, 41, 47, 99, 19]
used = set(left) | set(right) | set(top3v3) | set(vss) | {40}
p1.no_connect(*[f"U1.{n}" for n in range(1, 101) if n not in used])
# top pins: five VDD + VDDA on one 3V3 rail, VDDK on its own label
xs = sorted(p1.P(f"U1.{n}")[0] for n in top3v3)
for n in top3v3:
    x, y, r = p1.P(f"U1.{n}")
    assert r == 90 and y == UY + 305, (n, x, y, r)
    p1.wire((x, y), (x, y + 10))
p1.wire((xs[0] - 60, UY + 315), *[(x, UY + 315) for x in xs])
p1.label(xs[0] - 58, UY + 315, "3V3")
x, y, r = p1.P("U1.40")
assert r == 90 and x == xs[-1] + 10, (x, xs)
p1.wire((x, y), (x, y + 15), (x + 50, y + 15))
p1.label(x + 5, y + 15, "VDDK")
# bottom pins: five VSS + VSSA to ground
xs = sorted(p1.P(f"U1.{n}")[0] for n in vss)
for n in vss:
    x, y, r = p1.P(f"U1.{n}")
    assert r == 270 and y == UY - 305, (n, x, y, r)
    p1.wire((x, y), (x, y - 15))
p1.wire(*[(x, UY - 320) for x in xs])
p1.gnd(xs[2], UY - 320)

# decoupling: 3V3 rail y=275, GND rail y=215
RAIL, GR = 275, 215
dec = [("C3", "C100N"), ("C4", "C100N"), ("C5", "C10U"), ("C6", "C100N"), ("C7", "C100N"), ("C8", "C100N"),
       ("C9", "C100N"), ("C19", "C100N")]
dec = [(r, k, 530 + 50 * i) for i, (r, k) in enumerate(dec)]
vddk = [("C10", "C100N", 940), ("C11", "C2U2", 990)]
for ref, kind, cx in dec + vddk + [("C12", "C2U2", 1090)]:
    p1.part(ref, kind, cx, 245, 90)
    p1.wire((cx, RAIL), p1.P(ref + ".1")[:2])
    p1.wire(p1.P(ref + ".2")[:2], (cx, GR))
p1.wire(*[(cx, RAIL) for _, _, cx in dec])
p1.pwr(530, RAIL, "3V3", 0)
p1.wire(*[(cx, RAIL) for _, _, cx in vddk])
p1.label(945, RAIL, "VDDK")
p1.wire((1030, RAIL), (1090, RAIL))
p1.label(1032, RAIL, "P48_VDD18")
p1.wire(*[(cx, GR) for _, _, cx in dec + vddk], (1090, GR))
p1.gnd(680, GR)
# ASCII arrows here: host 4.1.78 split one multibyte char of this line across a save chunk (U+FFFD after reload).
p1.text(510, 365, "U1 CH32V407VET6 LQFP100 —— 双 USB2.0 HS Device 桥", bold=True)
p1.text(510, 348, "去耦：C3->U1.28  C4+C5->U1.46(主 VDD)  C6->U1.75  C7->U1.100  C8->U1.21/22 VREF+/VDDA  C9->U1.6 VBAT  C19->U1.11")
p1.text(510, 333, "C10+C11->U1.40 VDDK (1.2V 内核 LDO 输出，不得外接负载)。所有电容紧靠对应引脚。")
p1.text(510, 318, "C12 仅在改贴 CH32V467VET6 (48 脚=VDD18) 时需要；贴 V407 时 48 脚是 PE7，固件保持输入。")

# crystal
p1.part("Y1", "XTAL", 630, 740)
x, y, _ = p1.P("Y1.1")
p1.part("C15", "C15P", 530, 690, 90)
p1.wire((x, y), (530, y), p1.P("C15.1")[:2])
p1.label(535, y, "OSC_IN")
p1.gnd(*p1.P("C15.2")[:2])
x, y, _ = p1.P("Y1.3")
p1.part("C16", "C15P", 720, 690, 90)
p1.wire((x, y), (720, y), p1.P("C16.1")[:2])
p1.label(x + 5, y, "OSC_OUT")
p1.gnd(*p1.P("C16.2")[:2])
p1.gnd_stub("Y1.4", 0)
p1.gnd_stub("Y1.2", 0)
p1.text(510, 785, "25MHz 晶振 (CL=12pF, ±10ppm)：USB HS 必须用 HSE", bold=True)

# reset / boot
p1.wire((530, 620), (610, 620))
p1.label(535, 620, "NRST")
p1.hang("C14", "C100N", 610, 620)
p1.wire((530, 540), (610, 540))
p1.label(535, 540, "BOOT0")
p1.hang("R6", "R10K", 610, 540)
p1.wire((650, 540), (720, 540))
p1.label(655, 540, "BOOT1")
p1.hang("R7", "R10K", 720, 540)
p1.text(510, 638, "复位 / 启动配置 (BOOT0=0 从用户 Flash 启动；TP6 拉高进 ISP)", bold=True)

# setup flash
p1.part("U3", "FLASH", 930, 700)
x, y, _ = p1.P("U3.1")
p1.part("R8", "R10K", 770, 745, 90)
p1.wire((x, y), (770, y), p1.P("R8.2")[:2])
p1.label(790, y, "FLASH_CS")
p1.pwr(*p1.P("R8.1")[:2], "3V3", 0)
p1.stub("U3.2", "FLASH_MISO", 60)
p1.stub("U3.3", "3V3", 60)
p1.stub("U3.4", "GND", 60)
p1.stub("U3.5", "FLASH_MOSI", 60)
p1.stub("U3.6", "FLASH_SCK", 60)
p1.stub("U3.7", "3V3", 60)
x, y, _ = p1.P("U3.8")
p1.wire((x, y), (1110, y))
p1.pwr(1110, y, "3V3", 0)
p1.hang("C13", "C100N", 1110, y)
p1.text(830, 785, "安装资源 Flash 8MiB，SPI1 (PA4–PA7)，固件只读使用", bold=True)

# status LED
p1.wire((800, 580), (860, 580))
p1.label(805, 580, "LED")
p1.part("R9", "R1K", 880, 580)
p1.part("LED1", "LED", 950, 580, 180)
assert p1.P("LED1.1")[0] == 930, p1.P("LED1.1")
p1.wire((900, 580), (930, 580))
p1.wire((970, 580), (990, 580))
p1.gnd(990, 580, 270)
p1.text(800, 605, "状态 LED (PD2，高电平点亮)", bold=True)

# test pads
tps = [("TP1", "3V3", 800, 480), ("TP2", "GND", 800, 450), ("TP3", "SWDIO", 800, 420), ("TP4", "SWCLK", 800, 390),
       ("TP5", "NRST", 980, 480), ("TP6", "BOOT0", 980, 450), ("TP7", "UART_TX", 980, 420), ("TP8", "UART_RX", 980, 390)]
for ref, net, x0, y0 in tps:
    p1.part(ref, "TP", x0 + 80, y0, 0, bom=False)
    p1.wire((x0, y0), (x0 + 80, y0))
    p1.label(x0 + 5, y0, net)
p1.text(800, 515, "测试焊盘：WCH-LinkE (SWDIO/SWCLK/GND)＋ISP/串口。TP1 3V3 仅供产测治具受控供电", bold=True)

# ============================ PAGE 2: USB + POWER ============================
p2 = Page("USB_Power")
# --- USB1 plug (mirrored so the contact row faces right) ---
p2.part("J1", "PLUG", 150, 670, 0, mirror=True)
for pin, net in [("J1.A4", "VBUS1"), ("J1.A5", "USB1_CC"), ("J1.A6", "USB1_DP"), ("J1.A7", "USB1_DM")]:
    p2.stub(pin, net, 70)
p2.gnd_stub("J1.A1", 90)
p2.gnd_stub("J1.A12", 90)
p2.no_connect("J1.A2", "J1.A3", "J1.B10", "J1.B11")
x, y, _ = p2.P("J1.B9")
p2.wire((x, y), (x - 50, y))
p2.label(x - 47, y, "VBUS1")
xb, yb, _ = p2.P("J1.B12")
x0, y0, _ = p2.P("J1.0")
x1, y1, _ = p2.P("J1.1")
ys = sorted([yb, y0, y1])
p2.wire((xb, ys[2]), (xb - 20, ys[2]), (xb - 20, ys[0]), (xb, ys[0]))
p2.wire((xb, ys[1]), (xb - 20, ys[1]))
p2.gnd(xb - 20, (ys[0] + ys[1]) // 2 // 5 * 5, 90)
# --- USB1 data ESD ---
p2.part("D1", "ESD2", 490, 660)
p2.stub("D1.1", "USB1_DP", 70)
p2.stub("D1.3", "USB1_DM", 70)
p2.gnd_stub("D1.2", 90)
p2.stub("D1.6", "USB1_DP", 70)
p2.stub("D1.4", "USB1_DM", 70)
p2.no_connect("D1.5")  # left open like D2: no diode path from D+/D- into VBUS1, and no jumper under the USB1 pair
# --- USB1 CC ---
p2.wire((60, 545), (220, 545))
p2.label(65, 545, "USB1_CC")
p2.hang("R1", "R5K1", 140, 545)
p2.hang("D3", "ESD1", 220, 545)
# --- power chain ---
p2.wire((50, 430), (110, 430))
p2.label(62, 430, "VBUS1")
p2.hang("C18", "C100N", 50, 430)
p2.part("F1", "PTC", 130, 430)
p2.wire((150, 430), (200, 430))
p2.label(152, 430, "VBUS1_F")
p2.part("D6", "SCHOTTKY", 220, 430, 180)
assert p2.P("D6.2")[0] == 200 and p2.P("D6.1")[0] == 240
p2.part("U2", "LDO", 450, 420)
p2.wire((240, 430), p2.P("U2.1")[:2])
p2.label(300, 430, "VSYS")
p2.hang("C1", "C4U7", 270, 430)
p2.stub("U2.2", "GND", 60)
p2.stub("U2.3", "VSYS", 60)
p2.no_connect("U2.4")
x, y, _ = p2.P("U2.5")
p2.wire((x, y), (600, y))
p2.hang("C2", "C4U7", 550, y)
p2.pwr(600, y, "3V3", 0)
# --- USB2 receptacle ---
p2.part("J2", "RCPT", 1050, 650)
for pin, net in [("J2.A5", "USB2_CC1"), ("J2.B7", "USB2_DM"), ("J2.A6", "USB2_DP"),
                 ("J2.A7", "USB2_DM"), ("J2.B6", "USB2_DP"), ("J2.B5", "USB2_CC2"), ("J2.B4A9", "VBUS2")]:
    p2.stub(pin, net, 80)
p2.gnd_stub("J2.A1B12", 100)
p2.gnd_stub("J2.B1A12", 100)
p2.no_connect("J2.B8", "J2.A8", "J2.A4B9")  # one VBUS2 pad is enough for sensing; the plug shorts all four
sh = [p2.P(f"J2.{i}") for i in "1234"]
sx = sh[0][0]
sy = sorted(s[1] for s in sh)
p2.wire((sx, sy[3]), (sx + 20, sy[3]), (sx + 20, sy[0]), (sx, sy[0]))
p2.wire((sx, sy[1]), (sx + 20, sy[1]))
p2.wire((sx, sy[2]), (sx + 20, sy[2]))
p2.gnd(sx + 20, sy[1] + 5, 270)
# --- USB2 data ESD (pin 5 left open on purpose) ---
p2.part("D2", "ESD2", 780, 660)
p2.stub("D2.1", "USB2_DP", 70)
p2.stub("D2.3", "USB2_DM", 70)
p2.gnd_stub("D2.2", 90)
p2.stub("D2.6", "USB2_DP", 70)
p2.stub("D2.4", "USB2_DM", 70)
p2.no_connect("D2.5")
# --- USB2 CC ---
p2.wire((640, 545), (800, 545))
p2.label(645, 545, "USB2_CC1")
p2.hang("R2", "R5K1", 720, 545)
p2.hang("D4", "ESD1", 800, 545)
p2.wire((900, 545), (1060, 545))
p2.label(905, 545, "USB2_CC2")
p2.hang("R3", "R5K1", 980, 545)
p2.hang("D5", "ESD1", 1060, 545)
# --- VBUS2 detect ---
p2.wire((640, 430), (700, 430))
p2.label(645, 430, "VBUS2")
p2.part("R4", "R100K", 720, 430)
p2.wire((740, 430), (860, 430))
p2.label(745, 430, "VBUS2_DET")
p2.hang("R5", "R10K", 800, 430)
p2.hang("C17", "C100N", 860, 430)
# --- notes ---
p2.text(40, 785, "USB1：Type-C 公头，插主控机 —— 整板唯一供电入口", bold=True)
p2.text(40, 770, "UFP：CC 接 Rd 5.1k。SuperSpeed 触点不用。D1 第 5 脚悬空。")
p2.text(640, 785, "USB2：Type-C 母座，接被控机 —— 只做数据和 VBUS 检测", bold=True)
p2.text(640, 770, "VBUS2 不进任何电源轨，不与 VBUS1 相连；CC1/CC2 各自 Rd 5.1k，不与 USB1 共用。")
p2.text(640, 755, "D2 第 5 脚故意悬空：D+/D- 没有二极管通路进入 VBUS2 检测点或 3V3。")
p2.text(40, 580, "CC 端接 + ESD", bold=True)
p2.text(640, 580, "CC 端接 + ESD", bold=True)
p2.text(40, 462, "电源：VBUS1 → PTC 0.5A → 肖特基 (阻断向 USB1 回灌) → LDO 3.3V", bold=True)
p2.text(640, 462, "VBUS2 检测：100k/10k 分压 -> PC4 (ADC14)，固件用 ADC 读。VBUS2 上无储能电容", bold=True)
p2.text(640, 340, "VBUS2 为 5V 时 PC4 约 0.45V，低于引脚保护二极管的导通电压：只接 USB2 时不会经 PC4 向 3V3 漏电。")
p2.text(640, 325, "滤波约 1ms (9.1k x 100nF)。整板只由 USB1 供电；固件在 VBUS2 有效后才使能 USB2 上拉。")

if __name__ == "__main__":
    out = W / "scripts/plan.json"
    json.dump(dict(pages=[p1.dump(), p2.dump()]), open(out, "w"), ensure_ascii=False, indent=1)
    for p in (p1, p2):
        print(p.name, "parts", len(p.parts), "wires", len(p.wires), "labels", len(p.labels), "flags", len(p.flags),
              "nc", len(p.nc), "texts", len(p.texts))
