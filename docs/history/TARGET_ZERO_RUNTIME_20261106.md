# 被控端零自定义运行时边界（2026-11-06）

用户最新明确：mini 不安装程序、不运行脚本；产品代码只在硬件与主控机运行。此要求替代此前对“临时运行但不安装”的接受。不得继续将 WK_PORTABLE 部署到 mini，也不能通过远程终端或 HID 输入命令启动它。此前临时组件、目录接收端候选仅保留为历史开发产物，不是符合当前要求的交付。

## 本次观察

- 用户恢复现有 DevSpace 后，只调用 `open_workspace` 检查连接，成功返回工作区 `ws_a765eccc06`，根目录为 `/Users/kevinchen/Desktop/kevingit/WiredKVM-Agent`。
- 未在 mini 执行命令、传入文件、读取个人剪贴板、启动组件或修改设置。
- 屏幕共享仅打开了本机连接列表，没有建立远程会话；已结束该 UI 操作阶段。
- 上次被用户中断的本机构建句柄已不存在。日志确认 WK_TREE 候选因跨条件编译块的花括号语法失败。仅修正该语法，未部署或重新启动任何控制链。
- `results/collection-transfer-20261106/stream-v1/collections.json` 只证明 Rust 目录源、Swift 流引擎、C USB 桥的离线测试：双向各 33,570,435 字节、444 个文件哈希、3991 次模拟输入探测、0 失败。该版本明确 `folderPasteIntegration=false`；后续集成不得沿用这些结果声称通过。

## 可行性与未完成项

键鼠与四指/平滑滚动重新以硬件输入设备模拟为候选方向。当前 MT2 实验仍有端点取消/完成事件问题，不能直接刷入取代用户可用控制固件。

纯 USB HID 不提供读取目标 macOS 通用剪贴板的接口。更快的 Bulk 传输本身不解决目标剪贴板接入。

另一条待研究路径是 USB 网络设备与 macOS 已有系统服务。Apple 文档确认屏幕共享可共享文字/图片剪贴板，并以拖放传输文件/文件夹；这不等于已经支持要求中的双向文件 ⌘C/⌘V、后台透明工作或纯 USB 承载。系统服务启用、登录权限、纯有线路由、性能和输入共存均需分别验证，不能自动修改 mini 的共享设置。当前没有该路径的固件或实机证明。

资料：

- https://support.apple.com/en-sg/guide/mac-help/mh14066/mac
- https://developer.apple.com/documentation/appkit/nspasteboard
- https://www.xmos.com/documentation/XM-007103-AN/pdf/an00131_v3.1.0.pdf

目标三项仍未全部实现或验收。维持已有键鼠与边缘返回，不把 DevSpace、屏幕共享或之前的临时组件当作产品依赖。
