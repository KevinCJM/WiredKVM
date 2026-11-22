import sys, csv, io, subprocess
import build123d  # noqa: F401
sys.path.insert(0, "src")
from pcba import corrected_board
cpl_raw = subprocess.run(["iconv", "-f", "UTF-16", "-t", "UTF-8", "../manufacturing/R1-WIP/cpl.csv"], capture_output=True, text=True).stdout
cpl = {r["Designator"]: r for r in csv.DictReader(io.StringIO(cpl_raw), delimiter="\t")}
parts = corrected_board()
seen = {}
for p in parts:
    n = str(p.label); b = p.bounding_box()
    seen[n] = b
    print(f"{n:28s} x {b.min.X:7.2f}..{b.max.X:7.2f}  y {b.min.Y:7.2f}..{b.max.Y:7.2f}  z {b.min.Z:6.3f}..{b.max.Z:6.3f}")
names = {n.split("_")[0].split(" ")[0] for n in seen}
print("CPL rows without a 3D body:", sorted(d for d in cpl if not any(n.startswith(d + "_") or n == d or n.startswith(d + " ") for n in seen)))
for d, r in cpl.items():
    m = [n for n in seen if n.startswith(d + "_") or n == d]
    if m:
        b = seen[m[0]]; cx, cy = (b.min.X + b.max.X) / 2, (b.min.Y + b.max.Y) / 2
        mx, my = float(r["Mid X"].rstrip("m")), float(r["Mid Y"].rstrip("m"))
        if abs(cx - mx) > 0.6 or abs(cy - my) > 0.6:
            print(f"offset body vs CPL {d}: body centre ({cx:.2f},{cy:.2f}) CPL ({mx},{my})")
