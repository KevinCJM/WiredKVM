# 固件妙控板实验：阶段 1 准备

记录时间：2026-11-05。此文件是阶段记录，不代表实时设备状态。

## 用户方向与边界

用户反馈短滑优化后仍卡顿，方向和自动返回正常；选择优先固件模拟妙控板，mini 不装组件，接受刷板验证。
现有控制通路继续运行。尚未刷写板子，没有改变 mini 设置或软件。

## 已完成

- `experiments/mt2-usb/`：独立 `no_std` Rust 协议原型，18 项协议/FFI 测试通过。
- `experiments/mt2-petros-profile/`：隔离生成固件 overlay，不改生产 `firmware/`。
- 新增目标接口 6 / EP7，仅 Feature 握手及启用后的零触点探针。没有真实滑动入口，没有 WKSC 能力广告。
- 原接口 0..5 的配置字节保留，Book USB 身份保持 `1a86:4070`。
- 最终 3 项 C 胶水/布局测试通过，含完整 setup→completion、分包、溢出、disable 清缓存和错误 Report ID。
- 最终 ELF 的 ABI、符号、内存和关键对齐路径静态检查通过。未做栈水位或板测。

候选：`experiments/mt2-petros-profile/candidate-stage1-completionfix-20261105/wiredkvm-mt2-stage1.bin`

- 71,704 字节。
- SHA-256：`9fbbbfc3f942dbf3e7c33720a1de2be35a18edf048358dc363812a3928a92493`。
- 已重新核对构建清单的全部输入哈希。
- 机器可读记录：`results/mt2-research-20261105/stage1-ready.json`。

## 本次发现并修正

1. Cargo 自动注入 linker-plugin LTO，静态库含 LLVM bitcode，GNU ld 无法读取。仅实验构建显式关闭，并增加原生 ELF32 RISC-V 成员检查。
2. WCH SDK 在 IN 数据完成后同样调用完成回调。最初胶水只接受 SET_REPORT，导致 GET 状态阶段 STALL；已按真实 SDK 调用修正并补测试。
3. 禁用 MT2 后须清除尚未提交的 C 暂存空包，避免下一轮继续提交。

## 尚未验证

Apple `05ac:0265` 的本机驱动匹配含接口通配和 Mouse usage。改变整设备身份可能接管原鼠标接口；保留描述符不代表原控制实际仍可用。
因此首次实验先将目标 USB2 接 Book，检查驱动绑定及握手。不能直接当成 mini 可用固件。
此实验身份不代表量产身份授权。

四指输入、短滑流畅度、实际自动返回、并发文件传输都没有通过本候选验收。
当前 Book 捕获的是已识别手势事件，不是原始触点；下一阶段需要单独实现并验证触点转换、方向、惯性与抬手。

## 回退与下一步

已核对旧固件 28,524 字节，SHA-256 `53b4b741a9212ffb3c8a89dcb9aef282b4b3643bbf2a11696f8c23e5e97a6e70`；完整 Flash 备份也核对一致。
备份位于相邻 `WiredKVM-recovery-20261104/diagnosis-20261105/`，路径见机器记录。

已请求用户断开 USB1/USB2，仅连接 DBG→Book。收到完成反馈后，重新核对探针完整序列号、芯片 ID 和 UID，读取当前固件，再刷写并独立读回校验。
调试器可能暂停 MCU；不要在当前控制使用中做调试读取。旧控制器必须在实验目标接 Book 前停止，以免输入回送本机。

## 18:27 实机写入记录

用户确认仅 DBG→Book。实读探针 `A47C8F062A1A`、芯片 `0x46740011`、UID `ad21ad506c54c6c6` 一致。
完整旧 Flash 再次备份，SHA-256 与旧备份一致；原控制器已退出，输入 relay 已正常停止。
实验版已写入，独立读回 71,704 字节，SHA-256 与上述候选完全一致，随后 reset run 成功。
记录：`results/mt2-flash-20261105/flash-result.json`；完整操作日志和本次备份在同目录。

当前等待 USB1、USB2 都接 Book、DBG 留空，进行驱动绑定和 `MT2?` 查询；不是 mini 功能验收。
只读检查工具为 `experiments/mt2-petros-profile/inspect_book.py`，可保存指定板子的接口父子链，
查询前拒绝运行中的控制器及已占用串口。不会打开目标 HID、安装驱动或发送输入动作。

## 本轮 Book 枚举结果

双线初次接入只见 USB1，`MT2?` 回复 enabled=0、resets=1、gets=0、sets=0；不能由此归因驱动或线缆。
用户改为原 USB1 线单接 USB2 后，目标以 `05ac:0265 / bcdDevice 0268` 枚举。
两次观察的 Book locationID 不同，因此这不是严格只改变板端的一因素试验，初次未识别原因保留未知。

iface6 的 110 字节 MT2 描述符被加载，绑定 AppleMultitouchTrackpadHIDEventDriver，且子服务
AppleMultitouchDevice 显示 SupportsGestureScrolling=true、TrackpadFourFingerGestures=true。
这是驱动识别证据，没有执行实际手势，不能称四指或流畅度已通过。

同时实证 iface0/iface1 的旧 Mouse 报告也被专用 MT 驱动接管；这版不适合交给 mini 使用。
证据：`results/mt2-flash-20261105/book-target-binding-confirmed.json`。
观察脚本已修正：只从真实 IOUSBHostInterface 继承父接口号，不能让驱动匹配属性 `*` 覆盖它。

本机 AppleUserHIDEventDriver 明确接受 Generic Desktop / Pointer，专用 MT 驱动匹配 Mouse。
因此准备了可选 `--pointer-collections` 变体，旧两个 Mouse Application 改为 Pointer。
它与上板版仅 3 字节不同：两个 Usage 和 bcdDevice 0269；原报告字段、绝对 XY flags 与 MT2 接口不变。
4 项离线测试通过。候选位于 `experiments/mt2-petros-profile/candidate-stage1-pointer-20261105/`，
SHA-256 `2761ac0af8247daf56a4c4ef70762da2a6a07c4058296ed76dc3564a989f2f23`。

需要实际检查 generic 绑定及绝对坐标。Apple 旧公开驱动可能把 Absolute+Preferred 轴当 multiaxis；
当前 macOS 使用的 AppleUserHIDEventDriver 行为不能仅凭旧源码外推。未擅改 NoPreferred flags。
已请求用户回到仅 DBG→Book，准备下一版刷写。摘要为 `results/mt2-flash-20261105/enumeration-result.json`。

## Pointer 变体已写入与枚举

用户确认仅 DBG 后，已核对同一探针/芯片 UID，重新保存完整 Flash，写入 Pointer 候选并独立读回一致。
记录：`results/mt2-flash-pointer-20261105/flash-result.json`。
用户单接 USB2→Book 后，iface0/1 改由 AppleUserHIDEventService 接管；iface6 保持完整多点设备。
驱动误接管问题在本机得到修正；尚不能据此称绝对坐标、拖选或自动返回通过。

之后加入 USB1 的第二路连接没有枚举。换 Book 端口仍未出现。
同一根第二路线移到 DBG 后，独立 WCH-LinkE A47C8F062A1A 正常枚举，目标 USB2 仍在线；
这证明该线和该 Book 接口支持数据，但不能排除 USB 高速信号质量或数据口启动/热接恢复问题。
本次只读系统枚举，没有连接调试器或暂停芯片。
已请求把 DBG 线移回 USB1 并轻按 RESET，检查晚接入的数据口能否恢复。
绝对定位测试仍待双口同时在线；Book 的活动屏幕为 1512×982（读取时），没有发送定位/点击/文字动作。

## 后续状态及 2026-11-06 继续诊断

用户移回 USB1 并 RESET 后，仍仅 USB2 枚举。该次复位没有验证晚接恢复假设。
Book 实际 iface1 属性显示 `MultiAxisPointer`，绝对 XY 为 Preferred State；不能按普通绝对鼠标验收。
证据：`results/mt2-flash-pointer-20261105/book-dual-after-reset.json`、`book-pointer-parser-properties.json`。

已构建 NoPreferred 独立候选 `candidate-stage1-pointer-nopref-20261105`，71,704 字节，
SHA-256 `be9df7f1e72e48ec9fc2c8de0b2a287ebb3c3870f83ed962641667b5f57b7c68`。
与已刷 Pointer 候选只差 XY Input `02→22` 和版本 `0269→026a` 两字节；5 项离线测试通过。
本段记录时尚未刷写，不能据此宣告绝对定位修复。

三线都接 Book 的首次调试读取已正常恢复运行。记录在 `results/mt2-dual-diag-20261105/`。
首个身份检查仅因 UID 日志带连字符而中止，finally 已 resume；随后规范化 UID 后读取成功。
读取使用探针 `Program::ReadMemory`，RCC 快照与运行中的高速 USB 不一致，存在探针算法干扰疑点；
这批 RCC 数值不作为固件时钟根因证据。改用保存/恢复 CPU 临时寄存器的独立 DMI 工具继续取证。

2026-11-06 用户确认三根线仍全部接 Book。首次检查见 Host 与 DBG，随后 Host 消失。
内核日志记录 Type-C cable disconnected/powering off；目前不能仅据此归因固件、线缆或供电。
原控制器与 capture 未运行；mini 未连接。日志：`results/mt2-dual-diag-20261106/usb-kernel-log.txt`。
此次继续诊断尚未写固件，尚未发送定位、点击、文字或手势。

## 2026-11-06 NoPreferred 实机结果

直接 DMI 工具保存、恢复并核对 x5/x6 与 progbuf0/1，结束确认 allrunning。
快照 `results/mt2-dual-diag-20261106/direct-dmi.json` 的 DPC 对应当前 ELF 的 `wk407_now_ms`；
不能把非零历史 mcause/mtval 单独当作正在 fault。RCC 仍与预期时钟位不符，AttachChip 的影响尚未排除。

用户指出 Book 必须保留充电口。后续测试最多占用 Book 两个口；不再要求长期三线连接。
用户仅接 DBG 后，重新核对完整探针/芯片 UID、备份 Flash，写入 NoPreferred 候选并独立读回一致。
记录：`results/mt2-flash-nopref-20261106/flash-result.json`。

冷启动双数据口接 Book 时，只有 Host 出现；`MT2?` 回复 resets=1、gets=0、sets=0。
使用原已在线 USB1 的线单接 USB2，电脑端保持不动后，Target 026a 在同一 locationID 枚举。
iface6 保留完整多点设备，但 iface1 的通用驱动既无 MultiAxisPointer，也无 AbsolutePointer，
仅见 Scroll 与 SurfaceDimensions，RegisterService=false。因此 NoPreferred 未通过绝对指针识别检查。
证据：`book-target-known-cable.json`、`absolute-driver-properties.plist`（同上述结果目录）。
没有发送定位、点击、文字或手势；不将本候选交给 mini 使用。

已准备仅发送五个 A 帧的 Book 指针探针，默认离线；只在实际 AbsolutePointer 属性和精确描述符匹配时执行。
两线模式允许使用刚验证的 flash-result 作为用户确认同一块板的关联证据，不能称 USB 序列号唯一。
8 项离线检查通过，但当前候选不满足轴识别前提，未执行实机定位。

为恢复用户可用控制，已请求把单根 USB2 线移回 DBG；等待用户确认后回写已验证的原键鼠固件。

## 2026-11-06 原控制恢复并获用户确认

原固件 28,524 字节已回写，独立读回 SHA-256 `53b4b741a9212ffb3c8a89dcb9aef282b4b3643bbf2a11696f8c23e5e97a6e70` 一致。
仅 USB1→Book、USB2→mini、DBG 留空；Book 充电口可保留。
当前串口从 IORegistry 重新发现为 `/dev/cu.usbmodem1101`，`CPP_USB_HID_READY` 通过后启动保留的输入专用控制程序。
捕获就绪，进程持有当前串口，日志记录两次跨屏/自动返回；用户明确确认“能控制，也能返回”。
`WKINPUT_STARTED role=host clipboard=0 files=0`；本轮未启用剪贴板同步。
运行证据：`results/mt2-rollback-control-20261106/active-runtime.json`。PID 是当时状态，不应跨日直接复用。
四指与短滑流畅度仍未完成；NoPreferred 缺少属性是未通过检查，并非真实坐标注入失败的证据。
