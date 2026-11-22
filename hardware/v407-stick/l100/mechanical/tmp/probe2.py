from pathlib import Path
from collections import Counter
import build123d as bd
from cad import xbf
from cad.build123d import leaves
HERE = Path(__file__).resolve().parent
tree = xbf.read(HERE / "../vendor/board.xbf")
ps = leaves(tree)
print(Counter(str(p.label).split("~")[0].split("->")[0] if "~" in str(p.label) else "comp" for p in ps))
low = [(p.label, round(p.bounding_box().min.Z,2)) for p in ps if p.bounding_box().min.Z < 1.55 and "Copper" not in str(p.label)]
print("low:", low)
j2 = [p for p in ps if str(p.label).startswith("J2")][0]
sec = j2 & bd.Box(30, 0.3, 30, align=(bd.Align.CENTER, bd.Align.MIN, bd.Align.CENTER)).moved(bd.Location((0, 47.9, 0)))
b = sec.bounding_box(); print("J2 overhang section", b.min, b.max)
wide = [(p.label, round(p.bounding_box().min.X,2), round(p.bounding_box().max.X,2), round(p.bounding_box().min.Y,2), round(p.bounding_box().max.Y,2)) for p in ps if "Copper" not in str(p.label) and "Board" not in str(p.label) and (abs(p.bounding_box().min.X)>10.2 or abs(p.bounding_box().max.X)>10.2 or p.bounding_box().min.Y<0.8 or p.bounding_box().max.Y>47.0)]
print("near edges:", wide)
