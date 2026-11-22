#!/usr/bin/env python3
"""run_page.py <wipe|apply> <page-index>: wipe or apply one page of scripts/plan.json through eda.sh."""
import json, subprocess, sys, pathlib
W = pathlib.Path(__file__).resolve().parent.parent
PROJECT = "632e9e4e6157050ddba62fba214f10b5f54447076891210e819443a8e8343fab"
PAGES = ["c8eb732cdc837b77", "da540112c708b107"]
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
