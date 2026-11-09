# Windows 托盘设置原型（**不具备跨屏输入功能**）

此目录提供原生 Win32 的右下角系统托盘界面**源代码**，没有 Electron 和第三方运行时。
界面可设置被控设备（iPhone/Mac/Windows）、左右位置、鼠标速度、iPhone 自动返回和设备自动连接开关，配置存在当前用户的 `%APPDATA%\\WiredKVM\\settings.ini`。

重要：**由于用户当前 DevSpace 位于 MacBook 上，未安装 Windows SDK 或 Windows 测试机，本版本尚未进行 Windows 编译或实际运行验收。** 目前实现的是**设置 GUI**；“开始控制”被特意禁用，防止用户误以为 Windows 主控已能实际操作另一台设备。

在 Windows 10/11 + Visual Studio Build Tools 上测试：
```powershell
cmake -S windows -B build-win -A x64
cmake --build build-win --config Release
.\\build-win\\Release\\WiredKVMTray.exe
```

后续仍需完成：Windows 低级键鼠事件捕获、显示器边缘检测、USB COM 热插拔/身份验证、WK1 串口数据发送、USB HID 就绪探测、异常释放、管理员/权限体验和真实 Windows↔Mac/Windows/iPhone 联调。

由于未完成控制模块，**不会自动开机、不会检测设备、不会安装驱动、不会操作鼠标键盘**。这是 Windows 设置界面的开发基础，不是可销售的 Windows 版本。
