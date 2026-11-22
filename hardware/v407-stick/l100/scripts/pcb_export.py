#!/usr/bin/env python3
"""Export manufacturing files from the saved PCB (DRC must pass) and unpack the Gerber archive."""
import json, subprocess, sys, zipfile, pathlib
W = pathlib.Path(__file__).resolve().parent.parent
a = json.load(open(W / "scripts/args-export.json"))
a["jobs"] = ["gerber", "bom", "bomx", "cpl", "cplx", "netlist", "ipc", "step"]
subprocess.run([str(W / "scripts/eda.sh"), str(W / "scripts/30-export.js"), json.dumps(a), "300000"], check=False)
v = json.load(open(W / "evidence/30-export.json"))
files = (v.get("value") or {}).get("files", [])
for f in files:
    print(f.get("name"), f.get("size"), f.get("saved"), f.get("error") or "")
ok = v.get("ok") and (v["value"].get("drc") is True) and all(f.get("saved") is True for f in files)
out = pathlib.Path(a["outDir"]) / "gerber"
out.mkdir(exist_ok=True)
z = zipfile.ZipFile(pathlib.Path(a["outDir"]) / "gerber.zip")
for i in z.infolist():
    name = i.filename
    if not (i.flag_bits & 0x800):
        try:
            name = name.encode("cp437").decode("utf-8")
        except Exception:
            pass
    (out / pathlib.Path(name).name).write_bytes(z.read(i))
sys.exit(0 if ok else 1)
