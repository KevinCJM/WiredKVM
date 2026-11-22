"""Parser for the text source of a 嘉立创EDA .epcb2/.esch2 file: one record per line, `head||body|`."""
import json, pathlib

PROJ = pathlib.Path.home() / "Documents/LCEDA-Pro/projects/WiredKVM-V407-Stick-L100"
PCB = PROJ / "pcb/PCB1.epcb2"


def load(path=PCB):
    docs, cur = [], None
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line:
            continue
        head, _, body = line.partition("||")
        h = json.loads(head)
        body = body.rstrip("|")
        b = json.loads(body) if body else None
        if h["type"] == "DOCHEAD":
            cur = {"head": b, "recs": [], "title": None}
            docs.append(cur)
        else:
            if h["type"] == "META":
                cur["title"] = b.get("title")
            cur["recs"].append((h, b))
    return docs


def doc(docs, doc_type, title=None):
    for d in docs:
        if d["head"].get("docType") == doc_type and (title is None or d["title"] == title):
            return d
    raise KeyError((doc_type, title))
