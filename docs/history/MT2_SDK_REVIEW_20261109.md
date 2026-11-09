# MT2 Book 单口测试前驱动审查（2026-11-09）

上一回合为有效进展：取消实现、Rust 硬件待停状态、主机清理等待均已修改，48 项离线
检查与 RV32 构建通过。当前回合补真实 SDK 证据，并准备受控 Book 五点定位测试。

## 真实 SDK 联调

- `test_abort_sdk.py` 固定核对已审查 `usbd_driver_core.c` SHA，实际链接厂商核心及项目
  `single_port_abort.c`。只替换寄存器/DMA 边界，未修改外部 SDK。
- 实际 `usbd_upload`、`usbd_endp_set_response`、`usbd_event_handle` 和完成回调参与测试：
  1,000 次取消后立即提交新普通报告，DATA0/DATA1 交替；SIE 忙时 SDK 仍拒绝新 DMA；
  迟到完成只退役旧报告；另一 Bulk 端点始终保持待发送状态，再单独完成；reset settling 不写寄存器。
- 审查真实 port：USB2 轮询先派发 WCH core/完成回调，返回后才清 DONE，然后主循环 service；
  adapter 不在回调中上传新报告。因此旧 DONE 清除前，不会复用下一报告的 DMA。
- 厂商核心在端点 NAK 时设 SDK 状态 IDLE。新 helper 只在 NAK + fence + SIE idle + 无 DONE
  + 无 reset 后调用该函数；SDK 状态和 adapter busy 一起交回。已有 DONE 必须走正常回调。
- 测试允许厂商核心对枚举哨兵 `USBD_EVENT_COUNT` 未列入 switch 的既有编译警告；不修改厂商文件。
- 该测试依然不模拟芯片、真实总线和电气回灌。物理性能、定位、滚动和四指均未通过。

## 受控试验范围

只允许先在 Book 测 USB2 五个固定内侧坐标，无点击、按键、文字或任意位置指令。
USB1 与 DBG 留空，mini 不参与；旧服务须暂时停止。Book 保留充电接口。
同一块板通过 DBG 核对身份并刷写、读回一致后，才能执行。实验结束恢复可用固件与本机服务。

已审查候选：`candidate-cancel-v2-20261109`，74,792 字节，SHA
`0c8da9dd860070794a2ebc9eebb6ae1f69ec46407d5f9cf4637654f6cd79d8dd`。
可回退固件已重新读取文件核对：28,524 字节，SHA
`53b4b741a9212ffb3c8a89dcb9aef282b4b3643bbf2a11696f8c23e5e97a6e70`。

主机执行门禁由“恒 false”收窄为“只接受上述已审查候选哈希的编译绑定”。无绑定、旧缺陷
候选和任意不同 SHA 仍拒绝。新绑定也必须通过刷写凭据、UID、DBG serial、年龄、布局、
接口描述符、单口关联、无控制进程和鼠标按键释放检查。测试证明缺少凭据时在任何 USB 访问前失败。
该审核不表示允许量产部署，也不表示三项目标完成。首次物理试验待用户切换接线。

## 尚未解决

完整触点实时输入、双指轨迹与四指轨迹仍待开发/实测；只有描述符、协议编码器和定位探针。
双向剪贴板尚无符合被控端零自定义运行时的系统接入口，既有 Bulk 接收端需要目标组件，不能复用为本目标的成功证据。
