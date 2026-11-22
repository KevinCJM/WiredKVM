#!/bin/zsh
# Full rebuild of both schematic pages from scripts/gen_plan.py, then save -> reload -> fresh readback checks.
# Pages are replaced rather than edited because host 4.1.78 does not persist text delete/modify.
set -eu
W="${0:A:h:h}"; cd "$W"
P=94f35adb35c439ffbcf785c5e803473490ef833fa41d51fc5024a0c86c543723
python3 scripts/gen_plan.py
scripts/eda.sh scripts/15-recreate-pages.js "{\"projectUuid\":\"$P\"}" 120000
python3 - <<'PY'
import json, re, pathlib
v = json.load(open('evidence/15-recreate-pages.json'))
assert v.get('ok'), v
new = v['value']['created']
f = pathlib.Path('scripts/run_page.py'); f.write_text(re.sub(r'PAGES = \[.*?\]', 'PAGES = ' + json.dumps(new), f.read_text()))
a = json.load(open('scripts/args-verify.json')); a['pages'] = new; json.dump(a, open('scripts/args-verify.json', 'w'))
print('pages', new)
PY
python3 scripts/run_page.py apply 0
python3 scripts/run_page.py apply 1
scripts/eda.sh scripts/11-pages.js "{\"projectUuid\":\"$P\"}" 60000
scripts/eda.sh scripts/13-verify.js "$(cat scripts/args-verify.json)" 300000
python3 - <<'PY'
import json, pathlib, sys
v = json.load(open('evidence/13-verify.json'))['value']
ok = True
for p in v['pages']:
    print({k: (p[k] if k != 'nc' else len(p[k])) for k in p})
    ok &= p['saved'] is True and not p['badText']
print(v['pageNames'], 'erc', v['erc'], v['ercDetails'])
ok &= v['erc'] is True and v['ercDetails'] == [] and [n for _, n in v['pageNames']] == ['MCU', 'USB_Power']
d = pathlib.Path.home() / 'Documents/LCEDA-Pro/projects/WiredKVM-V407-Stick-L100/sch'
files = sorted(d.glob('*/*.esch2'))
ok &= len(files) == 2
for f in files:
    n = f.read_bytes().count(b'\xef\xbf\xbd'); print(f.name, f.stat().st_size, 'U+FFFD', n); ok &= n == 0
sys.exit(0 if ok else 1)
PY
python3 scripts/netlist_truth.py
