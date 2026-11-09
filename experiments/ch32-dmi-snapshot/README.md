# CH32 双 USB 状态快照

隔离 Rust 工具，仅供已授权停核的实验窗口。开发板唯一调试器：`1a86:8010 / A47C8F062A1A`，芯片必须是 `CH32V4X7 / 0x46740011`。

- 按序读取 RCC、USBHS1、USBHS2 配置/状态，再读取 DPC、mepc、mcause、mtval。
- 不调用 `Program::ReadMemory`、`GetChipInfo`、reset、flash，不改外设寄存器。
- DMI load 会使用 x5/x6、progbuf0/1。工具保存、恢复并核对这些寄存器；普通错误和 panic 展开时都会尝试恢复、resume、detach。
- halt/resume 的轮询最多 2 秒，并检查 running 状态。底层 USB I/O 可能阻塞，拔线、断电或 SIGKILL 无法保证清理。
- AttachChip、暂停及调试命令本身会扰动 USB 时序，快照不是无扰动运行证据。
- 不自动停止捕获程序。运行前由操作者核实无人使用控制通路、板上没有挂载卷。
- **不读取 UID**：本工具没有已核实的 V467 UID 寄存器地址，也不执行可能改时钟的探针 QueryInfo。预期 UID 为 `ad21ad506c54c6c6`；刷写前需独立核验。

构建/测试（离线缓存解包到实验目录，避免更改用户 Cargo 目录）：

```sh
CARGO_HOME="$PWD/experiments/ch32-dmi-snapshot/cargo-home" cargo test --offline --manifest-path experiments/ch32-dmi-snapshot/Cargo.toml
CARGO_HOME="$PWD/experiments/ch32-dmi-snapshot/cargo-home" cargo build --offline --manifest-path experiments/ch32-dmi-snapshot/Cargo.toml
```

无设备 dry-run：

```sh
experiments/ch32-dmi-snapshot/target/debug/ch32-dmi-snapshot --dry-run
```

授权实机运行（输出文件必须不存在）：

```sh
experiments/ch32-dmi-snapshot/target/debug/ch32-dmi-snapshot --out /absolute/new/snapshot.json
```

`success=true` 必须同时满足读取成功、寄存器恢复核对成功、running 状态核对成功及 detach 成功。不能只看进程退出或某个端口出现。

库源码核验：`wlink/src/dmi.rs:195` 的 read_mem32 使用 `lw x6,0(x5)`；`:90` 的 halt 原实现无界；`:114` 的 resume 原实现失败也可能返回 Ok。工具补保存恢复及有界握手，不修改 wlink 源码。
