import sys
sys.path.insert(0, "src")
import build123d as bd
from cad.build123d import leaves
from enclosure import top_shell_body
from pcba import corrected_board
j2 = [p for p in corrected_board() if str(p.label).startswith("J2")][0]
x = top_shell_body() & j2
print(x.bounding_box().min, x.bounding_box().max, x.volume)
for yy in (46.0, 47.0, 47.6, 48.0):
    s = j2 & bd.Pos(0, yy, 0) * bd.Box(30, 0.05, 30)
    b = s.bounding_box(); print(yy, round(b.min.X,2), round(b.max.X,2), round(b.min.Z,2), round(b.max.Z,2))
