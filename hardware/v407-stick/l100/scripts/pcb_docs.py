#!/usr/bin/env python3
"""Refresh the pictures in docs/ and the checksums of the manufacturing files after a rebuild.
Run with the workspace venv after scripts/pcb_rebuild.sh and scripts/29-capture.js:  .venv/bin/python scripts/pcb_docs.py"""
import hashlib, pathlib, shutil, sys, zipfile
W = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(W / "scripts"))
import pcb_layout as PL
import pymupdf

b = PL.b
(W / "docs/pcb").mkdir(parents=True, exist_ok=True)
(W / "docs/schematic").mkdir(parents=True, exist_ok=True)
b.render(W / "docs/pcb/assembly-top.png", region=(-b.W / 2 - 0.5, -0.5, b.W / 2 + 0.5, b.L + 0.5), scale=44)
for f in sorted((W / "evidence/pcb-capture").glob("*.png")):
    if not f.name.startswith("._"):
        shutil.copy(f, W / "docs/pcb" / ("eda-" + f.name))
for nm, out in (("Gerber_TopLayer.GTL", "gerber-top-copper.png"), ("Gerber_BottomLayer.GBL", "gerber-bottom-copper.png"),
                ("Gerber_TopSilkscreenLayer.GTO", "gerber-top-silk.png"), ("Gerber_BottomSilkscreenLayer.GBO", "gerber-bottom-silk.png")):
    pg = pymupdf.open(str(W / "evidence/gerber-svg" / (nm + ".svg")))[0]
    z = 1600 / max(pg.rect.width, pg.rect.height)
    pg.get_pixmap(matrix=pymupdf.Matrix(z, z)).save(str(W / "docs/pcb" / out))
with zipfile.ZipFile(W / "evidence/schematic-png.zip") as z:
    for i in z.infolist():
        name = pathlib.Path(i.filename).name
        out = "MCU.png" if "1-MCU" in name else ("USB_Power.png" if "USB_Power" in name else name)
        (W / "docs/schematic" / out).write_bytes(z.read(i))
shutil.copy(W / "evidence/schematic.net.json", W / "docs/schematic/netlist.json")
m = W / "manufacturing/R1-WIP"
lines = [f"{hashlib.sha256(f.read_bytes()).hexdigest()}  {f.relative_to(m)}"
         for f in sorted(list(m.glob("*")) + list((m / "gerber").glob("*")))
         if f.is_file() and not f.name.startswith("._") and f.name not in ("README.md", "SHA256SUMS.txt")]
(m / "SHA256SUMS.txt").write_text("\n".join(lines) + "\n")
print(len(lines), "manufacturing files hashed;", len(list((W / "docs/pcb").glob("*.png"))), "pictures in docs/pcb")
