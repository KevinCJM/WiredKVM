# 实时触点转发候选，2026-11-09

当前状态：native-v2 已部署；用户确认双指、四指、自动返回及四项保留功能正常。当前运行快照见 `results/live-touch-20261109/CURRENT_RUNTIME.json`。高速双向剪贴板仍未完成。下文按阶段保留历史状态，不能把早期候选或失败状态当作当前运行状态。

## 实现

1. Book 的 Rust helper 只选择经过 registry ID、built-in、SPI、Product 核对的内置妙控板。私有 96 字节 ABI 仍限本机 macOS 15.6.1。
2. 原始回调只解码并尝试写入 128 帧有界队列，不做串口、文件或 stdout I/O。溢出显式终止手势；不静默丢掉最后一帧。
3. Swift 捕获器独占向 native 的输出。helper 使用独立 Pipe；主线程定时排出至多 64 条暂存记录，不让异步 stdout 字节交错。
4. native 独占 CDC。只有已进入被控屏幕、目标版本匹配且 MT Feature 已启用，才接受当前 epoch 的 `H B/D/E`。转换成严格的 `MT2B/D/E` 指令，不能透传任意固件命令。
5. 固件 Rust 队列保留触点增减和释放顺序；同一触点集合的移动可以合并。16 槽容量，独立于键鼠与两个 Bulk 队列。
6. 新增触点只从 USB2 EP87 发出，最快每 4 ms 一帧。既有按键、按钮、绝对位置及自动返回逻辑保留。单指定位和普通鼠标滚轮沿用旧通道；多指接触不再重复发送整数滚轮或 Book 生成的惯性。
7. 返回、退出、来源失联、Feature 关闭和 USB 复位均撤销旧会话。旧 DMA 用 NAK/SIE 空闲/DONE 清除规则退休，不 close/open 或重置 DATA toggle。先释放，再接新会话，旧 epoch 不可重放。
8. 来源活动断流 120 ms 则 helper 释放；固件触点/在途报告租约 180 ms。没有触点的空闲会话不因久等而失效。源状态 5 为离开，不能当作持续按下。

所有进程只运行在 Book。未访问 mini 的终端、文件、共享服务或剪贴板，未在 mini 启动组件。

## 离线证据

- Rust 触点协议/队列：10 万帧移动、1 万次取消与新会话、旧 DMA 完成竞争、来源断线、时钟回绕、空闲后新手势。
- 真实 WCH SDK 核心：EP87 的 1,000 次取消/重传、两种 DATA toggle、SIE 忙、DONE 竞争、复位及并行 Bulk；错误 W0C 实现的变异测试必须失败。
- 实际生成的 C 主循环 + C ABI + Rust 核心：双向 Bulk 队列满载下 1,000 轮键盘/绝对位置/触点混合，验证真实完成回调、释放与旧 epoch 丢弃。只模拟 USB 边界。
- C++ 触点队列：10 万帧、有界排队及释放顺序。
- Swift helper 生命周期：本机/目标门控、回屏后延迟帧过滤、新 epoch、关闭硬件能力。
- 原有主控回归：滚动/来源识别/本机剪贴板、拖选、自动返回、断线、ACK 重试及普通键盘事件。沙盒阻止图形 XPC 或回环端口的测试，在正常权限范围重跑并另存结果，不计为代码通过。

证据和二进制清单位于 `results/live-touch-20261109/`。实测延迟、四指动作、短滑手感、mini 键盘/拖选/返回均仍待验收。

## 本轮发现并修正

- 原 stage-1 的 input_done 是提交时清理暂存零帧；不能把它当作 USB 完成。实时队列的 done 已接到真正 data_cb，完整主循环测试覆盖两帧先后到达。
- 所有移动只保留一帧会吞掉手势结束，改为只合并相同触点拓扑。
- 空闲等待和已释放后的会话不应触发触点租约。
- 新手势若直接出现 MakeTouch，可立即开始；已按住的旧触点须先离开，避免跨屏重放。
- 初次 Swift 编译缺 main.swift 入口名，测试编译又缺显式 module-cache/target；已改用隔离入口和工作区缓存。

## 实机下一步

先只接 DBG，核对唯一调试器完整序列号、芯片 ID、UID，备份并刷写候选、独立读回比较。再只接 USB2→Book，检查各接口驱动绑定和 Feature；然后断电，恢复 USB1→Book、USB2→mini，用本机主控候选转发真实触点。mini 无独立键鼠，必须保留原固件与旧 Book 配置的回退路径。

Book 的稳定自动服务二进制不用更换：候选 native 支持专属进程环境 `WK_RAW_TOUCH_HELPER`；主控配置可指向已核对哈希的新 native/capture。当前配置尚未切换。旧 input-only relay 只在 Book 运行，不是 mini 组件。

## 尚未完成

触点坐标按 Linux MT2 的范围映射；形状/压力使用显式合成值，未标定，不是实际接触面积或压力。macOS 是否接受并生成顺滑双指/四指动作，须实机确认。仅离线与驱动绑定不能判通过。

USB Bulk 调度仍在，但 Bulk 本身不能读取或写入 mini 的系统剪贴板。当前没有符合“被控端不安装、不运行程序，也不用共享”的双向系统剪贴板入口；未启用旧目标组件方案，不能宣称高速双向复制粘贴已完成。

协议依据：[Linux HID Magic Mouse/MT2 驱动](https://raw.githubusercontent.com/torvalds/linux/master/drivers/hid/hid-magicmouse.c)、[bt2usb 的 MT2 USB 头与时钟实现](https://raw.githubusercontent.com/timothyb89/bt2usb/53ecc1f728a44fdf20b7c950bd37c1855937b749/bt2usb/src/mt2_translate.rs)。这些公开实现不等于当前 mini 驱动的实机证明。


## 实机进展与兼容修复

首个实时固件 `a4df4824...` 已按唯一 DBG 序列号和芯片 UID 核对，整片旧 Flash 备份后写入，独立读回一致。Book 的 USB2 实测：原始接口0/1仍绑定 TopCase/通用事件服务，iface6 绑定 AppleMultitouchTrackpadHIDEventDriver 与 AppleMultitouchDevice；SupportsGestureScrolling 与 TrackpadFourFingerGestures 为 true。仅对该 iface6 非独占读 Feature2，返回 `[2,1]`。这些是枚举/握手证据，不是滚动/四指实机验收。

接回两端时发现自启服务还检查完整 USB 产品名：候选沿用通用 `WiredKVM CH32 Host`，服务要求 `WiredKVM Petros V467 Host`，因此没有启动控制。已在仅实时候选的描述符覆盖中改回旧名称，增加实际 descriptor 字符串检查；原服务二进制及辅助功能授权保持不变。不得再以 VID/PID 相同推断完整身份兼容。

候选还增加 `rx/max_contacts/inputs` 聚合诊断；inputs 表示 EP87 成功提交，不能称为应用处理或手势验收。主控保底已修正：Feature 未开启或固件不支持实时扩展时，保持旧键鼠通道，不能让一个新功能阻止键鼠启动。

首次硬件枚举脚本漏处理 ioreg plist 的字典根节点；shell 多语句仍继续了 status 读取。实读 UID 与授权板一致，未刷错设备。后续刷写改用单个结构化 Python 脚本，列表/字典均遍历，先断言完整身份，再执行每条 check 返回码的 wlink 命令。完整旧 Flash 与配置保存在 `results/live-touch-20261109/hardware/`。


## mini 实测失败与已恢复状态

实际记录到 CH32 `rx=535,max_contacts=4,inputs=538,faults=0,errors=0`，但用户明确报告双指和四指均无响应。因此仅“收到触点、EP87 提交、驱动启用”不能判定手势通过。已关闭 Book 的 WK_RAW_TOUCH_HELPER 环境，恢复旧捕获器；用户确认滚动和返回均恢复。当前仍用 `6f40340e...` 实时固件，实验入口无调用者，普通输入工作；不是已恢复成原 28524 字节固件。

当前自动服务匹配固定子进程 basename；把候选命名为 macos-capture-v2 会导致每8秒重试。已使用版本目录 `runtime-v5/`，目录内恢复 wiredkvm-native/macos-capture 原名，二进制字节不变。launchctl bootout 后立即 bootstrap 曾短暂返回5，待原标签注销后恢复成功。当前配置保留正常服务与旧捕获器；见 `results/live-touch-20261109/CURRENT_RUNTIME.json`。

## 新发现的报文缺项，尚未实测修复

独立交叉核对 VoodooInput 的 MT2 packed layout：13位X、13位Y之后，不是6位保留位，而是3位 Finger 与3位 State。Finger=0 表示 Undefined；旧映射器恰好一直输出0。原生 State 的 Start=3、Active=4、Stop=7；仅用 Linux 的最高两位无法表达完整状态。USB头的三个时钟字节共同组成时钟，最低三位含标志；不能把最高字节0x88当常数，也不能每8秒仅回绕16位。

现已增加独立 Rust native_format、协议v2队列验证及 forward_native 映射：显式手指类型、1..15标识、Start→Active→Stop→Inactive 生命周期、完整三字节时钟及低位标志。它仍属新候选，未替换目前可用控制。USB presence 继续用真实USB资料的1/0，不混用 VoodooInput 的 I2C 3/2标志。下一次先在Book观察被模拟USB设备经原生框架解码的触点，不能再把USB提交计数当验收。

来源：[打包字段与状态定义](https://raw.githubusercontent.com/acidanthera/VoodooInput/master/VoodooInput/VoodooInputSimulator/VoodooInputSimulatorDevice.hpp)、[构造与完整时间戳](https://raw.githubusercontent.com/acidanthera/VoodooInput/master/VoodooInput/VoodooInputSimulator/VoodooInputSimulatorDevice.cpp)、[手指类型](https://raw.githubusercontent.com/acidanthera/VoodooInput/master/VoodooInput/VoodooInputMultitouch/VoodooInputTransducer.h)。这些源码用于独立校核协议字段，并不证明当前USB候选已获macOS接受。


## native-v2 实机验收与当前可用版本

固件 `9322b86a3e70b272e71716d1051ec641783afdd33b8d0fc40452608f33d0866b`（77,232字节）已写入同板并独立读回一致。USB1→Book、USB2→mini、DBG留空。Book 自动服务原二进制和授权身份保持，实际运行 native-v2 目录中的 native/capture 和协议2 helper。helper 的活动构建目录不得覆盖，已另存冻结备份与全部运行程序哈希。

用户先明确回复“**双指、四指和返回都正常**”，再确认“**四项都正常**”：Book内部新文字复制粘贴、mini内部新文字复制粘贴、mini左键拖选、双指方向与Book一致。它们是用户实机反馈；并非仅从EP87提交推断。短滑已能操作，但没有测量滚动延迟，也没有独立量化卡顿改善。当前最新聚合计数为 rx=1035、max_contacts=4、inputs=1063、faults=0、errors=0；inputs仍仅表示USB提交。

本次没有在 mini 启动本项目程序、脚本、组件，也没有使用共享功能。单指/普通鼠标仍走原定位通道，多指走实时触点。不得因实验部分成功替换稳定运行路径或改动正在使用的helper输出文件。

Book双数据口解码台架因USB2未收到总线复位而阻断，未注入测试触点。用户只有USB-C数据线，未继续要求三线同时接Book。记录这一限制后改为mini受控实测并保留Book立即回退，结果由上述用户反馈确认。任意插入顺序、实际Book重启、Windows及大文件满速时的真实输入延迟仍未验收。

早期“120ms没有回调就释放”已被替换：静止手指可能没有新回调。现在按框架运行状态、队列溢出、进程/USB/会话生命周期撤销，16ms重复有效快照；固件保留180ms活动租约。

### 持续Bulk离线测试与测试夹具修正

`native-continuous-bulk-fixed.log`通过：真实生成的C主循环、Rust核心和完成回调，在两个Bulk方向每轮补满的条件下混合运行1,000轮输入/触点。两个Bulk输出各至少1,000次，旧epoch被拒绝，取消释放与新触点推进正常。这只证明模拟调度；没有访问物理设备，也不等于端到端文件吞吐或输入延迟验收。

增加持续补满测试时，首次夹具用0x5a无效数据配合“还有空间就补”循环，协议解析器正确丢弃数据，空间不减少，测试120秒超时。已改为合法WKS5二进制单元、明确会话/事务准入、最多队列槽数次补充，并逐次断言队列增长；固件和活动程序未因此修改。原超时日志保留，不计为通过。

### 高速双向剪贴板的剩余边界

重新核对实际源码：`WKOnDemandClipboard.swift`的WKCompanion负责系统剪贴板会话；`WKClipboardContent.swift`通过NSPasteboard读取正文及写回文字/图片/文件URL；`WKStreamFiles.swift`是该组件的正文传输层。`native/clipboard_channel.hpp`只转发报告，不拥有系统剪贴板语义；CH32 bridge只做准入、独立队列与有界转发。当前Book中继保持input-only。

因此当前代码仍没有符合“mini不安装、不临时运行程序、不用共享”的目标剪贴板系统入口。未启用旧组件、未读取mini剪贴板、未制造新伪入口。文字、图片、多文件、文件夹的高速双向⌘C/⌘V未交付；历史有组件版本的成功不能算到本次零运行版本。

完整快照、固定程序哈希及用户验收：`results/live-touch-20261109/accepted-native-v2/`。
