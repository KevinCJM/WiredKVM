# Book 触点观察器（隔离 Rust 原型）

只读检查主控机内置妙控板。没有 USB 输出、输入注入、剪贴板访问或被控端代码。
当前不接入运行中的控制服务。零第三方 crate，独立 workspace，不改变已审核固件。

```sh
cargo test --offline --manifest-path experiments/host-touch-observer/Cargo.toml
cargo run --offline --manifest-path experiments/host-touch-observer/Cargo.toml -- --dry-run
cargo run --offline --manifest-path experiments/host-touch-observer/Cargo.toml -- --inspect
cargo run --offline --manifest-path experiments/host-touch-observer/Cargo.toml -- --observe --seconds 10
```

- 默认不加载 framework；inspect 只枚举设备，不注册回调或调用 Start。
- observe 为显式有界操作（1–30 秒），只接受唯一、非零 registry ID、内置、SPI、Product 含
  Trackpad 且非 WiredKVM 的设备。鼠标、Touch Bar、外置和身份未知设备不作为回退选择。
- 先检查设备句柄未运行；停止后核查 `MTDeviceIsRunning`，注销回调后才释放设备。
  SIGINT/SIGTERM 只设置原子退出标志，实际清理在主线程执行。保留 framework 到进程退出，
  避免迟到回调进入已卸载映像。强杀进程不等于正常清理验证。
- 回调只复制/校验有限记录、使用 try_lock，输出聚合数量与时序，不保存触点轨迹，不阻塞等待。
  忙时会计数丢帧；此策略只适用于诊断，不是可交付的手势 begin/end 可靠队列。
- 96 字节记录布局来自公开逆向资料，不是 Apple 稳定 API。仅启用在当前 Book 的 macOS
  15.6.1 上；版本匹配也不证明布局正确。校验长度、时钟/帧号、ID、状态、坐标和有限值。
  没有解释压力/形状等未知字段，也没有把记录改成 MT2 报告。

当前实机事实：Book macOS 15.6.1，`Apple Internal Keyboard / Trackpad` / SPI / built-in，
registry ID `4294970335`。首次无交互窗口为零帧；随后用户明确完成两指和四指动作，30 秒
窗口收到 529 帧、0 无效/丢帧；旧计数器记录 15 帧四个触点，最大数 4；停止状态已核查。
随后核对更完整的公开阶段声明，state 5 是 BreakTouch，不能继续按 down 计算。已修正为
只有 state 3/4 计为 down，并新增原始四记录帧数及阶段直方图。旧日志未保留逐帧数据，
这 15 帧不能重算成严格四指 down 帧数；保留为旧规则结果，不扩大其证明范围。
这支持本机已用字段的布局，不验证压力/形状字段，更不代表 USB 输出或 mini 手势通过。
9 个单元测试仍只覆盖合成记录。统计最大帧间隔包含用户未触摸的空闲，不是输入延迟。

下一步实现触点到 MT2 的映射、生命周期与传输，再分别验证双指方向/顺滑、四指动作、
取消、普通鼠标和自动返回。不能把 Book 采集成功当作 mini 接收成功。

资料仅用于协议事实核对，未复制这些项目的实现：

- [公开 MultitouchSupport 声明](https://github.com/calftrail/TrackMagic/blob/master/MultitouchSupport.h)：不透明设备、公开逆向函数签名、回调及生命周期。
- [mactic 的触点布局观察](https://github.com/MatMercer/mactic/blob/main/docs/implementation.md)：96 字节记录及前缀字段。其形状/压力解释仅为作者观察，本原型不采用。

实验记录：`docs/history/HOST_TOUCH_20261109.md`；结果在 `results/host-touch-20261109/`。


## 2026-11-09 实时转发候选

已增加显式 opt-in 的 Book→CH32→目标 MT2 触点链路，见
[本轮设计、离线证据和实机边界](../../docs/history/LIVE_TOUCH_20261109.md)。
这不是已刷入或已通过手势验收的版本。默认诊断/旧主控配置保持原行为。
`--live-touch` 固件、主控 `--raw-touch /绝对路径/helper`（或专属进程环境
`WK_RAW_TOUCH_HELPER`）与带 `WK_PIXEL_SCROLL`、`WK_RAW_TOUCH` 的捕获器须配套使用。
helper 的 `--stream` 通过 stdin 接受 `ON epoch`/`OFF`，仅在 Book 运行；
目标不运行组件。真实输入仅从主控的 CDC 所有者发往独立 EP87。
