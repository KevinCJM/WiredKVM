# 2026-11-05 双指短滑优化及用户验收

## 范围

仅修改 Book 捕获器的 HID 滚动回退转换。当前部署为 `WK_PIXEL_SCROLL`、desktop absolute、input-only，目标没有 WKSC 像素能力响应。没有刷固件、安装 mini 程序或修改系统设置。

## 代码与证据

`host/macos_capture.swift` 在当前生产模式下，对已识别的连续 trackpad 事件使用 FixedPtDelta 的 Double 值，不再先丢弃小数。最近整数舍入保留有符号误差，方向判断使用最后一个非零输入符号。保留零事件/边界复位、iPhone 旧整数路径、鼠标/未知源路径及原生像素路径。兼容构建未启用 WK_PIXEL_SCROLL 时原本以 continuous 推断 trackpad，新算法也作用于该旧推断路径；不据此宣称所有构建都具备设备识别。

14 项滚动测试、7 项生产路径测试（9 种配置）、3 项候选二进制安全自测通过。未向系统注入测试输入。相同合成输入比较旧/新源码：每次 1 行、比例 0.25 时，首输出从第 4 个样本提前至第 2 个；固定点 0.25 行、整数为 0、比例 0.35 时，旧源码 24 次无输出，新源码第 6 次输出。此数据是离线转换测试，不是实机延迟。

候选路径 `build/scroll-short-20261105/macos-capture`，实际部署记录、回退命令及哈希位于 `results/scroll-short-20261105/active-runtime.json` 和 `result.json`。旧二进制保留在 `build/input-relay-20261105/runtime/`。输入中继仍使用该旧目录的二进制；没有改动文件或剪贴板通道。

## 用户验收

用户明确反馈：“仍卡顿，方向和返回正常”。因此本次只能记为量化转换改善，**短滑卡顿尚未解决**，不能记录成功修复。普通整数 HID 滚轮仍限制输出细度；继续验证像素级接收或固件触点模拟。

## 后续研究

见 `docs/research/MT2_FIRMWARE_FEASIBILITY_20261105.md`。存在 USB 模拟 Magic Trackpad 2 的开源实例；这不等于当前 CH32 固件、复合设备布局和 Book 触点来源已经通过实机验证。完整四指仍未恢复。
