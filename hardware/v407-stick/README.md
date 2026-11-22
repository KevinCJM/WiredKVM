# WiredKVM V407 U 盘形态板：PCB、PCBA、BOM、CAD

状态（2026-11-22）：**原理图、PCB、生产文件和外壳模型都已完成，只做过软件检查；没有下单，没有实物。**
需求见 [`../PCBA_REQUIREMENTS.md`](../PCBA_REQUIREMENTS.md)。

| 目录 | 内容 |
|---|---|
| [`l100/`](l100/) | **当前要下单的版本**。主控 CH32V407VET6（LQFP100），因为小封装缺货。说明见 [`l100/README.md`](l100/README.md) |
| [`qfn68/`](qfn68/) | 小封装原版，主控 CH32V407WEU6（QFN68），暂停。电路相同 |

每个版本里：

| 子目录 | 内容 |
|---|---|
| `docs/pcb/DESIGN_NOTES.md` | 设计取舍、检查记录、**下单前必须处理的事**、已知风险。先看这个 |
| `docs/schematic/`、`docs/pcb/` | 原理图、网表、PCB 画面和 Gerber 渲染图 |
| `manufacturing/R1-WIP/` | 生产文件：Gerber（`gerber/`）、钻孔、BOM（`bom.csv/xlsx`）、贴片坐标（`cpl.csv/xlsx`）、IPC 网表、EDA 导出的 `board.step` |
| `eda-project/` | 嘉立创 EDA 专业版工程（`.eprj3` 加 `sch/`、`pcb/`、`panel/`），要整个目录一起打开 |
| `scripts/` | 画原理图、布局布线、检查、导出用的脚本；PCB 的器件位置和走线以 `scripts/pcb_layout.py` 为准 |
| `mechanical/`（只有 l100） | 外壳第 2 版和带公头的整板三维模型：源码 `src/`、`STEP/`、打印用 `STL/`、渲染图。说明见 [`l100/mechanical/README.md`](l100/mechanical/README.md) |

## 没放进仓库的

- **Gerber 压缩包**：仓库忽略 `*.zip`。下单前把 `manufacturing/R1-WIP/gerber/` 整个目录压成 zip 上传。
  `SHA256SUMS.txt` 里 `gerber.zip` 那一行对应的是 EDA 原始导出的包，自己重新压的包校验值会不一样。
- **厂家规格书**（版权归厂家），到立创或嘉立创零件页下载：
  - 主控 CH32V407VET6 [C54937001](https://www.lcsc.com/product-detail/C54937001.html)
  - USB-C 公头 TC-002 [C3039316](https://jlcpcb.com/partdetail/C3039316)
  - USB-C 母座 TYPE-C-31-M-12 [C165948](https://jlcpcb.com/partdetail/C165948)
  - Flash P25Q64SH-SSH-IR [C18185312](https://www.lcsc.com/product-detail/C18185312.html)
- **EDA 操作的原始返回和日志**（`evidence/`）：只留在本机。`scripts/eda.sh` 等脚本要用到它，所以脚本只能在本机工作区里跑，仓库里的是存档。
- **外壳装配体 STEP**（40 MB）和 `mechanical/vendor/board.xbf`：都可以重新生成，方法见 `l100/mechanical/README.md`。

## 注意

- 仓库里是本机工作区的快照。改设计在本机工作区改，改完再同步过来。
- 嘉立创 EDA 用 `.eprj3` 文件所在的完整路径区分工程：把 `eda-project/` 复制到别处打开，就是一个独立的新工程，不会影响原来那个。
