# 1.1.25 build 27 菜单栏实时网速

菜单栏使用 Stats 的 64 位 `NET_RT_IFLIST2` 接口计数和双行显示方式。固定来源提交为 `b796af44541a6e1802e58918d301aa8c7c07572d`，完整 MIT 许可证与原始来源文件保存在 `ThirdParty/Stats`。应用资源及 DMG 包含许可证。

仅集成上传、下载速率：每秒读取当前主要物理网卡；用实际采样间隔计算速率；首次读取、接口切换、断网后重连和超过5秒未采样时重建基线。显式监听系统唤醒通知并清空基线，覆盖 systemUptime 不含睡眠时间但 Dark Wake 期间计数增长的情况。计数器回退和超过100Gbps的单次跳变归零。VPN 优先选择底层物理接口，避免重复计算。原工具箱菜单、OCR、录屏停止图标及计时保留；菜单展开期间继续刷新图像，不替换正在交互的菜单。

新增12项测试已通过，覆盖速率方向和实际时间间隔、零计数起点、重置恢复、网卡切换和断连、睡眠/无效间隔、显式唤醒重置、异常大跳变、物理接口选择、路由消息截断/接口编号、单位换算以及图像尺寸和录屏指示。先运行缺少实现时的测试，再实现并验证通过。日志：`.build/network-red.log`、`.build/network-green.log`。

原生验证程序读取系统接口计数成功，并对两次相隔约1秒的采样计算出有限非负速率；未进行主动带宽测速。生成模拟菜单栏的浅色/深色、空闲/传输/录屏预览并完成视觉检查；没有截取用户屏幕。预览：`.build/network-validation/menu-preview.png`。独立审查提出唤醒计时边界问题，已补充通知重置及回归测试。

完整 release 回归运行285项、41组，报告10个问题，与此前已验证的修改前基线一致。本次未改动下列失败涉及的功能：

- `blinkingCaretDoesNotReportMissingTail()`：静止光标末尾判断。
- `Scrolling back up gives a negative offset`：上游反向位移。
- `Sticky header and footer are found and ignored when matching`：上游固定栏匹配。
- `Stitched page matches the real page, with header and footer once`：上游完整页面拼接。
- `heicExportProducesAnActualDecodableHEICWithOriginalDimensions(width:opaque:)`：6组参数 HEIC 编码失败。

本次日志：`.build/network-full-final.log`。此前基线：`.build/ocr-baseline-tests.log`。完整回归不是全绿，不能据此声称所有功能均通过。编译器仍报告原有摄像头驱动 Sendable 警告以及测试环境 SwiftPM 缓存不可写提示。

构建/打包入口为 `scripts/build.py`、`scripts/package.py`，版本1.1.25 build27，Apple Silicon / macOS15+。使用本地 ad-hoc 签名，未经 Apple 公证。应用未自动安装或替换，未修改系统配置，未推送仓库。
