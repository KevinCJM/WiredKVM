"""Conditional CH32V407 PCBA estimate; no PCB design, quote, or purchase.

Use saved JLC SMT CNY price tiers. Preserve the complete preceding BOM,
5% procurement reserve, manufacturing allowances, and batch quantities.
"""
import copy
import csv
from decimal import Decimal
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'results/costdown-20261031'
D = lambda v: Decimal(str(v))


def price_tiers(text, code):
    # Search tables contain multiple products; never use another SKU's price.
    if '型号：' in text:
        rows = [r for r in text.split('收藏') if f'\n{code}\n' in r]
        assert len(rows) == 1, (code, len(rows))
        text = rows[0]
    else:
        assert f'\n{code}\n' in text
    return [(int(q), D(v)) for q, v in
            re.findall(r'(\d+)\+\s*：?\s*¥([0-9.]+)', text.split('整盘单价')[0])]


def main():
    baseline = json.loads((ROOT / 'results/ch32v407-flash4m-cost-20261031.json').read_text())
    evidence = json.loads((OUT / 'public-price-evidence.json').read_text())
    snaps = evidence['snapshots']
    replacements = [
        ('C165948', 'C5178539', 'HX TYPE-C 16PIN', 'costsnap_socket_8', 41237,
         'USB-C receptacle; USB2 data pins and 10000 cycles documented; shell solder process pending'),
        ('C47773', 'C2932546', 'BL9165-330BARN', 'costsnap_bl9165', 2471,
         '3.3 V LDO with current/short/thermal protection; board thermal validation pending'),
        ('C14663', 'C30926', '0603B104K500NT', 'costsnap_12', 2509819,
         '100 nF 50 V X7R 0603 +/-10%; same count'),
    ]
    cases, csv_rows = [], []
    for original in baseline['cases']:
        n = original['boards']
        c = copy.deepcopy(original)
        savings = []
        for old_code, new_code, model, key, stock, purpose in replacements:
            part = next(p for p in c['materials'] if p['code'] == old_code)
            snap = snaps[key]
            tiers = price_tiers(snap['text'], new_code)
            price = max((q, v) for q, v in tiers if q <= part['buy_qty'])[1]
            allocated = price * part['buy_qty'] / n
            saved = D(part['allocated_CNY']) - allocated
            assert saved > 0
            savings.append(dict(old_code=old_code, new_code=new_code,
                                saving_CNY_per_board=float(saved)))
            part.update(code=new_code, model=model, purpose=purpose,
                        unit_CNY=float(price), allocated_CNY=float(allocated),
                        displayed_stock_NOT_reserved=stock,
                        source=snap['url'],
                        price_kind='public_tax_inclusive_tier_' + snap['observed_at'])
        assert len(c['materials']) == 19 and c['estimated_solder_points'] == 253
        assert c['extra_tax_inclusive_allowances_CNY'] == original['extra_tax_inclusive_allowances_CNY']
        material = sum(D(p['allocated_CNY']) for p in c['materials'])
        total_saving = sum(D(s['saving_CNY_per_board']) for s in savings)
        assert material == D(original['material_total_CNY']) - total_saving
        groups = {}
        for p in c['materials']:
            groups[p['group']] = groups.get(p['group'], D(0)) + D(p['allocated_CNY'])
            csv_rows.append({'boards': n, **p})
        fixed = D(c['assembly_fixed_order_CNY_before_tax']) / n
        standard_smt = (fixed + D(253) * D('.01')) * D('1.13')
        assert standard_smt == D(original['assembly_CNY_with_13pct_reserve'])
        # Both connectors' 36 estimated points retain full price. Shell legs
        # and the plug's recessed mounting need the factory's process review.
        conditional_smt = (fixed + D(217) * D('.005') + D(36) * D('.01')) * D('1.13')
        allowances = [sum(D(v[i]) for v in c['extra_tax_inclusive_allowances_CNY'].values()) for i in (0, 1)]
        ordinary = [material + standard_smt + a for a in allowances]
        qualified = [material + conditional_smt + a for a in allowances] if n == 1000 else None
        c.update(material_total_CNY=float(material),
                 material_groups_CNY={k: float(v) for k, v in groups.items()},
                 substitutions=savings, component_saving_CNY=float(total_saving),
                 total_per_board_CNY=[float(v) for v in ordinary],
                 total_order_CNY=[float(v*n) for v in ordinary],
                 midpoint_not_quote_CNY=float(sum(ordinary)/2),
                 entire_budget_below_25=ordinary[1] < 25,
                 entire_budget_below_50=ordinary[1] < 50,
                 entire_budget_below_100=ordinary[1] < 100,
                 # Remove ambiguous old-version saving field.
                 saving_per_board_CNY=float(total_saving),
                 qualified_fee_scenario=None)
        if qualified:
            margin = D(25) - qualified[1]
            mcu = next(p for p in c['materials'] if p['code'] == 'C54937001')
            c['qualified_fee_scenario'] = dict(
                rule=evidence['manufacturing_rule'],
                assembly_CNY_with_13pct_reserve=float(conditional_smt),
                solder_fee_saving_CNY=float(standard_smt-conditional_smt),
                total_per_board_CNY=[float(v) for v in qualified],
                total_order_CNY=[float(v*n) for v in qualified],
                entire_budget_below_25=qualified[1] < 25,
                headroom_to_25_CNY=float(margin),
                maximum_MCU_unit_CNY_at_other_upper_allowances=float(
                    D(mcu['unit_CNY']) + margin * n / mcu['buy_qty']),
                conditions_verified=False)
        cases.append(c)
    result = dict(date='2026-10-31', currency='CNY', quote=False,
        candidate='CH32V407VET6 + 4 MiB BY25Q32ESTIG + HX TYPE-C 16PIN + TC-002 + BL9165',
        supply_confirmed=False, PCB_designed=False,
        real_hardware_performance_validated=False, runtime_code_changed=False,
        installer_capacity_verified_previously=True, compact_installer_integration_complete=False,
        prices='Tax-inclusive ordinary tiers; no reel-only subsidy, coupons, or shipping stock assumed',
        unchanged=['MCU dual-HS candidate', 'MCU RAM', '4 MiB external installation storage',
                   'USB/CC ESD protection', 'both-port power isolation and fuses',
                   '25 MHz crystal', '19 BOM line items', 'all manufacturing/test contingencies'],
        conditions=['MCU 1050-unit quote/stock pending; displayed reference price is not a bulk contract',
                    'Both connectors need factory solder-process review',
                    'LDO needs worst-case load/voltage/temperature verification',
                    'Single PCB order area >1 m2 and EasyEDA design required for discounted scenario',
                    '4 MiB compact bootstrap and CH32 installation integration pending',
                    'Full-load HID/edge-return latency must pass physical-board acceptance'],
        excludes=baseline['excludes'], cases=cases)
    (OUT / 'cost-model.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
    with (ROOT / 'hardware/CH32V407_COSTDOWN_BOM_CNY_20261031.csv').open('w', newline='', encoding='utf-8-sig') as f:
        writer = csv.DictWriter(f, fieldnames=list(csv_rows[0]))
        writer.writeheader(); writer.writerows(csv_rows)
    print(json.dumps([dict(boards=c['boards'], materials=c['material_total_CNY'],
                           normal=c['total_per_board_CNY'],
                           conditional=c['qualified_fee_scenario']) for c in cases],
                     ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
