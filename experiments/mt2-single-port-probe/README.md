# USB2 单口绝对定位探针

独立 Rust 工具，无第三方依赖。默认只打印离线计划，**不读设备、不读进程、不读 flash-proof、不移动光标**。

只验收 026c 实验固件的五个固定绝对点位。它不证明双指滚动、四指手势、自动返回、复制粘贴或双口控制可用。生产代码及当前控制程序不改变。

## 离线检查

```
cargo test --offline --manifest-path experiments/mt2-single-port-probe/Cargo.toml
cargo run --offline --manifest-path experiments/mt2-single-port-probe/Cargo.toml -- --dry-run
```

`--out NEW.json` 可保存结果；已有文件拒绝覆盖。dry-run 即使带不存在的 `--flash-proof`，也不读取它。

## 执行门禁

**当前状态：测试固件已写入并独立读回，USB2 单独接 Book 的五点定位已经通过，原光标已恢复。** 2026-11-09 已审核手册寄存器语义、实际 WCH 完成回调／ACK 顺序，并以真实 WCH 核心完成 1,000 次取消联调。寄存器与总线仍未实测，不能部署 mini。

默认无哈希和旧候选都保持关闭；只有编译绑定
`0c8da9dd860070794a2ebc9eebb6ae1f69ec46407d5f9cf4637654f6cd79d8dd`
的新版本可进入后续检查。任意其它 SHA 不能解除门禁；仍需实际刷写、独立回读与下列
现场条件全部满足。审核资料在 `results/mt2-sdk-review-20261109/`。这不是自动刷板工具。

后续人工安排测试时，还必须明确提供：

- `--execute --flash-proof PATH --same-board A47C8F062A1A/ad21ad506c54c6c6`。证明文件必须是最近六小时的已刷写、读回一致、reset-run 记录；完整 UID、DBG 序号、芯片 ID 和编译绑定固件哈希必须一致。
- 只有 USB2 接 Book；USB1 与 DBG 必须不在 Book USB 列表。已核对 flash-proof 加操作者确认关联同一块板；共享 USB role serial 本身不是唯一硬件认证。
- Book 只能启用内屏。原控制器、capture、Companion 必须已退出；工具只检查，不停止它们。
- 精确 `05ac:0265 / bcdDevice 026c / ff60:61`、厂商、serial、位置和实际报告描述符。不存在 `AbsolutePointer` 属性本身不会导致拒绝；坐标实测才是最终判断。

Feature 使用 ID 0，固定 64 字节，无 ID 前缀。只打开 vendor HID，选项为 None，不 seize 鼠标或 MT2。ARM 使用新 nonce；每次只提交一个固定点位，并等待对应 completed sequence，再读取 Book 光标。未达 4 个屏幕点误差即中止后续点位。

## 清理和限制

设备调用在受父进程监督的子进程中运行。子进程最多运行 12 秒；超时或普通终止信号会被结束并回收。固件租期固定为 5 秒，不能续租。正常结束显式 DISARM；异常后父进程等待租期届满，再恢复原光标。

父进程独立保存光标，并在失败路径清理。若屏幕布局已改变或用户按住鼠标键，则拒绝额外恢复移动并报错。强制杀死父进程（SIGKILL）、系统崩溃或断电不能保证恢复光标；这些情况不能写作测试通过。

新版状态 flags 低位 3 表示硬件仍在 quiescing。即使 nonce 已清零或租约已到期，也必须
等待该位及其它输入位清零，才报告停止完成；出现其它 nonce 则拒绝归为本次清理成功。

2026-11-09 已实机执行：五点均通过，最大误差约 1.043 个屏幕点，原光标已恢复。该结果覆盖本次 Feature/lease/completion 与坐标派发，不代表热插拔或其它输入验收。SET 完成只代表暂存，工具会等待主循环实际接受和完成；失败结果保留已测点位及最后状态。完整触点采集、两指合成、四指合成和实时输入通道均不属于本工具。
