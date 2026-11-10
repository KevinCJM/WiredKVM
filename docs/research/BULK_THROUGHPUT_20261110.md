# 2026-11-10 有线吞吐诊断

## 已确认

- V467 UID `ad21ad506c54c6c6` 仍运行 Bulk-batch-v1 固件，SHA-256 `6fdfccd6c45686444aea213ec81022be3c90594a13aec80fca54c353a7c21250`。
- v12 便携组件的 64 MiB 双向传输完成，返回文件大小为 `67108864`，整体 SHA-256 为 `40621e8b98e78fc9d40caf3049c7466dab1c7fa8060bfdaea9ec06d570408543`，与源文件相同。
- 正向从首个正文 ACK 至完成约 `81.918s / 0.819 MB/s`；反向 START 至完整接收约 `78.070s / 0.860 MB/s`。两个时间窗口略有区别，都不是从用户按 V 开始计时。
- 用户确认两个方向的控制正常；正向明确确认手势，反向回复“回传成功，控制正常，但是很慢”。不能把这项主观确认换成饱和输入延迟验收。
- 两侧组件报告 480 Mbps；Book 侧只读缓存描述符显示文件接口为 Bulk、512 字节、interval=0。这不等于真实文件吞吐达标，也不证明限速原因。

本机模拟使用实际异步磁盘封装可达约 12.45 MB/s，但没有 USB 或 C 桥。
当前不把“模拟快、实机慢”直接归因为芯片、CDC 驱动或 USB 单包重新装载。

## 本次诊断版本

新增显式 `--bulk-profile`，对既有状态附加主循环、文件 OUT / IN 回调、提交、
失败和队列深度数字。没有额外查询通道，不记录文件路径、UUID、正文或剪贴板内容。
生成的 USB 描述符与当前已刷版本逐字节相同。

固件：`candidate-bulk-profile-20261110/wiredkvm-mt2-stage1.bin`，`85408` 字节，
SHA-256 `6caef7f682024f1b2b3f94859e714180aa610782ae866d8acf8aa9a9658cb604`。
编译前后源码和外部 SDK 哈希不变。默认关闭计数的原配置也通过回归。

Book 需更新日志接收过滤；仅接收固定数字格式，未知字段、重复字段、溢出值、
路径和正文均拒绝。仍复用 v12 线内组件、程序盘及原捕获/触点程序；不安装或通过终端
操作 mini。

## 验证与下一步

1. 实际生成主循环 / C / Rust 模型：1,000 轮双向满载、800ms 两侧文件 IN 堵塞期间键鼠和触点继续推进；取消、旧 DMA、环形队列和提交失败检查通过。
2. 诊断专测：只统计文件端点、计数回绕、最坏状态长度和原前缀保留通过。
3. Book 配套程序的 `--self-test` 已通过预检、数字日志过滤、私有 IPC、进度和断线回归。协调器 SHA-256 为 `66ceea9834c0ec5966f8fc5e0492ff9ba1c17c6536ac53461aeac459bb52b458`。
4. 仍需 USB 实机短测中的正文收发计数，才能分析文件通道。该版本不能称为提速完成。

## 实机部署与当前中断

用户确认仅 DBG 后，已核对调试器 `A47C8F062A1A` 和芯片 UID，并备份完整
`589824` 字节。旧 Flash SHA-256 为 `abfa3593975986c007ee7734745e6c8ec42ffec436e62eaf6878f8e36d427bd9`；
前缀与已验收 Bulk-batch-v1 相同。写入上述诊断版后，独立读回 `85408` 字节逐字节一致。
证据：`results/portable-direct-cable-20261110/hardware-bulk-profile-v1/result.json`。

用户接回两端后，Book 协调器已切换，沿用原捕获器、触点程序和 v12 线内组件；
输入 READY、有线组件连接和有限数字状态均已实际观测。新服务未安装为登录项。
这些观测不替代用户对输入/手势的确认，也不证明新固件的文件吞吐。

随后 Book 的 USB1 连接消失，子进程正常退役，自动服务仍在等待。外部 USB 枚举确认
无 CH32/DBG；不是仅凭旧状态文件推断。绑定旧组件 PID 的采样器拒绝继续采样；
尚未观测到任何新的 8 MiB 正文，不能报告其传输成功、失败或 CPU 瓶颈。
最后的数字状态没有新增 reset 回调或触点错误；它不能说明连接为何消失。
已请求完整断电后按 USB1→Book、USB2→mini 顺序接回，并为新实例准备独立监测目录。

## 已验证旧固件的回退入口

`scripts/flash_portable_candidate.py` 增加显式 `--known bulk-batch-v1`，只接受脚本内
固定路径和 SHA-256 的旧二进制，不依赖后来已经修改的源码或旧构建清单。
`--known` 与任意 `--profile` 互斥；新候选仍须核对全部当前编译输入，包括生成依赖头。
恢复时仍要求仅 DBG、完整设备身份、`--expected-current bulk-profile-v1`、完整备份和
逐字节读回。回退失败仍先恢复完整刚备份的 Flash。没有执行新的物理刷写。

文件预览命令（不接触设备）：

```
python3 scripts/flash_portable_candidate.py --describe --known bulk-batch-v1 --wlink /已核对的/wlink
```

`python3 tests/test_flash_portable_candidate.py` 的 11 项隔离检查通过，包括输入冲突、
篡改固定二进制、错误探针、错误当前固件、完整备份、读回失败时完整恢复；USB/DBG
全部为 mock。它们不证明实际 USB 重连，也没有把诊断版标记为功能验收。

先前等待 8 MiB 用户操作的 1,800 秒采样窗口未触发，没有采样结果；不得把它报告为
CPU 空闲或忙。Finder 原生取消仍未通过；与本次吞吐诊断分开验收。

本地结果位于 `results/portable-direct-cable-20261110/physical-scheduling-v12/`、
`bulk-profile-candidate/` 和 `build/portable-book-20261110-bulk-profile/`。
这些生成结果不提交公开仓库；源码、规格、有限结果和可重跑测试随提交保留。

## 用户重新接线后恢复

用户随后说明，前一次测试中手动插拔了硬件并关闭了测试文件夹。因此，先前断线
不能用作诊断固件故障的证据。用户确认完整断电并按主控先接顺序重连后，Book 检测
到新注册号 `4295713211`；原监督服务自动启动新控制子进程，输入 READY、数字状态
及 mini 组件连接均已观测。程序盘重新上传 `8.449s`、`reused=false`。

Book 测试窗口已重新打开并选中 8 MiB 文件。新监测目录为
`results/portable-direct-cable-20261110/physical-bulk-profile-v2/`，绑定新实例身份；
等待用户本轮复制粘贴。前两轮采样没有正文数据，不与本轮混用。

### Single-paste failure and text recovery

- User reports Book-to-mini Finder -43 for the new single-03 filename with one C/V. Generation 21 / nonce 2390645657 reaches whole-transfer COMPLETE at 1794303969.926 after first progress 1794303959.999. No destination hash or Finder acceptance; repeated C/V is not the sole trigger. The bounded v3 sampling window had already ended; no CPU sample was collected for this transfer.
- Text also failed per user. Only the identity/hash-verified Book helper 92766 was normally terminated. The existing coordinator reuses the same program disk, starts helper 74228, and links again. Coordinator 92654, native 92687 and capture 92688 remain unchanged. User confirms both fresh text directions recovered. This is recovery, not a proven root-cause fix. No target terminal or install.
- Regression with private pasteboards passes repeat V/recopy, independent pending snapshots, images and collection pipelines. Initial sandbox execution could not access the private pasteboard service; the same built binary passed after a scoped sandbox escalation.
- A separate Book-only real read-only loopback VFS probe creates 12 dynamic own files: all immediate lstat calls and full reads pass. It never touches the general clipboard or USB. It does not establish the target Finder behavior.
- Candidate diagnostic: eight fixed numeric HTTP outcome counters, a changed-only 37-byte keepalive at most once per second / 64 times per connection, and numeric paste gating checks. No URL, capability, name or clipboard content. Counter success means HTTP body sent, not destination commit. Candidate is not deployed and does not change the file protocol or native input path.

Candidate v13 validation: actual C bridge/Swift/Rust 32 MiB streams in both directions, 444 tree file hashes, 280 protocol cancel rounds, blocked disks/late completion, image pipeline, repeated V/recopy and file-portal failure followed by fresh text pass. Portal HTTP counters match HEAD/PROPFIND/404/400/verified GET/failed GET outcomes. Wrong session, flags, sequence, transfer, version and payload length cannot enter peer logs; report cap is 64 and exhausted diagnostics do not block text. These are isolated tests, not mini Finder or native-cancel acceptance.

Universal portable binary SHA-256 `81515766d457a8c73a036cca370e411f96d6738b38a3f68cf897fdd3f708e939`; Book coordinator `e4c27da8ef6953fe8fe41934ee57d78059454d07b03c6553226ed9f8d08f50a2`; program asset `3774e1f29acfdeec7bc14e7806580a7518eeaecf12f8f7834b70d54ff720e0b4` (3,500,032 bytes). Native binary matches the current baseline; capture/touch are reused in place. Read-only program disk and five portable packaging checks pass. No deployment, firmware update or input change has occurred.
