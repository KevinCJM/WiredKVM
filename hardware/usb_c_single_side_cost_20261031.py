"""Planning model only: public tax-inclusive JLC material prices, no orders.

Reuses the prior candidate BOM quantities without importing its executable model.
No hardware, EDA project, or running application is changed.
"""
from pathlib import Path
from decimal import Decimal, ROUND_CEILING
import csv
import json
import re

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "results"
D = lambda value: Decimal(str(value))
BASE = json.loads((OUT / "ch32v407-complete-cost-model-20261031.json").read_text())
CAPTURE = json.loads((OUT / "usb-c-single-side-public-ui-20261031.json").read_text())
PRICE_FILES = ["v407_periph_prices1", "v407_periph_prices2", "v407_periph_prices3",
               "v407_periph_metadata", "v407_refresh", "v407_periph_prices4"]
items = {}
for name in PRICE_FILES:
    data = json.loads((OUT / f"ch32v407-audit-20261031-{name}.json").read_text())
    for result in data.get("results", []):
        for item in result.get("items", []):
            items[item["code"]] = item

plug_ui = next(c for c in CAPTURE["captures"] if c["key"] == "single_side_C3039316_ui")
assert "价格(含税)" in plug_ui["text"]
assert "标准型SMT专用" in plug_ui["text"]
plug_tiers = [(int(q), D(p)) for q, p in re.findall(
    r"(\d+)\+\s*：\s*¥([0-9.]+)", plug_ui["text"].split("整盘单价")[0])]
assert plug_tiers == [(1,D("2.22")),(10,D("1.98")),(30,D("1.86")),
                      (100,D("1.746")),(500,D("1.674")),(1000,D("1.638"))]

def material_rows(n):
    rows = []
    for old in BASE["materials"]["10"]["rows"]:
        code = old["code"]
        qty = old["per_board_qty"]
        buy = int((D(n)*qty*D("1.05")).to_integral_value(rounding=ROUND_CEILING))
        if code == "C3151751":
            code, model, purpose = "C3039316", "TC-002", "单排 SMT 公头；沉板工艺仍须审核"
            unit = max((q,p) for q,p in plug_tiers if q <= buy)[1]
            stock, price_kind = 1048, "public_tier_including_tax"
        else:
            item = items[code]
            matches = [p for p in item["priceList"] if p["startNumber"] <= buy
                       and (p["endNumber"] == -1 or p["endNumber"] >= buy)]
            assert len(matches) == 1, (code,buy)
            unit = D(matches[0]["productPrice"])
            model, purpose, stock = item["model"], old["purpose"], item.get("stockNum")
            price_kind = "reference_supply_unconfirmed" if code == "C54937001" else "public_tier_including_tax"
        rows.append(dict(code=code, model=model, purpose=purpose, group=old["group"],
                         per_board_qty=qty, buy_qty=buy, unit_CNY=float(unit),
                         allocated_CNY=float(unit*buy/n), price_kind=price_kind,
                         displayed_stock_NOT_reserved=stock,
                         source=f"https://www.jlc-smt.com/lcsc/search?q={code}"))
    return rows

def case(n):
    rows = material_rows(n)
    material = sum(D(r["allocated_CNY"]) for r in rows)
    # 12 plug signal pads + 4 shell/tab solder areas conservatively counted.
    # Estimated netlist count only; not a manufacturer assembly quotation.
    points = 265-28+16
    types = len(rows)
    assert types == 19 and points == 253
    fixed = D(150+50+8*types)
    assembly = (fixed/n+D(points)*D(".01"))*D("1.13")
    if n < 1000:
        # Same prototype PCB/test allowances as the earlier audit.
        # Only explicitly order-level shipping and fixture costs are divided.
        extras = dict(PCB=(D(4),D(8)), burn_and_test=(D(3),D(6)),
                      packaging_and_freight=(D(10)/n,D(20)/n),
                      assembly_fixture=(D(0),D(50)/n),
                      electrical_process_contingency=(D(1),D(2)))
    else:
        extras = dict(PCB=(D("1.5"),D(3)), burn_and_test=(D(1),D(2)),
                      packaging_and_freight=(D(".2"),D(".5")),
                      assembly_fixture=(D(".05"),D(".2")),
                      electrical_process_contingency=(D(".5"),D("1.5")))
    low = material+assembly+sum(v[0] for v in extras.values())
    high = material+assembly+sum(v[1] for v in extras.values())
    groups = {g:float(sum(D(r["allocated_CNY"]) for r in rows if r["group"]==g))
              for g in sorted({r["group"] for r in rows})}
    return dict(boards=n, materials=rows, material_total_CNY=float(material), material_groups_CNY=groups,
                estimated_solder_points=points, material_tax_added_again=0,
                assembly_fixed_order_CNY_before_tax=float(fixed),
                assembly_CNY_with_13pct_reserve=float(assembly),
                extra_tax_inclusive_allowances_CNY={k:[float(x) for x in v] for k,v in extras.items()},
                total_per_board_CNY=[float(low),float(high)],
                total_order_CNY=[float(low*n),float(high*n)],
                supply_confirmed=False, single_face_factory_process_approved=False)

result = dict(date="2026-10-31", currency="CNY", quote=False,
              candidate="CH32V407VET6 + TC-002 single-face standard SMT",
              scope="PCBA planning only; no PCB designed, no procurement or firmware changes",
              excludes=["R&D", "certification", "case", "external cable", "commercial USB VID", "initial test-fixture development"],
              quantities_note="10 and 1000 are the prior working basis; 50 is an optional batch comparison, not user approval",
              material_tax_note="Public JLC UI confirms inclusive tax; previous extra material VAT reserve removed",
              reserves_note="5% extra component quantities; PCB/test/fixture/electrical allowances are not factory quotes; no coupon or speculative reel discount",
              source_snapshot="usb-c-single-side-public-ui-20261031.json",
              cases=[case(n) for n in (10,50,1000)])
path=OUT/"usb-c-single-side-cost-model-20261031.json"
path.write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n")
with (ROOT/"hardware/USB_C_SINGLE_SIDE_BOM_CNY_20261031.csv").open("w",newline="",encoding="utf-8-sig") as f:
    fields=["boards"]+list(result["cases"][0]["materials"][0])
    writer=csv.DictWriter(f,fieldnames=fields)
    writer.writeheader()
    for c in result["cases"]:
        for row in c["materials"]:writer.writerow({"boards":c["boards"],**row})
print(json.dumps([{k:v for k,v in c.items() if k!="materials"} for c in result["cases"]],ensure_ascii=False,indent=2))
