#!/usr/bin/env python3
"""Placement and routing data for WiredKVM-V407-Stick-L100 (CH32V407VET6, LQFP100).

Run: .venv/bin/python scripts/pcb_layout.py [preview-dir]
Writes scripts/pcb_plan.json (mil) for the EDA apply script and PNG previews.
All routing is on the top layer except one 1.3 mm jumper at the receptacle, so the bottom layer stays a ground plane.

U1 is rotated 270 deg: USB1 pins (70/71) on the south row facing the plug, USB2 pins (92/93) on the east row,
SPI on the west row, crystal on the north row. The LQFP has no exposed pad, so the top layer under the package
carries a 3V3 ring; every VDD pin drops onto it from its inner pad end and every VSS pin has a via to the plane.
"""
import json, sys, pathlib
from pcbtool import Board, TOP, BOT, FP

W_BOARD, L = 22.0, 47.8
b = Board(W_BOARD, L)
P = b.P

# ---------- placement (x, y, rot) ----------
U, V = 0.2, 21.0                   # U1 centre; 0.2 mm east of the board centre so the west margin takes the SPI bus and C3
J2Y = L + 0.5 - 5.094              # receptacle front protrudes 0.5 mm past the board edge
YIN = J2Y - 3.125                  # inner end of the J2 pad row
D2Y = YIN - 3.6
FX, FY = -7.3, 33.6                # flash centre
XP = U + 8.9                       # USB2 D+ vertical run; D- runs at XP + PITCH
# USB pair: 0.45 mm tracks, 0.20 mm gap. On 1.0 mm FR-4 over the bottom plane two independent 2-D field solvers put
# this at about 90 ohm where solder mask covers it and the top ground pour is 0.25 mm away on both sides, and about
# 100 ohm where there is no pour beside it (estimates, not measured). The earlier 0.60/0.16 geometry was 78-95 ohm.
WU, PITCH = 0.45, 0.65
YH = 9.2                           # USB1 D+ horizontal run
YW = 34.2                          # USB2 D+ horizontal run, 0.5 mm clear of the crystal pads
XW = U - 9.0                       # centre line of the capacitors standing along the west pad row
XDET = -10.5                       # VBUS2 sense run up the west edge


def rel(*pts):
    """Points given relative to the U1 centre."""
    return [(U + x, V + y) for x, y in pts]


# plug end: USB1 ESD and CC parts on the west, power chain on the east
b.put("J1", 0, 1.22, 0)            # footprint draws the board edge 1.22 mm below its origin
b.put("D1", -2.7, 5.6, 180)
b.put("R1", -0.6, 5.3, 90)
b.put("D3", 0.6, 5.4, 90)
b.put("C18", 2.75, 3.2, 270)
b.put("F1", 4.5, 3.7, 0)
b.put("D6", 8.05, 4.3, 270)
b.put("C1", 6.25, 6.6, 180)
b.put("U2", 9.0, 8.6, 0)
b.put("C2", 6.15, 9.75, 180)

b.put("U1", U, V, 270)
b.put("C6", U + 6.42, 12.05, 0)     # pin 75
b.put("R6", U + 7.7, 13.4, 0)       # BOOT0 pull-down
b.put("R9", U + 9.5, V - 2.5, 0)    # LED resistor at pin 83
b.put("LED1", U + 9.85, V - 4.2, 90)
b.put("C7", U + 7.4, V + 7.6, 180)  # pin 100
b.put("C12", U - 7.14, 11.8, 180)   # pin 48 (VDD18 on V467 only)
b.put("C5", U - 8.7, 13.3, 0)       # pin 46 bulk
b.put("C4", XW, V - 4.42, 270)      # pins 46/47
b.put("C10", XW, V - 1.42, 270)     # VDDK: across pins 40/41
b.put("C11", XW - 1.1, V - 1.9, 270) # VDDK bulk, outboard of C10
b.put("R7", XW - 0.42, V + 0.42, 180)    # BOOT1 pull-down, pin 37
b.put("C17", XW - 0.42, V + 1.9, 0)     # VBUS2 sense filter at pin 33
b.put("C3", XW, V + 5.47, 90)       # pins 27/28
b.put("C8", U - 3.83, 30.0, 0)      # pins 19..22 (VSSA, VREF-, VREF+, VDDA)
b.put("C13", U - 4.1, 31.0, 0)      # flash VCC
b.put("C14", U - 2.6, 30.67, 90)    # NRST
b.put("C16", U - 1.8, 31.57, 90)   # OSC_OUT load
b.put("Y1", U + 0.5, 32.0, 180)
b.put("C15", U + 3.25, 32.85, 0)    # OSC_IN load
b.put("C19", U + 1.47, 30.0, 0)     # pins 10/11
b.put("C9", U + 3.92, 30.0, 0)      # pin 6 VBAT

b.put("U3", FX, FY, 180)
b.put("R8", FX + 1.47, FY + 4.3, 0)

b.put("J2", 0, J2Y, 180)
b.put("D2", 0, D2Y, 0)
b.put("R4", -2.45, YIN - 1.05, 270)
b.put("D5", -2.8, YIN - 2.5, 180)
b.put("R3", -2.48, YIN - 3.5, 180)
b.put("R5", -3.7, YIN - 1.4, 0)
b.put("R2", 2.3, YIN - 2.0, 270)
b.put("D4", 3.6, YIN - 2.3, 270)

TPS = {  # ref: (x, y, exposed-disc diameter)
    "TP1": (9.8, 11.4, 1.2), "TP2": (5.7, 8.2, 1.2), "TP3": (U + 5.1, 11.3, 0.9), "TP4": (U + 9.6, 14.2, 1.0),
    "TP5": (U - 3.18, 32.9, 0.9), "TP6": (U + 7.95, 12.25, 1.0), "TP7": (U + 0.4, 11.6, 1.0), "TP8": (U + 2.0, 11.1, 1.0),
}
for ref, (x, y, d) in TPS.items():
    b.put(ref, x, y, 0)


def route():
    T, VIA = b.track, b.via

    def gnd_via(pad, dx=0.0, dy=0.0, w=0.3, dia=0.6):
        x, y = P(pad)
        VIA("GND", x + dx, y + dy, 0.3, dia)
        T("GND", [(x, y), (x + dx, y + dy)], w)

    # ===== J1 plug: USB1 data through D1 =====
    a7, a6 = P("J1.A7"), P("J1.A6")
    d14, d13, d16, d11 = P("D1.4"), P("D1.3"), P("D1.6"), P("D1.1")
    T("USB1_DM", [a7, (a7[0], 2.5), (d14[0], 2.5 + a7[0] - d14[0]), d14], 0.2)
    T("USB1_DM", [d14, d13], 0.25)
    T("USB1_DP", [a6, d16], 0.2)
    T("USB1_DP", [d16, d11], 0.25)
    # pair from D1 to U1 pins 70 (D-) / 71 (D+): north, north-east, east, north-east, north, then a short neck
    p70, p71 = P("U1.70"), P("U1.71")
    xdp, xdm = p71[0] + (PITCH - 0.5) / 2, p70[0] - (PITCH - 0.5) / 2
    r2 = 2 ** 0.5
    y0, dd = 8.53, 1.0
    yn = V - 8.45 - 0.75                                # necks start here
    c1 = d11[0] - y0                                    # D+ first diagonal:  x - y = c1
    c2 = xdp - dd - YH                                  # D+ second diagonal: x - y = c2
    c1m, c2m = c1 - PITCH * r2, c2 - PITCH * r2
    T("USB1_DP", [d11, (d11[0], y0), (YH + c1, YH), (xdp - dd, YH), (xdp, YH + dd), (xdp, yn)], WU)
    T("USB1_DP", [(xdp, yn), (p71[0], yn + 0.1), p71], 0.2)
    yh2 = YH + PITCH
    T("USB1_DM", [d13, (d13[0], d13[0] - c1m), (yh2 + c1m, yh2), (yh2 + c2m, yh2), (xdm, xdm - c2m), (xdm, yn)], WU)
    T("USB1_DM", [(xdm, yn), (p70[0], yn + 0.1), p70], 0.2)
    # D1 pin 5 stays open (as on D2); D1 pin 2 goes to ground under the body
    b9, a4 = P("J1.B9"), P("J1.A4")
    T("VBUS1", [b9, (b9[0], 2.6), (-0.6, 2.75), (-0.6, 3.65), (a4[0], 3.65), a4], 0.25)
    T("VBUS1", [(a4[0], 3.65), (2.75, 3.65), P("F1.1")], 0.4)
    T("VBUS1", [(2.75, 3.65), P("C18.1")], 0.4)
    VIA("GND", -2.7, 5.6)
    T("GND", [P("D1.2"), (-2.7, 5.6)], 0.3)
    # CC pull-down and its ESD diode
    a5, r11, d31 = P("J1.A5"), P("R1.1"), P("D3.1")
    T("USB1_CC", [(a5[0] + 0.05, a5[1]), (a5[0] + 0.05, r11[1]), r11], 0.15)
    T("USB1_CC", [r11, (r11[0] + 0.22, d31[1]), d31], 0.2)
    # plug ground pins
    b12 = P("J1.B12")
    VIA("GND", 0.6, 2.85)
    T("GND", [b12, (b12[0], 2.5), (0.6, 2.85)], 0.25)
    for sgn, pin in ((-1, "A12"), (1, "A1")):
        p = P(f"J1.{pin}")
        T("GND", [(p[0], 1.5), (p[0] + sgn * 0.6, 0.9), (sgn * 3.575, 0.9)], 0.25)
        T("GND", [(sgn * 3.575, 0.65), (sgn * 4.7, 0.65)], 0.4)
        T("GND", [(sgn * 4.7, 1.2), (sgn * 6.1, 1.2), (sgn * 6.1, 2.4)], 0.5)
        VIA("GND", sgn * 6.1, 1.2)
        VIA("GND", sgn * 6.1, 2.4)
    T("GND", [P("J1.A1"), P("C18.2")], 0.25)
    r12, d32 = P("R1.2"), P("D3.2")
    T("GND", [d32, (d32[0] - 0.43, r12[1] + 0.85), (r12[0], r12[1] + 0.85)], 0.25)
    gnd_via("R1.2", dy=0.85, w=0.25)

    # ===== power chain: VBUS1 -> F1 -> D6 -> U2 -> 3V3 =====
    f12, d62, d61 = P("F1.2"), P("D6.2"), P("D6.1")
    T("VBUS1_F", [f12, (d62[0] - 1.15, f12[1]), (d62[0] - 0.45, 3.0), (d62[0], 3.0)], 0.5)
    u21, u23, u25 = P("U2.1"), P("U2.3"), P("U2.5")
    T("VSYS", [d61, u21], 0.4)
    T("VSYS", [(d61[0] + 0.25, 6.4), (u23[0], 6.4), u23], 0.25)
    T("VSYS", [P("C1.1"), (d61[0] - 0.3, 6.35)], 0.4)
    gnd_via("C1.2", dy=-0.95, w=0.4)
    u22 = P("U2.2")
    VIA("GND", u22[0], 8.6)
    T("GND", [u22, (u22[0], 8.6)], 0.3)
    c21, c61, p75 = P("C2.1"), P("C6.1"), P("U1.75")
    T("3V3", [u25, c21], 0.5)
    T("3V3", [(c21[0] - 0.2, c21[1]), (c21[0] - 0.2, 10.6), (c61[0] + 0.25, 10.6), (c61[0], 10.85), c61], 0.35)
    T("3V3", [c61, p75], 0.25)
    t1 = P("TP1.1")
    T("3V3", [u25, (u25[0], 11.0), (u25[0] + 0.5, t1[1]), t1], 0.3)
    c22, t2 = P("C2.2"), P("TP2.1")
    T("GND", [c22, (c22[0], t2[1] + 0.3), t2], 0.3)
    gnd_via("TP2.1", dx=-1.0, w=0.4)
    gnd_via("C6.2", dy=-0.85)

    # ===== U1 supply: 3V3 ring on the top layer under the package =====
    R, WR = 4.8, 0.6
    T("3V3", rel((-R, -R), (R, -R), (R, R)), WR)          # two halves, so each is a simple outline
    T("3V3", rel((R, R), (-R, R), (-R, -R)), WR)
    T("3V3", [P("U1.46")] + rel((-R, -4.0)), 0.3)
    T("3V3", [P("U1.28")] + rel((-5.0, 5.0), (-R, R)), 0.3)
    T("3V3", [P("U1.100")] + rel((5.6, 6.0), (R, 5.2), (R, R)), 0.3)
    T("3V3", [p75] + rel((6.0, -5.6), (5.2, -R), (R, -R)), 0.3)
    for pin, x in (("21", -4.0), ("22", -4.5), ("11", 1.0), ("6", 3.5)):
        T("3V3", [P("U1." + pin)] + rel((x, R)), 0.25)
    # VSS pins: via to the ground plane just inside the pad row
    def vss(pin, vx, vy, dia=0.5, mid=None):
        v = rel((vx, vy))[0]
        if not any(abs(q["x"] - v[0]) < 1e-3 and abs(q["y"] - v[1]) < 1e-3 for q in b.vias):   # pins 19 and 20 share one
            VIA("GND", v[0], v[1], 0.3, dia)
        T("GND", [P("U1." + pin)] + (rel(mid) if mid else []) + [v], 0.2)
    vss("10", 1.65, 6.0)
    vss("19", -3.25, 5.95, 0.6, (-3.0, 6.35))
    vss("20", -3.25, 5.95, 0.6, (-3.5, 6.35))
    vss("27", -6.0, 5.75, 0.5, (-6.3, 5.5))
    vss("41", -6.0, -1.5)
    vss("47", -5.7, -4.65, 0.5, (-6.1, -4.5))
    vss("99", 6.05, 5.35)

    # ===== south row: UART pads, SWDIO; SE corner: BOOT0; east row: SWCLK, LED =====
    p68, p69, t7, t8 = P("U1.68"), P("U1.69"), P("TP7.1"), P("TP8.1")
    T("UART_RX", [p69, (p69[0], 12.3), (p69[0] - 0.4, 11.9), (p69[0] - 0.4, 11.5), t8], 0.15)
    T("UART_TX", [p68, (p68[0], 12.35), (p68[0] - 0.45, 11.9), (t7[0] + 0.4, 11.9), t7], 0.15)
    p72, t3 = P("U1.72"), P("TP3.1")
    T("SWDIO", [p72, (p72[0], 12.3), (p72[0] + 0.3, 12.0), t3], 0.15)
    p94, r61, t6 = P("U1.94"), P("R6.1"), P("TP6.1")
    xb = U + 6.45                                       # BOOT0 runs south between the ring and the east pad row
    T("BOOT0", [p94, (xb + 0.2, p94[1]), (xb, p94[1] - 0.2), (xb, r61[1] + 0.2), (xb + 0.2, r61[1]), r61], 0.15)
    T("BOOT0", [r61, (r61[0], 12.9), t6], 0.15)
    gnd_via("R6.2", dx=0.85, w=0.25)
    p76, t4 = P("U1.76"), P("TP4.1")
    T("SWCLK", [p76, (U + 8.9, p76[1]), (U + 9.5, p76[1] - 0.6), t4], 0.2)
    p83, r91 = P("U1.83"), P("R9.1")
    T("LED", [p83, r91], 0.2)
    led_a = [p["net"] for p in b.pads("R9") if p["n"] == "2"][0]   # unnamed net between R9 and the LED
    T(led_a, [P("R9.2"), P("LED1.1")], 0.25)
    gnd_via("LED1.2", dx=-0.93, w=0.25, dia=0.5)

    # ===== west row: pin 48 capacitor, pins 46/47, VDDK, BOOT1, VBUS2 sense =====
    p48, c121 = P("U1.48"), P("C12.1")
    xa = U - 6.44                                       # centred in the gap between pad 51 and the west pad ends
    T("P48_VDD18", [p48, (xa - 0.2, p48[1]), (xa, p48[1] - 0.2), (xa, c121[1] + 0.3), c121], 0.25)
    c41, c42, p46, p47 = P("C4.1"), P("C4.2"), P("U1.46"), P("U1.47")
    T("3V3", [p46, c41], 0.25)
    T("GND", [(p47[0], p47[1] - 0.08), (c42[0] + 0.3, p47[1] - 0.08), (c42[0] + 0.1, c42[1] + 0.1)], 0.15)
    gnd_via("C4.2", dy=-0.85)
    c51 = P("C5.1")
    xl = XW - 0.95
    T("3V3", [c51, (xl, c51[1] + 0.55), (xl, c41[1] - 0.25), (xl + 0.25, c41[1]), c41], 0.4)
    c52, c122 = P("C5.2"), P("C12.2")
    gnd_via("C5.2", dx=0.95)
    gnd_via("C12.2", dx=-0.95)
    p40, p41, c101, c102, c111, c112 = P("U1.40"), P("U1.41"), P("C10.1"), P("C10.2"), P("C11.1"), P("C11.2")
    T("VDDK", [p40, c101], 0.25)
    T("VDDK", [c101, c111], 0.3)
    T("GND", [(p41[0], p41[1] - 0.08), (c102[0] + 0.3, p41[1] - 0.08), (c102[0] + 0.1, c102[1] + 0.1)], 0.15)
    T("GND", [c102, c112], 0.3)
    gnd_via("C11.2", dx=-0.45, dy=-0.95)
    T("BOOT1", [P("U1.37"), P("R7.1")], 0.2)
    p33, c171 = P("U1.33"), P("C17.1")
    xdet = XDET
    T("VBUS2_DET", [p33, (xdet + 0.3, p33[1]), (xdet, p33[1] + 0.3)], 0.15)
    T("VBUS2_DET", [c171, (c171[0], p33[1])], 0.15)
    gnd_via("C17.2", dx=-0.1, dy=-0.74, w=0.25, dia=0.5)
    r72 = P("R7.2")
    VIA("GND", r72[0] - 0.26, r72[1] - 0.76, 0.3, 0.5)
    T("GND", [r72, (r72[0] - 0.26, r72[1] - 0.76)], 0.25)

    # ===== SPI flash: bus up the west margin, then into the flash from its south side =====
    u31, u32, u33, u35, u36, u37, u38 = (P(f"U3.{i}") for i in (1, 2, 3, 5, 6, 7, 8))
    x0 = XW - 0.5                                      # first column, just outside C3
    bus = [("CS", "29", x0, FX, 27.6), ("SCK", "30", x0 - 0.3, u36[0], 27.75), ("MISO", "31", x0 - 0.6, FX - 1.27, 27.9),
           ("MOSI", "32", x0 - 0.9, u35[0], 28.05)]
    for k, pin, col, tx, yj in bus:
        p = P("U1." + pin)
        path = [p, (col + 0.2, p[1]), (col, p[1] + 0.2), (col, yj), (tx, yj + tx - col)]
        if k == "SCK":
            path += [u36]
        elif k == "MOSI":
            path += [u35]
        elif k == "CS":
            path += [(FX, FY - 1.0), (u31[0], FY - 1.0), u31]
        else:
            path += [(tx, FY - 0.35), (u32[0], FY - 0.35), u32]
        T(f"FLASH_{k}", path, 0.15)
    c31, c32, p27, p28 = P("C3.1"), P("C3.2"), P("U1.27"), P("U1.28")
    T("3V3", [p28, (c31[0], p28[1])], 0.25)
    T("GND", [(p27[0] - 0.86, p27[1]), (c32[0] + 0.2, c32[1] - 0.1), c32], 0.2)
    T("3V3", [(u37[0], FY - 3.2), (u38[0], FY - 3.2)], 0.4)
    xr = FX + 2.55                                     # 3V3 run round the east end of the flash to WP# and R8
    r81, r82 = P("R8.1"), P("R8.2")
    T("3V3", [(u38[0], FY - 3.2), (xr, FY - 3.2), (xr, FY + 4.85), (r81[0], FY + 4.85), r81], 0.25)
    T("3V3", [r81, (u33[0], r81[1]), u33], 0.25)
    T("FLASH_CS", [u31, r82], 0.2)
    gnd_via("U3.4", dy=1.6)

    # ===== north row: VDDA/VREF, NRST, crystal, pins 10/11, VBAT =====
    c81, c82 = P("C8.1"), P("C8.2")
    p19, p20, p21, p22 = (P(f"U1.{i}") for i in (19, 20, 21, 22))
    T("3V3", [p21, (p21[0], c81[1] - 0.25), c81], 0.25)
    T("3V3", [p22, (p22[0], c81[1] - 0.4), c81], 0.25)
    T("GND", [p20, (p20[0], c82[1] - 0.25), c82], 0.25)
    T("GND", [p19, (p19[0], c82[1] - 0.4), c82], 0.25)
    T("3V3", [c81, (u38[0] + 0.5, c81[1]), (u38[0], c81[1] + 0.3)], 0.3)
    c131, c132 = P("C13.1"), P("C13.2")
    T("3V3", [c131, (u38[0], c131[1])], 0.3)
    T("GND", [c82, c132], 0.25)
    gnd_via("C13.2", dx=-0.2, dy=0.85)
    p14, c141, c142, t5 = P("U1.14"), P("C14.1"), P("C14.2"), P("TP5.1")
    yr = V + 8.78                                       # NRST runs west just above the pad row
    T("NRST", [p14, (p14[0], yr), (c141[0], yr), c141], 0.15)
    T("NRST", [(c141[0] - 0.25, c141[1] + 0.1), (t5[0], c141[1] + 0.1 + c141[0] - 0.25 - t5[0]), t5], 0.15)
    gnd_via("C14.2", dy=0.85)
    p13, y3, c161, c162 = P("U1.13"), P("Y1.3"), P("C16.1"), P("C16.2")
    T("OSC_OUT", [p13, (p13[0], y3[1])], 0.2)
    T("OSC_OUT", [c161, y3], 0.25)
    y2 = P("Y1.2")
    VIA("GND", c162[0] - 0.1, c162[1] + 0.85)
    T("GND", [c162, (c162[0] - 0.1, c162[1] + 0.85), (y2[0] - 0.4, y2[1])], 0.3)
    p12, y1, c151 = P("U1.12"), P("Y1.1"), P("C15.1")
    T("OSC_IN", [p12, (p12[0], y1[1]), y1], 0.2)
    T("OSC_IN", [y1, c151], 0.25)
    gnd_via("C15.2", dy=-0.85)
    p10, p11, c191, c192, y4 = P("U1.10"), P("U1.11"), P("C19.1"), P("C19.2"), P("Y1.4")
    T("3V3", [p11, (p11[0], c191[1] - 0.2), c191], 0.25)
    T("GND", [(p10[0], p10[1] + 0.75), c192], 0.2)
    T("GND", [c192, (c192[0], y4[1] - 0.3)], 0.3)
    gnd_via("Y1.4", dx=1.3)
    p6, c91 = P("U1.6"), P("C9.1")
    T("3V3", [p6, (p6[0], c91[1] - 0.2), c91], 0.25)
    gnd_via("C9.2", dy=0.85)
    p100, c71 = P("U1.100"), P("C7.1")
    T("3V3", [(c71[0], p100[1]), c71], 0.25)
    gnd_via("C7.2", dy=0.85)

    # ===== USB2 pair: east out of pins 92 (D-) / 93 (D+), north along the east edge, north-west, west, into D2 =====
    p92, p93 = P("U1.92"), P("U1.93")
    d21, d23 = P("D2.1"), P("D2.3")
    xm = XP + PITCH
    xe = U + 8.65                                       # just outside the pad row
    yw = p93[1] + 1.1                                   # the pair is wide from here
    T("USB2_DP", [p93, (xe, p93[1]), (XP, p93[1] + XP - xe), (XP, yw)], 0.2)
    T("USB2_DM", [p92, (xe + 0.55, p92[1]), (xm, p92[1] + xm - xe - 0.55), (xm, yw)], 0.2)
    ys = V + 8.9                                        # the north-west diagonal starts here
    c = XP + ys                                         # D+ diagonal: x + y = c
    cm = c + PITCH * r2
    yw2 = YW + PITCH
    T("USB2_DP", [(XP, yw), (XP, ys), (c - YW, YW), (d21[0] + 0.4, YW), (d21[0], YW + 0.4)], WU)
    T("USB2_DM", [(xm, yw), (xm, cm - xm), (cm - yw2, yw2), (d23[0] + 0.4, yw2), (d23[0], yw2 + 0.4)], WU)
    T("USB2_DP", [(d21[0], YW + 0.4), d21], 0.4)
    T("USB2_DM", [(d23[0], yw2 + 0.4), d23], 0.4)
    T("USB2_DP", [d21, P("D2.6")], 0.25)
    T("USB2_DM", [d23, P("D2.4")], 0.25)
    VIA("GND", 0, D2Y)
    T("GND", [P("D2.2"), (0, D2Y)], 0.3)

    # ===== J2 receptacle =====
    b6, a6r, b7, a7r = P("J2.B6"), P("J2.A6"), P("J2.B7"), P("J2.A7")
    d26, d24 = P("D2.6"), P("D2.4")
    yj = YIN - 1.25                                     # D+ joining level below the pad row
    T("USB2_DP", [(b6[0] - 0.05, b6[1]), (b6[0] - 0.05, yj)], 0.15)
    T("USB2_DP", [(a6r[0] + 0.05, a6r[1]), (a6r[0] + 0.05, yj), (b6[0] - 0.05, yj)], 0.15)
    T("USB2_DP", [(b6[0] - 0.05, yj), (d26[0], yj - 0.15), d26], 0.2)
    VIA("USB2_DM", a7r[0], YIN - 0.55, 0.3, 0.5)
    T("USB2_DM", [a7r, (a7r[0], YIN - 0.55)], 0.2)
    VIA("USB2_DM", 0.85, YIN - 1.0, 0.3, 0.5)
    T("USB2_DM", [(a7r[0], YIN - 0.55), (a7r[0] + 0.45, YIN - 1.0), (0.85, YIN - 1.0)], 0.2, BOT)
    T("USB2_DM", [b7, (b7[0], YIN - 0.5), (0.85, YIN - 1.0), (d24[0], YIN - 1.5), d24], 0.2)
    a5r, r21, d41 = P("J2.A5"), P("R2.1"), P("D4.1")
    T("USB2_CC1", [a5r, (a5r[0], YIN - 0.35), (a5r[0] + (YIN - 0.35 - r21[1]), r21[1]), r21, d41], 0.2)
    b5, d51, r31 = P("J2.B5"), P("D5.1"), P("R3.1")
    xc = b5[0] - 0.05                                   # CC2 leaves the pad, then steps left to clear the D2 body
    T("USB2_CC2", [(xc, b5[1]), (xc, YIN - 1.95), (d51[0], YIN - 1.95 - (xc - d51[0])), d51, r31], 0.15)
    T("VBUS2", [P("J2.B4A9"), P("R4.1")], 0.25)
    d52, r32 = P("D5.2"), P("R3.2")
    VIA("GND", d52[0] - 0.25, YIN - 3.25)
    T("GND", [d52, (d52[0] - 0.25, YIN - 3.25), r32], 0.25)
    gnd_via("R2.2", dy=-0.85, w=0.25)
    gnd_via("D4.2", dy=-0.85, w=0.25)
    for sgn in (-1, 1):
        g = P("J2.A1B12" if sgn > 0 else "J2.B1A12")
        gv = (3.2, YIN - 0.75) if sgn > 0 else (-3.3, YIN - 0.6)     # west one sits clear of R5 and R4
        VIA("GND", *gv)
        T("GND", [g, gv], 0.4)
    # VBUS2 sense: divider at the receptacle, long high-impedance run up the west edge from C17 / pin 33
    r42, r51, r52 = P("R4.2"), P("R5.1"), P("R5.2")
    yd = r51[1] + 0.2                                   # passes north of the flash and its 3V3 loop
    T("VBUS2_DET", [(xdet, p33[1] + 0.3), (xdet, yd - 0.4), (xdet + 0.4, yd), (r51[0] - 0.3, yd), r51], 0.15)
    yc = r51[1] - 0.55                                  # then south of R5's ground pad to R4
    T("VBUS2_DET", [r51, (r51[0] + 0.2, yc), (r42[0] - 0.15, yc), (r42[0], yc + 0.15), r42], 0.15)
    T("GND", [r52, (-3.3, YIN - 0.6)], 0.25)

    # ===== exposed test pads =====
    for ref, (x, y, d) in TPS.items():
        b.disc(b.pads(ref)[0]["net"], x, y, d)


def stitch(pitch=1.0, spacing=2.2):
    """Ground stitching vias tying the top and bottom pours: fence the USB pairs first, then the board edge, then fill."""
    from shapely.geometry import Point, box
    from shapely.ops import unary_union
    from shapely.prepared import prep
    r, gap = 0.3, 0.3
    keep = []
    for net, ly, shape, label in b.copper():
        is_pad = "." in label and not label.startswith(("track", "via", "disc"))
        if net != "GND" or is_pad or label.startswith("via"):
            keep.append(shape.buffer(r + (gap if net != "GND" else 0.15)))
    keep.append(box(-4.9, J2Y - 2.4, 4.9, L))                    # under the receptacle body
    x, y, _ = b.place["Y1"]
    keep.append(box(x - 1.3, y - 0.9, x + 1.3, y + 0.9))         # under the crystal
    blocked = prep(unary_union(keep))
    usb = unary_union([s for n, ly, s, lab in b.copper() if n.startswith("USB") and lab.startswith("track") and ly == TOP])
    inner = box(-W_BOARD / 2 + 0.8, 0.8, W_BOARD / 2 - 0.8, L - 0.8)
    cands = []
    nx, ny = int(W_BOARD / pitch * 2), int(L / pitch * 2)
    for i in range(1, nx):
        for j in range(1, ny):
            px, py = -W_BOARD / 2 + i * pitch / 2, j * pitch / 2
            pt = Point(px, py)
            if not inner.contains(pt) or blocked.contains(pt):
                continue
            d_usb = pt.distance(usb)
            d_edge = min(px + W_BOARD / 2, W_BOARD / 2 - px, py, L - py)
            rank = 0 if d_usb < 1.2 else (1 if d_edge < 1.3 else 2)
            cands.append((rank, d_usb if rank == 0 else d_edge, px, py))
    chosen = [(v["x"], v["y"]) for v in b.vias if v["net"] == "GND"]
    n0 = len(chosen)
    for rank, _, px, py in sorted(cands):
        need = 1.5 if rank == 0 else spacing
        if all((px - cx) ** 2 + (py - cy) ** 2 >= need ** 2 for cx, cy in chosen):
            chosen.append((px, py))
            b.via("GND", px, py)
    return len(chosen) - n0


BOTTOM_TEXT_MIRROR = False   # host 4.1.78: checked against the exported bottom-silk Gerber (see docs/pcb/DESIGN_NOTES.md)


def silk():
    """Silkscreen: part designators are hidden; test pads get a digit, the bottom carries the legend."""
    from shapely.geometry import box
    from shapely.ops import unary_union
    def text(layer, x, y, s, size=0.9, rot=0, align=5, mirror=False):
        b.texts.append(dict(layer=layer, x=x, y=y, text=s, size=size, stroke=0.15, rot=rot, align=align, mirror=mirror))
    solid = unary_union([sh.buffer(0.2) for net, ly, sh, lab in b.copper()
                         if ly == TOP and (lab.startswith("disc") or ("." in lab and not lab.startswith(("track", "via"))))])
    taken = []
    board = box(-W_BOARD / 2 + 0.3, 0.3, W_BOARD / 2 - 0.3, L - 0.3)
    for ref, (x, y, d) in TPS.items():
        w, h = 0.75, 1.05
        import math
        near = [(d / 2 + 0.65, 0), (-d / 2 - 0.65, 0), (0, d / 2 + 0.8), (0, -d / 2 - 0.8), (d / 2 + 0.5, d / 2 + 0.6), (-d / 2 - 0.5, d / 2 + 0.6),
                (d / 2 + 0.5, -d / 2 - 0.6), (-d / 2 - 0.5, -d / 2 - 0.6)]
        ring = [((d / 2 + k) * math.cos(math.radians(a_)), (d / 2 + k) * math.sin(math.radians(a_))) for k in (0.9, 1.1, 1.4) for a_ in range(0, 360, 30)]
        for dx, dy in near + ring:
            bx = box(x + dx - w / 2, y + dy - h / 2, x + dx + w / 2, y + dy + h / 2)
            if not bx.intersects(solid) and all(not bx.intersects(t) for t in taken) and board.contains(bx):
                taken.append(bx)
                text(3, x + dx, y + dy, ref[2:], 1.15)
                break
        else:
            print(f"silk: no room for a digit next to {ref}; it is identified by the bottom legend only")
    for s_, x, y in SILK_TOP:
        bx = box(x - len(s_) * 0.38 - 0.1, y - 0.6, x + len(s_) * 0.38 + 0.1, y + 0.6)        # 1.2 size: about 0.76 mm per character
        assert board.contains(bx) and not bx.intersects(solid), f"top silk text {s_} leaves the board or lies on a pad"
        text(3, x, y, s_, 1.2)                                                               # 0.9 size came out 0.64 mm high in the Gerber
    lines = ["WiredKVM-V407-Stick", "L100 R1  2026-11", "TP1 3V3    TP2 GND", "TP3 SWDIO  TP4 SWCLK", "TP5 NRST   TP6 BOOT0", "TP7 TX     TP8 RX", "USB1 HOST  -  USB2 TARGET"]
    for i, s_ in enumerate(lines):
        assert len(s_) * 0.76 < W_BOARD - 1.6, s_
        text(4, 0, 32.6 - i * 2.1, s_, 1.2, mirror=BOTTOM_TEXT_MIRROR)


SILK_TOP = [("HOST", -7.0, 5.0), ("WiredKVM", -7.0, 8.9), ("L100 R1", -7.0, 7.3), ("TARGET", 6.6, 37.6)]

# Top ground pour: keep copper out from under the plug's terminal tails (between the board edge and the J1 pad row).
h = W_BOARD / 2
b.top_pour = [(-h, 0), (-3.25, 0), (-3.25, 1.25), (3.25, 1.25), (3.25, 0), (h, 0), (h, L), (-h, L)]

# Package bodies (half width, half height at rotation 0, worst-case tolerance) for the pad-to-body check.
b.bodies = {"U1": (7.1, 7.1), "U3": (2.5, 2.0), "U2": (1.5, 0.9), "D1": (1.5, 0.85), "D2": (1.5, 0.85), "Y1": (1.65, 1.3),
            "D6": (1.45, 0.95), "F1": (0.85, 0.45), "LED1": (0.85, 0.45)}

route()
N_STITCH = stitch()
silk()

if __name__ == "__main__":
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "evidence/pcb-preview")
    out.mkdir(parents=True, exist_ok=True)
    print("unplaced:", sorted(set(FP) - set(b.place)), "stitching vias:", N_STITCH, "tracks:", len(b.tracks), "vias:", len(b.vias))
    # total copper per net; USB2 includes both receptacle branches, so the pin-to-pad paths are about 2-3 mm shorter
    print("copper length USB1 D+/D- %.2f / %.2f mm   USB2 D+/D- %.2f / %.2f mm" % tuple(b.net_length(n) for n in ("USB1_DP", "USB1_DM", "USB2_DP", "USB2_DM")))
    b.check()
    b.render(out / "board.png", region=(-11.5, -0.5, 11.5, L + 0.5), scale=30)
    zones = {"z1": (-11.2, -0.3, 11.2, 13.0), "z2": (-11.2, 11.5, 11.2, 24.5), "z3": (-11.2, 19.5, 11.2, 32.5),
             "z4": (-11.2, 27.5, 11.2, 40.5), "z5": (-11.2, 35.0, 11.2, L + 0.3)}
    for name, reg in zones.items():
        b.render(out / f"{name}.png", region=reg, scale=80)
    json.dump(b.export(), open(pathlib.Path(__file__).parent / "pcb_plan.json", "w"))
