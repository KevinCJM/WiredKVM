# L100 R1-WIP 生产文件（未下单）

大封装版（CH32V407VET6，LQFP100）。2026-11-21 由 `scripts/pcb_rebuild.sh` 从嘉立创 EDA 工程
`WiredKVM-V407-Stick-L100` 导出，导出前 DRC 通过。**没有下单，下单前须用户确认。**

| 文件 | 内容 |
|---|---|
| `gerber.zip`（已解包到 `gerber/`） | 顶/底铜、阻焊、顶面钢网、丝印、板框、钻孔 |
| `bom.csv` / `bom.xlsx` | 物料清单，42 个贴装器件、20 行；UTF-16、制表符分隔 |
| `cpl.csv` / `cpl.xlsx` | 贴片坐标，50 行（含 8 个不贴料的测试点 TP1–TP8） |
| `pcb.net.json` | PCB 网表 |
| `ipc-d-356a.ipc` | 裸板电测网表 |
| `board.step` | 3D 模型（EDA 里没有设置叠层厚度，STEP 里的板厚没有核对；外壳设计前要先核对） |
| `SHA256SUMS.txt` | 以上文件的校验值 |

下单参数：双层、板厚 **1.0 mm**、1 oz、单面贴装（顶面）、板子 22 × 47.8 mm；四边铣边加邮票孔，不做 V 割；TP1–TP8 不贴。
下单前要处理的事见 `../../docs/pcb/DESIGN_NOTES.md` 第 6 节。
核对方法：`.venv/bin/python scripts/export_check.py`。
