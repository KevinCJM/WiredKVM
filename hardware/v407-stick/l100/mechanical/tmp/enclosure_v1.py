"""WiredKVM V407 Stick L100 enclosure, version 1: two 3D-printed halves.

Split at the board's top surface (z = 1.0). The bottom shell holds the board in
a pocket; six posts in the top shell press it down at clear spots. The long
sides close with a lap joint: a lip on the bottom shell inside a skirt of the
top shell (friction fit; a drop of glue makes it permanent). Opening it again
gives access to the SWD test pads.

The nose wraps the TC-002 plug shell for 4.45 mm, so the plug's bending load
goes into the case and the board pocket rather than the plug's solder joints.
The nose starts 6.8 mm behind the plug tip (USB Type-C needs at least 6.65 mm of
bare shell) and stays inside the 12.35 x 6.5 mm plug overmold envelope.

Frame = pcba.py's: board bottom z = 0, plug end y = 0, x centred.
Check: cad model dfm "$ID" --process printing --technology mjf   (also sla)
"""

import build123d as bd
from cad import model

from pcba import pcba_l100

# Board and parts (from board.step, with the board at 1.0 mm)
BOARD_HALF_W = 10.985
BOARD_LEN = 47.8
BOARD_T = 1.0
PLUG_TIP_Y = 1.22 - 12.597            # -11.377
PLUG_W, PLUG_H, PLUG_Z = 8.25, 2.40, 1.23  # shell width, height, centre height
PLUG_TOP = PLUG_Z + PLUG_H / 2         # 2.43
J2_W, J2_TOP = 8.94, 4.25              # socket section past the board edge: x +-4.47, z 1.05..4.25
LED_XY = (10.05, 16.8)                 # cpl.csv
# Clear board-top spots for the hold-down posts: no part or test pad within 0.35 mm of a post,
# and at least 0.7 mm from a wall (a narrower slot can fuse in printing)
POSTS = [(-9.4, 1.6), (4.2, 5.6), (-9.4, 24.6), (9.4, 29.8), (-9.4, 46.2), (9.4, 46.2)]
POST_R = 1.0

# Enclosure
CLR = 0.2           # board to pocket, sideways
CLR_END = 0.1       # board to pocket, at each end
FIT = 0.1           # plug and socket openings, per side
WALL = 2.1          # lip 1.0 + gap 0.1 + skirt 1.0
FLOOR = 1.2
ROOF = 1.2
END_WALL = 1.0      # socket face sits 0.64 mm inside the case end
EXPOSED_PLUG = 6.8  # bare plug shell ahead of the nose
NOSE_W = 11.6
NOSE_TOP = 4.03

SPLIT_Z = BOARD_T
CAV_HALF_W = BOARD_HALF_W + CLR                 # 11.185
OUT_HALF_W = CAV_HALF_W + WALL                  # 13.285
Y_CAV0, Y_CAV1 = -CLR_END, BOARD_LEN + CLR_END
Y_OUT0, Y_OUT1 = Y_CAV0 - WALL, Y_CAV1 + END_WALL
Z_BOT = -FLOOR
Z_CEIL = J2_TOP + 0.25
Z_TOP = Z_CEIL + ROOF
Y_NOSE = PLUG_TIP_Y + EXPOSED_PLUG              # -4.577

LIP_T, LIP_H, LIP_GAP = 1.0, 0.8, 0.1
LIP_Y = (2.0, 44.5)   # straight sides only, clear of the R3 corners

SHELL_COLOR = "#e8e6e1"


def box(x0, x1, y0, y1, z0, z1):
    return bd.Pos((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2) * bd.Box(x1 - x0, y1 - y0, z1 - z0)


def rrect_z(w, l, r, z0, z1, cx=0.0, cy=0.0):
    """Rounded rectangle w (x) by l (y), extruded from z0 to z1."""
    return bd.Pos(cx, cy, z0) * bd.extrude(bd.RectangleRounded(w, l, r), z1 - z0)


def rrect_y(w, h, r, y0, y1, cx=0.0, cz=0.0):
    """Rounded rectangle w (x) by h (z), extruded from y0 to y1; r >= h/2 makes a stadium."""
    sk = bd.SlotOverall(w, h) if 2 * r >= h else bd.RectangleRounded(w, h, r)
    return bd.Pos(cx, y0, cz) * bd.extrude(bd.Plane.XZ * sk, -(y1 - y0))


def mirrored_x(shape):
    return shape + bd.mirror(shape, bd.Plane.YZ)


def outer_solid():
    body = rrect_z(2 * OUT_HALF_W, Y_OUT1 - Y_OUT0, 3.0, Z_BOT, Z_TOP, cy=(Y_OUT0 + Y_OUT1) / 2)
    body = bd.fillet(body.edges().group_by(bd.Axis.Z)[-1], 1.2)
    body = bd.fillet(body.edges().group_by(bd.Axis.Z)[0], 0.6)
    nose = rrect_y(NOSE_W, NOSE_TOP - Z_BOT, 1.5, Y_NOSE, Y_OUT0 + 1.0, cz=(NOSE_TOP + Z_BOT) / 2)
    nose = bd.fillet(nose.edges().group_by(bd.Axis.Y)[0], 0.4)
    return body + nose


def openings():
    """Air shared by both shells: plug bore, latch-spring recess, socket opening."""
    bore = rrect_y(PLUG_W + 2 * FIT, PLUG_H + 2 * FIT, PLUG_H / 2 + FIT, Y_NOSE - 1, 0.0, cz=PLUG_Z)
    # runs on into the cavity: a recess ending inside the front wall leaves a 0.48 mm sliver
    latch = box(-0.6, 0.6, PLUG_TIP_Y + 8.8, Y_CAV0 + 0.5, PLUG_Z, PLUG_TOP + 0.4 + 0.2)
    # top corners rounded, bottom edge square on the split (round ones there leave knife edges)
    sock_h = J2_TOP + FIT - SPLIT_Z + 1.0
    socket = rrect_y(J2_W + 2 * FIT, sock_h, 0.9, BOARD_LEN - 1.0, Y_OUT1 + 1, cz=J2_TOP + FIT - sock_h / 2)
    socket &= box(-20, 20, -20, 60, SPLIT_Z, 20)
    return bore + latch + socket


def lip_room(grow):
    """The lap joint's lip on both long sides, grown by `grow` on its free faces."""
    return mirrored_x(box(CAV_HALF_W - 0.1, CAV_HALF_W + LIP_T + grow,
                          LIP_Y[0] - grow, LIP_Y[1] + grow, SPLIT_Z - 1, SPLIT_Z + LIP_H + grow))


def bottom_shell_body():
    lower = outer_solid() & box(-20, 20, -20, 60, Z_BOT - 1, SPLIT_Z)
    pocket = rrect_z(2 * CAV_HALF_W, Y_CAV1 - Y_CAV0, 1.2, 0.0, SPLIT_Z + 1, cy=(Y_CAV0 + Y_CAV1) / 2)
    lip = mirrored_x(box(CAV_HALF_W, CAV_HALF_W + LIP_T, LIP_Y[0], LIP_Y[1], SPLIT_Z, SPLIT_Z + LIP_H))
    shell = lower - pocket - openings() + lip
    shell.label = "bottom_shell"
    shell.color = SHELL_COLOR
    return shell


def top_shell_body():
    upper = outer_solid() & box(-20, 20, -20, 60, SPLIT_Z, Z_TOP + 1)
    cavity = rrect_z(2 * CAV_HALF_W, Y_CAV1 - Y_CAV0, 1.2, SPLIT_Z - 1, Z_CEIL, cy=(Y_CAV0 + Y_CAV1) / 2)
    # Room for the plug's collar over the board edge, inside the front wall
    tail = box(-5.6, 5.6, Y_CAV0 - 0.1, 2.6, SPLIT_Z - 1, PLUG_TOP + 0.3)
    led = bd.Pos(*LED_XY, Z_CEIL - 0.5) * bd.Cylinder(
        0.75, ROOF + 1, align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN))
    posts = [bd.Pos(x, y, SPLIT_Z) * bd.Cylinder(
        POST_R, Z_CEIL - SPLIT_Z + 0.1, align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN)) for x, y in POSTS]
    shell = upper - cavity - tail - lip_room(LIP_GAP) - openings() - led
    shell = shell.fuse(*posts)
    shell.label = "top_shell"
    shell.color = SHELL_COLOR
    return shell


@model
def bottom_shell():
    s = bottom_shell_body()
    assert len(s.solids()) == 1, len(s.solids())
    return s


@model
def top_shell():
    s = top_shell_body()
    assert len(s.solids()) == 1, len(s.solids())
    return s


@model
def top_shell_print():
    """The top shell as printed: roof down on the plate."""
    s = bd.Rot(180, 0, 0) * top_shell().shape
    s.label = "top_shell"
    return s


@model
def enclosure():
    asm = bd.Compound(children=[bottom_shell().shape, top_shell().shape, pcba_l100().shape],
                      label="wiredkvm_stick_l100")
    print(f"outside: {2 * OUT_HALF_W:.1f} x {Y_OUT1 - PLUG_TIP_Y:.1f} (with plug) x {Z_TOP - Z_BOT:.1f} mm; "
          f"case body {Y_OUT1 - Y_OUT0:.1f} long, nose {Y_OUT0 - Y_NOSE:.2f}")
    return asm


@model
def enclosure_exploded():
    lift = 8.0
    asm = bd.Compound(children=[bd.Pos(0, 0, -lift) * bottom_shell().shape,
                                bd.Pos(0, 0, lift) * top_shell().shape,
                                pcba_l100().shape], label="wiredkvm_stick_l100_exploded")
    return asm


if __name__ == "__main__":
    bottom_shell()
    top_shell()
    top_shell_print()
    enclosure()
    enclosure_exploded()
