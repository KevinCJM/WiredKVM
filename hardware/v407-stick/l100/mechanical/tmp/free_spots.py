import sys, math
import build123d  # noqa: F401  (tells cad run to add the integration)
sys.path.insert(0, "src")
from pcba import corrected_board
boxes = []
for p in corrected_board():
    n = str(p.label)
    if n.startswith(("TopCopper", "BottomCopper", "pcb")): continue
    b = p.bounding_box(); boxes.append((n, b.min.X, b.min.Y, b.max.X, b.max.Y))
boxes.append(("J1tail", -5.6, -0.2, 5.6, 2.6))
tps = [(9.8,11.4),(5.7,8.2),(5.3,11.3),(9.8,14.2),(-2.98,32.9),(8.15,12.25),(0.6,11.6),(2.2,11.1)]
R = 1.0 + 0.35
def free(x, y):
    for n,x0,y0,x1,y1 in boxes:
        dx = max(x0-x, 0, x-x1); dy = max(y0-y, 0, y-y1)
        if math.hypot(dx, dy) < R: return False
    return all(math.hypot(x-a, y-b) >= R + 0.6 for a,b in tps)
pts = [(x/10, y/10) for x in range(-94, 95, 2) for y in range(16, 463, 2) if free(x/10, y/10)]
for cx, cy in [(-11,0),(11,0),(-11,48),(11,48),(-11,24),(11,24),(4.2,5.6)]:
    best = min(pts, key=lambda p: math.hypot(p[0]-cx, p[1]-cy))
    print((cx,cy), "->", best)
print(len(pts), "free grid points")
