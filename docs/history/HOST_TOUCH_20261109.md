# Book 原始触点输入前置验证（2026-11-09）

上一目标回合有进展：真实 WCH 驱动取消联调及审核完成，专用 Book 定位工具就绪。
用户尚未确认已改成 DBG 单口，因此本回合没有刷板或停止可用控制；接线问题仍待回复。
本回合推进独立的 Book 触点输入观察器，未用其它传输或系统共享替代目标。

## 新增代码

`experiments/host-touch-observer` 为独立 Rust workspace，无第三方 crate。默认 dry-run。
动态解析 MultitouchSupport 的设备和回调接口，使用公开 IOKit 属性绑定物理来源：
built-in、SPI、非零 registry ID、Product 含 Trackpad；不根据系统 continuous 滚动猜设备。

只观察本机，不注入、不截断 Quartz 事件、不连接 USB 板、mini 或剪贴板。96 字节记录
解析以外部观察为依据，尚未收到真实触点来验证；版本门禁不能代替 ABI 证据。
压力和形状字段不猜测，数据尚未映射或发送给 MT2。

## 实际结果

- 8 个单元测试通过，检查 0/2/4/5/16 记录、越界数量、截断、时钟/帧号不一致、NaN、
  重复 ID、触摸/hover 区分、设备误识别、时间倒退及观察时长边界。使用合成记录，不是实机触点。
- Book macOS 实际为 15.6.1。初次枚举只有名称 `AppleMultitouchDevice`，不能按名称包含
  Trackpad 选择。随后只读 IOKit 确认 Product=`Apple Internal Keyboard / Trackpad`、
  Transport=`SPI`、VendorID=1452，registry ID=`4294970335`。
- inspect 已成功返回 eligible=true，回调未启动。没有按索引或“只有一个设备”盲选。
- 5 秒 observe 正常返回，frames/invalid/dropped 全 0；private framework 输出 family 0x6c、
  24×18 传感器信息。该窗口无用户配合触摸，不能判断零帧是无输入、权限还是回调问题。
- 后续补 `MTDeviceIsRunning` 的启动前与停止后检查，进行 1 秒生命周期复核；结果单独存档。
  这项检查不替代实际手势，也不保证其它进程的控制体验。当前未宣称实际两指/四指读取通过。

## 下一步与保留条件

硬件定位须用户先确认仅 DBG→Book，再刷已审核候选并读回，随后 USB2 单独接 Book。
触点验证则需要用户在观察窗口做两指/四指；不能因为无人触摸就更换 ABI、放宽设备校验或
虚构触点。尚未收到接线回复，不重复发相同问题或擅自刷写。

三项目标仍未完成：顺滑/四指的输入与输出都缺实机证据；高速双向剪贴板仍缺被控端零运行时
接入口。既有目标组件方案不符合当前约束；没有使用或启动该组件。
