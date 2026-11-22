"""Fit checks for enclosure v2: clearances, snap engagement, tab bending room, strain."""
import sys
import build123d as bd
sys.path.insert(0, "src")
from cad.build123d import leaves
import enclosure as E
from pcba import corrected_board, J1_AT, BOARD_T
from plug import tc002_plug

top, bot = E.top_shell_body(), E.bottom_shell_body()
plug = bd.Pos(J1_AT[0], J1_AT[1], BOARD_T) * tc002_plug()
shell = [c for c in leaves(plug) if c.label == "shell"][0]
parts = corrected_board()
pcb = [p for p in parts if p.label == "pcb"][0]
comps = [p for p in parts if not str(p.label).startswith(("pcb", "TopCopper", "BottomCopper"))]
print("bare plug ahead of nose: %.2f (USB-C needs >= 6.65)" % (E.Y_NOSE - E.PLUG_TIP_Y))
print("plug shell to top shell %.3f, to bottom shell %.3f" % (shell.distance_to(top), shell.distance_to(bot)))
print("board to bottom shell %.3f, to top shell (posts) %.3f" % (pcb.distance_to(bot), pcb.distance_to(top)))
print("nearest parts to top shell:", sorted((round(p.distance_to(top), 3), str(p.label)) for p in comps)[:4])
print("nearest parts to bottom shell:", sorted((round(p.distance_to(bot), 3), str(p.label)) for p in comps)[:3])
j2 = [p for p in parts if str(p.label).startswith("J2")][0]
print("J2 to top shell %.3f, face recess %.2f" % (j2.distance_to(top), E.Y_OUT1 - j2.bounding_box().max.Y))

# Snap engagement: the hook overlaps the window sill in x by this much
x_hook = E.CAV_HALF_W + E.SNAP_T + E.HOOK_H
x_sill = E.CAV_HALF_W + E.SNAP_T + E.SNAP_GAP
print("hook overlap on the sill %.2f mm; z play %.2f" % (x_hook - x_sill, E.WIN_PLAY))
# Bending: tip deflection needed and strain (cantilever, eps = 1.5 t y / L^2)
L = (E.HOOK_Z0 + E.HOOK_RAMP_Z) / 2 - E.SNAP_ROOT_Z
y = x_hook - x_sill
eps = 1.5 * E.SNAP_T * y / L ** 2
b = E.SNAP_Y[0][1] - E.SNAP_Y[0][0]
P = 3 * 1700 * (b * E.SNAP_T ** 3 / 12) * y / L ** 3
print("tab L %.2f, deflection %.2f, strain %.1f %% (PA12 ok < ~5 %%), push per tab %.1f N" % (L, y, eps * 100, P))
# Bending room: a tab bent inward by y at the hook must not touch any part (tilt about its root)
for y0, y1 in E.SNAP_Y:
    for s in (1, -1):
        tab = E.snap_tab(y0, y1)
        if s < 0:
            tab = bd.mirror(tab, bd.Plane.YZ)
        ang = (y * 1.5 / L) * 57.2958   # slope at the tip of a cantilever = 1.5 y / L, degrees
        bent = bd.Pos(0, 0, E.SNAP_ROOT_Z) * bd.Rot(0, s * -ang, 0) * bd.Pos(0, 0, -E.SNAP_ROOT_Z) * tab
        dmin = min(bent.distance_to(p) for p in comps + [pcb])
        print("tab x%+d y %.1f..%.1f bent %.2f deg: nearest part %.3f" % (s, y0, y1, ang, dmin))
# Planted fault: a hook 0.5 mm further in must show it still clears the sill (overlap goes negative)
print("planted fault: hook height 0.05 -> overlap %.2f (must be < 0)" % (E.CAV_HALF_W + E.SNAP_T + 0.05 - x_sill))
