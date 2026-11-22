import sys
sys.path.insert(0, "src")
import build123d as bd
from cad.build123d import leaves
from enclosure import bottom_shell_body, top_shell_body, Y_NOSE, PLUG_TIP_Y, Y_OUT1
from pcba import corrected_board, J1_AT, BOARD_T
from plug import tc002_plug
top, bot = top_shell_body(), bottom_shell_body()
plug = bd.Pos(J1_AT[0], J1_AT[1], BOARD_T) * tc002_plug()
shell = [c for c in leaves(plug) if c.label == "shell"][0]
print("bare plug ahead of nose: %.2f mm (USB-C needs >= 6.65)" % (Y_NOSE - PLUG_TIP_Y))
print("plug shell to top shell: %.3f, to bottom shell: %.3f" % (shell.distance_to(top), shell.distance_to(bot)))
parts = corrected_board()
pcb = [p for p in parts if p.label == "pcb"][0]
print("board to bottom shell: %.3f, board to top shell (posts): %.3f" % (pcb.distance_to(bot), pcb.distance_to(top)))
worst = sorted((p.distance_to(top), str(p.label)) for p in parts
               if not str(p.label).startswith(("pcb", "TopCopper", "BottomCopper")))[:4]
print("nearest parts to top shell:", [(n, round(d, 3)) for d, n in worst])
j2 = [p for p in parts if str(p.label).startswith("J2")][0]
print("socket face recess behind case end: %.2f mm" % (Y_OUT1 - j2.bounding_box().max.Y))
# planted fault: move the plug 0.15 mm up; the check above must then report contact (0)
moved = bd.Pos(0, 0, 0.15) * shell
print("planted fault (plug +0.15 z) -> distance to top shell: %.3f" % moved.distance_to(top))
