#!/usr/bin/env python3
"""Summarise the DRC detail tree saved by 24-verify-pcb.js."""
import json, sys, pathlib, collections
W = pathlib.Path(__file__).resolve().parent.parent
v = json.load(open(sys.argv[1] if len(sys.argv) > 1 else W / "evidence/24-verify-pcb.json"))["value"]
print("drc pass:", v.get("drc"))
n = 0
def walk(node, path):
    global n
    if "list" in node:
        for c in node["list"]:
            walk(c, path + [node.get("name", "?")])
    else:
        n += 1
        e = node.get("explanation", {}); prm = e.get("param", {})
        o1, o2 = node.get("obj1", {}), node.get("obj2", {})
        pos = node.get("pos") or {}
        print("  %-40s %s%s | %s%s | %s -> %s | (%.2f, %.2f) mm %s" % (" / ".join(path[-2:]), o1.get("typeName", ""), o1.get("suffix", ""), o2.get("typeName", ""), o2.get("suffix", ""),
              prm.get("minDistance", prm.get("actual", "")), prm.get("shouldBe", ""), (pos.get("x") or 0) * 0.254, (pos.get("y") or 0) * 0.254, node.get("layer", "")))
for top in v.get("drcDetails") or []:
    walk(top, [])
print("violations:", n)
