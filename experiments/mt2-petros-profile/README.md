# Petros MT2 枚举实验 profile

**最新 026c 候选：已在仅 DBG 连接时刷入开发板并独立读回，待 Book 受控五点定位，`deployable: false`。**
2026-11-06 草稿的 P1 是取消时 close/open EP82 重置 DATA toggle，且未退役旧完成事件。
2026-11-09 已替换该实现：`single_port_abort.c` 先 NAK，保留 W0C 完成标志，逐轮等待
SIE 空闲且 DONE 清除后再释放旧 DMA 所有权，不重开端点。Rust 状态与主机工具新增
quiescing 标志，不能把逻辑租约失效误报为硬件已停。
完整回调／寄存器模型、真实 WCH 驱动核心联调与构建已通过；实际芯片时序、驱动坐标
派发尚未验证。主机默认和旧候选仍被禁用，只有编译绑定已审核候选哈希的专用版本
允许进入 Book 测试，仍须新鲜刷写回读凭据、同板确认、USB2 单口和无人控制等检查。详见
`../../docs/history/MT2_CANCEL_20261109.md`。

本目录只构建独立候选。**不刷板、不停当前控制、不生成触点操作。**

生产 `firmware/` 不修改。生成器严格匹配当前 `main.c` 和 `descriptors.c` 上下文，
在新的输出目录产生 overlay。上下文变化就失败，输出已存在也失败；不做清理。

## 阶段 1 范围

- Book 设备身份保持 `1a86:4070`。
- mini 侧实验身份使用 `05ac:0265`。仅协议研究，不代表商业身份授权。
- 保留原接口 0..5，新增接口 6 / interrupt IN EP7 (`0x87`)。
- 原键盘、鼠标、绝对指针、vendor HID、CDC、MSC 描述符字节保持；
  端点数组扩到 8 槽，USB reset、轮询及对齐修复保留。
- MT2 Feature/描述符来自独立 `experiments/mt2-usb` Rust 核心。
- 支持超过 64 字节的 Feature 回复：控制缓冲 128 字节，DB 回复 76 字节。
- 每次成功 `SET_REPORT 02=[1]` 只排一次 12 字节零触点包；重复激活可再次排包。
  禁用时丢弃尚未提交的空包。没有 Book 触点 ingress，没有 WKSC 广告。
- 原 HID 与控制 ACK 优先，空触点探针随后，Bulk/MSC 最后。
- Petros 不含外置 NOR；沿用现有 no-medium MSC adapter。保留接口不等于安装盘已可用。

**保留代码不等于保留实际控制。** 本机 Apple 驱动的接口匹配含通配规则，
整设备改成 Apple 身份后，原绝对 Mouse 接口也可能被 Apple 驱动接管。
这可能影响鼠标和自动返回。复合布局兼容性尚未实测，不能直接替换用户正在使用的固件。
第一物理测试应先让目标 USB2 接 Book，仅读枚举和驱动绑定；不用 mini 作为首次冒险目标。

可选 `--pointer-collections` 变体只将旧相对/绝对鼠标的 Application Usage 从
Generic Desktop / Mouse (`1/2`) 改为 Pointer (`1/1`)；报告 ID、长度、字段和桥接数据不变。
MT2 接口 6 的描述符不变，目标 `bcdDevice` 改为 `0x0269` 以区分枚举缓存。
默认 profile 仍保持原 Mouse usage 和版本 `0x0268`。
该变体用于验证通用 Pointer 驱动能否避免 Apple 多触点驱动误接管旧接口，
**不代表绝对坐标、鼠标控制和自动返回已经通过实机测试。**

另一个独立变体 `--pointer-collections --absolute-no-preferred` 仅在上述 Pointer 变体上，
将绝对 XY 的 Input 标志从 `0x02` 改为 `0x22`（增加 No Preferred State），
目标版本改成 `0x026a`。它不改变坐标范围、报告格式或 MT2 接口，也不调整 USB PHY。
用于研究 macOS 将旧 XY 识别成 MultiAxisPointer 的问题；是否得到 AbsolutePointer
必须读取实际驱动属性并另做鼠标/返回验证。

`--pointer-collections --absolute-mouse-logical` 是第三个独立变体，目标版本 `0x026b`。
它以 `0269` 为基线，只把绝对报告 ID 3 内层的 Pointer Physical 改为 Mouse Logical。
外层仍是 Pointer Application，XY 保留 Preferred 标志 `0x02`；与 NoPreferred 选项互斥。
相对报告、键盘、按钮布局、坐标范围、MT2 接口、转发代码和 USB PHY 均不变。
离线测试解析编译后的描述符，验证 Application/Physical usage pairs 不包含 Mouse，
而 XY 的祖先集合包含 Mouse。此检查只是公开 Apple 旧算法的模型，**不是当前驱动行为证明**。
仍须检查实际绑定并发送少量定位报告；不能仅凭 `AbsolutePointer` 属性存在或缺失判定通过。
来源与后续验收见 `NEXT_POINTER_CANDIDATE.md`。本变体未刷板。

## 026c 单 USB2 定位草稿（已知阻断，不能部署）

选项 `--single-port-probe` 必须同时使用 `--pointer-collections --absolute-mouse-logical`。
默认 profile 不增加此通路。新 Rust 核心位于 `single-port-core/`，窄 C glue 为
`single_port_probe.c/.h`。原 MT2 Rust 源码、生产 bridge、SDK 均未修改。
接口 2 的 vendor HID `ff60/61` 增加未编号的 64 字节 Feature Report（ID 0，无 ID 前缀）；
原 Input/Output 保留，MT2 接口 6 不变。目标版本为 `026c`。

Feature SET 必须为 `21/09/0300/index2/length64`，GET 必须为
`a1/01/0300/index2/length64`。C 回调检查 setup/completion 一致和缓存身份，只暂存请求。
主循环先检查安全状态、服务普通键鼠，再服务固定点探针，之后才是 MT2/Bulk。
探针使用独立 kind 9，Rust 完成回调核对租约 epoch/sequence；普通队列不能被探针完成弹出。
USB1 已枚举（包括休眠）、普通 HID 非空/忙、按钮/修饰键/键值/Fn/release-pending 非空均拒绝。
复位、断开、休眠、租期到期使租约失效。**新版撤销路径已做模型回归，实际芯片时序仍未闭合。**

所有 u32 均小端。命令布局：

| 字节 | 内容 |
|---|---|
| 0–3 / 4 | `WKAP` / 版本 1 |
| 5 / 6 / 7 | op：1 ARM、2 POINT、3 DISARM / point / 保留 0 |
| 8–11 / 12–15 | 非零 nonce / 非零 sequence |
| 16–63 | 全 0 |

ARM 必须 seq=1、point=0。租期固定 5 秒，重复 ARM 不续期。
POINT seq=2…6，最多五次；只接受中心、左上、右上、左下、右下五个固定内侧点。
归一化坐标分别为 `(16384,16384)`、`(8192,8192)`、`(24576,8192)`、
`(8192,24576)`、`(24576,24576)`。输出固定 8 字节绝对 ID3，按钮、滚轮、横滚均为 0。
DISARM point=0，seq 为下一序号。精确重复幂等；busy 请求不消耗序号。不允许任意坐标。

状态布局：0–3=`WKAS`，4=1；5 phase（0 idle、1 armed、2 queued、3 flight、4 done）；
6 result（0 OK、1 invalid、2 busy、3 unsafe、4 nonce、5 sequence、6 expired、7 lifecycle）；
7 为最后接受的点（初始 255）。u32 字段依次为 nonce@8、accepted_seq@12、submitted_seq@16、
completed_seq@20、received_seq@24、剩余毫秒@28、flags@32、失效计数@36、epoch@40。
44–63 为 0。flags 低位 0/1/2 表示 armed/staged/in-flight；位 8/9/10/11 表示
USB1 raw-enumerated/target-online/普通 HID 忙/按键保持。2026-11-09 新增低位 3 表示
quiescing；phase=0 不等于端点已停，主机须等低四位全部清零后才报告 DISARM 完成。
DISARM 后 phase=0、nonce=0，accepted_seq 保留 DISARM 序号；此前 submitted/completed 保留。

离线证据：6 项 Rust 状态测试覆盖重复、忙、错误序号、五点白名单、租期与 u32 回绕、
失效和旧 epoch 完成。profile 第 7 项测试编译实际生成 main、实际 bridge、C callbacks 和 Rust
核心，使用 USB mock 检查 EP0 暂存、上传失败、队列不误弹、复位/断开/休眠。
新版集成模型覆盖 W0C、auto-toggle、SIE 忙、读写间完成竞态、普通报告紧跟旧完成、
1,000 次取消重开租约和 reset settling；错误 RMW 的变异构建必须失败。
模型不模拟真实总线时序，仍不能证明实际硬件取消安全。
完整构建保留 RV32 archive 审计、map、C/Rust/依赖源码哈希；不是实机验证。

```
cargo test --offline --manifest-path experiments/mt2-petros-profile/single-port-core/Cargo.toml \
  --target-dir experiments/mt2-petros-profile/single-port-core-test-20261106
```

## 只读诊断

Book 控制 CDC 发送 ASCII `MT2?\n`，返回有界一行：

```
MT2,enabled=0,resets=1,gets=0,sets=0,get_ids=0,set_ids=0,errors=0,inputs=0
```

`get_ids` / `set_ids` 是位图：1=report01，2=report02，4=DB，8=99，16=其它。
计数和 enable 只能证明请求/固件状态，不能证明 macOS 已识别原生手势。
`inputs` 表示已提交 USB 的空包数，不表示最终主机成功消费。
诊断行单槽，可合并重复查询，永不阻塞普通 ACK。

解析器支持任意 USB 分包；仅截获整行精确 `MT2?`，普通 WK1/C1 原样交回旧解析器。
超过 192 字节的行透传至换行，再恢复匹配；不会误截取 C1 正文里的查询字符串。
不要用调试器读取握手状态，调试暂停 MCU 会破坏 USB 现场。

## 离线验证

```
python3 experiments/mt2-petros-profile/test_profile.py
```

真实 WCH 核心联调另运行 `test_abort_sdk.py --sdk <已核实 sdk-patched>`。
它固定核对已审查核心的 SHA，直接链接 `usbd_driver_core.c`；只有寄存器边界为模型。
覆盖 1,000 次取消／发送新报告、忙端点拒绝覆盖 DMA、迟到完成与并行 Bulk，以及错误
W0C 写法的变异检测。它不证明实际总线时序和原生手势。

测试使用本机 C stub 与合成 USB 请求，覆盖描述符旧字节保留、Feature 长度、
所有两段分包位置、逐字节输入、超长行后恢复、零触点状态。它不验证 Apple 驱动。
Rust 核心另有真实状态机单元测试，C stub 不能替代 Rust 测试。

仅生成 overlay（`--output` 必须是本目录下尚不存在的目录）：

```
python3 experiments/mt2-petros-profile/build_profile.py \
  --output "$PWD/experiments/mt2-petros-profile/generated-stage1"
```

完整构建另加 `--build --sdk <已核实 sdk-patched> --gcc-prefix <riscv32-esp-elf->`。
Rust 使用已安装 `riscv32imac-unknown-none-elf`，Cargo `--offline`，C 使用显式 GCC。
混合链接显式禁用 `lto`、`linker-plugin-lto`、嵌入 bitcode，并验证静态库成员均为
原生 ELF32 RISC-V；GNU ld 不能消费此前 Cargo 生成的 LLVM bitcode 成员。
SDK 标记检查不能替代完整来源校验。构建保留 map、日志、输入哈希和 `profile.json`。
不链接额外 PSRAM；二进制上限仍是 512 KiB。

协议来源及身份风险详见
`../../docs/research/MT2_FIRMWARE_FEASIBILITY_20261105.md` 和 `../mt2-usb/` 归属说明。
当前可用固件 SHA-256 `53b4b741a9212ffb3c8a89dcb9aef282b4b3643bbf2a11696f8c23e5e97a6e70`
仅作为已知回退身份；任何上板操作前必须重新核对确切备份与设备身份。


## 2026-11-09 实时转发候选

已增加显式 opt-in 的 Book→CH32→目标 MT2 触点链路，见
[本轮设计、离线证据和实机边界](../../docs/history/LIVE_TOUCH_20261109.md)。
这不是已刷入或已通过手势验收的版本。默认诊断/旧主控配置保持原行为。
`--live-touch` 固件、主控 `--raw-touch /绝对路径/helper`（或专属进程环境
`WK_RAW_TOUCH_HELPER`）与带 `WK_PIXEL_SCROLL`、`WK_RAW_TOUCH` 的捕获器须配套使用。
helper 的 `--stream` 通过 stdin 接受 `ON epoch`/`OFF`，仅在 Book 运行；
目标不运行组件。真实输入仅从主控的 CDC 所有者发往独立 EP87。

## 2026-11-10 文件 IN 合并候选

`--bulk-batch` 是单独启用的实验选项，不改变默认生成配置或 USB 描述符。
它只对高速文件 IN 端点启用 SDK 的 BURST，并将已排队的最多八格合并到
独立的 4 KiB DMA 缓冲；有一格就发送，不等待凑满。全速连接仍每次最多
512 字节；HID、触点、控制、MSC 及文件 OUT 的端点和缓冲不变。
提交失败不弹出队列，成功提交后复制件由 DMA 独占；取消能清除未提交的旧格。
已经交给 DMA 的旧数据最多 4 KiB，接收方仍须按代次拒绝它。

```
python3 experiments/mt2-petros-profile/test_live_touch.py --native-format --ram-setup --bulk-batch
```

测试执行真实生成主循环、C 桥和 Rust 触点核心，覆盖队列环回、提交失败、
DMA 副本不变、取消后新代次及两侧文件堵塞时的键鼠/触点推进。
USB 硬件边界仍是模型，不能作为真实速度、总线时序或交互延迟验收。
当前候选 `candidate-bulk-batch-20261110/` 已构建，尚未刷板；最新实机记录见
`../../docs/research/DIRECT_CABLE_RUNTIME_20261109.md`。
