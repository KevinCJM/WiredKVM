# WiredKVM-V407-Stick 硬件工作区

状态（2026-11-21，同日返修一轮）：**原理图和 PCB（R1）已完成并通过软件检查；没有下单，没有实物。**
需求来源：[`../../PCBA_REQUIREMENTS.md`](../../PCBA_REQUIREMENTS.md)。
大封装版（CH32V407VET6，主控缺货时的替代）在 [`../l100/`](../l100/)；本目录是小封装原版。
返修前的工程备份没有放进仓库，返修内容见 `docs/pcb/DESIGN_NOTES.md` 第 9 节。
设计取舍、检查记录、下单前要处理的事：先看 [`docs/pcb/DESIGN_NOTES.md`](docs/pcb/DESIGN_NOTES.md)。

## 位置

- 嘉立创 EDA 工程：`eda-project/`（`.eprj3`，须保留整个目录）。
  原理图两页 `MCU`、`USB_Power`；PCB 一个 `PCB1`。
- 图：`docs/schematic/`（原理图、网表）、`docs/pcb/`（装配图、EDA 画面、Gerber 渲染）。
- 生产文件：`manufacturing/R1-WIP/`（Gerber、钻孔、BOM、坐标、STEP、校验值）。
- 手册：厂家文件没有放进仓库，链接见 [`../README.md`](../README.md)。

## 怎么重建和检查

EDA 要先开着这个工程，会话号写在 `evidence/session.txt`
（`LCEDA-Pro open --path <工程.eprj3>` 返回的 `sessionId`）。

```bash
scripts/rebuild.sh        # 原理图：按 gen_plan.py 重画两页 → 保存重开 → ERC → 网表比对
scripts/pcb_rebuild.sh    # PCB：离线检查 → 写入 EDA → 保存重开 → DRC → 网表比对 → 导出 → 核对导出文件
```

原理图有改动时，`rebuild.sh` 之后先把工程整个关掉再新开一个窗口（`LCEDA-Pro session close --session <id> --destroy true`，
再 `open --path`，新会话号写回 `evidence/session.txt`），然后在新会话里：

```bash
scripts/eda.sh scripts/13-verify.js "$(cat scripts/args-verify.json)" 300000   # 重新导出原理图网表（未命名网络的名字随会话变）
python3 scripts/pcb_apply.py wipe                                              # 清掉旧铜
scripts/eda.sh scripts/20-import-pcb.js "$(cat scripts/args-pcb-import.json)" 200000
python3 scripts/pcb_extract_footprints.py                                      # 同时核对焊盘网络与原理图网表一致
scripts/pcb_rebuild.sh
```

最后再关掉重开一次，只跑 `24-verify-pcb.js` 和 `pcb_drc_summary.py`，确认新会话里 DRC 仍是 0 项。
画面截图和文档图片：`scripts/29-capture.js`（参数在 `args-capture.json`）和 `.venv/bin/python scripts/pcb_docs.py`。

| 文件 | 作用 |
|---|---|
| `scripts/gen_plan.py` | 原理图摆放和连线的唯一来源 |
| `scripts/netlist_truth.py` | 目标网表，独立于画图脚本；原理图和 PCB 网表都和它比 |
| `scripts/pcb_layout.py` | PCB 器件位置、全部走线和过孔、丝印的唯一来源（单位 mm） |
| `scripts/pcbtool.py` | 离线几何模型和检查（间距、板边、连通、孔距、阻焊桥、过孔离焊盘、器件本体、测试盘）；与大封装版工作区的是同一份 |
| `scripts/pcb_footprints.json` | 从 EDA 读回的真实焊盘几何，不手写 |
| `scripts/export_check.py` | 用独立解析器核对导出的 BOM、坐标、Gerber、钻孔 |
| `scripts/eda.sh` | 经官方 `LCEDA-Pro invoke --ext-uuid eda` 执行脚本，原始返回存 `evidence/` |

## 最近一次检查结果（2026-11-21）

- 原理图 ERC（严格）通过；原理图网表、PCB 网表与目标网表一致：49 器件、31 网络、202 引脚、50 个 NC。
- PCB 保存重开后 DRC 通过，0 项（整个工程关掉、新开窗口后再查也是 0 项）；离线检查 0 项。
- 导出文件核对全部通过：板框 20 × 44 mm、115 个过孔、BOM 41 个贴装器件 20 行、坐标 49 行。
- 以上是软件检查，不是电气验证，也不是实物测试。

## 本机 EDA 4.1.78 的坑

- 原理图文字（`sch_PrimitiveText`）的删除和修改在保存重开后不生效，改注释只能整页重建。
- 保存时个别多字节字符会被写坏成 U+FFFD（遇到过一次，在“→”上），`rebuild.sh` 会检查。
- `createNetLabel` 没有可用返回值，要从网表回读确认。
- 工程库里的封装被改过后，从系统库放同一个器件会弹“工程库存在其他版本”对话框并卡住接口；
  公头现在从工程库放置（`devices.json` 的 `projectLibraryDevices`）。
- 工程 UUID 是 `.eprj3` 完整路径的 SHA-256，路径不变就不变（文档 UUID 也不变）。
- 器件的 “Channel ID” 和未命名网络的名字（如 `$1N73`）带着“本次会话里第几张图页”的序号。同一会话里重画原理图后序号会涨，
  PCB 导入、DRC 都通过；但下次打开工程序号回到 1、2，DRC 报 “Netlist Error：原理图与 PCB 网表不一致”，`pcb_apply.py` 报
  “Pad model mismatch”。处理办法就是上面“原理图有改动时”的流程：新会话里导入、提取、重建。
- `pcb_ManufactureData.getPdfFile` 不返回，没有导出 PDF。
- PCB 底面丝印文字用 `mirror=false`。
