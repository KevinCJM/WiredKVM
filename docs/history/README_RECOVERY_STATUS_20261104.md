# WiredKVM

CH32V407 量产候选，CH32V467WEU6 Petros 开发板测试。先做 Mac ↔ Mac；不做 PCB。

## 2026-11-04 恢复状态

项目发生过源码丢失。本目录目前是**部分恢复的、可构建 CH32 核心**，不是完整历史工程。

- 已放回 144 份源码；逐文件来源与 SHA-256 见 `RESTORE_MANIFEST_20261104.json`。
- CH32 固件、原有输入捕获、自动边缘返回、Bulk 引擎及剪贴板协调器使用恢复源码。
- 新写的工程构建入口和离线压力测试使用 **Rust**，位于 `rust-rebuild/`。
- 主控、捕获、Companion、CH32 启动器以及 Petros 非诊断固件均已重新编译成功。
- 尚缺完整菜单应用的 `WiredKVMCore.swift`、`WiredKVMMenu.swift` 等历史文件；需要重写的产品部分仍按 Rust 实现，不用不完整片段冒充恢复。

独立恢复副本在同级 `WiredKVM-recovery-20261104/`。历史脚本和候选测试仅保留供审查；当前构建入口如下。造成事故的 `ch32v467_physical_probe.swift` 及其构建脚本没有放回本项目。

## 当前入口

在 `rust-rebuild/` 执行：

```sh
cargo test --offline
cargo run --offline -- check-sources ..
cargo run --offline -- build-macos .. ../build/recovered-macos-next
```

`build-macos` 的输出目录必须不存在。只编译，不启动应用，不执行旧自检，不安装组件、不改权限、不访问 USB，也不清理目录。

Petros 构建需要明确传入已检查的本地 SDK 和编译器前缀：

```text
cargo run --offline -- build-petros SOURCE_ROOT PATCHED_SDK COMPILER_PREFIX NEW_OUTPUT_DIRECTORY
```

本次构建产物保留在恢复目录的 `rebuilt-macos-20261104/` 和 `rebuilt-petros-20261104/`；未部署。Petros 产物是不使用外接 NOR、额外 PSRAM 的非诊断构建，不是当前板上诊断固件的字节复刻；不得直接据此宣称实板验收完成。

## 验证边界

- Rust 的 4 项路由回归通过：双向 Bulk 队列满载时 120,000 次绝对鼠标 HID 探针成功；取消后新事务立即进入；断线后旧会话不重放；错误控制 CRC 被拒绝。
- 已恢复的 C/C++ 核心测试通过 ASan/UBSan，包括满载下键盘/鼠标处理、左右边缘返回、拖动保护、看门狗和 500,000 字节解析器输入。
- 捕获模块的同机/跨机粘贴意图区分、紧急返回快捷键和右侧入屏逻辑通过隔离检查。没有安装 EventTap、注入系统输入或修改真实剪贴板内容。
- 以上不证明实机 USB 延迟、端到端文件 SHA、Finder 粘贴或两台机器的完整交互回归。Rust 路由夹具的 SHA 槽是显式哨兵，不能用于真实文件接收。

现有键鼠进程保持运行；本轮没有刷写开发板、替换运行程序或修改 mini 应用。完整目标及验收门槛仍以 `hardware/PCBA_REQUIREMENTS.md` 为准。
