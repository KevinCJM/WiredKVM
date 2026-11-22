import sys
import build123d  # noqa: F401
sys.path.insert(0, "src")
from enclosure import bottom_shell_body
from pcba import corrected_board
pcb = [p for p in corrected_board() if p.label == "pcb"][0]
ov = bottom_shell_body() & pcb
for s in ov.solids():
    b = s.bounding_box(); print("overlap", round(s.volume, 4), [round(v, 3) for v in (b.min.X, b.max.X, b.min.Y, b.max.Y, b.min.Z, b.max.Z)])
