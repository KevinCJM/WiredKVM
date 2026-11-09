# MT2 USB protocol experiment — isolated, not deployed

此目录是隔离的 Rust `no_std` 研究原型，零第三方 crate 依赖。它没有 USB 驱动，不刷固件、不读剪贴板，也不被生产构建引用。可选 `c-abi` 导出实验固件接口；没有默认启用。`0.0.0` 不表示可发布版本。

## 已做的范围

- 已知 MT2 报告头、9 字节触点记录的封装；0/2/4/5 指分别输出 12/30/48/57 字节，均小于 64 字节。
- 按已核实的位布局更新 X/Y、触点 ID、接触阶段，其他字节保持调用方提供的原值。
- 显式 16 位时间戳回绕、释放帧、清空帧与本地状态 reset。
- Feature `00/01/02/99/DB` 的受限草案；未知请求返回错误，模拟未来 STALL。
- `GET_REPORT` 截短与 `SET_REPORT` 长度/值检查；显式区分含 report ID 和不含 report ID 的输入。

**并未生成可用的四指物理模型。** `Contact::from_observed_record` 要求调用方提供完整触点字节，其类型名不证明这些字节能被 macOS 识别。测试使用人为字节，只验证编码/边界，不是妙控板真实手势测试。

2026-11-09 增加 `Contact::synthesized` / `Geometry`，明确构造合成触点的 major/minor、
size、pressure、orientation 字段；不再把人工选择的形状字节冒充实测模板。
字段事实据 [Linux MT2 解码器](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-magicmouse.c)
的 `magicmouse_emit_touch`，仅参考协议事实，未复制解码器实现。方向范围 -4…3，超界拒绝，
协议单位没有宣称已校准为毫米/力度。新增 3 项编码/释放测试；仍没有 live ingress 或新 C ABI。
这些新构造字段尚未由 macOS 实机接收，不能据此宣告原生滚动/四指可用。

默认纯协议 API 的 Feature DB 属性由调用方注入。新增的 `c-abi` 实验功能内置公开项目的候选属性 fixture，其中最后 12 字节为上游重构，**不是独立完整实测数据**。此功能只用于验证枚举/握手，不能证明原生手势可用；出处和许可在 `THIRD_PARTY_NOTICES.md`。

## 运行

在 `WiredKVM` 根目录执行：

```sh
cargo test --offline --manifest-path experiments/mt2-usb/Cargo.toml
```

2026-11-05：默认 12 个离线测试通过；加 `--features c-abi` 共 18 个通过。覆盖包大小、精确位值、边界坐标、字段保留、重复 ID、超过 5 指、禁用状态、时间回绕、release/reset、未知 Feature、错误长度、report-ID 前缀及 GET 截短。FFI 增加空指帧、缓冲区、76 字节 EP0 响应及并发快照测试。无硬件结果。

`Cargo.toml` 的独立 `[workspace]` 防止把该原型隐式加入上级工程。没有 build script，没有依赖下载，没有清理脚本。构建输出留在本目录 `target/`。

## 可选 C ABI（仅第一阶段）

头文件为 `include/wkmt2.h`。编译示例：

```sh
cargo test --offline --manifest-path experiments/mt2-usb/Cargo.toml --features c-abi
cargo rustc --offline --release --manifest-path experiments/mt2-usb/Cargo.toml \
  --target riscv32imac-unknown-none-elf --features c-abi -- --crate-type staticlib
```

目标 Rust 标准组件必须预先可用；此命令不自行安装工具、不连接板子。预计静态库位于 `target/riscv32imac-unknown-none-elf/release/`；具体生成结果由独立 profile 的构建检查确认。

- 导出 110 字节描述符、Feature GET/SET、enable 查询、reset 和 input；不导出 Apple VID/PID。
- GET 包含 report ID；SET 明确要求不含 report ID。USB glue 必须根据其协议缓冲区去除一次前缀，不能猜测。
- Feature DB 的 76 字节响应走 EP0 控制传输，须支持跨 64 字节包。中断输入上限仍为 64 字节。
- 初始禁用；只有合法 Feature02 enable 后，才产生一次 12 字节零触点包。没有真实触点、鼠标增量、按钮或滚轮数据。
- 不发布 WKSC pixel-scroll capability，不消费 WKSC sample，不会接管 Book 滚动。未来第二阶段必须单独启用和验证。
- `wkmt2_input` 仅在目标已配置且 IN 端点可提交时调用。成功取包会消费待发送状态。总线 reset/取消配置调用 `wkmt2_reset`，关闭 enable。
- 状态使用 32 位原子变量，避免中断和主循环共享可变引用。没有堆分配、等待 I/O 或阻塞锁。

## 数据接口和限制

- `Encoder::frame` 只在调用方明确传入 `enabled=true` 时编码。它不绑定 FeatureMachine；未来适配器必须统一生命周期，不能任意放行。
- `Encoder::release` 返回两个待发送报告（release、0 指），不负责它们之间的发送时间。真实设备可能需要重复/渐变释放，必须测量。
- `Encoder::reset` 只清本地状态，不能替代已连接目标上的释放帧。断链、禁用、bus reset 各自的次序要在 USB 适配器中定义。
- 64 字节限制仅指中断输入包。Feature 走控制传输，可以多于 64 字节；本草案总响应上限 256 字节。
- X 的有符号 13 位范围为 -4096..4095；Y 在报文中取负，所以逻辑范围为 -4095..4096。这是编码范围，不是已校准的真实触控面范围。
- 两指点增量已经可能含 Book 加速/惯性，不能不加判断地再变为 mini 触点运动。原型没有实现插值、速度曲线或惯性。
- 无按钮合成：报文指针/按钮字节保持 0；当前普通键鼠路径不应被替换。

## 尚缺的协议证据

1. **SET_REPORT 前缀**：USB 适配库传给应用的缓冲区是否含 report ID 要实测。参考实现的 Feature 01/02 处理风格不同；纯协议层有 `set_wire` 和 `set_payload` 两个明确接口。C ABI 固定采用不含前缀的 `set_payload`，实际 USB 请求与 glue 的契约仍需验证。
2. **真实 Feature 属性**：需要完整 compound DB 及 selector 01/99 的冷启动和重连抓包。当前机器只模拟已观察到的两个 selector；未知 selector 拒绝，不猜长度。
3. **触点剩余字段**：接触面积、方向、压力及保留位的组合是否影响四指识别、点按及手掌拒绝。暂时保留原字节，不能用零值模板宣称四指成功。
4. **完整释放序列**：还需核实 release/none/零触点的顺序、次数、时距与 macOS 取消行为。
5. **输入来源**：当前 Book 代码是识别后的 DockSwipe/滚动事件，不提供全部原始触点。要验证原始采集，或明确用合成触点重建手势，而非声称透传。
6. **设备身份和驱动**：真实参考实现采用整个设备的 Apple VID/PID。新增独立 HID 接口是否足够、自有 VID 能否绑定、现有绝对指针/CDC/MSC 是否保留，均未验证。
7. **资源/实时性**：尚无 CH32 target build、端点分配、DMA、输入优先级、满载延迟或热插拔测试。

## 下一步顺序

独立 CH32 实验 build profile 的 glue 位于另一个实验目录，不能改默认生产构建。保留当前二进制、普通键鼠和自动返回；先验证 mini 驱动识别与空报告，再两指短滑，再四指。此 crate 没有自动刷板步骤。现有开发板足够开展这些实验，不要求新购硬件。

研究来源与许可边界见 [SOURCES.md](SOURCES.md)。完整可行性分析见 [研究文档](../../docs/research/MT2_FIRMWARE_FEASIBILITY_20261105.md)。


## 2026-11-09 实时转发候选

已增加显式 opt-in 的 Book→CH32→目标 MT2 触点链路，见
[本轮设计、离线证据和实机边界](../../docs/history/LIVE_TOUCH_20261109.md)。
这不是已刷入或已通过手势验收的版本。默认诊断/旧主控配置保持原行为。
`--live-touch` 固件、主控 `--raw-touch /绝对路径/helper`（或专属进程环境
`WK_RAW_TOUCH_HELPER`）与带 `WK_PIXEL_SCROLL`、`WK_RAW_TOUCH` 的捕获器须配套使用。
helper 的 `--stream` 通过 stdin 接受 `ON epoch`/`OFF`，仅在 Book 运行；
目标不运行组件。真实输入仅从主控的 CDC 所有者发往独立 EP87。
