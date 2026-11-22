"""HANBO TC-002 USB Type-C SMT plug (LCSC C3039316), J1 on the L100 board.

The JLC library part has no 3D model, so the board STEP exported without it.
Drawn from docs/datasheets/TC-002_C3039316.pdf at simplified detail: the outside
shell, the mating opening, the top latch spring, the tail and its solder legs.

Frame = the EDA footprint's: origin at the footprint origin on the board's top
surface, +Y into the board, +Z up. The board edge is at y = -1.22 (footprint),
so the shell overhangs it by 11.38 mm.
"""

import build123d as bd
from cad import model

# Datasheet dimensions (mm)
SHELL_W = 8.25          # shell width (top view)
SHELL_H = 2.40          # shell height (side view)
COLLAR_W = 8.35         # rear collar width (front view)
SHELL_LEN_BOTTOM = 11.25  # front to the end of the full-height shell
SHELL_LEN_TOP = 11.75     # front to the end of the upper collar
TOTAL_LEN = 13.60       # front to the end of the solder legs
TOP_ABOVE_LEGS = 1.43   # shell top above the solder-leg plane (= board top)
LATCH_RISE = 0.40       # latch spring above the shell top
LEG_SPAN = 10.10        # across the side ground wings

FRONT_Y = -12.597       # footprint bbox: plug tip
EDGE_Y = -1.22          # board edge in footprint coordinates

STEEL = "#c9ccd1"
PLASTIC = "#2b2b2b"
COPPER = "#d9a441"


def stadium(width, height, length):
    """Stadium prism along +Y, centred on x = 0 and z = 0, from y = 0 to `length`."""
    sk = bd.SlotOverall(width, height)
    return bd.extrude(bd.Plane.XZ * sk, amount=-length)  # Plane.XZ faces -Y, so a negative amount grows +Y


def tc002_plug():
    z_mid = TOP_ABOVE_LEGS - SHELL_H / 2          # shell centre height above the board top
    z_bot = TOP_ABOVE_LEGS - SHELL_H              # -0.97: below the board top, inside the board's thickness span

    # Full-height shell, tip to just past the board edge
    shell = bd.Pos(0, FRONT_Y, z_mid) * stadium(SHELL_W, SHELL_H, SHELL_LEN_BOTTOM)
    # Mating opening: shell lip, then the slot the receptacle tongue enters
    shell -= bd.Pos(0, FRONT_Y, z_mid) * stadium(SHELL_W - 0.5, SHELL_H - 0.5, 0.6)
    shell -= bd.Pos(0, FRONT_Y, z_mid) * stadium(6.83, 0.80, 6.5)
    # Upper collar over the board edge (only above the board top)
    collar_len = SHELL_LEN_TOP - SHELL_LEN_BOTTOM
    collar = bd.Pos(0, FRONT_Y + SHELL_LEN_BOTTOM, z_mid) * stadium(COLLAR_W, SHELL_H, collar_len)
    collar &= bd.Pos(0, FRONT_Y + SHELL_LEN_BOTTOM, 0) * bd.Box(
        COLLAR_W, collar_len, TOP_ABOVE_LEGS, align=(bd.Align.CENTER, bd.Align.MIN, bd.Align.MIN))
    shell += collar
    # Latch spring on top, 9.0-10.5 mm from the tip
    shell += bd.Pos(0, FRONT_Y + 9.0, TOP_ABOVE_LEGS) * bd.Box(
        0.8, 1.5, LATCH_RISE, align=(bd.Align.CENTER, bd.Align.MIN, bd.Align.MIN))
    # Side ground wings: drop from the collar to the board and out to the 1.3 x 2.1 pads
    y_tail = FRONT_Y + SHELL_LEN_TOP
    for s in (-1, 1):
        shell += bd.Pos(s * (COLLAR_W / 2 - 0.1), EDGE_Y + 0.02, 0) * bd.Box(
            0.2, 0.6, 1.0, align=(bd.Align.CENTER, bd.Align.MIN, bd.Align.MIN))
        shell += bd.Pos(s * 4.6, -1.0, 0) * bd.Box(
            LEG_SPAN / 2 - 4.15, 2.0, 0.15, align=(bd.Align.CENTER, bd.Align.MIN, bd.Align.MIN))
        # small ground legs at x = +-3.575, pads 0.5 x 0.9
        shell += bd.Pos(s * 3.575, -1.02, 0) * bd.Box(
            0.4, 0.9, 0.15, align=(bd.Align.CENTER, bd.Align.MIN, bd.Align.MIN))
    shell.label = "shell"
    shell.color = STEEL

    # Plastic tail behind the collar
    tail_end = FRONT_Y + TOTAL_LEN
    tail = bd.Pos(0, y_tail, 0.15) * bd.Box(
        6.9, tail_end - 0.6 - y_tail, TOP_ABOVE_LEGS - 0.35, align=(bd.Align.CENTER, bd.Align.MIN, bd.Align.MIN))
    tail.label = "housing"
    tail.color = PLASTIC

    # 12 terminal tails on the 0.30 x 1.00 pads (0.5 mm pitch)
    xs = [-2.7508, -2.2504, -1.7501, -1.2497, -0.7493, -0.2489, 0.2489, 0.7493, 1.2497, 1.7501, 2.2504, 2.7508]
    pins = [bd.Pos(x, 0.08, 0) * bd.Box(0.25, 1.0, 0.15, align=(bd.Align.CENTER, bd.Align.MIN, bd.Align.MIN))
            for x in xs]
    terminals = pins[0].fuse(*pins[1:])
    terminals.label = "terminals"
    terminals.color = COPPER

    plug = bd.Compound(children=[shell, tail, terminals], label="J1_TC-002")
    b = plug.bounding_box()
    assert abs(b.min.Y - FRONT_Y) < 1e-6, b.min.Y
    assert abs(b.size.Z - (SHELL_H + LATCH_RISE)) < 1e-6, b.size.Z
    assert abs(b.min.Z - z_bot) < 1e-6, b.min.Z
    return plug


@model
def tc002():
    return tc002_plug()


if __name__ == "__main__":
    tc002()
