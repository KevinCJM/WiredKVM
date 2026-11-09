# 触点阶段与合成字段（2026-11-09）

当前硬件已恢复可用固件，用户确认控制和自动返回正常。下述修改只在隔离 Rust 实验代码中，
没有替换安装程序、捕获程序或板上固件。

## 阶段修正

核对 [Calf Trail 原始逆向声明](https://github.com/calftrail/TrackMagic/blob/master/MultitouchSupport.h)
及其后续声明：3=MakeTouch，4=Touching，5=BreakTouch，6=Linger。此前参考的 mactic
说明将 5 描述为 press，语义冲突；观察器旧逻辑 3…5 都算 down，可能把抬指计为按住。
现在仅 3/4 算 down，另计原始四记录帧和阶段直方图，避免后续转发残留触点。

之前 30 秒日志的 529 帧、0 invalid/dropped 仍为实测事实，用户也确认做了四指动作；
但旧日志没有逐帧数据，15 个旧“四触点帧”包含 BreakTouch 的可能性，不能重算为严格
四个同时 down 的帧数。没有把其改写成新计数规则的成功证据。已在结果中明确这一限制。

## 合成记录

增加 `Geometry` 和 `Contact::synthesized`，按
[Linux MT2 解码器的协议字段](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-magicmouse.c)
构造 major/minor、size、pressure 和方向，方向 -4…3，越界拒绝。使用人工选择值时明确为
synthetic，不再复用“observed”类型名暗示这些字节来自捕获。坐标、ID、按钮限制沿用既有实现。

没有从 Linux 复制算法实现，仅核对报文协议事实。没有宣称单位已校准，也未在 macOS 输出
这些新合成触点。压力和形状仍需实际接受测试。

## 验证与后续

- MT2 Rust 21 项、触点观察器 9 项、完整生成 profile/回调 7 项离线检查通过。
- 包括固定协议向量、方向/ID/坐标拒绝、四点与释放帧保留几何字段、按钮始终为零，
  Break/Linger 不保持 down。profile 集成仍能抓住旧取消竞态。
- 实时触点入口、优先队列、取消/断线释放、主控远端状态门禁及端到端 MT2 输出尚未接通。
  本轮没有交付顺滑滚动或原生四指，双向剪贴板零目标运行时问题也未解决。
