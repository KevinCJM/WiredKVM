# 四指手势与 USB 妙控板模拟：证据及验证方案

日期：2026-11-05。范围：代码/网络研究与隔离离线协议原型；本子任务未刷板、未更改正在运行的控制器。

## 结论和证据边界

**存在可研究的固件实现，不应再将“mini 必须装组件”说成绝对限制。** `bt2usb` 作者报告在 Pico W 上通过 USB 模拟 Magic Trackpad 2，使 macOS 无目标端组件接收精细滚动及多指触点。它的 USB 输出部分有完整 Rust 源码。无线仅是该项目的输入来源；WiredKVM 可以研究用已有有线通道代替。

WiredKVM 候选链路保持全有线：Book 捕获 → USB1 → CH32 → USB2 → mini。这里只研究 `bt2usb` 的 USB 输出协议，不引入其蓝牙前端。

这是第三方实现及作者测试报告，**不是我们 CH32V467 板的实测结果**。当前 CH32 固件仍只输出普通键鼠 HID。未证明现有复合设备加入 Apple 模拟后，键鼠、文件和自动返回仍正常。

`bt2usb` 固定研究版本：`53ecc1f728a44fdf20b7c950bd37c1855937b749`，提交日期 2026-04-14。此日期不表示全平台兼容期限。

## 已核实的固件实现

| 证据 | 源码事实 | 对本项目的含义 |
|---|---|---|
| [mt2.rs L17-L25](https://github.com/timothyb89/bt2usb/blob/53ecc1f728a44fdf20b7c950bd37c1855937b749/bt2usb/src/mt2.rs#L17) | 整个 USB 设备采用 `05ac:0265`，提供 MT 激活状态 | 不是只给普通鼠标增加“Touch Pad”名称 |
| [mt2.rs L29-L99](https://github.com/timothyb89/bt2usb/blob/53ecc1f728a44fdf20b7c950bd37c1855937b749/bt2usb/src/mt2.rs#L29) | 110 字节复合 HID 报告描述符 | 包含普通指针、Digitizer 和厂商多触点集合 |
| [mt2.rs L159-L258](https://github.com/timothyb89/bt2usb/blob/53ecc1f728a44fdf20b7c950bd37c1855937b749/bt2usb/src/mt2.rs#L159) | Feature `01/02/DB/99` 查询、状态与激活握手 | 只补一份报告描述符不足以工作 |
| [mt2.rs L264-L374](https://github.com/timothyb89/bt2usb/blob/53ecc1f728a44fdf20b7c950bd37c1855937b749/bt2usb/src/mt2.rs#L264) | 独立 actuator 接口及配置回读 | 完整点击语义还有附加接口；研究期宜保留现有普通按键/点击路径 |
| [mt2_translate.rs L14-L36](https://github.com/timothyb89/bt2usb/blob/53ecc1f728a44fdf20b7c950bd37c1855937b749/bt2usb/src/mt2_translate.rs#L14) | 12 字节 USB 头，每个触点 9 字节，最多 5 指为 57 字节 | 4 指为 48 字节，可装入一个 64 字节中断包；带宽不是主要障碍 |
| [mt2_translate.rs L63-L143](https://github.com/timothyb89/bt2usb/blob/53ecc1f728a44fdf20b7c950bd37c1855937b749/bt2usb/src/mt2_translate.rs#L63) | 真实 MT2 触点透传、坐标插值、单调时间戳 | 多指能力来自原始触点输入，不能当作“CGEvent 已能合成四指”的证据 |
| [usb.rs L354-L388](https://github.com/timothyb89/bt2usb/blob/53ecc1f728a44fdf20b7c950bd37c1855937b749/bt2usb/src/usb.rs#L354) | 固定 4 ms ticker，不随输入到达重启定时 | 避免输入不断到来时饿死滚动输出；不能盲目复制其时间/平滑参数 |
| [usb.rs L637-L787](https://github.com/timothyb89/bt2usb/blob/53ecc1f728a44fdf20b7c950bd37c1855937b749/bt2usb/src/usb.rs#L637) | 键盘、MT2、actuator、厂商 RPC 为多个 USB 接口 | 证明这种复合思路存在；未证明我们的 CDC、MSC、绝对鼠标组合被接受 |

注意源码注释与实际报告格式并非处处一致：部分注释称触点发 `0x44`，实际模板和 `Mt2Passthrough` 发以 `0x02` 开头、内部含 `0x31` 的报告。开发时须依据实际字节和抓包验证，不能只照注释。

该仓库 [README](https://github.com/timothyb89/bt2usb#magic-trackpad-2-input-support) 说明 Force Touch 查词不工作，第三方手势工具未测试；且 README 声明大量代码由 AI 生成。本次核查代码而未运行其固件。

## Book 现有事件可以做什么

本地 `host/macos_capture.swift` 的 `gestureTapCallback` 在远端控制时捕获会话层手势；`host/clipboard/WKGestureRelay.swift` 的 `WKGestureEnvelope` 接受类型 `18/19/20/29/30/31`，其中 DockSwipe 是 type 30、subtype 23。已有通路保存 begin/change/end/cancel 和连续进度，但只在目标组件完成能力握手后发送。

**当前代码没有逐指原始触点采集。** DockSwipe 说明操作系统已识别桌面手势，不能可靠说明它由三指还是四指发起。具体指数量受 Book 的系统手势设置影响。不要把“识别到 DockSwipe”记录成“抓到四个触点”。

私有字段依据来自当前代码及 [Mac Mouse Fix TouchSimulator](https://github.com/noah-nuebling/mac-mouse-fix/blob/c57baf73e53329acd637268eb26bc66ed173c7e1/Helper/Core/Touch/TouchSimulator.m#L241)：123 为轴，124 为累计进度，132 为阶段，129/130 为退出速度。它们不是 Apple 的稳定公开 API；新系统需复验。

有两条实施路线：

1. **动作映射，最小改动**：Book 识别桌面手势，在既有 HID 键盘链路发送 Control+方向键。mini 无组件、无需刷固件，可完成切桌面/Mission Control/App Exposé。系统快捷键可自定义，因此不能默认保证每台机器相同。只实现一次动作，不提供随手指连续展开、反向拉回的动画。
2. **触点模拟，目标体验**：Book 采集实际多触点（需另验证系统 API/权限），或从 Dock 轴与进度构造 4 个虚拟触点，CH32 输出 MT2 USB 报告。后者不是原样透传，须校准 mini 的识别阈值、速度和取消。两指像素事件已经过 Book 加速/惯性，直接当触点位移再送 mini 可能被再次加速/产生双重惯性；须明确唯一惯性来源。

Apple 资料：[切换桌面用 Control+左右](https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/mac)，[Mission Control 用 Control+上；App Exposé 用 Control+下](https://support.apple.com/guide/mac-help/view-open-windows-spaces-mission-control-mh35798/mac)。方向必须用本机实采事件校准，不能仅凭进度正负猜测。

动作映射的最低保护：只在远端、来源为 trackpad、独立输入模式启用时执行；每个有效手势只发一次；cancel 不触发；返回/断线/超时清状态；只释放合成的键，保留用户按住的键；本机手势及本机复制粘贴直接透传。不要把每个 changed 包都变成快捷键。

## CH32 集成约束

当前代码实读位置：

- `firmware/ch32v407/descriptors.c`：target 为 `1a86:4071`；6 个接口为相对键鼠、绝对指针、vendor HID、CDC 控制/数据、MSC。接口/端点号码已有消费者。
- `firmware/ch32v407/main.c`：端点数组 `[2][7]`，循环只注册 1..6；HID 状态数组长度 3；`interface_setup` 未实现 MT2 Feature 握手。
- `firmware/ch32v407/bridge.h`：普通 HID 包数组只有 16 字节，不能直接容纳 48 字节四指报告。
- `firmware/ch32v407/main.c::service`：现有 HID 优先于文件，每次有界处理；需要继续保持。
- `host/clipboard/WiredKVMCompanion.swift`：target 搜索写死 `1a86:4071`；改设备身份会改变发现路径。

USB VID/PID 是设备级身份，不能在一个普通复合设备的新增接口上单独使用另一组 VID/PID。因此“在原设备上加一个独立 MT2 HID 接口、保证原功能不变”目前没有证据。开发实验可以保留原键盘/绝对鼠标报告和 Bulk 端点，增加单独的触点状态/队列，但还必须验证 Apple 驱动是否接受该复合布局，以及 CDC/MSC 能否正常绑定。

### 当前 Book 驱动匹配的本机证据

主任务只读提取了 Book（macOS 15.6.1，24G90）的 AppleTopCase 驱动 Info.plist，证据位于 [`book-driver-match.json`](../../results/mt2-research-20261105/book-driver-match.json)。源 plist 的 SHA-256 为 `d073f38e074db247b23291512c54478e8a6f65d9ba66f446841559befb6ff9e4`。

- USB 接口驱动条件为 Apple VID `1452 / 0x05ac`、PID 数组含 `613 / 0x0265`、配置 1，`bInterfaceNumber="*"`。
- 多点事件驱动条件为同一 Apple 设备身份及 Generic Desktop / Mouse usage（Page 1、Usage 2）。
- 由此可推断：改整个设备的 VID/PID 后，**旧绝对鼠标等 Mouse collection 也可能匹配 Apple 多点驱动**。只在新增接口放 MT2 描述符，不能排除此风险。

这是当前 Book 的静态匹配规则，不是 mini 的驱动实测，也不是实际错误绑定的证据。下一次候选固件实机阶段应先让 **USB2 接 Book 做枚举/驱动绑定检查**；不向工作中的 mini 直接交付。确认旧普通键盘、鼠标、绝对指针接口仍能正确绑定之前，不做触点输入和 mini 接管。

输入调度建议：触点 begin/end/cancel 不丢；移动只保留最新帧，禁止积压过时动画；紧急释放有独立容量；每轮优先键盘/按钮/边缘返回，再触点，再 Bulk。所有触点离开及 USB reset 清零要有独立测试。

## 分步验证，不直接替换可用固件

1. 离线实现并测试有界触点编码器/Feature 状态机，覆盖 0/2/4/5 指、坐标越界、时间戳回绕、取消及队列满。先不要用额外 PSRAM 掩盖 V407 资源限制。
2. 保留当前精确固件和回退流程，建立独立 CH32 实验 build profile，不作为默认构建，不自动刷板。保留普通键鼠与自动返回实现。先将 USB2 接 Book，仅验证枚举、各接口实际驱动绑定、Feature 握手及空触点报告。尤其验证旧 Mouse 接口没有被错误接管；未成功之前不向 mini 交付、不发触点输入。
3. 在明确测试页面发送两指短滑，再验证四指水平/垂直；同时核对普通键盘、拖选、鼠标位置及边缘返回。比较真实 CGEvent 输出和体感，不能把 USB ACK 当作手势成功。
4. 验证中途撤回、快速新手势、主机睡眠/唤醒、拔线、鼠标和妙控板混用。
5. 复合设备功能全部恢复后，再压测双向大文件并记录输入尾延迟、停止响应、文件哈希及本机复制粘贴；通过前不能称替代生产方案。

已新增 [`experiments/mt2-usb`](../../experiments/mt2-usb/README.md)：无第三方 crate 依赖的 `no_std` 编码器及可选 C ABI。18 项离线测试通过。C ABI 第一阶段只暴露描述符/Feature，激活后最多发一次零触点报告；不发布 WKSC 像素能力、不接管滚动、不合成手势。它不证明 CH32/macOS 可用。

## 许可证与商业身份

`bt2usb` [Cargo.toml](https://github.com/timothyb89/bt2usb/blob/53ecc1f728a44fdf20b7c950bd37c1855937b749/bt2usb/Cargo.toml#L1) 和 README 声明 `MIT OR Apache-2.0`；本次目录树中未见独立 LICENSE 文件。真正复用前保存许可声明、作者归属并逐个核对引入文件，不把外部固件整体复制进主构建。本次没有复制其代码进产品。

其 Apple VID/PID/品牌模拟是实验兼容办法，开源代码许可不等于获准使用 Apple 的产品身份。量产仍需单独确认合法设备身份和 macOS 驱动匹配方案；不能依据技术演示将这点默认为已解决。

本研究不要求购买任何新硬件。现有 CH32V467 板先用于协议实验；只有明确实验失败原因后，才讨论是否需要硬件改动，不能提前承诺最终原生兼容验收结果。
