# 2026-11-05 输入通道恢复

本文件记录本次变更与证据，不代表之后的实时状态。

## 问题与根因

- 用户报告 Book/mini 双指滚动方向相反，mini 四指无效。
- 运行中的 native 命令没有 `--invert-scroll`，也没有中继 socket；捕获日志显示 `GESTURE_CAPTURED ready=0`。
- Book 的私有 `input-mode.json` 已是 `gestures`。旧版的 `CaptureGesturePacer` 和鼠标/妙控板识别源码都已恢复，但滚动/手势仍被 `wiredClipboardEnabled` 门控。
- 用户引用的历史会话中，0.6.8/build18 Book 与 0.6.7/build17 mini 曾得到“四指完整完成，其他手势与滚动正常”的确认。那是两端软件中继，不是固件独立模拟妙控板。

## 变更

1. capture 新增独立 `WK_WIRED_INPUT`，兼容原有剪贴板启用方式。不启用跨机复制粘贴拦截。
2. native 新增 `--input-socket`，与 `--clipboard-socket` 互斥。只允许 `WKSC/WKG1/WKG2` 双向通过；未知、剪贴板、文件报告均丢弃。
3. 新增 `WKInputRelay`，由 Companion 的 `--input-only --headless` 入口运行。该入口不创建剪贴板、Finder portal、安装器或文件流。
4. 输入模式的 capture 控制管道也设为非阻塞，避免 LINK/RETURN 卡住事件循环。
5. 本次启动启用 `--invert-scroll`，修正当前纯 HID 回退的两轴方向。像素中继保持 Quartz 原方向，不叠加反向。
6. 沿用 `WKPointingSource`：硬件 sender、MayBegin、阶段关联及设备列表共同判断；未知设备不冒充妙控板。

## 验证

- 完整 macOS 候选构建成功。构建器用 Rust，保留已有 C++/Swift 实现；没有重写固件。
- `test_clipboard_native.py`：7 项通过，含输入与剪贴板隔离、合成 HID/边缘返回、通道拥堵、断线及 CRC。
- `test_independent_input.py`：6 项通过，覆盖 7 种运行配置；验证实际 Unix socket 中继、鼠标/妙控板/未知来源、两轴方向、Dock 手势阶段、Book 本机输入直通。
- `input_relay_selftest.swift`：10 项通过，未编译剪贴板内容或文件服务模块；未注入真实事件。
- 新 capture 的现有辅助功能授权检查为 `true`，无需重建授权。
- 最初 socket 测试在沙箱内遭拒；使用受审查的本机回环测试通过。恢复源码中的合成 capture 脚本缺执行位，已恢复该执行位后通过集成测试。

## 部署与限制

候选位于 `build/input-relay-20261105/runtime/`，原程序未覆盖。启动参数、PID、回退命令在 `results/input-relay-20261105/active-runtime.json`；源码及二进制 SHA 在同目录 `build-manifest.json`。

已启动输入模式，日志确认 capture 和本地 relay 在线、识别到 trackpad。此时尚无目标 `WKSC` 能力报文，因此不能把捕获就绪当作 mini 四指通过。用户反馈 mini 的旧 Companion 打不开或找不到；远端诊断连接器返回 Internal error，未借此猜测目标安装状态。

固件未写入，系统滚动设置未修改，跨机剪贴板仍关闭。本次没有恢复或安装 mini 组件。用户随后明确确认“方向一致，返回正常”，因此这两项已通过本次实机验收。完整四指仍待目标组件恢复，或另行验证固件模拟 Apple 妙控板协议。

固件模拟属于尚未验证的替代路线：需要匹配多触点报告与初始化握手，并测 macOS 驱动识别。将手势映射为 USB 键盘快捷键是另一种较简单方案，但不等于连续原生手势。
