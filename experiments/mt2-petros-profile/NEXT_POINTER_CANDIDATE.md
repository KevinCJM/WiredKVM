# 绝对指针与 MT2 共存：下一候选

研究日期：2026-11-06。状态：**仅研究，未实现、未刷写、未验证**。
本轮先恢复用户可用控制，不继续刷实验固件。

## 已知现场与证据边界

`results/mt2-flash-nopref-20261106/absolute-driver-properties.plist` 记录：
`05ac:0265`、`bcdDevice=0x026a` 的绝对接口由通用
`AppleUserHIDEventDriver` 接管；有 Scroll、SurfaceDimensions，
`RegisterService=false`，未见 MultiAxisPointer 或 AbsolutePointer 属性。
**属性缺失不能替代真实定位测试，也不能单独证明绝对坐标已失效。**
此前 Mouse Application 会匹配 Apple 多触点驱动；Pointer Application
加 Preferred State 会出现 MultiAxisPointer。这两条实机结果只适用于已测版本。

## Apple 源码依据

1. `IOHIDDevice::newDeviceUsagePairs` 收集所有 Application 和 Physical 集合，
   不收集 Logical 集合。因此“外层 Pointer、内层 Mouse Physical”仍会发布
   Mouse usage，不能用来可靠避开现有 Apple Mouse 匹配。
   [IOHIDDevice.cpp，1652–1692 行](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDDevice.cpp#L1652)
2. `IOHIDElementPrivate::conformsTo` 沿父元素查找 usage/page，不限定集合类型。
   因此 Mouse Logical 能提供 Mouse 祖先语义，同时不进入上述 usage pairs。
   [IOHIDElementPrivate.cpp，2053–2071 行](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDElementPrivate.cpp#L2053)
3. 当前 DriverKit 文档确认 `parsePointerElement` 会识别并缓存可分派的指针元素，
   但未公开具体分类条件。**不能把旧 IOHIDFamily 的实现直接等同于当前
   AppleUserHIDEventDriver。**
   [Apple：parsePointerElement](https://developer.apple.com/documentation/hiddriverkit/iouserhideventdriver/parsepointerelement)

源码行号按当日直接读取原始文件核对；`main` 后续可能移动。

## 最小候选（推断，待验证）

以现有 Pointer `0x0269` profile 为基线，仅改变绝对报告 ID 3 的内层集合：

```text
旧：05 01 09 01 A1 01 85 03 09 01 A1 00
新：05 01 09 01 A1 01 85 03 09 02 A1 02
                                ^^    ^^
                         Mouse usage  Logical collection
```

外层仍是 Pointer Application。绝对 XY 保留原 `Input 81 02`；
报告 ID、长度、按钮、坐标范围、滚轮、桥接字节、接口 6 MT2 均保持。
若从 NoPreferred `0x026a` 生成，须另将 XY `81 22` 恢复为 `81 02`，
并在构建记录中明确这第三处差异。新实验须使用独立版本号。

预期：匹配层只看见 Pointer；元素解析层仍看见 Mouse 祖先。
这是基于公开代码的候选，不是当前 macOS 的成功证据。
Mouse Logical 并非典型鼠标描述符布局，其兼容性仍需实测。
不改成 Pen 或 TouchScreen；这些设备的事件、按钮和坐标映射语义不同，
目前没有无副作用的证据。

## 后续最小验收

1. 先做描述符离线差异检查；只允许上述变化及实验版本号变化。
2. 另行安排实机验证，USB2 先接 Book；确认绝对接口绑定通用驱动，
   DeviceUsagePairs 不含 Mouse，接口 6 仍绑定预期 MT2 驱动。
3. 发少量无点击、无文字的绝对位置，直接观察光标位置。
   重复同一坐标应保持不动，不能只查看注册表属性。
4. 位置通过后再验拖选、按钮释放、双指滚动、自动边缘返回。
   任一失败即回退，不能把枚举成功当作功能完成。

本文件不授权刷板；本次未修改固件或运行设备操作。
