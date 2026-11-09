# Book 自动连接服务

Book 登录后由 `com.wiredkvm.control-autostart` 启动。USB1 接入 Book 后自动找到控制接口，检查 mini HID 就绪，再启动已有键鼠控制版本。端口名称变化、USB 重连、控制进程退出都会重新发现和连接。

- Rust 管理启动、单实例、重试和进程身份；C 仅封装 macOS IOKit、console user 和 libproc。
- 500 ms 检查一次 USB/进程；失败后 3 秒内重试。完整启动还取决于 USB 枚举、目标唤醒和辅助功能授权。
- PID、进程创建时间和完整可执行路径全部匹配才管理进程。多块相同开发板时暂停，避免选错设备；原型序列号不唯一。
- 只用已有输入版本和 `--input-only`。不启用剪贴板，不运行 mini 程序，不用 macOS 共享。
- 不改变固件、键鼠算法、滚动方向和自动返回算法。
- 可接管已有控制进程；服务退出或拔线时释放输入。紧急返回仍为 Control＋Option＋Esc。
- 登录服务须单独获得 Book 辅助功能授权；从 Codex/终端启动时权限有效，不能证明 launchd 启动也有效。
- `AbandonProcessGroup` 保留监督服务异常退出后的键鼠子进程；重启后按创建时间重新接管。正常退出仍主动释放输入。
- 当前保留已获授权的捕获程序路径；移动或删除这几个工程内二进制会阻止启动。升级须重新核对哈希及权限。

构建和检查：

```sh
cargo test --offline --manifest-path native/control-service/Cargo.toml
cargo build --release --offline --manifest-path native/control-service/Cargo.toml
native/control-service/target/release/wiredkvm-control-service inventory
python3 scripts/configure_control_autostart.py prepare build/control-autostart-STAMP
python3 scripts/configure_control_autostart.py install build/control-autostart-STAMP
```

`prepare` 只生成工程内文件。`install` 明确写入主控用户的 LaunchAgents 和 Application Support，保留正在运行的控制进程；若已有安装则拒绝覆盖。

停止并关闭自动启动：

```sh
launchctl disable gui/$(id -u)/com.wiredkvm.control-autostart
launchctl bootout gui/$(id -u)/com.wiredkvm.control-autostart
```

状态在 `~/Library/Application Support/WiredKVM/control-autostart/state/status.txt`。`session.tsv` 是带进程创建时间的接管记录，不能只按旧 PID 操作。

重启验收必须指 Book 登录后的用户桌面；FileVault 解锁前不属于本服务运行范围。单元测试和 launchd 重载不是一次真实重启的证据。

系统启动机制参考：[Apple — Creating Launch Daemons and Agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)。
