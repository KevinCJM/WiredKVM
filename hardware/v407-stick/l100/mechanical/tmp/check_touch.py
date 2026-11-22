import sys
sys.path.insert(0, "src")
import build123d as bd
from cad.build123d import leaves
from enclosure import bottom_shell_body, top_shell_body
from pcba import J1_AT, BOARD_T
from plug import tc002_plug
top, bot = top_shell_body(), bottom_shell_body()
plug = bd.Pos(J1_AT[0], J1_AT[1], BOARD_T) * tc002_plug()
shell = [c for c in leaves(plug) if c.label == "shell"][0]
for name, s in (("top", top), ("bottom", bot)):
    d, p1, p2 = shell.distance_to_with_closest_points(s)
    print(name, round(d, 3), [round(v, 3) for v in p1], [round(v, 3) for v in p2])
# bore-only: distance from the plug's stadium barrel (tip to board edge) to each shell
barrel = shell & bd.Pos(0, -6, 1.23) * bd.Box(20, 10, 10)
print("barrel y<-1:", round(barrel.distance_to(top), 3), round(barrel.distance_to(bot), 3))
print("barrel +0.15z to top:", round((bd.Pos(0, 0, 0.15) * barrel).distance_to(top), 3))
