"""WiredKVM V407 Stick L100 enclosure, version 2: two 3D-printed halves held by snap hooks.

Split at the board's top surface (z = 1.0). How the board is held:
- Down (z): it sits on the bottom shell's floor; six posts in the top shell press its top at
  clear spots. Four snap hooks hold the halves together, so the posts keep pressing.
- Sideways (x): by its two connectors. The plug sits in the nose bore and the socket in the end
  wall opening, each with FIT per side. The board edges keep CLR from the pocket walls, which
  covers the board maker's +-0.2 mm outline tolerance.
- Lengthwise (y): its front edge rests on the pocket's front wall (this sets how much plug is
  bare). Two crush ribs on the rear wall push it forward and take up the outline tolerance.

Snap hooks: four tabs rise from the bottom shell's side walls into pockets in the top shell.
Each tab is a 1.0 mm cantilever rooted below the board, with a hook that clicks into a window in
the top shell's side. To open: push each hook in through its window with a pin and lift.

The nose wraps the TC-002 plug shell, so sideways load on the plug goes into the case. The nose
starts EXPOSED_PLUG behind the plug tip (USB Type-C needs at least 6.65 mm of bare shell) and
stays inside the 12.35 x 6.5 mm plug overmold envelope.

Frame = pcba.py's: board bottom z = 0, plug end y = 0, x centred. Board outline from
manufacturing/R1-WIP/gerber/Gerber_BoardOutlineLayer.GKO: x +-11.0, y 0..47.8, R1.0 corners.
Material: MJF PA12 (the hooks need nylon; standard SLA resin is too brittle for them).
Check: cad model dfm "$ID" --process printing --technology mjf
"""

import build123d as bd
from cad import model

from pcba import pcba_l100

# Board and parts (board at 1.0 mm)
BOARD_HALF_W = 11.0
BOARD_LEN = 47.8
BOARD_T = 1.0
PLUG_TIP_Y = 1.22 - 12.597            # -11.377
PLUG_W, PLUG_H, PLUG_Z = 8.25, 2.40, 1.23  # shell width, height, centre height
PLUG_TOP = PLUG_Z + PLUG_H / 2         # 2.43
J2_W, J2_TOP = 8.94, 4.25              # socket section past the board edge: x +-4.47, z 1.05..4.25
J2_FACE_Y = 48.26                      # socket mating face (board.step)
# Floor reliefs (x0, x1, y0, y1) under the socket's through-board parts, from the drill files:
# shell-leg slots at x +-4.325 (0.8 wide) and locating pegs at (+-2.9, 42.0) (NPTH 0.6)
J2_RELIEFS = [(2.1, 5.125, 40.55, 42.8), (3.525, 5.125, 44.88, 46.48)]
LED_XY = (10.05, 16.8)                 # cpl.csv
# Clear board-top spots for the hold-down posts: no part or test pad within 0.35 mm of a post,
# and at least 0.7 mm from a wall (a narrower slot can fuse in printing)
POSTS = [(-9.4, 1.6), (4.2, 5.6), (-9.4, 24.6), (9.4, 29.8), (-9.4, 46.2), (9.4, 46.2)]
POST_R = 1.0

# Enclosure
CLR = 0.3           # board edge to pocket wall, sideways (outline tolerance +-0.2)
CLR_FRONT = 0.1     # board front edge to pocket front wall
CLR_REAR = 0.15     # board rear edge to pocket rear wall; the crush ribs close it
RIB_R, RIB_H = 0.5, 0.25  # crush ribs: protrude RIB_H, so 0.1 mm interference at nominal size
RIB_X = 7.5
FIT = 0.15          # plug and socket openings, per side
WALL = 2.3          # lip 1.0 + gap 0.1 + skirt 1.2
FLOOR = 1.2
ROOF = 1.2
FRONT_WALL = 2.1
END_WALL = 1.0      # socket face sits Y_OUT1 - J2_FACE_Y inside the case end
EXPOSED_PLUG = 7.0  # bare plug shell ahead of the nose; 0.35 over the minimum for board tolerances
NOSE_W = 11.6
NOSE_TOP = 4.03

SPLIT_Z = BOARD_T
CAV_HALF_W = BOARD_HALF_W + CLR                 # 11.3
OUT_HALF_W = CAV_HALF_W + WALL                  # 13.6
Y_CAV0, Y_CAV1 = -CLR_FRONT, BOARD_LEN + CLR_REAR
Y_OUT0, Y_OUT1 = Y_CAV0 - FRONT_WALL, Y_CAV1 + END_WALL
Z_BOT = -FLOOR
Z_CEIL = J2_TOP + 0.25
Z_TOP = Z_CEIL + ROOF
Y_NOSE = PLUG_TIP_Y + EXPOSED_PLUG              # -4.377

LIP_T, LIP_H, LIP_GAP = 1.0, 0.8, 0.1
LIP_Y = (2.0, 44.5)   # straight sides only, clear of the R3 corners

# Snap hooks (both sides). The tab is the lip, taller and cut free.
SNAP_Y = [(7.0, 10.5), (36.5, 40.0)]  # tab ends along y
SNAP_T = 1.0          # tab thickness (MJF minimum for a free-standing wall)
SNAP_ROOT_Z = -0.5    # tab is free down to here (0.7 mm of floor stays under the moat)
SNAP_TOP_Z = 4.2
HOOK_Z0, HOOK_H = 3.4, 0.45  # hook's flat holding face, and how far it sticks out
HOOK_RAMP_Z = 3.6     # ramp runs from here up to the tab top
SNAP_GAP = 0.1        # tab to top shell, each side
MOAT = 0.6            # free space around the tab inside the bottom shell (fuses if < 0.51)
WIN_PLAY = 0.05       # hook face to window sill

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


def xz_prism(pts, y0, y1):
    """Polygon in the XZ plane (points as (x, z)), extruded from y0 to y1."""
    return bd.Pos(0, y0, 0) * bd.extrude(bd.Plane.XZ * bd.Polygon(*pts, align=None), -(y1 - y0))


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


def snap_tab(y0, y1):
    """One snap tab on the +x side: the cantilever and its hook (flat face down, ramp up)."""
    x0, x1 = CAV_HALF_W, CAV_HALF_W + SNAP_T
    tab = box(x0, x1, y0, y1, SNAP_ROOT_Z, SNAP_TOP_Z)
    hook = xz_prism([(x1 - 0.01, HOOK_Z0), (x1 + HOOK_H, HOOK_Z0), (x1 + HOOK_H, HOOK_RAMP_Z),
                     (x1 - 0.01, SNAP_TOP_Z)], y0, y1)
    return tab + hook


def snap_moat(y0, y1):
    """Bottom-shell material removed around a tab so it can bend (the tab is added back after)."""
    x0, x1 = CAV_HALF_W - MOAT, CAV_HALF_W + SNAP_T + MOAT
    below = box(x0, x1, y0 - MOAT, y1 + MOAT, SNAP_ROOT_Z, SPLIT_Z)
    lip_cut = box(CAV_HALF_W - 0.1, CAV_HALF_W + LIP_T + 0.1, y0 - MOAT, y1 + MOAT, SPLIT_Z - 0.01, SPLIT_Z + LIP_H + 0.1)
    return below + lip_cut


def snap_pocket(y0, y1):
    """Top-shell room for a tab, plus the window its hook clicks into."""
    x0, x1 = CAV_HALF_W - SNAP_GAP, CAV_HALF_W + SNAP_T + SNAP_GAP
    pocket = box(x0, x1, y0 - SNAP_GAP, y1 + SNAP_GAP, SPLIT_Z - 1, SNAP_TOP_Z + SNAP_GAP)
    window = box(x1 - 0.01, OUT_HALF_W + 1, y0 - SNAP_GAP, y1 + SNAP_GAP,
                 HOOK_Z0 - WIN_PLAY, SNAP_TOP_Z + SNAP_GAP)
    return pocket + window


def crush_ribs():
    """Two vertical ribs on the pocket's rear wall, tapered at the top as a lead-in."""
    ribs = []
    for s in (-1, 1):
        at = bd.Pos(s * RIB_X, Y_CAV1 + RIB_R - RIB_H, 0)
        ribs.append(at * bd.Cylinder(RIB_R, 0.7, align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN)))
        ribs.append(at * bd.Pos(0, 0, 0.7) * bd.Cone(RIB_R, RIB_R - 0.3, SPLIT_Z - 0.7,
                                                       align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN)))
    rib = ribs[0].fuse(*ribs[1:])
    return rib & box(-20, 20, Y_CAV1 - 1, Y_CAV1 + 0.01, 0, SPLIT_Z)


def leg_reliefs():
    """Floor pockets under the socket's through-board legs and pegs (and their solder)."""
    cuts = [box(x0, x1, y0, y1, -0.5, 0.01) for x0, x1, y0, y1 in J2_RELIEFS]
    return mirrored_x(cuts[0].fuse(*cuts[1:]))


def bottom_shell_body():
    lower = outer_solid() & box(-20, 20, -20, 60, Z_BOT - 1, SPLIT_Z)
    pocket = rrect_z(2 * CAV_HALF_W, Y_CAV1 - Y_CAV0, 1.2, 0.0, SPLIT_Z + 1, cy=(Y_CAV0 + Y_CAV1) / 2)
    lip = mirrored_x(box(CAV_HALF_W, CAV_HALF_W + LIP_T, LIP_Y[0], LIP_Y[1], SPLIT_Z, SPLIT_Z + LIP_H))
    moats = mirrored_x(bd.Compound([snap_moat(*y) for y in SNAP_Y]).fuse())
    tabs = mirrored_x(bd.Compound([snap_tab(*y) for y in SNAP_Y]).fuse())
    # the socket overhangs the board's rear edge 0.05 above the split: lower the end wall under it
    under_j2 = box(-J2_W / 2 - FIT, J2_W / 2 + FIT, Y_CAV1 - 0.01, Y_OUT1 + 1, SPLIT_Z - 0.15, SPLIT_Z + 0.1)
    shell = lower - pocket - openings() - leg_reliefs() - under_j2 + lip - moats
    shell = shell.fuse(tabs, crush_ribs())
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
    pockets = mirrored_x(bd.Compound([snap_pocket(*y) for y in SNAP_Y]).fuse())
    shell = upper - cavity - tail - lip_room(LIP_GAP) - openings() - led - pockets
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
          f"case body {Y_OUT1 - Y_OUT0:.1f} long, nose {Y_OUT0 - Y_NOSE:.2f}, socket recess {Y_OUT1 - J2_FACE_Y:.2f}")
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
