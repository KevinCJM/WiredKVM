#!/usr/bin/env python3
"""Send scripts/pcb_plan.json to the EDA. Usage: pcb_apply.py [wipe] [place] [outline] [copper] [pour] [silk]"""
import json, subprocess, sys, pathlib
W = pathlib.Path(__file__).resolve().parent.parent
steps = set(sys.argv[1:]) or {"wipe", "place", "outline", "copper", "pour", "silk"}
dev = json.load(open(W / "scripts/devices.json"))
args = dict(projectUuid=dev["projectUuid"], pcbUuid="b548f4f398f3a4f4", plan=json.load(open(W / "scripts/pcb_plan.json")), **{s: True for s in steps})
r = subprocess.run([str(W / "scripts/eda.sh"), str(W / "scripts/23-apply-pcb.js"), json.dumps(args, ensure_ascii=True), "600000"], capture_output=True, text=True)
print(r.stdout.strip(), r.stderr.strip()[:300])
v = json.load(open(W / "evidence/23-apply-pcb.json"))
print(json.dumps(v, ensure_ascii=False)[:1500])
sys.exit(0 if v.get("ok") and v["value"].get("saved") is True else 1)
