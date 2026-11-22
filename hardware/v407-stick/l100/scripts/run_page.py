#!/usr/bin/env python3
"""run_page.py <wipe|apply> <page-index>: wipe or apply one page of scripts/plan.json through eda.sh."""
import json, subprocess, sys, pathlib
W = pathlib.Path(__file__).resolve().parent.parent
PROJECT = "94f35adb35c439ffbcf785c5e803473490ef833fa41d51fc5024a0c86c543723"
PAGES = ["f4dfc3117690325d", "1503672ef7465fb0"]
mode, idx = sys.argv[1], int(sys.argv[2])
args = dict(projectUuid=PROJECT, schPageUuid=PAGES[idx])
script = "08-wipe-page.js"
if mode == "apply":
    args["plan"] = json.load(open(W / "scripts/plan.json"))["pages"][idx]
    script = "12-apply-page.js"
# ensure_ascii: raw UTF-8 in argv got one character mangled to U+FFFD on the way into the editor
r = subprocess.run([str(W / "scripts/eda.sh"), str(W / "scripts" / script), json.dumps(args, ensure_ascii=True), "600000"],
                   capture_output=True, text=True)
print(r.stdout.strip(), r.stderr.strip())
ev = W / "evidence" / (script[:-3] + ".json")
keep = W / "evidence" / f"{script[:-3]}-p{idx + 1}.json"
keep.write_bytes(ev.read_bytes())
print(ev.read_text()[:1500])
