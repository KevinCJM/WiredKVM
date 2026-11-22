from pathlib import Path
from cad import xbf
from cad.build123d import leaves
HERE = Path(__file__).resolve().parent
tree = xbf.read(HERE / "../vendor/board.xbf")
rows = []
for p in leaves(tree):
    b = p.bounding_box()
    rows.append((p.label, round(b.min.X,2), round(b.min.Y,2), round(b.min.Z,2), round(b.max.X,2), round(b.max.Y,2), round(b.max.Z,2)))
rows.sort(key=lambda r: -(r[4]-r[1])*(r[5]-r[2]))
for r in rows[:25]: print(r)
for r in rows:
    if any(k in str(r[0]) for k in ("J2","LED","U1","SW","J1")): print("**", r)
