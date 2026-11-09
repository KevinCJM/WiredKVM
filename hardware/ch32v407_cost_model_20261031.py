"""Reproduce a planning BOM from public JLC SMT CNY snapshots; NOT a factory quote.

No PCB, firmware, online order, supplier contact, or connected device is changed.
Manufacturing allowances are explicit assumptions. MCU supply remains unresolved.
"""
from pathlib import Path
from decimal import Decimal, ROUND_CEILING
import csv
import json

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "results"
D = lambda v: Decimal(str(v))
snapshot_names = ["v407_periph_prices1", "v407_periph_prices2", "v407_periph_prices3",
                  "v407_periph_metadata", "v407_refresh", "v407_periph_prices4"]
items = {}
for name in snapshot_names:
    obj = json.loads((OUT / f"ch32v407-audit-20261031-{name}.json").read_text())
    for result in obj.get("results", []):
        for item in result.get("items", []):
            items[item["code"]] = item

# Candidate quantities and solder-point counts are cost allowances, not a netlist.
# Pin-level, thermal, signal-integrity and assembly validation remain necessary.
BOM = [
    ("主芯片；供货未确认", "C54937001", 1, 100, "MCU"),
    ("16 MiB 安装资源 Flash", "C49023667", 1, 8, "Flash"),
    ("USB-C 母座", "C165948", 1, 20, "connectors"),
    ("USB-C 夹板公头；工艺待确认", "C3151751", 1, 28, "connectors"),
    ("双路 USB 数据及 VBUS ESD", "C2687116", 2, 6, "power_protection"),
    ("CC ESD；不能用于高速 D+/D-", "C20600744", 3, 2, "power_protection"),
    ("3.3V LDO；热预算待测", "C47773", 1, 5, "power_protection"),
    ("两路 VBUS 防反灌二极管", "C64885", 2, 2, "power_protection"),
    ("两路 PTC；非精密限流器", "C135338", 2, 2, "power_protection"),
    ("25 MHz 晶振", "C13740", 1, 4, "clock_passives"),
    ("晶振负载电容；值待匹配", "C1663", 2, 2, "clock_passives"),
    ("100nF 去耦", "C14663", 12, 2, "clock_passives"),
    ("2.2uF 电源电容", "C23630", 3, 2, "clock_passives"),
    ("4.7uF 电源电容", "C19666", 2, 2, "clock_passives"),
    ("10uF 电源电容；浪涌待核", "C15850", 1, 2, "clock_passives"),
    ("5.1k CC 下拉", "C23186", 3, 2, "clock_passives"),
    ("10k 启动/复位/上拉预留", "C25804", 6, 2, "clock_passives"),
    ("100k VBUS 检测等预留", "C25803", 4, 2, "clock_passives"),
    ("串联阻尼预留；勿未经 SI 校核直接装", "C23138", 4, 2, "clock_passives"),
]

def price(code, count):
    matches = [p for p in items[code]["priceList"]
               if p["startNumber"] <= count and (p["endNumber"] == -1 or p["endNumber"] >= count)]
    assert len(matches) == 1, (code, count, matches)
    return D(matches[0]["productPrice"])

def calculate_bom(n, mcu="C54937001", esd="C2687116"):
    rows = []
    for purpose, code, qty, points, group in BOM:
        if code == "C54937001": code = mcu
        if code == "C2687116": code = esd
        order_qty = int((D(n) * qty * D("1.05")).to_integral_value(rounding=ROUND_CEILING))
        unit = price(code, order_qty)
        item = items[code]
        rows.append(dict(purpose=purpose, code=code, model=item["model"], group=group,
                         library=item["type"], per_board_qty=qty, order_qty=order_qty,
                         displayed_unit_CNY=float(unit), allocated_CNY=float(unit*order_qty/n),
                         stockNum=item.get("stockNum"), canPreSaleStockNum=item.get("canPreSaleStockNum"),
                         supply_unresolved=code.startswith("C549"),
                         source=f"https://www.jlc-smt.com/lcsc/search?q={code}"))
    return rows, sum(D(r["allocated_CNY"]) for r in rows)

VAT_RESERVE = D("1.13")
points = sum(q*p for _, _, q, p, _ in BOM)
assert points == 265
extended = sum(items[c]["type"] == "expand" for _, c, *_ in BOM)
assert extended == 10
def case(n, mode):
    rows, material = calculate_bom(n)
    if mode == "economic_plus_manual_CONDITIONAL":
        # Manual plug is excluded from machine feeder and machine solder charge.
        fixed = D(50 + 20*(extended-1) + 20)
        solder = D(points-28)*D("0.01") + D(28)*D("0.2")
        eligibility = "NOT confirmed: clip-board plug has pads on both sides; official economic manual service restricts opposite-side work"
    elif mode == "standard_single_plus_manual_CONDITIONAL":
        fixed = D(150+50+8*len(BOM)+20)
        solder = D(points-28)*D("0.01") + D(28)*D("0.2")
        eligibility = "NOT confirmed: separate manual assembly must be accepted without a second SMT pass"
    else:
        fixed = D(150*2+50*2+8*len(BOM))
        solder = D(points)*D("0.01")
        eligibility = "NOT confirmed: automated plug assembly, fixture, PCB stack-up and quotation required"
    assembly = (fixed/n + solder) * VAT_RESERVE
    # These are tax-inclusive planning allowances, NOT supplier quotations.
    extra = ({"PCB": (4,8), "burn_and_function_test": (3,6), "packaging_and_freight": (1,2),
              "assembly_fixture_allocation": (0,5), "electrical_and_process_contingency": (1,2)} if n == 10 else
             {"PCB": (1.5,3), "burn_and_function_test": (1,2), "packaging_and_freight": (.2,.5),
              "assembly_fixture_allocation": (.05,.2), "electrical_and_process_contingency": (.5,1.5)})
    low = material+assembly+sum(D(v[0]) for v in extra.values())
    # Public material price tax basis is not confirmed; reserve up to 13%, not asserted extra VAT.
    high = material*VAT_RESERVE+assembly+sum(D(v[1]) for v in extra.values())
    return dict(quantity=n, mode=mode, eligibility=eligibility, material_CNY=float(material),
                fixed_assembly_order_CNY_before_tax=float(fixed), solder_CNY_before_tax=float(solder),
                assembly_CNY_with_13pct_reserve=float(assembly), extra_allowances_CNY=extra,
                additional_material_tax_reserve_CNY=[0,float(material*D(".13"))],
                total_planning_range_CNY=[float(low),float(high)],
                NOT_A_QUOTE=True, MCU_supply_confirmed=False)

result = {"date":"2026-10-31", "currency":"CNY", "spares":"ceil(required * 1.05)",
          "quantity_basis":[10,1000], "solder_points_estimate":points, "extended_types":extended,
          "scope":"candidate complete PCBA cost model; no schematic or PCB exists; no locked supply or factory quote",
          "excluded":"R&D, certification, tooling development for functional-test fixture, case, external cable, commercial USB VID licensing",
          "cases":[case(10,m) for m in ["economic_plus_manual_CONDITIONAL","standard_single_plus_manual_CONDITIONAL","standard_double"]]+[case(1000,"standard_double")],
          "materials":{}, "alternatives":{}}
for n in [10,1000]:
    rows,total=calculate_bom(n)
    result["materials"][str(n)]={"rows":rows,"total_CNY":float(total)}
    for m in ["C54946769"]:
        _, alt=calculate_bom(n,mcu=m)
        result["alternatives"][f"{n}_{m}"]={"material_CNY":float(alt),"delta_CNY":float(alt-total),"supply_confirmed":False,"extra_QFN_inspection_not_included":True}
    _,st=calculate_bom(n,esd="C7519")
    result["alternatives"][f"{n}_ST_ESD"]={"material_CNY":float(st),"delta_CNY":float(st-total)}

dest=OUT/"ch32v407-complete-cost-model-20261031.json"
dest.write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n")
csv_path=ROOT/"hardware/CH32V407_CANDIDATE_BOM_CNY_20261031.csv"
with csv_path.open("w",newline="",encoding="utf-8-sig") as f:
    headers=["boards"]+list(result["materials"]["10"]["rows"][0])
    w=csv.DictWriter(f,fieldnames=headers);w.writeheader()
    for n in [10,1000]:
        for row in result["materials"][str(n)]["rows"]:w.writerow({"boards":n,**row})
print(json.dumps({"cases":result["cases"],"alternatives":result["alternatives"]},ensure_ascii=False,indent=2))
