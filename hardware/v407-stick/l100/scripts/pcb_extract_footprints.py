#!/usr/bin/env python3
"""Turn the EDA readback of the imported PCB parts (evidence/20-import-pcb.json) into pad geometry in mm,
relative to each part origin at rotation 0. This is the only footprint source used by pcbtool.py."""
import json, pathlib

W = pathlib.Path(__file__).resolve().parent.parent
M = 0.0254
v = json.load(open(W / "evidence/20-import-pcb.json"))["value"]
fp = {}
def unrot(x, y, deg):
    d = deg % 360
    return {0: (x, y), 90: (y, -x), 180: (-x, -y), 270: (-y, x)}[d]


for p in v["parts"]:
    R = round(p["rotation"] / 90) * 90 % 360          # parts may already be placed; undo their rotation
    assert abs(p["rotation"] - round(p["rotation"] / 90) * 90) < 1e-6, (p["ref"], p["rotation"])
    pads = []
    for q in p["pads"]:
        sh = q["pad"]
        ux, uy = unrot(q["x"] - p["x"], q["y"] - p["y"], R)
        d = dict(n=q["padNumber"], x=round(ux * M, 4), y=round(uy * M, 4), kind=sh[0],
                 rot=round(q["rotation"] - R) % 360, layer=q["layer"], net=q["net"])
        if sh[0] == "POLYGON":
            pts = [c for c in sh[1] if isinstance(c, (int, float))]
            d["poly"] = [[round(c * M, 4) for c in unrot(pts[i] - p["x"], pts[i + 1] - p["y"], R)] for i in range(0, len(pts), 2)]
            xs, ys = [a for a, _ in d["poly"]], [b for _, b in d["poly"]]
            d["w"], d["h"] = round(max(xs) - min(xs), 4), round(max(ys) - min(ys), 4)
        else:
            d["w"], d["h"] = round(sh[1] * M, 4), round(sh[2] * M, 4)
        if q["hole"]:
            d["hole"] = [q["hole"][0], round(q["hole"][1] * M, 4), round(q["hole"][2] * M, 4)]
        pads.append(d)
    b = p["bbox"]
    c = [unrot(b["minX"] - p["x"], b["minY"] - p["y"], R), unrot(b["maxX"] - p["x"], b["maxY"] - p["y"], R)]
    fp[p["ref"]] = dict(id=p["id"], pads=pads, bbox=[round(min(c[0][0], c[1][0]) * M, 3), round(min(c[0][1], c[1][1]) * M, 3),
                                                      round(max(c[0][0], c[1][0]) * M, 3), round(max(c[0][1], c[1][1]) * M, 3)])
# Pad nets must equal the schematic netlist. The editor gives a net to an unconnected pad that old copper touches,
# so extract only from a PCB whose stale copper has been wiped (pcb_apply.py wipe) and re-imported.
sch = {}
for c in json.load(open(W / "evidence/schematic.net.json"))["components"].values():
    for num, pin in c["pinInfoMap"].items():
        sch[(c["props"].get("Designator"), num)] = pin["net"]
bad = [(ref, p["n"], p["net"], sch.get((ref, p["n"]))) for ref, f in fp.items() for p in f["pads"] if sch.get((ref, p["n"])) != p["net"]]
assert not bad, f"pad nets differ from the schematic netlist: {bad[:10]}"
json.dump(fp, open(W / "scripts/pcb_footprints.json", "w"), indent=0)
print(len(fp), "footprints; pad nets equal the schematic netlist")
