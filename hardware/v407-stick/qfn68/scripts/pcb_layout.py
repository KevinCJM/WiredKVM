#!/usr/bin/env python3
"""Placement and routing data for WiredKVM-V407-Stick.

Run: .venv/bin/python scripts/pcb_layout.py [preview-dir]
Writes scripts/pcb_plan.json (mil) for the EDA apply script and PNG previews.
All routing is on the top layer except three short bottom jumpers, so the bottom layer stays a ground plane.
"""
import json, sys, pathlib
from pcbtool import Board, TOP, BOT, FP

W_BOARD, L = 20.0, 44.0
b = Board(W_BOARD, L)
P = b.P

# Schematic revision used: VBUS2 sense on PC4 (pin 23), LED on PD2 (pin 57), one VBUS2 pad of J2 in use,
# D1 pin 5 and D2 pin 5 left open.

# ---------- placement (x, y, rot) ----------
U, V = -1.3, 16.5                  # U1 centre
J2Y = L + 0.5 - 5.094              # receptacle front protrudes 0.5 mm past the board edge
YIN = J2Y - 3.125                  # inner end of the J2 pad row
D2Y = YIN - 3.6
FX, FY = U - 5.55, 26.15           # flash centre
XP = U + 7.75                      # USB2 D+ vertical run; D- runs at XP + PITCH
WU, PITCH = 0.45, 0.65             # USB pair main width and centre pitch: 0.20 mm gap, about 90-100 ohm on 1.0 mm FR-4
                                   # with pour beside and solder mask (field solver; 0.60/0.16 came out at 78-95 ohm)

b.put("J1", 0, 1.22, 0)            # footprint draws the board edge 1.22 mm below its origin
b.put("D1", -2.7, 5.6, 180)
b.put("R1", -0.6, 5.3, 90)
b.put("D3", 0.6, 5.4, 90)
b.put("C18", 2.75, 3.2, 270)
b.put("F1", 4.5, 3.7, 0)
b.put("D6", 7.4, 5.7, 270)
b.put("U2", 4.7, 8.6, 90)
b.put("C1", 7.8, 9.4, 90)
b.put("C2", 1.6, 7.65, 180)

b.put("U1", U, V, 270)
b.put("C7", U - 3.6, V - 5.3, 270)      # pin 35
b.put("C5", U - 5.4, V - 5.2, 270)      # pin 35 bulk
b.put("C12", U - 2.65, V - 6.8, 270)    # pin 36
b.put("C8", U + 3.2, V - 5.3, 270)      # pin 51
b.put("C6", U - 4.6, V + 4.6, 0)        # pin 18
b.put("R7", U - 5.3, V - 0.4, 180)      # BOOT1
b.put("C10", U - 5.2, V - 1.6, 180)     # VDDK
b.put("C11", U - 5.6, V - 3.0, 180)     # VDDK bulk
b.put("C9", U + 5.2, V + 3.2, 0)        # pin 68
b.put("C3", U + 4.5, V + 4.85, 0)       # pin 1 VBAT
b.put("C4", U - 1.45, V + 5.25, 90)     # pin 13 VDDA
b.put("C14", U - 0.05, V + 4.75, 180)   # NRST
b.put("Y1", U + 1.7, V + 8.1, 180)
b.put("C16", U - 1.0, V + 7.25, 180)
b.put("C15", U + 4.1, V + 8.1, 270)
b.put("R6", U + 6.5, V + 1.75, 0)       # BOOT0
b.put("R9", U + 5.3, V - 1.2, 0)
b.put("LED1", U + 7.5, V - 1.2, 180)

b.put("U3", FX, FY, 180)
b.put("C13", U - 2.3, FY - 2.85, 90)
b.put("R8", FX + 1.47, FY + 4.3, 0)

b.put("J2", 0, J2Y, 180)
b.put("D2", 0, D2Y, 0)
b.put("R4", -2.45, YIN - 1.05, 270)
b.put("D5", -2.8, YIN - 2.5, 180)
b.put("R3", -2.48, YIN - 3.5, 180)
b.put("R5", -5.05, YIN - 3.15, 180)
b.put("C17", -5.05, YIN - 4.05, 180)
b.put("R2", 2.3, YIN - 2.0, 270)
b.put("D4", 3.6, YIN - 2.3, 270)

TPS = {  # ref: (x, y, exposed-disc diameter)
    "TP1": (3.9, 10.9, 1.2), "TP2": (6.3, 11.6, 1.2), "TP3": (0.75, 9.2, 1.2), "TP4": (4.9, V - 3.2, 1.2),
    "TP5": (U - 0.42, V + 6.0, 0.9), "TP6": (U + 5.0, V + 1.75, 1.0), "TP7": (U - 1.7, V - 5.1, 0.9), "TP8": (U - 0.2, V - 5.4, 0.9),
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
    # pair from D1 up to U1 pins 46/47: wide diagonal, then a narrow neck into the 0.4 mm pitch pins
    p46, p47 = P("U1.46"), P("U1.47")
    xdp, xdm = p47[0] + 0.175, p46[0] - 0.175
    ya = 8.4
    cdp1 = d11[0] - ya                                  # D+ diagonal: x - y = cdp1
    cdm1 = cdp1 - PITCH * 2 ** 0.5
    T("USB1_DP", [d11, (d11[0], ya), (xdp, xdp - cdp1)], WU)
    T("USB1_DP", [(xdp, xdp - cdp1), (p47[0], xdp - cdp1 + 0.175), p47], 0.2)
    T("USB1_DM", [d13, (d13[0], d13[0] - cdm1), (xdm, xdm - cdm1)], WU)
    T("USB1_DM", [(xdm, xdm - cdm1), (p46[0], xdm - cdm1 + 0.175), p46], 0.2)
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

    # ===== power chain =====
    T("VBUS1_F", [P("F1.2"), (P("D6.2")[0], P("F1.2")[1])], 0.5)
    d61, u21, u23, c11 = P("D6.1"), P("U2.1"), P("U2.3"), P("C1.1")
    T("VSYS", [d61, (d61[0] - 0.35, u21[1]), u21], 0.4)
    T("VSYS", [(6.75, u21[1]), (6.75, u23[1]), u23], 0.25)
    T("VSYS", [d61, (c11[0], d61[1] + 0.5), c11], 0.4)
    u22 = P("U2.2")
    VIA("GND", 4.7, u22[1])
    T("GND", [u22, (4.7, u22[1])], 0.3)
    gnd_via("C1.2", dy=0.95, w=0.4)
    u25, c21, c81, p51 = P("U2.5"), P("C2.1"), P("C8.1"), P("U1.51")
    xt = 2.55                                           # 3V3 trunk from the regulator up to U1 pin 51
    vb = (U + 4.2, V - 5.2)                             # via B: top trunk -> bottom trunk under U1
    T("3V3", [u25, c21], 0.5)
    T("3V3", [(xt, u25[1]), (xt, 10.0), (vb[0], 10.0 + vb[0] - xt), vb, (vb[0] - 0.32, c81[1]), c81], 0.3)
    T("3V3", [c81, p51], 0.2)
    T("3V3", [(vb[0], 10.9), P("TP1.1")], 0.3)
    VIA("3V3", *vb)
    r12 = P("R1.2")
    d32 = P("D3.2")
    T("GND", [d32, (d32[0] - 0.43, r12[1] + 0.85), (r12[0], r12[1] + 0.85)], 0.25)
    gnd_via("C2.2", dx=-1.0)
    gnd_via("C8.2", dy=-0.85)
    gnd_via("R1.2", dy=0.85, w=0.25)

    # ===== U1 supply: 3V3 trunk on the BOTTOM layer under the package =====
    # The chip's exposed ground pad may be up to 6.2 mm wide (datasheet: 5.6 +0.6/-0.3), so no top copper is allowed
    # between the centre pad and the pin row. The trunk is an X: it enters at the SE corner and leaves at the SW, NW
    # and NE corners, the two diagonals crossing under the pad centre. That cuts the bottom ground under the chip into
    # four sectors (N, S, E, W), each open to the plane outside its own pin row and each with two centre-pad vias, so
    # every decoupling capacitor and both USB pairs return to the chip's ground without going round a slot.
    def rel(*pts):
        return [(U + x, V + y) for x, y in pts]
    WT = 0.4
    va, vc1, vc2, vd = (U - 4.41, V - 4.78), (U - 2.3, V + 4.85), (U - 4.75, V + 5.45), (U + 4.5, V + 4.02)
    vb2 = (vb[0], vb[1] + 0.65)                                                                      # second feed via beside vb
    T("3V3", [vb, vb2], 0.3)
    T("3V3", [vb] + rel((4.2, -4.2), (-4.35, 4.35), (-4.35, 5.15)) + [vc2], WT, BOT)                 # SE entry -> centre -> NW exit (pin 18, flash)
    T("3V3", [va] + rel((-4.41, -4.41), (4.02, 4.02)) + [vd], WT, BOT)                               # SW exit (pin 35) <- centre -> NE exit
    T("3V3", rel((-2.3, 2.3)) + [vc1], WT, BOT)                                                      # stub -> pin 13
    for v in (va, vc1, vc2, vd, vb2):
        VIA("3V3", *v)
    T("GND", [P("U1.12"), (U - 1.2, V + 2.6)], 0.2)
    for dx, dy in ((0.9, 2.3), (-0.9, 2.3), (0.9, -2.3), (-0.9, -2.3), (2.3, 0.9), (2.3, -0.9), (-2.3, 0.9), (-2.3, -0.9)):
        VIA("GND", U + dx, V + dy)                                                                   # two per sector, near the pin rows

    # ===== U1 bottom edge: pins 35/36 capacitors, UART pads, SWD =====
    p35, p36 = P("U1.35"), P("U1.36")
    c71, c51, c121 = P("C7.1"), P("C5.1"), P("C12.1")
    T("3V3", [p35, (p35[0], c71[1] + 0.3), (c71[0], c71[1])], 0.2)
    T("3V3", [(c71[0], c71[1] + 0.1), (c51[0], c71[1] + 0.1)], 0.3)
    T("P36_VDD18", [p36, (p36[0], c121[1] + 0.5), c121], 0.2)
    c72 = P("C7.2")
    VIA("GND", c72[0] - 0.5, c72[1] - 0.8)
    T("GND", [c72, (c72[0] - 0.5, c72[1] - 0.8)], 0.3)
    gnd_via("C5.2", dy=-1.0)
    gnd_via("C12.2", dx=-1.0)
    p44, p45 = P("U1.44"), P("U1.45")
    t7, t8 = P("TP7.1"), P("TP8.1")
    T("UART_TX", [p44, (p44[0], V - 4.3), (p44[0] - 0.2, V - 4.5), (t7[0], V - 4.5), t7], 0.2)
    T("UART_RX", [p45, (p45[0], V - 4.65), (p45[0] - 0.2, V - 4.85), (t8[0], V - 4.85), t8], 0.2)
    p48, t3 = P("U1.48"), P("TP3.1")
    T("SWDIO", [p48, (p48[0], 11.9), (1.15, 11.9 - (1.15 - p48[0])), (1.15, t3[1] + 0.4 + 1.15 - t3[0]), (t3[0], t3[1] + 0.4), t3], 0.2)
    T("SWCLK", [P("U1.52"), P("TP4.1")], 0.2)
    gnd_via("TP2.1", dx=1.1, w=0.4)
    # LED on PD2 (pin 57)
    p57, r91 = P("U1.57"), P("R9.1")
    T("LED", [p57, r91], 0.2)
    led_a = [p["net"] for p in b.pads("R9") if p["n"] == "2"][0]   # unnamed net between R9 and the LED
    T(led_a, [P("R9.2"), P("LED1.1")], 0.25)
    gnd_via("LED1.2", dx=0.95)

    # ===== U1 left side: VDDK, BOOT1, pin 18, SPI flash =====
    p30, c101, c111 = P("U1.30"), P("C10.1"), P("C11.1")
    T("VDDK", [p30, c101], 0.2)
    T("VDDK", [(c101[0] - 0.05, c101[1]), (c101[0] - 0.05, c111[1])], 0.3)
    for pad in ("C10.2", "C11.2", "R7.2"):
        gnd_via(pad, dx=-0.95)
    T("BOOT1", [P("U1.27"), P("R7.1")], 0.2)
    p18, c61, c131 = P("U1.18"), P("C6.1"), P("C13.1")
    u37, u38 = P("U3.7"), P("U3.8")
    T("3V3", [p18, (c61[0], p18[1]), c61, (c61[0], vc2[1] - 0.45), vc2, (u37[0], vc2[1] + 0.25), (u37[0], FY - 3.2)], 0.25)
    T("3V3", [(u37[0], FY - 3.2), (u38[0], FY - 3.2)], 0.4)
    xr = FX + 2.62                                     # 3V3 run round the right end of the flash to WP# and R8
    r81, r82, u33, u31 = P("R8.1"), P("R8.2"), P("U3.3"), P("U3.1")
    T("3V3", [(u38[0], FY - 3.2), (xr, FY - 3.2), (xr, FY + 5.05), (r81[0], FY + 5.05), r81], 0.25)
    T("3V3", [(xr, FY - 3.2), (c131[0], FY - 3.2)], 0.25)
    T("3V3", [r81, (u33[0], r81[1]), u33], 0.25)
    T("FLASH_CS", [u31, r82], 0.2)
    c62 = P("C6.2")
    VIA("GND", U - 3.3, V + 4.85)
    T("GND", [c62, (U - 3.55, V + 4.85), (U - 3.3, V + 4.85)], 0.3)
    gnd_via("C13.2", dy=0.85)
    gnd_via("U3.4", dy=1.6)
    # SPI: leave the pins westwards, turn north in the column of the flash pin (or pad gap) each one enters
    cols = {"CS": ("19", FX), "SCK": ("20", P("U3.6")[0]), "MISO": ("21", FX - 1.27), "MOSI": ("22", P("U3.5")[0])}
    for k, (pin, x1) in cols.items():
        p = P(f"U1.{pin}")
        path = [p, (x1 + 0.3, p[1]), (x1, p[1] + 0.3)]
        if k == "SCK":
            path += [P("U3.6")]
        elif k == "MOSI":
            path += [P("U3.5")]
        elif k == "CS":
            path += [(FX, FY - 1.0), (u31[0], FY - 1.0), u31]
        else:
            u32 = P("U3.2")
            path += [(x1, FY - 0.35), (u32[0], FY - 0.35), u32]
        T(f"FLASH_{k}", path, 0.2)

    # ===== U1 top edge: VDDA, NRST, crystal, VBAT, VBUS2 sense on PA0 =====
    p13, c41, c42 = P("U1.13"), P("C4.1"), P("C4.2")
    T("3V3", [p13, (p13[0], c41[1])], 0.2)
    T("3V3", [vc1, c41], 0.3)
    VIA("GND", c42[0], c42[1] + 0.78)
    T("GND", [P("C16.2"), (c42[0], c42[1] + 0.78), c42], 0.3)
    p7, c141, t5 = P("U1.7"), P("C14.1"), P("TP5.1")
    T("NRST", [p7, (p7[0], c141[1] - 0.25), (p7[0] - 0.25, c141[1]), c141], 0.2)
    T("NRST", [c141, (c141[0], t5[1] - 0.4), (t5[0] + 0.3, t5[1]), t5], 0.2)
    c142 = P("C14.2")
    T("GND", [c142, (c142[0] - 0.4, c142[1] + 0.4), (c42[0] + 0.25, c42[1])], 0.25)
    p6, y3 = P("U1.6"), P("Y1.3")
    T("OSC_OUT", [p6, (p6[0], y3[1])], 0.2)
    T("OSC_OUT", [P("C16.1"), y3], 0.25)
    p5, y1 = P("U1.5"), P("Y1.1")
    xg = b.place["Y1"][0]
    T("OSC_IN", [p5, (p5[0], V + 4.5), (xg, V + 4.5 + abs(xg - p5[0])), (xg, y1[1]), y1], 0.2)
    T("OSC_IN", [(y1[0] + 0.5, P("C15.1")[1]), P("C15.1")], 0.25)
    gnd_via("C15.2", dy=-0.85)
    gnd_via("Y1.2", dy=1.15)
    T("GND", [P("Y1.4"), P("C15.2")], 0.3)
    p1, c31 = P("U1.1"), P("C3.1")
    T("3V3", [p1, (p1[0], c31[1] - 0.3), (p1[0] + 0.3, c31[1]), c31], 0.2)
    gnd_via("C3.2", dx=0.9)
    T("3V3", [P("U1.68"), P("C9.1")], 0.2)
    T("3V3", [P("C9.1"), vd, c31], 0.3)
    gnd_via("C9.2", dx=0.9)
    p23 = P("U1.23")
    r51, c171, r42 = P("R5.1"), P("C17.1"), P("R4.2")
    xw, ye = U - 8.15, c171[1] - 0.63
    T("VBUS2_DET", [p23, (xw + 0.3, p23[1]), (xw, p23[1] + 0.3), (xw, ye - 0.3), (xw + 0.3, ye), (c171[0], ye), c171, r51], 0.15)
    T("VBUS2_DET", [r51, (r51[0], r42[1] - 0.3), (r51[0] + 0.3, r42[1]), r42], 0.15)
    gnd_via("R5.2", dx=-0.95, w=0.25)
    gnd_via("C17.2", dx=-0.95, w=0.25)

    # ===== U1 right side: BOOT0 parts, USB2 pair =====
    p63, t6, r61 = P("U1.63"), P("TP6.1"), P("R6.1")
    T("BOOT0", [p63, (t6[0] - 0.3, p63[1]), t6, r61], 0.2)
    gnd_via("R6.2", dy=0.85, w=0.25)
    p61, p62 = P("U1.61"), P("U1.62")                  # D- (lower), D+ (upper)
    d21, d23 = P("D2.1"), P("D2.3")
    xn = U + 7.3                                        # end of the necked east run
    # neck: 0.2 mm tracks, 0.4 mm pitch, east then a 45-degree corner to north
    k = 0.4 * (2 ** 0.5 - 1)                            # corner offset that keeps the pitch through the bend
    yn = p62[1] + (XP - xn)                             # D+ reaches its column here
    T("USB2_DP", [p62, (xn, p62[1]), (XP, yn), (XP, yn + 0.9)], 0.2)
    T("USB2_DM", [p61, (xn + k, p61[1]), (XP + 0.4, yn - k), (XP + 0.4, yn + 0.2), (XP + PITCH, yn + 0.2 + PITCH - 0.4), (XP + PITCH, yn + 0.9)], 0.2)
    # main run: wide, north then north-west to D2
    cdp = d21[0] + (d21[1] - 1.15)                      # D+ diagonal: x + y = cdp
    cdm = cdp + PITCH * 2 ** 0.5
    xm = XP + PITCH
    T("USB2_DP", [(XP, yn + 0.9), (XP, cdp - XP), (d21[0], cdp - d21[0])], WU)
    T("USB2_DM", [(xm, yn + 0.9), (xm, cdm - xm), (d23[0], cdm - d23[0])], WU)
    T("USB2_DP", [(d21[0], cdp - d21[0]), d21], 0.4)
    T("USB2_DM", [(d23[0], cdm - d23[0]), d23], 0.4)
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
    VIA("USB2_DM", a7r[0], YIN - 0.55, 0.3, 0.6)
    T("USB2_DM", [a7r, (a7r[0], YIN - 0.55)], 0.2)
    VIA("USB2_DM", 0.85, YIN - 1.0, 0.3, 0.6)
    T("USB2_DM", [(a7r[0], YIN - 0.55), (a7r[0] + 0.45, YIN - 1.0), (0.85, YIN - 1.0)], 0.2, BOT)
    T("USB2_DM", [b7, (b7[0], YIN - 0.5), (0.85, YIN - 1.0), (d24[0], YIN - 1.5), d24], 0.2)
    a5r, r21, d41 = P("J2.A5"), P("R2.1"), P("D4.1")
    T("USB2_CC1", [a5r, (a5r[0], YIN - 0.35), (a5r[0] + (YIN - 0.35 - r21[1]), r21[1]), r21, d41], 0.2)
    b5, d51, r31 = P("J2.B5"), P("D5.1"), P("R3.1")
    xc = b5[0] - 0.05                                   # CC2 leaves the pad, then steps left to clear the D2 body
    T("USB2_CC2", [(xc, b5[1]), (xc, YIN - 1.95), (d51[0], YIN - 1.95 - (xc - d51[0])), d51, r31], 0.15)
    T("VBUS2", [P("J2.B4A9"), P("R4.1")], 0.25)
    d52, r32 = P("D5.2"), P("R3.2")
    VIA("GND", d52[0] - 0.2, YIN - 3.28)
    T("GND", [d52, (d52[0] - 0.2, YIN - 3.28), r32], 0.25)
    gnd_via("R2.2", dy=-0.85, w=0.25)
    gnd_via("D4.2", dy=-0.85, w=0.25)
    for sgn in (-1, 1):
        g = P("J2.A1B12" if sgn > 0 else "J2.B1A12")
        VIA("GND", sgn * 3.3, YIN - 0.6)
        T("GND", [g, (sgn * 3.3, YIN - 0.6)], 0.4)

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
            keep.append(shape.buffer(r + (gap if net != "GND" else 0.22)))
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
    """Silkscreen: part designators are hidden (no room on a 20 mm board); test pads get a digit, the bottom carries the legend."""
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
    for s_, x, y in (("WiredKVM", 6.3, 31.3), ("V407 R1", 6.3, 29.7), ("TARGET", 7.0, 35.0), ("HOST", -7.2, 5.6)):
        bx = box(x - len(s_) * 0.38 - 0.1, y - 0.6, x + len(s_) * 0.38 + 0.1, y + 0.6)        # 1.2 size: about 0.76 mm per character
        assert board.contains(bx) and not bx.intersects(solid), f"top silk text {s_} leaves the board or lies on a pad"
        text(3, x, y, s_, 1.2)
    lines = ["WiredKVM-V407-Stick R1", "2026-11", "TP1 3V3   TP2 GND", "TP3 SWDIO TP4 SWCLK", "TP5 NRST  TP6 BOOT0", "TP7 TX    TP8 RX", "USB1 HOST - USB2 TARGET"]
    for i, s_ in enumerate(lines):
        assert len(s_) * 0.76 < W_BOARD - 1.6, s_
        text(4, 0, 30.6 - i * 2.1, s_, 1.2, mirror=BOTTOM_TEXT_MIRROR)


# Top ground pour: keep copper out from under the plug's terminal tails (between the board edge and the J1 pad row).
h = W_BOARD / 2
b.top_pour = [(-h, 0), (-3.25, 0), (-3.25, 1.25), (3.25, 1.25), (3.25, 0), (h, 0), (h, L), (-h, L)]

# Package bodies (half width, half height at rotation 0, worst-case tolerance) for the pad-to-body check.
b.bodies = {"U1": (4.05, 4.05), "U3": (2.5, 2.0), "U2": (1.5, 0.9), "D1": (1.5, 0.85), "D2": (1.5, 0.85), "Y1": (1.65, 1.3),
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
    b.render(out / "board.png", region=(-10.5, -0.5, 10.5, L + 0.5), scale=30)
    for name, reg in {"z1": (-10.2, -0.3, 10.2, 12.5), "z2": (-10.2, 9.5, 10.2, 22.5), "z3": (-10.2, 19.5, 10.2, 32.5), "z4": (-10.2, 29.5, 10.2, 44.3)}.items():
        b.render(out / f"{name}.png", region=reg, scale=80)
    json.dump(b.export(), open(pathlib.Path(__file__).parent / "pcb_plan.json", "w"))
