#!/usr/bin/env python3
"""Cross-check the exported manufacturing files against the plan and the intended netlist with independent parsers.
Run with the workspace venv: .venv/bin/python scripts/export_check.py [export-dir]"""
import csv, io, json, pathlib, sys, collections, math
W = pathlib.Path(__file__).resolve().parent.parent
D = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else W / "manufacturing/R1-WIP"
sys.path.insert(0, str(W / "scripts"))
import netlist_truth
plan = json.load(open(W / "scripts/pcb_plan.json"))
ok = True
def check(cond, msg):
    global ok
    print(("PASS " if cond else "FAIL ") + msg)
    ok &= bool(cond)

# ---- BOM: every fitted part once, with the supplier number of the intended netlist ----
rows = list(csv.DictReader(io.StringIO((D / "bom.csv").read_bytes().decode("utf-16")), delimiter="\t"))
bom = {}
for r in rows:
    for ref in r["Designator"].split(","):
        bom[ref.strip()] = r["Supplier Part"]
want = {k: v for k, v in netlist_truth.PARTS.items() if v}
check(bom == want, f"BOM: {len(bom)} fitted parts, {len(rows)} lines, supplier numbers equal the intended list")
if bom != want:
    print("   diff:", {k: (bom.get(k), want.get(k)) for k in set(bom) | set(want) if bom.get(k) != want.get(k)})
check(sum(int(r["Quantity"]) for r in rows) == len(want), "BOM: quantities add up to the part count")

# ---- CPL: position and rotation of every part equal the plan ----
cpl = {r["Designator"]: r for r in csv.DictReader(io.StringIO((D / "cpl.csv").read_bytes().decode("utf-16")), delimiter="\t")}
bad = []
for q in plan["parts"]:
    r = cpl.get(q["ref"])
    if not r:
        bad.append((q["ref"], "missing")); continue
    x, y = float(r["Ref X"].replace("mm", "")), float(r["Ref Y"].replace("mm", ""))
    if abs(x - q["x"] * 0.0254) > 0.02 or abs(y - q["y"] * 0.0254) > 0.02 or int(float(r["Rotation"])) % 360 != q["rot"] or r["Layer"] != "T":
        bad.append((q["ref"], x, y, r["Rotation"], r["Layer"]))
check(not bad and len(cpl) == len(plan["parts"]), f"CPL: {len(cpl)} rows, origin/rotation/side equal the plan" + (f" {bad[:5]}" if bad else ""))

# ---- Gerber / drill with gerbonara ----
from gerbonara import GerberFile, ExcellonFile
g = D / "gerber"
def bbox(f):
    (x0, y0), (x1, y1) = f.bounding_box(unit="mm") if hasattr(f, "bounding_box") else ((0, 0), (0, 0))
    return x0, y0, x1, y1
ko = GerberFile.open(g / "Gerber_BoardOutlineLayer.GKO")
x0, y0, x1, y1 = bbox(ko)
w, h = x1 - x0, y1 - y0
BW, BL = plan["board"]["W"], plan["board"]["L"]
check(abs(w - BW - 0.254) < 0.05 and abs(h - BL - 0.254) < 0.05, f"outline: {w:.3f} x {h:.3f} mm including the 0.254 mm line (board {BW:g} x {BL:g})")
off = (x0 + x1) / 2, y0 + 0.127          # Gerber offset of the board frame (centre x, bottom edge)
holes = {}
for name in ("Drill_PTH_Through_Via.DRL", "Drill_PTH_Through.DRL", "Drill_NPTH_Through.DRL"):
    e = ExcellonFile.open(g / name)
    objs = list(e.objects)
    holes[name] = objs
    sizes = collections.Counter((type(o).__name__, round(o.unit.convert_to("mm", o.tool.diameter), 3)) for o in objs)
    print(f"     {name}: {len(objs)} objects, tools {dict(sizes)}")
check(len(holes["Drill_PTH_Through_Via.DRL"]) == len(plan["vias"]), f"drill: {len(plan['vias'])} vias in the plan = via drill hits")
check(len(holes["Drill_NPTH_Through.DRL"]) == 2, "drill: 2 non-plated holes (receptacle pegs)")
tl = GerberFile.open(g / "Gerber_TopLayer.GTL")
bl = GerberFile.open(g / "Gerber_BottomLayer.GBL")
for nm, f in (("top copper", tl), ("bottom copper", bl)):
    a0, b0, a1, b1 = bbox(f)
    check(a0 >= x0 + 0.3 and a1 <= x1 - 0.3 and b0 >= y0 + 0.2 and b1 <= y1 - 0.3, f"{nm}: inside the outline with margin ({a0 - x0:.2f}/{x1 - a1:.2f}/{b0 - y0:.2f}/{y1 - b1:.2f} mm)")
paste = GerberFile.open(g / "Gerber_TopPasteMaskLayer.GTP")
n_paste = sum(1 for o in paste.objects)
print(f"     top paste objects: {n_paste}; top silk objects: {sum(1 for _ in GerberFile.open(g / 'Gerber_TopSilkscreenLayer.GTO').objects)}")
check(not (g / "Gerber_BottomPasteMaskLayer.GBP").exists(), "no bottom paste layer (single-side assembly)")
for nm in ("Gerber_TopLayer.GTL", "Gerber_BottomLayer.GBL", "Gerber_BottomSilkscreenLayer.GBO", "Gerber_TopSilkscreenLayer.GTO", "Gerber_BoardOutlineLayer.GKO", "Gerber_TopSolderMaskLayer.GTS", "Gerber_TopPasteMaskLayer.GTP"):
    out = W / "evidence/gerber-svg"; out.mkdir(exist_ok=True)
    (out / (nm + ".svg")).write_text(str(GerberFile.open(g / nm).to_svg(fg="black", bg="white")))
print("OVERALL", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
