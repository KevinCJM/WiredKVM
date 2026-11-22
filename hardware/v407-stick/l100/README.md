# WiredKVM-V407-Stick-L100 硬件工作区（大封装版）

这是 WiredKVM U 盘形态板的**大封装版本**：主控换成 CH32V407VET6（LQFP100，C54937001），
因为小封装 CH32V407WEU6（QFN68）在嘉立创和立创商城缺货。电路功能与小封装版相同。

- 小封装原版（保留不动）：仓库里的 [`../qfn68/`](../qfn68/)，
  EDA 工程 `../qfn68/eda-project/`。
- 本版：EDA 工程在 `eda-project/`（由原工程复制后改画）。

状态、设计取舍、检查记录、下单前要处理的事：见 [`docs/pcb/DESIGN_NOTES.md`](docs/pcb/DESIGN_NOTES.md)。
需求来源：[`../../PCBA_REQUIREMENTS.md`](../../PCBA_REQUIREMENTS.md)。

## 位置

- 图：`docs/schematic/`（原理图、网表）、`docs/pcb/`（装配图、EDA 画面、Gerber 渲染）。
- 生产文件：`manufacturing/R1-WIP/`（Gerber、钻孔、BOM、坐标、STEP、校验值）。
- 手册：厂家文件没有放进仓库，链接见 [`../README.md`](../README.md)。
- 外壳和带公头的整板三维模型：`mechanical/`（见其 README；`manufacturing/R1-WIP/board.step` 缺公头且板厚是 1.6 mm）。

## 怎么重建和检查

EDA 要先开着本工程，会话号写在 `evidence/session.txt`
（`LCEDA-Pro open --path <工程.eprj3>` 返回的 `sessionId`）。

```bash
scripts/rebuild.sh        # 原理图：按 gen_plan.py 重画两页 → 保存重开 → ERC → 网表比对
scripts/pcb_rebuild.sh    # PCB：离线检查 → 写入 EDA → 保存重开 → DRC → 网表比对 → 导出 → 核对导出文件
scripts/eda.sh scripts/29-capture.js "$(cat scripts/args-capture.json)" 120000   # EDA 画面
.venv/bin/python scripts/pcb_docs.py                                              # 刷新 docs/ 里的图和校验值
```

原理图有改动时，`rebuild.sh` 之后先把工程整个关掉再新开一个窗口（`LCEDA-Pro session close --session <id> --destroy true`，
再 `open --path`，新会话号写回 `evidence/session.txt`），然后在新会话里执行
（先清掉 PCB 上的旧铜，否则悬空焊盘会被旧走线“染”上网络名）：

```bash
scripts/eda.sh scripts/13-verify.js "$(cat scripts/args-verify.json)" 300000   # 重新导出原理图网表（未命名网络的名字随会话变）
python3 scripts/pcb_apply.py wipe
scripts/eda.sh scripts/20-import-pcb.js "$(cat scripts/args-pcb-import.json)" 200000
python3 scripts/pcb_extract_footprints.py     # 同时核对焊盘网络与原理图网表一致
scripts/pcb_rebuild.sh
```

最后再关掉重开一次，只跑 `24-verify-pcb.js` 和 `pcb_drc_summary.py`，确认新会话里 DRC 仍是 0 项。

| 文件 | 作用 |
|---|---|
| `scripts/gen_plan.py` | 原理图摆放和连线的唯一来源 |
| `scripts/netlist_truth.py` | 目标网表，独立于画图脚本；U1 引脚号取自手册表 2-1 的 LQFP100 列 |
| `scripts/pcb_layout.py` | PCB 器件位置、全部走线和过孔、丝印的唯一来源（单位 mm） |
| `scripts/pcbtool.py` | 离线几何模型和检查（间距、板边、连通、孔距、器件本体、测试盘） |
| `scripts/pcb_footprints.json` | 从 EDA 读回的真实焊盘几何，不手写 |
| `scripts/export_check.py` | 用独立解析器核对导出的 BOM、坐标、Gerber、钻孔 |
| `scripts/eda.sh` | 经官方 `LCEDA-Pro invoke --ext-uuid eda` 执行脚本，原始返回存 `evidence/` |

## 本机 EDA 4.1.78 的坑

小封装版 README 里列的坑同样适用，另外：

- 工程 UUID 等于 `.eprj3` 文件完整路径的 SHA-256，所以把工程目录复制到新路径就是一个独立工程；
  文档 UUID（原理图 `3a973cf1726fa281`、PCB `b548f4f398f3a4f4`）两个工程相同，不冲突。
- 悬空（NC）焊盘被旧走线碰到时，EDA 会把走线的网络名记到焊盘上；换封装后必须先清铜再导入。
- 同一位置重复放过孔，离线检查原来查不出，EDA DRC 报“孔到孔”；`pcbtool.py` 已加孔距检查。
- 器件的 “Channel ID” 和未命名网络的名字（如 `$1N73`）带着“本次会话里第几张图页”的序号。同一会话里重画原理图后序号会涨，
  PCB 导入、DRC 都通过；但下次打开工程序号回到 1、2，DRC 报 “Netlist Error：原理图与 PCB 网表不一致”，`pcb_apply.py` 报
  “Pad model mismatch”。处理办法就是上面“原理图有改动时”的流程。
