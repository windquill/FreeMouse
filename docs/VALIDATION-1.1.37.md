# OmniDesk 1.1.37 验证记录

上传/下载仅首个箭头按各自速率变色，数字、空格和单位使用系统 labelColor，随浅色/深色外观适配。保留原有动态颜色刻度、菜单布局、录屏提示与刷新频率。

使用实际绘制函数检查浅色与深色外观下空闲、32KB/s、1MB/s、10MB/s、100MB/s 的离屏渲染；示例图见 docs/images/network-speed-colors.png。

相关回归范围：NetworkSpeedTests、NetworkMonitorTests、KeyboardShortcutTests。日志位于 .build/network-arrow-color-tests.log 与 .build/network-arrow-color-build.log。

2026-10-21：相关 3 个套件 31 项测试通过。
