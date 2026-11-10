# Finder 原生取消：实测与验证边界

## 已观察到的结果

2026-11-10 在 Book 运行一次经用户本次授权的独立测试。测试只提供自建的 512 KiB 文件，使用本机只读 WebDAV 入口；没有 USB 传输、mini 访问、安装或后台服务。

测试在源 URL 发布可取消的 `Progress`，Finder 粘贴后出现原生拷贝窗口。点击“停止进程”后，窗口变为“正在停止”；69.15 秒观察窗口内，源 `cancellationHandler` 没有被调用。手动完成自建正文后，Finder 窗口关闭，目标目录为空。随后测试程序正常清理退出。原始时间和有限事件在 `results/portable-direct-cable-20261110/finder-cancel-physical-v2/result.json`。

这次验证不通过。不能把发布 `Progress` 或协议层取消测试通过，写成 Finder 原生取消已完成。它也不是“USB 慢导致取消慢”的证据，因为该测试没有 USB。

## 与当前源码的关系

`WKPortalHTTPServer` 的 GET 在返回成功头之前等待 `WKPortalStore.waitPayload`。当前实现只有整个接收文件通过长度和整体 SHA-256 验证后，才提供 `WKReceivedFile`。因此，等待中的 Finder 请求还没有收到正文。

HTTP 连接断开检查只会结束该请求，尚未连接到文件引擎的取消。不能简单将所有 GET 断开都视为用户取消：正常请求完成、预览、重试和并行读取也可能关闭连接。

保留现有完整性条件。任何分段方案都必须验证最终失败、取消和断线时，Finder 不会把预分配或未校验文件当成成功；不能用零内容、跳过整体校验或提前发布半成品来换取进度。

## 系统资料与下一步假设

[Apple Progress.publish 文档](https://developer.apple.com/documentation/foundation/progress/publish())说明发布使进度可被其他进程发现，并通过订阅观察；这不能证明 Finder 已把源进度纳入其复制操作。[取消回调文档](https://developer.apple.com/documentation/foundation/progress/cancellationhandler)说明实际取消仍由应用负责。

[Apple 公开 WebDAV 源码](https://github.com/apple-oss-distributions/webdavfs/blob/main/mount.tproj/webdav_network.c)的 `stream_get_transaction` 先取得首段数据，再把剩余下载交给后台。[文件关闭路径](https://github.com/apple-oss-distributions/webdavfs/blob/main/mount.tproj/webdav_file.c)含终止后台下载的处理。公开源码不保证与当前 macOS 二进制完全相同；这里只用于提出下一步实验，不据此宣称已经修复。

下一次独立实验应先检查：只订阅自建源 URL 和源目录，是否能观察到 Finder 自己发布的可取消进度。测试用自建目标目录作为对照；产品不能依赖预先知道目标目录，也不能扩为观察用户任意文件操作。如果源订阅仍不可用，再验证分段读取的取消及最终完整性，不能直接替换当前可用入口。

## 与吞吐问题分开

当前 v12 的两端均自行报告 480 Mbps。Book 缓存描述符还确认文件接口 3 的 OUT 0x04、IN 0x84 都是 Bulk、最大包长 512；查询没有打开、独占或重配 USB。

64 MiB 正向首个已确认字节至最终确认约 81.918 秒，约 0.819 MB/s；用户确认成功且键鼠、双指/四指、返回正常。反向约 78.070 秒，约 0.860 MB/s；Book 返回文件与原文件整体 SHA-256 一致。它们不能算高速验收。接口协商速度和包长正确，也不能定位实际吞吐瓶颈。

下一步用自建 8 MiB 文件，在传输中只读采样固定身份的 Book 剪贴板组件 3 秒，区分计算忙与等待 I/O。该采样不访问 mini，不暂停 MCU，也不读取剪贴板正文。
