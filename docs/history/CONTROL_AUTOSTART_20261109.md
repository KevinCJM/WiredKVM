# Book 自动启动与重插检查 — 2026-11-09

当前需求：Book 登录后和未重启时均自动连接；控制程序退出后再次插入也自动启动。只在 Book 与开发板运行产品代码，不使用 macOS 共享，不改变 mini 或两台本机剪贴板。

## 已完成

- 新增 `native/control-service`：Rust 管理运行生命周期，C 为 IOKit/libproc ABI。500 ms 轮询，按设备角色、接口、产品、序列号筛选；端口路径与 registry ID 变化后重新连接。原型序列号不唯一，多候选拒绝自动选择。
- 复用先前用户验收的输入程序和捕获程序；不重新编译或移动它们。安装目录为 Book 用户的 `Library/Application Support/WiredKVM/control-autostart`，启动项 `com.wiredkvm.control-autostart`。
- 保留既有进程并接管；只按 PID、创建时间、完整可执行路径管理。所有新会话使用单独 socket，维持 `--input-only`、绝对鼠标、右侧进入、滚动反向设置与自动边缘返回。
- 用户批准并完成触控 ID，新服务的辅助功能开关已确认开启。此前从 Codex 手动启动权限为 true，而 launchd 启动为 false，这是两个运行身份。
- 12 项离线/本机进程测试通过，包括 1000 次虚拟拔插、PID 重用、单实例锁、探针超时、登录状态、程序退出与错误状态码。
- 登录服务卸载重载后自动启动成功，记录约 0.759 秒。控制程序正常退出后自动恢复，记录约 1.841 秒。两者均有新的进程和捕获 ready 日志。
- 重载首次出现 bootstrap 错误 5，原因是 bootout 后立即重载，旧任务尚未退出；确认任务消失后重试成功。未使用 root。
- `AbandonProcessGroup=true` 防止监督进程异常退出时 launchd 直接杀掉捕获子进程；正常退出由 Rust 释放输入。此配置来自本机 `launchd.plist` 手册，异常退出路径尚未进行物理用户验证。

## 尚未通过

- 保持 USB2→mini，只拔插 USB1→Book：两次用户反馈不能控制，且 Book IORegistry 均没有 CH32 设备。服务保持 waiting USB1；不是程序已启动即完成热插拔。
- 两线保持连接，按 RESET：USB1 仍未出现在 IORegistry。
- 曾同时拔插两线，按 USB1 先、USB2 后接回后重新识别；当时接着暴露登录服务授权问题，授权已修好。
- 用户澄清上一轮实际先接 mini、后接 Book，该失败不能归入 Book-first 冷启动失败。按 USB1→Book 先接、USB2→mini 后接，设备于 10:36:57（Asia/Singapore）枚举，服务于 10:37:04 自动启动；未手动拉起控制器。用户确认能控制、能自动返回。USB1-only 热插拔和任意顺序仍未修复。
- 没有重启 Book 做物理验证。RunAtLoad/KeepAlive、服务重载及模拟登录测试不等于真实重启验收。
- 固件、USB-C 供电及主机端口状态仍需区分。本次没有刷写固件。未获取这块 Petros CH32V467W Bet 小板的可核实原理图，不把另一款 WCH 官方 EVB 图当成本板证据。

## 证据与边界

证据在 `results/control-autostart-20261109/summary.json`、`launch-agent-restart.json`、`controller-exit-restart.json`。原文件备份在其 `before/`。

正常连接的现场日志已有进入 mini 与自动返回记录；随后 USB1-only 热插拔失败，所以不能宣布全部需求完成。mini 没有安装/启动程序；没有使用共享功能；输入服务未启用跨机剪贴板。

参考：[Apple launchd](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)。厂商 [Petros 商品页](https://www.analoglamb.com/products/petros-ch32v467-risc-v-dual-usb2-0-development-board) 的 User Guide/SDK 仍标 TBD，链接 Wiki 是另一种 EVB，不能据此确认本板双口供电隔离。

## 插入顺序诊断补充

- 新证据：`results/control-autostart-20261109/book-first-cold-start.json`、`ports-working.json`、`port3-connection-events.txt`。Book 的端口 3 与 CH32 位置 0x02100000 对应。
- 系统日志在 10:21:29 显示该端口 CC inactive / connection inactive；失败及 RESET 期间未记录重新 active。直到 10:36:56 Book-first 恢复时才重新 active，随后枚举并自动授权。该观察把故障范围前移到 Type-C 连接建立阶段，但日志不等于电压测量。
- 正常时该端口为 Host、480 Mbps、Policy Authorized、Driver Ready；读取时枚举失败/地址失败/过流计数均为 0。不能据此证明电路无缺陷，也不能据此将故障归入捕获权限。
- 核对与既有恢复固件哈希对应的 diagnostic-symbols 源码：两路设备初始化不等待另一电脑连接；端口 reset 处理有界；主循环轮询两口。未见可控制本板 CC/VBUS 隔离的产品 GPIO 逻辑。此为静态检查，不能排除未捕获的固件状态错误。
- 当前优先假设是 USB2 供电影响 USB1 的 Type-C 附着条件，例如 VBUS 回灌；还没有本板原理图或电压测量，根因未确认。USB Type-C R2.0 4.5.2.2.8.2 要求 Source 进入 Attached.SRC 前满足 VBUS vSafe0V 和稳定的 Rd；若检测电压异常，重启业务程序并不能建立物理连接。
- 实际 Petros 小板商品页的 User Guide/SDK 为 TBD，其 Wiki 是另一块 Type-A 官方 EVB；不能用官方板的 CH213 保护替实际小板背书。
- 用户无万用表或 USB-C 测试表。随后完成下述无仪表对照，用户要求暂不处理现板可能的硬件问题，并将仅 USB1 供电写入后续 PCBA 约束。
- 本次 UI 检查未获准访问 SystemUIServer，因此改用已授权的只读 IOKit 和内核 USB 日志；没有修改附件安全设置。

规范来源：[USB Type-C R2.0](https://www.usb.org/sites/default/files/USB%20Type-C%20Spec%20R2.0%20-%20August%202019_0.pdf)，4.5.2.2.8.2。该规范支持机制分析，不证明本板存在回灌。

## 无仪表对照及后续范围

- 用户本次实际仅拔插 USB1，USB2 一直接 mini；不是原计划的 mini-first 冷启动。10:46:24（Asia/Singapore）Book 端口 3 的 CC inactive，USB2 transport 消失，ConnectCount 保持 4。插回后仍为 ConnectionActive=false / TransportsActive=[]。
- 用户随后只拔掉 USB2，保持 USB1 和 Book 接口不动。10:48:04，CC active，CH32 Host 重新以 480 Mbps 枚举，ConnectCount 变为 5。自动服务先等待目标 HID，再恢复控制；用户最终确认 USB2 接回后能控制并自动返回。USB2 接回的精确时刻未单独确认。
- 该对照强烈支持 USB2 连接/供电影响 USB1 的 Type-C 附着条件；仍不能区分 VBUS 回流、CC 电路及其它电气因素。拔 USB2 还可能引起板内掉电，故不能仅凭这个动作完全排除固件状态。
- Book IOPort 发布的 Status Reg 原始数据保存在证据中。未验证 Apple 该代控制器的位定义，不能直接套用另一型号 TI 寄存器表当作电压实测。
- 原始记录：`results/control-autostart-20261109/order-probe/events.jsonl`、`port-failed.json`、`port-mini-removed.json`。观测工具只读 IOKit/服务状态，没有打开串口、暂停 MCU 或写寄存器，已正常结束。
- 用户要求：若为硬件问题，本阶段先不处理；后续 PCBA 仅 USB1 给整板供电，任意接入顺序不能影响功能。已形成 `hardware/USB_POWER_AND_HOTPLUG_REQUIREMENTS.md`。USB2 保留数据与高阻 VBUS 检测，不作为整板供电入口。
- 本轮未刷固件、未修改运行中的自动服务、未改板、未设计 PCB；当前控制与自动返回已由用户确认恢复。现板的 USB1-only 热插拔及任意顺序仍未修复，根因未做电压确认。
