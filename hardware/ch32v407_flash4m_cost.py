"""Recalculate the complete prior BOM with the verified 4 MiB candidate.

Public CNY prices, not an order or manufacturing quote. Preserve all other
components, manufacturing/test reserves, and the prior 10/50/1000 quantities.
"""
import argparse
import copy
import csv
from decimal import Decimal
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
D = lambda x: Decimal(str(x))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--capacity-result', type=Path, required=True)
    args = p.parse_args()
    capacity = json.loads(args.capacity_result.read_text())
    assert capacity['every_file_and_mode_equal'] and capacity['raw_sector_readback_equal']
    assert capacity['total_with_reservations'] <= 4 * 1024 * 1024
    assert not capacity['physical_usb_validated']
    old = json.loads((ROOT / 'results/usb-c-single-side-cost-model-20261031.json').read_text())
    capture = json.loads((ROOT / 'results/jlc-smt-hardware-comparison-flash32-20261031.json').read_text())
    text = capture['content'][0]['text']
    public = json.loads(text.split('```json\n', 1)[1].split('\n```', 1)[0])
    matches = [r for r in public['rows'] if '\nC22391875\n' in r]
    assert len(matches) == 1
    row = matches[0]
    tiers = [(int(q), D(price)) for q, price in re.findall(r'(\d+)\+\s*：\s*¥([0-9.]+)', row.split('整盘单价')[0])]
    assert tiers == [(1,D('2.59')), (10,D('2.03')), (30,D('1.79')), (100,D('1.5')), (500,D('1.37')), (1000,D('1.29'))]
    cases = []
    csv_rows = []
    for previous in old['cases']:
        c = copy.deepcopy(previous)
        n = c['boards']
        flash = next(r for r in c['materials'] if r['code'] == 'C49023667')
        qty = flash['buy_qty']
        price = max((q, v) for q, v in tiers if q <= qty)[1]
        allocation = price * qty / n
        saved = D(flash['allocated_CNY']) - allocation
        flash.update(code='C22391875', model='BY25Q32ESTIG', purpose='4 MiB compressed installation assets; integration pending',
            unit_CNY=float(price), allocated_CNY=float(allocation), displayed_stock_NOT_reserved=1336,
            source='https://www.jlc-smt.com/lcsc/search?q=C22391875',
            price_kind='public_tax_inclusive_snapshot_20261031T101250Z')
        c['material_total_CNY'] = float(D(c['material_total_CNY']) - saved)
        c['material_groups_CNY']['Flash'] = float(allocation)
        c['total_per_board_CNY'] = [float(D(v) - saved) for v in c['total_per_board_CNY']]
        c['total_order_CNY'] = [float(D(v) * n) for v in c['total_per_board_CNY']]
        c['saving_per_board_CNY'] = float(saved)
        c['midpoint_not_quote_CNY'] = float(sum(D(v) for v in c['total_per_board_CNY']) / 2)
        c['entire_budget_below_25'] = c['total_per_board_CNY'][1] < 25
        c['entire_budget_below_50'] = c['total_per_board_CNY'][1] < 50
        c['entire_budget_below_100'] = c['total_per_board_CNY'][1] < 100
        assert abs(sum(D(r['allocated_CNY']) for r in c['materials']) - D(c['material_total_CNY'])) < D('0.000001')
        assert c['estimated_solder_points'] == 253 and len(c['materials']) == 19
        for part in c['materials']:
            if part['code'] == 'C54937001':
                part['displayed_stock_NOT_reserved'] = 182
            csv_rows.append({'boards': n, **part})
        cases.append(c)
    result = dict(date='2026-10-31', currency='CNY', quote=False,
        candidate='CH32V407VET6 + BY25Q32ESTIG + TC-002 single-face standard SMT',
        component_price_observed_at=public['at'], flash_price_refresh_rate_limited=True,
        capacity_report=str(args.capacity_result.resolve()), capacity_fits=True,
        shipping_installer_complete=False, supply_confirmed=False,
        developer_board_cost_is_one_time_validation_not_unit_BOM=True,
        no_PCB_design=True, no_firmware_or_live_app_change=True,
        conditions=['Compact bootstrap and CH32 SPI/MSC implementation pending',
                    'Signed/notarized final packages need a new size check',
                    'Manufacturing quote and MCU stock for 1050 units not confirmed',
                    'Full-load HID and edge return require physical hardware validation'],
        excludes=old['excludes'], cases=cases)
    out = ROOT / 'results/ch32v407-flash4m-cost-20261031.json'
    out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    with (ROOT / 'hardware/CH32V407_FLASH4M_BOM_CNY_20261031.csv').open('w', newline='', encoding='utf-8-sig') as f:
        writer = csv.DictWriter(f, fieldnames=list(csv_rows[0]))
        writer.writeheader(); writer.writerows(csv_rows)
    print(json.dumps([{k: v for k, v in c.items() if k != 'materials'} for c in cases], ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
