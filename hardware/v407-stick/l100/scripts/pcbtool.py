"""Offline PCB planning model for WiredKVM-V407-Stick: placement, tracks, vias, checks and preview.

Units are mm. Board frame: x across the width (centre 0), y along the length from the plug end (0) to the
receptacle end (L). Rotation is counter-clockwise, same as the 嘉立创EDA PCB editor (measured: 22-rot-probe).
Footprint geometry comes from the real imported parts (scripts/pcb_footprints.json), never from memory.
"""
import json, math, pathlib
from shapely.geometry import Polygon, LineString, Point, box
from shapely.ops import unary_union

HERE = pathlib.Path(__file__).resolve().parent
FP = json.load(open(HERE / "pcb_footprints.json"))
TOP, BOT = 1, 2


def rot(x, y, deg):
    d = deg % 360
    if d == 0: return x, y
    if d == 90: return -y, x
    if d == 180: return -x, -y
    if d == 270: return y, -x
    r = math.radians(deg)
    return x * math.cos(r) - y * math.sin(r), x * math.sin(r) + y * math.cos(r)


class Board:
    def __init__(self, width, length):
        self.W, self.L = width, length
        self.place = {}      # ref -> (x, y, rot)
        self.tracks = []     # dict(net, layer, w, pts)
        self.vias = []       # dict(net, x, y, drill, dia)
        self.fills = []      # dict(net, layer, kind, ...) exposed copper discs for test pads
        self.pad_net_override = {}  # (ref, padnumber) -> net, for planned schematic changes
        self.corner = 1.0           # board corner radius
        self.top_pour = [(-width / 2, 0), (width / 2, 0), (width / 2, length), (-width / 2, length)]  # top ground pour outline
        self.texts = []             # silkscreen strings: dict(layer, x, y, text, size, stroke, rot, align, mirror)

    # ---- placement ----
    def put(self, ref, x, y, r=0):
        assert ref in FP, ref
        self.place[ref] = (x, y, r % 360)

    def pads(self, ref):
        x0, y0, r = self.place[ref]
        out = []
        for q in FP[ref]["pads"]:
            dx, dy = rot(q["x"], q["y"], r)
            w, h = q["w"], q["h"]
            if (q["rot"] + r) % 180 == 90:
                w, h = h, w
            d = dict(ref=ref, n=q["n"], x=x0 + dx, y=y0 + dy, w=w, h=h, kind=q["kind"], layer=q["layer"],
                     net=self.pad_net_override.get((ref, q["n"]), q["net"]), hole=q.get("hole"))
            if q["kind"] == "POLYGON":
                d["poly"] = [(x0 + a, y0 + b) for a, b in (rot(px, py, r) for px, py in q["poly"])]
            out.append(d)
        return out

    def P(self, name, which=0):
        """Pad centre by 'REF.NUM'. `which` picks among pads sharing a number (sorted by x then y)."""
        ref, num = name.split(".")
        c = sorted((p for p in self.pads(ref) if p["n"] == num), key=lambda p: (round(p["x"], 3), round(p["y"], 3)))
        assert c, name
        return c[which]["x"], c[which]["y"]

    def bbox(self, ref):
        x0, y0, r = self.place[ref]
        b = FP[ref]["bbox"]
        c = [rot(b[0], b[1], r), rot(b[2], b[3], r)]
        xs, ys = [p[0] for p in c], [p[1] for p in c]
        return x0 + min(xs), y0 + min(ys), x0 + max(xs), y0 + max(ys)

    # ---- copper ----
    def track(self, net, pts, w=0.2, layer=TOP):
        pts = [(round(float(x), 4), round(float(y), 4)) for x, y in pts]
        clean = [pts[0]]
        for p in pts[1:]:
            if p != clean[-1]:
                clean.append(p)
        assert len(clean) >= 2, (net, pts)
        self.tracks.append(dict(net=net, layer=layer, w=w, pts=clean))

    def via(self, net, x, y, drill=0.3, dia=0.6):
        self.vias.append(dict(net=net, x=round(float(x), 4), y=round(float(y), 4), drill=drill, dia=dia))

    def disc(self, net, x, y, dia, layer=TOP):
        self.fills.append(dict(net=net, layer=layer, x=round(float(x), 4), y=round(float(y), 4), dia=dia))

    # ---- geometry for checks ----
    @staticmethod
    def pad_shape(p):
        if p["kind"] == "POLYGON":
            return Polygon(p["poly"])
        if p["kind"] in ("ELLIPSE", "OVAL") and abs(p["w"] - p["h"]) < 1e-6:
            return Point(p["x"], p["y"]).buffer(p["w"] / 2, 16)
        if p["kind"] == "OVAL":
            r = min(p["w"], p["h"]) / 2
            if p["w"] > p["h"]:
                return LineString([(p["x"] - p["w"] / 2 + r, p["y"]), (p["x"] + p["w"] / 2 - r, p["y"])]).buffer(r, 16)
            return LineString([(p["x"], p["y"] - p["h"] / 2 + r), (p["x"], p["y"] + p["h"] / 2 - r)]).buffer(r, 16)
        return box(p["x"] - p["w"] / 2, p["y"] - p["h"] / 2, p["x"] + p["w"] / 2, p["y"] + p["h"] / 2)

    def copper(self):
        """List of (net, layer, shape, label). Layer 12 pads appear on both copper layers."""
        out = []
        for ref in self.place:
            for p in self.pads(ref):
                s = self.pad_shape(p)
                for ly in ((TOP, BOT) if p["layer"] == 12 else (p["layer"],)):
                    out.append((p["net"], ly, s, f"{ref}.{p['n']}"))
        for i, t in enumerate(self.tracks):
            out.append((t["net"], t["layer"], LineString(t["pts"]).buffer(t["w"] / 2, 8), f"track{i}:{t['net']}"))
        for v in self.vias:
            c = Point(v["x"], v["y"]).buffer(v["dia"] / 2, 16)
            out.append((v["net"], TOP, c, f"via:{v['net']}@{v['x']},{v['y']}"))
            out.append((v["net"], BOT, c, f"via:{v['net']}@{v['x']},{v['y']}"))
        for f in self.fills:
            out.append((f["net"], f["layer"], Point(f["x"], f["y"]).buffer(f["dia"] / 2, 24), f"disc:{f['net']}"))
        return out

    def check(self, clearance=0.153, edge=0.3, verbose=True):
        cu = self.copper()
        problems = []
        for ly in (TOP, BOT):
            items = [c for c in cu if c[1] == ly]
            for i in range(len(items)):
                for j in range(i + 1, len(items)):
                    a, b = items[i], items[j]
                    if a[0] == b[0] and a[0] != "":
                        continue
                    if a[3].split(".")[0] == b[3].split(".")[0] and "." in a[3] and "." in b[3]:
                        continue  # pads of the same part
                    d = a[2].distance(b[2])
                    both_tracks = a[3].startswith("track") and b[3].startswith("track")
                    if d < (0.149 if both_tracks else clearance):
                        problems.append(f"L{ly} clearance {d:.3f} {a[3]}[{a[0]}] <> {b[3]}[{b[0]}]")
        outline = box(-self.W / 2 + edge, edge, self.W / 2 - edge, self.L - edge)
        for net, ly, s, label in cu:
            if label.startswith(("J1.", "J2.")):
                continue  # connector pads sit at the edge by design
            if not outline.contains(s):
                problems.append(f"edge: {label} outside {edge} mm inset")
        for i in range(len(self.vias)):                       # two drills in the same place (EDA: hole-to-hole)
            for j in range(i + 1, len(self.vias)):
                a, c = self.vias[i], self.vias[j]
                d = math.hypot(a["x"] - c["x"], a["y"] - c["y"]) - (a["drill"] + c["drill"]) / 2
                if d < 0.3:
                    problems.append(f"holes {d:.2f} mm apart: via {a['net']}@{a['x']},{a['y']} <> via {c['net']}@{c['x']},{c['y']}")
        # connectivity per net (GND excluded: it is completed by the pours and checked by the EDA DRC)
        nets = {}
        for net, ly, s, label in cu:
            if net and net != "GND":
                nets.setdefault(net, []).append((ly, s, label))
        for net, items in sorted(nets.items()):
            parent = list(range(len(items)))
            def find(a):
                while parent[a] != a:
                    parent[a] = parent[parent[a]]; a = parent[a]
                return a
            for i in range(len(items)):
                for j in range(i + 1, len(items)):
                    if items[i][0] == items[j][0] and items[i][1].intersects(items[j][1]):
                        parent[find(i)] = find(j)
                    elif items[i][2].startswith("via") and items[i][2] == items[j][2]:
                        parent[find(i)] = find(j)
            groups = {}
            for i, it in enumerate(items):
                if "." in it[2] and not it[2].startswith(("track", "via", "disc")):
                    groups.setdefault(find(i), []).append(it[2])
            roots = {find(i) for i in range(len(items))}
            if len(roots) > 1:
                problems.append(f"open net {net}: " + " | ".join(",".join(sorted(g)) for g in groups.values()))
        # part overlap by pad-union bounding boxes on the same side
        boxes = {}
        for ref in self.place:
            ps = self.pads(ref)
            boxes[ref] = unary_union([self.pad_shape(p) for p in ps]).envelope
        refs = sorted(r for r in boxes if r not in getattr(self, "bodies", {}))   # parts with a body box are checked above
        for i in range(len(refs)):
            for j in range(i + 1, len(refs)):
                d = boxes[refs[i]].distance(boxes[refs[j]])
                if d < 0.15:
                    problems.append(f"parts close {d:.2f}: {refs[i]} {refs[j]}")
        # pads of different parts need a solder-mask dam between them (0.05 mm mask expansion each side + 0.1 mm web);
        # the copper clearance rule alone (0.153 mm) lets the two mask openings merge
        allpads = [(ref, p, self.pad_shape(p)) for ref in self.place if not ref.startswith("TP") for p in self.pads(ref)]
        for i in range(len(allpads)):
            for j in range(i + 1, len(allpads)):
                (ra, pa, sa), (rb, pb, sb) = allpads[i], allpads[j]
                if ra == rb:
                    continue
                d = sa.distance(sb)
                if d < 0.21:
                    problems.append(f"mask dam: pads {ra}.{pa['n']}[{pa['net']}] and {rb}.{pb['n']}[{pb['net']}] only {d:.3f} mm apart")
        # a via ring touching or almost touching an SMD pad draws solder off the pad
        for v in self.vias:
            c = Point(v["x"], v["y"])
            for ref, pd, shape in allpads:
                if pd.get("hole"):
                    continue
                if pd["net"] == v["net"] and shape.area > 9 and shape.contains(c.buffer(v["dia"] / 2)):
                    continue  # via inside a large exposed pad of its own net (QFN centre pad): intended
                d = c.distance(shape) - v["dia"] / 2
                if d < 0.2:
                    problems.append(f"via {v['net']}@{v['x']},{v['y']} only {d:.2f} mm from pad {ref}.{pd['n']}")
        # test discs on different nets: a probe slip or a solder blob must not join them
        for i in range(len(self.fills)):
            for j in range(i + 1, len(self.fills)):
                a, c = self.fills[i], self.fills[j]
                d = math.hypot(a["x"] - c["x"], a["y"] - c["y"]) - (a["dia"] + c["dia"]) / 2
                if a["net"] != c["net"] and d < 0.6:
                    problems.append(f"test discs {a['net']} and {c['net']} only {d:.2f} mm apart")
        # exposed test-pad discs must not merge with a pad of another part (solder would be drawn off that pad)
        discs = [(f, Point(f["x"], f["y"]).buffer(f["dia"] / 2, 24)) for f in self.fills]
        for ref in self.place:
            if ref.startswith("TP"):
                continue
            for p in self.pads(ref):
                for f, shape in discs:
                    d = shape.distance(self.pad_shape(p))
                    if d < 0.25:
                        problems.append(f"disc {f['net']} only {d:.2f} mm from pad {ref}.{p['n']}")
        # pads of other parts must stay clear of declared package bodies (the EDA DRC does not check bodies)
        for ref, (hw, hh) in getattr(self, "bodies", {}).items():
            x, y, r = self.place[ref]
            if r % 180 == 90:
                hw, hh = hh, hw
            body = box(x - hw, y - hh, x + hw, y + hh)
            for other in self.place:
                if other == ref:
                    continue
                for p in self.pads(other):
                    d = body.distance(self.pad_shape(p))
                    if d < 0.2:
                        problems.append(f"pad {other}.{p['n']} only {d:.2f} mm from the body of {ref}")
        # declared package bodies must stay inside the board with a margin (depanelling, handling)
        inset = box(-self.W / 2 + 0.45, 0.45, self.W / 2 - 0.45, self.L - 0.45)
        for ref, (hw, hh) in getattr(self, "bodies", {}).items():
            x, y, r = self.place[ref]
            if r % 180 == 90:
                hw, hh = hh, hw
            if not inset.contains(box(x - hw, y - hh, x + hw, y + hh)):
                problems.append(f"edge: body of {ref} closer than 0.45 mm to the board edge")
        if verbose:
            print(f"check: {len(problems)} problem(s)")
            for p in problems:
                print("  -", p)
        return problems

    def net_length(self, net):
        import math
        return sum(math.dist(t["pts"][i], t["pts"][i + 1]) for t in self.tracks if t["net"] == net for i in range(len(t["pts"]) - 1))

    # ---- preview ----
    def render(self, path, region=None, scale=40, show_bottom=True, labels=True):
        from PIL import Image, ImageDraw, ImageFont
        x0, y0, x1, y1 = region or (-self.W / 2 - 1, -1 - 12.5, self.W / 2 + 1, self.L + 1)
        Wp, Hp = int((x1 - x0) * scale), int((y1 - y0) * scale)
        img = Image.new("RGB", (Wp, Hp), (16, 20, 16))
        d = ImageDraw.Draw(img, "RGBA")
        T = lambda x, y: ((x - x0) * scale, (y1 - y) * scale)
        try:
            font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", max(9, int(scale * 0.32)))
        except Exception:
            font = ImageFont.load_default()
        d.rectangle([T(-self.W / 2, self.L), T(self.W / 2, 0)], fill=(8, 60, 30), outline=(255, 255, 0))
        for g in range(int(x0), int(x1) + 1):
            d.line([T(g, y0), T(g, y1)], fill=(255, 255, 255, 14 if g % 5 else 40))
        for g in range(int(y0), int(y1) + 1):
            d.line([T(x0, g), T(x1, g)], fill=(255, 255, 255, 14 if g % 5 else 40))
        def poly(shape, fill, outline=None):
            for g in getattr(shape, "geoms", [shape]):
                if g.is_empty: continue
                d.polygon([T(*c) for c in g.exterior.coords], fill=fill, outline=outline)
        colors = {}
        def net_color(net):
            if net == "GND": return (120, 120, 120)
            if net == "": return (70, 70, 70)
            if net not in colors:
                h = (hash(net) * 2654435761) & 0xFFFFFF
                colors[net] = (90 + (h & 0x7F), 90 + ((h >> 8) & 0x7F), 90 + ((h >> 16) & 0x7F))
            return colors[net]
        if show_bottom:
            for t in self.tracks:
                if t["layer"] == BOT:
                    poly(LineString(t["pts"]).buffer(t["w"] / 2, 4), (60, 110, 255, 170))
        for ref in self.place:
            b = self.bbox(ref)
            d.rectangle([T(b[0], b[3]), T(b[2], b[1])], outline=(255, 255, 255, 70))
        for ref in self.place:
            for p in self.pads(ref):
                poly(self.pad_shape(p), net_color(p["net"]) + (255,), (0, 0, 0))
        for t in self.tracks:
            if t["layer"] == TOP:
                poly(LineString(t["pts"]).buffer(t["w"] / 2, 4), net_color(t["net"]) + (215,))
        for f in self.fills:
            poly(Point(f["x"], f["y"]).buffer(f["dia"] / 2, 24), net_color(f["net"]) + (230,), (255, 255, 255))
        for v in self.vias:
            poly(Point(v["x"], v["y"]).buffer(v["dia"] / 2, 16), (230, 200, 60, 255))
            poly(Point(v["x"], v["y"]).buffer(v["drill"] / 2, 12), (0, 0, 0, 255))
        if labels:
            for ref in self.place:
                x, y, r = self.place[ref]
                d.text(T(x, y), ref, fill=(255, 255, 255), font=font, anchor="mm")
        img.save(path)
        return path

    @staticmethod
    def _poly_src(pts, k):
        src = [round(pts[0][0] * k, 3), round(pts[0][1] * k, 3), "L"]
        for x, y in list(pts[1:]) + [pts[0]]:
            src += [round(x * k, 3), round(y * k, 3)]
        return src

    # ---- export for the EDA apply script (mil) ----
    def export(self):
        k = 1 / 0.0254
        return dict(
            board=dict(W=self.W, L=self.L),
            parts=[dict(ref=r, x=round(x * k, 3), y=round(y * k, 3), rot=rt,
                        pads=[dict(n=p["n"], x=round(p["x"] * k, 3), y=round(p["y"] * k, 3), net=p["net"]) for p in self.pads(r)])
                   for r, (x, y, rt) in self.place.items()],
            outline=dict(src=["R", round(-self.W / 2 * k, 3), round(self.L * k, 3), round(self.W * k, 3), round(self.L * k, 3), 0, round(self.corner * k, 3)]),
            pours=[dict(net="GND", layer=1, name="GND_TOP", priority=1, src=self._poly_src(self.top_pour, k)),
                   dict(net="GND", layer=2, name="GND_BOT", priority=1,
                        src=["R", round(-self.W / 2 * k, 3), round(self.L * k, 3), round(self.W * k, 3), round(self.L * k, 3), 0, round(self.corner * k, 3)])],
            tracks=[dict(net=t["net"], layer=t["layer"], w=round(t["w"] * k, 3), pts=[[round(x * k, 3), round(y * k, 3)] for x, y in t["pts"]]) for t in self.tracks],
            vias=[dict(net=v["net"], x=round(v["x"] * k, 3), y=round(v["y"] * k, 3), drill=round(v["drill"] * k, 3), dia=round(v["dia"] * k, 3)) for v in self.vias],
            texts=[dict(t, x=round(t['x'] * k, 3), y=round(t['y'] * k, 3), size=round(t['size'] * k, 2), stroke=round(t['stroke'] * k, 2)) for t in self.texts],
            fills=[dict(net=f["net"], layer=f["layer"], x=round(f["x"] * k, 3), y=round(f["y"] * k, 3), dia=round(f["dia"] * k, 3)) for f in self.fills],
        )
