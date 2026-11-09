# 取消修正版固件写入（2026-11-09）

用户明确回复已只连接 DBG→Book，USB1、USB2 已拔。此前接线阻塞已解除，本轮继续实机步骤。

- 实际 USB 枚举仅有 WCH-Link `1a86:8010`，完整序列号 `A47C8F062A1A`，registry ID
  `4294977864`。未选其它 ESP32。WCH status 实读芯片 ID `0x46740011`、UID
  `ad21ad506c54c6c6`；状态查询会停核/扰动时钟，仅在此次 DBG 单口窗口使用。
- 暂时 bootout `gui/501/com.wiredkvm.control-autostart`，等待任务退出并确认没有控制/
  capture 子进程；原 plist 已备份，未重签或重新申请权限。测试结束须恢复服务。
- 完整读取 576 KiB；其前 28,524 字节与可用回退 SHA `53b4b741...a6e70` 一致。
  全片备份 SHA 与原始日志保存在 `results/mt2-flash-cancel-20261109/`。
- 写入仅审核候选 SHA `0c8da9dd860070794a2ebc9eebb6ae1f69ec46407d5f9cf4637654f6cd79d8dd`，
  74,792 字节；flash/readback 均保持 no-detach，独立读回逐字节完全一致。
- 最后执行 WCH `Reset::Soft` quit-reset/run 命令。`reset_run=true` 记录已执行的探针命令，
  不表示已验证 USB 枚举或定位。凭据明确 `runtime_enumeration_verified=false`。

下一步已请求：拔 DBG，整板断电 5 秒，只连接 USB2→Book，USB1、DBG、mini 均留空。
收到接好回复后先读真实枚举、接口绑定与描述符，再运行绑定该固件 SHA 的五点定位工具。
定位成功仅证明绝对坐标；不代表四指、顺滑滚动、自动返回或跨机剪贴板通过。

本次未在 mini 运行代码、未使用系统共享、未修改剪贴板。当前为实验固件，不能让用户
直接接 mini 当作可用控制版本；物理试验结束后按结果恢复已核对的可用固件和 Book 服务。

## 后续 Book 测试与恢复

- 用户接成 USB2 单独到 Book；识别 `05ac:0265 / bcdDevice 026c`、serial
  `CH32V407-DoNotShip`、registry ID `4294978537`，无 USB1、DBG 和旧控制进程。
- 绑定此固件 SHA 的 Rust 工具实测五点成功，最大误差 `1.042429` 个屏幕点，原光标恢复。
  结果在 `book-five-points.json`；只证明本机绝对位置派发，不代表普通键鼠/边缘返回/手势。
- 30 秒 Book 内置 SPI 触点观察收 529 帧，0 invalid/dropped，用户确认完成两指/四指动作。
  旧规则计 15 个“四触点帧”，含 state 5；之后修正 state 5 为 BreakTouch。旧统计不能当作
  严格四指 down 帧数。位置/时钟/ID 前缀获得真实输入证据，压力/形状尚未校准，未转发至 USB。
- 补充驱动诊断使用 `ioreg -l` 时误将继承 VID/PID 的接口节点算为物理设备，触发唯一性断言；
  没有据此刷写或复位。用户切回 DBG 前后还出现一次 plist 解析失败，原始失败输出未保存，
  原因未确认；没有据此重启硬件。
- 用户切回 DBG 后，核对同一序列号与 UID，恢复 28,524 字节可用固件、独立读回完全一致，
  恢复原 LaunchAgent。记录在 `results/mt2-restore-after-book-20261109/`。
- 用户按 USB1→Book 先、USB2→mini 后接回，原服务自动连接。用户再次确认“能控制，也能自动返回”。
  原控制恢复已验证；这并未解决之前的 USB1-only 热插拔或任意插入顺序问题。

当前板上为原可用控制固件，实验候选不再运行。后续开发在隔离目录继续；新触点入口/队列、
原生 USB 手势及符合零目标运行时的双向剪贴板均尚未完成。
