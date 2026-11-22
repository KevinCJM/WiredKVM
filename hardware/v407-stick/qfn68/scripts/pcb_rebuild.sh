#!/bin/zsh
# Full PCB rebuild from scripts/pcb_layout.py: offline check -> apply to the EDA -> save/reload/DRC -> netlist check
# -> export -> cross-check of the exported files. Stops at the first failing step. Nothing is ordered.
set -eu
W="${0:A:h:h}"; cd "$W"
PY=.venv/bin/python
$PY scripts/pcb_layout.py | tee evidence/pcb-layout.log
grep -q "check: 0 problem" evidence/pcb-layout.log
python3 scripts/pcb_apply.py > evidence/pcb-apply.log; tail -c 300 evidence/pcb-apply.log; echo
scripts/eda.sh scripts/24-verify-pcb.js "$(cat scripts/args-verify-pcb.json)" 300000
python3 scripts/pcb_drc_summary.py | tee evidence/pcb-drc.log
grep -q "drc pass: True" evidence/pcb-drc.log
python3 scripts/netlist_truth.py evidence/pcb.net.json
python3 scripts/netlist_truth.py evidence/schematic.net.json
python3 scripts/pcb_export.py
$PY -W ignore scripts/export_check.py
