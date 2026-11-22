import sys
import build123d  # noqa: F401
sys.path.insert(0, "src")
from pcba import corrected_board
for p in corrected_board():
    if p.label == "pcb":
        b = p.bounding_box(); print("pcb", b.min, b.max, "faces", len(p.faces()))
