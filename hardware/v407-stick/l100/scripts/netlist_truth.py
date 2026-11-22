#!/usr/bin/env python3
"""Intended netlist for WiredKVM-V407-Stick-L100 (CH32V407VET6, LQFP100), written independently of the drawing plan, and a checker
against the netlist exported by 嘉立创EDA (evidence/schematic.net.json)."""
import json, pathlib, sys

W = pathlib.Path(__file__).resolve().parent.parent
caps_gnd = [f"C{i}.2" for i in range(1, 20)]
# U1 pin numbers are the LQFP100 column of datasheet table 2-1 (CH32V407VET6), not taken from the drawing script.
TRUTH = {
    "3V3": "U1.6 U1.11 U1.21 U1.22 U1.28 U1.46 U1.75 U1.100 U2.5 U3.3 U3.7 U3.8 R8.1 C2.1 C3.1 C4.1 C5.1 C6.1 C7.1 C8.1 "
           "C9.1 C13.1 C19.1 TP1.1",
    "GND": "U1.10 U1.19 U1.20 U1.27 U1.41 U1.47 U1.99 U2.2 U3.4 J1.A1 J1.A12 J1.B12 J1.0 J1.1 J2.A1B12 J2.B1A12 J2.1 J2.2 "
           "J2.3 J2.4 D1.2 D2.2 D3.2 D4.2 D5.2 Y1.2 Y1.4 R1.2 R2.2 R3.2 R5.2 R6.2 R7.2 LED1.2 TP2.1 " + " ".join(caps_gnd),
    "VBUS1": "J1.A4 J1.B9 F1.1 C18.1",
    "VBUS1_F": "F1.2 D6.2",
    "VSYS": "D6.1 C1.1 U2.1 U2.3",
    "VBUS2": "J2.B4A9 R4.1",
    "VBUS2_DET": "R4.2 R5.1 C17.1 U1.33",          # PC4 / ADC14
    "USB1_CC": "J1.A5 R1.1 D3.1",
    "USB1_DP": "J1.A6 D1.1 D1.6 U1.71",            # PA12
    "USB1_DM": "J1.A7 D1.3 D1.4 U1.70",            # PA11
    "USB2_CC1": "J2.A5 R2.1 D4.1",
    "USB2_CC2": "J2.B5 R3.1 D5.1",
    "USB2_DP": "J2.A6 J2.B6 D2.1 D2.6 U1.93",      # PB7
    "USB2_DM": "J2.A7 J2.B7 D2.3 D2.4 U1.92",      # PB6
    "OSC_IN": "U1.12 Y1.1 C15.1",
    "OSC_OUT": "U1.13 Y1.3 C16.1",
    "NRST": "U1.14 C14.1 TP5.1",
    "BOOT0": "U1.94 R6.1 TP6.1",                   # PE12
    "BOOT1": "U1.37 R7.1",                         # PB2
    "VDDK": "U1.40 C10.1 C11.1",
    "P48_VDD18": "U1.48 C12.1",                    # PE7 on V407VET6, VDD18 on V467VET6
    "FLASH_CS": "U1.29 U3.1 R8.2",                 # PA4..PA7 = SPI1
    "FLASH_SCK": "U1.30 U3.6",
    "FLASH_MISO": "U1.31 U3.2",
    "FLASH_MOSI": "U1.32 U3.5",
    "SWDIO": "U1.72 TP3.1",                        # PA13
    "SWCLK": "U1.76 TP4.1",                        # PA14
    "UART_TX": "U1.68 TP7.1",                      # PA9
    "UART_RX": "U1.69 TP8.1",                      # PA10
    "LED": "U1.83 R9.1",                           # PD2
    "?LED_A": "R9.2 LED1.1",  # unnamed short wire; only connectivity is checked
}
U1_USED = {6, 10, 11, 12, 13, 14, 19, 20, 21, 22, 27, 28, 29, 30, 31, 32, 33, 37, 40, 41, 46, 47, 48, 68, 69, 70, 71, 72,
           75, 76, 83, 92, 93, 94, 99, 100}
NC = ([f"U1.{n}" for n in range(1, 101) if n not in U1_USED]
      + "U2.4 D1.5 D2.5 J1.A2 J1.A3 J1.B10 J1.B11 J2.B8 J2.A8 J2.A4B9".split())
# Device identity: designator -> LCSC id read back from the placed instance
PARTS = {
    "U1": "C54937001", "U2": "C82942", "U3": "C18185312", "J1": "C3039316", "J2": "C165948", "D1": "C2687116",
    "D2": "C2687116", "D3": "C5274290", "D4": "C5274290", "D5": "C5274290", "D6": "C8598", "F1": "C883095", "Y1": "C9006",
    "LED1": "C2286", "R1": "C25905", "R2": "C25905", "R3": "C25905", "R4": "C25741", "R5": "C25744", "R6": "C25744",
    "R7": "C25744", "R8": "C25744", "R9": "C11702", "C1": "C19666", "C2": "C19666", "C5": "C19702", "C11": "C23630",
    "C12": "C23630", "C15": "C1548", "C16": "C1548",
    **{f"C{i}": "C1525" for i in (3, 4, 6, 7, 8, 9, 10, 13, 14, 17, 18, 19)}, **{f"TP{i}": None for i in range(1, 9)},
}


def main(path):
    nl = json.load(open(path))
    got, ident, errors = {}, {}, []
    for c in nl["components"].values():
        ref = c["props"].get("Designator")
        if ref in ident:
            errors.append(f"duplicate designator {ref}")
        ident[ref] = c["props"].get("Supplier Part")
        for num, pin in c["pinInfoMap"].items():
            got.setdefault(pin["net"], set()).add(f"{ref}.{num}")
    for ref, sid in PARTS.items():
        if ref not in ident:
            errors.append(f"missing part {ref}")
        elif (ident[ref] or None) != sid:
            errors.append(f"{ref}: expected {sid}, got {ident[ref]}")
    for ref in set(ident) - set(PARTS):
        errors.append(f"unexpected part {ref}")
    all_pins = set().union(*got.values())
    floating = got.get("", set())
    by_pins = {frozenset(v): k for k, v in got.items() if k != ""}
    for net, pins in TRUTH.items():
        pins = frozenset(pins.split())
        if net.startswith("?"):
            if pins not in by_pins:
                errors.append(f"{net}: no net with exactly {sorted(pins)}")
        elif got.get(net) != pins:
            g = got.get(net, set())
            errors.append(f"{net}: missing {sorted(pins - g)} extra {sorted(g - pins)}")
    named = {k for k in TRUTH if not k.startswith("?")}
    for net in set(got) - named - {""}:
        if frozenset(got[net]) != frozenset(TRUTH["?LED_A"].split()):
            errors.append(f"unexpected net {net}: {sorted(got[net])}")
    if floating != set(NC):
        errors.append(f"floating pins differ: unexpected {sorted(floating - set(NC))} missing {sorted(set(NC) - floating)}")
    truth_pins = set().union(*(set(v.split()) for v in TRUTH.values())) | set(NC)
    if truth_pins != all_pins:
        errors.append(f"pin coverage: not in truth {sorted(all_pins - truth_pins)} not in EDA {sorted(truth_pins - all_pins)}")
    print(f"parts {len(ident)}  nets {len(got) - (1 if '' in got else 0)}  pins {len(all_pins)}  floating(NC) {len(floating)}")
    print("NETLIST MATCH" if not errors else "NETLIST MISMATCH")
    for e in errors:
        print("  -", e)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else W / "evidence/schematic.net.json"))
