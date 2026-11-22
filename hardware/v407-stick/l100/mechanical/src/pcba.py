"""WiredKVM V407 Stick L100 PCBA: the EDA board STEP, corrected for enclosure work.

Two fixes over manufacturing/R1-WIP/board.step:
- J1 (TC-002 plug) has no 3D model in the JLC library; it is added from plug.py.
- The EDA export uses its default 1.6 mm board; the board is ordered at 1.0 mm,
  so the board is cut to 1.0 mm and every top-side part comes down 0.6 mm.

Frame = board.step's: board bottom at z = 0, top at z = 1.0, plug end at y = 0,
socket end at y = 47.8, x centred.
"""

from pathlib import Path

import build123d as bd
from cad import model, xbf
from cad.build123d import leaves

from plug import tc002_plug

HERE = Path(__file__).resolve().parent

EXPORT_THICKNESS = 1.6
BOARD_T = 1.0
DROP = EXPORT_THICKNESS - BOARD_T
J1_AT = (0.0, 1.22)  # pcb_layout.py: b.put("J1", 0, 1.22, 0)


def corrected_board():
    parts = []
    for p in leaves(xbf.read(HERE / "../vendor/board.xbf")):
        name = str(p.label)
        b = p.bounding_box()
        if b.size.X == 0 and b.size.Y == 0:
            continue  # empty silkscreen / stiffener layers
        if name.startswith("Board"):
            p = bd.Pos(0, 0, -DROP) * (p & bd.Pos(0, 0, DROP) * bd.Box(
                100, 100, BOARD_T, align=(bd.Align.CENTER, bd.Align.MIN, bd.Align.MIN)))
            p.label, p.color = "pcb", "#1f5f3a"
        elif name.startswith("BottomCopper"):
            pass
        else:
            label, color = p.label, p.color
            p = bd.Pos(0, 0, -DROP) * p
            p.label, p.color = label, color
        parts.append(p)
    return parts


@model
def pcba_l100():
    parts = corrected_board()
    plug = bd.Pos(J1_AT[0], J1_AT[1], BOARD_T) * tc002_plug()
    pcba = bd.Compound(children=parts + [plug], label="WiredKVM_V407_Stick_L100")
    b = pcba.bounding_box()
    assert abs(b.min.Y - (J1_AT[1] - 12.597)) < 1e-3, b.min.Y   # plug tip 11.38 mm past the edge
    assert b.max.Z < 4.3, b.max.Z                               # tallest part (J2) 3.25 above a 1.0 board
    return pcba


if __name__ == "__main__":
    pcba_l100()
