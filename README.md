# WiredKVM

通过有线 USB 在两台电脑间共享键鼠，并开发双向剪贴板和文件传输。当前先验证 **MacBook ↔ Mac mini**；后续目标包括 Mac ↔ Windows。

这是正在开发的硬件与软件原型，尚未完成全部功能，也没有完成量产 PCB 设计。

## 当前状态

| 功能 | 状态 |
| --- | --- |
| 键盘、鼠标、左键拖选 | 已在当前 MacBook／Mac mini 组合确认可用 |
| 自动边缘返回 | 已确认可用 |
| 妙控板双指滚动、四指手势 | native-v2 已经用户实机确认；不代表其他系统版本通过 |
| 两台机器内部复制粘贴 | 已确认保留正常 |
| 跨机文字、图片、文件、多文件及文件夹复制粘贴 | 新版免安装路径待开发及端到端验收 |
| 大文件不阻塞键鼠、手势和自动返回 | 有离线混合负载验证；完整实机吞吐、延迟及取消验收待完成 |
| 任意插入顺序和单端热插拔 | 当前开发板仍有供电／连接限制，尚未验收 |

历史带接收组件版本的成功，不等于当前免安装方案已经交付。现有压力测试也不能替代真实文件哈希和交互测试。

## 硬件与数据路径

- 当前开发板：Petros／XPU Labs **CH32V467WEU6**。
- 量产候选：**CH32V407**；目标保留 USB-C 公头＋USB-C 母头。
- 当前接线：USB1 接主控 MacBook，USB2 接 Mac mini；DBG 仅用于经核对后的调试与刷写。
- 量产电源要求：仅 USB1 给整板供电；USB2 只提供数据和 VBUS 检测，不得回灌。
- 产品数据仅走有线 USB；不依赖 Wi-Fi、蓝牙或 macOS 共享服务。
- 键鼠／触点与图片／文件正文使用独立通道；正文采用 Bulk 二进制，不回退到旧 HID 小包或 JSON/Base64 正文路径。

当前已验收的 native-v2 固件及生成源码保留在
[`experiments/mt2-petros-profile/candidate-native-v2-final-20261109/`](experiments/mt2-petros-profile/candidate-native-v2-final-20261109/)。
固件大小为 77,232 字节，SHA-256：

```text
9322b86a3e70b272e71716d1051ec641783afdd33b8d0fc40452608f33d0866b
```

该二进制仅记录当前测试基线。USB 身份是实验配置，不是量产身份；不要把构建成功当作可以直接刷入任意设备。

## 被控端免安装方案

最新选择是 **直接从线内运行程序**：程序存在线内，由被控电脑 CPU 临时执行，不复制到“应用程序”、不注册后台服务、不设置登录启动项。它与“被控端完全不运行程序”不同。

计划在现有硬件输入先可用的前提下，由用户从线内入口启动轻量接收端，再完成系统剪贴板与文件接入。首次运行或权限确认遵循系统流程。此路径尚未完成，不承诺首次零操作或完整无残留。

## 目录

| 路径 | 内容 |
| --- | --- |
| `firmware/ch32v407/` | 双 USB 桥、描述符、独立队列与启动盘逻辑 |
| `firmware/ch32v467_petros/` | 当前开发板适配 |
| `experiments/mt2-usb/` | Rust 触点协议与队列核心 |
| `experiments/host-touch-observer/` | Book 原始触点采集与转发 |
| `experiments/mt2-petros-profile/` | 固件实验构建、适配和离线联调 |
| `host/`、`native/` | 主控输入、自动服务及历史剪贴板组件 |
| `native/transfer-tree/` | Rust 多文件／目录传输核心 |
| `rust-rebuild/` | 恢复工程的 Rust 构建入口与回归测试 |
| `tests/` | 主机模拟与隔离测试 |
| `hardware/` | 硬件可行性、成本、供电与热插拔要求 |
| `docs/history/` | 日期化过程、验收与恢复记录 |
| `docs/research/` | 协议和方案核查；历史结论须结合最新用户约束阅读 |

项目有过源码缺失，目前是部分恢复工程。来源和哈希见
[`RESTORE_MANIFEST_20261104.json`](RESTORE_MANIFEST_20261104.json)，恢复说明见
[`docs/history/README_RECOVERY_STATUS_20261104.md`](docs/history/README_RECOVERY_STATUS_20261104.md)。

## 开发检查

以下命令是离线代码检查／测试，不会证明 mini 实机已通过。需要本机已有 Rust、C/C++ 编译器；Swift 测试需 macOS 工具链。`--offline` 要求依赖已经缓存。

```sh
cargo test --offline --manifest-path experiments/mt2-usb/Cargo.toml --features c-abi,native-mt2
cargo test --offline --manifest-path experiments/host-touch-observer/Cargo.toml --features native-mt2
cargo test --offline --manifest-path native/control-service/Cargo.toml
cargo test --offline --manifest-path native/transfer-tree/Cargo.toml
cargo run --offline --manifest-path rust-rebuild/Cargo.toml -- check-sources .
```

完整固件构建还需要外部 WCH SDK 和 RISC-V 工具链，本仓库没有捆绑这些依赖。具体入口见各子目录 README。历史脚本须先审查，不应自动运行刷写、安装、权限修改或清理命令。

## 验收要求

- 分别验证两机本机复制粘贴和双向跨机文字、图片、单文件、多文件、目录。
- 文件和目录逐项核对大小与 SHA-256，不能只看文件出现。
- 记录图片／文件完成时间、有效吞吐、输入延迟及自动返回；传输时仍须能正常控制。
- 满载取消后及时停止旧事务，新粘贴不得等待旧数据；断线后拒绝旧会话重放。
- Mac ↔ Windows、其他系统版本及最终 CH32V407 量产板须分别验证。

## 仓库范围与第三方来源

Git 保存源码、测试、文档以及上述小体积已验收固件基线。`build/`、`results/`、设备备份、运行日志、工具链缓存和临时测试目录保留本地，不上传。部分历史记录引用这些本地证据路径，克隆仓库后不会自动拥有这些证据。

整体项目尚未指定统一开源许可证。第三方内容保留各自声明；触点实验的来源和声明见
[`SOURCES.md`](experiments/mt2-usb/SOURCES.md) 和
[`THIRD_PARTY_NOTICES.md`](experiments/mt2-usb/THIRD_PARTY_NOTICES.md)。
