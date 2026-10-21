# OmniDesk 1.1.36 验证记录

菜单栏上传与下载各自按实际 bytes/s 映射颜色，沿用每秒采样与刷新。0 或无效速率为灰色，1KB/s 以下为蓝色，1MB/s 绿色，10MB/s 橙色，100MB/s 及以上红色，中间以对数刻度插值。箭头保留方向信息。

速度图使用非模板图片，移除按钮整体着色以保留每行颜色；录屏图标和计时独立为红色。原有间距、点击区域、文字宽度和录屏时长布局保留。

2026-10-21：NetworkSpeedTests、NetworkMonitorTests、KeyboardShortcutTests 共 31 项相关回归通过。使用实际绘制函数生成并检查浅色与深色外观、空闲到 100MB/s 的离屏预览，见 `docs/images/network-speed-colors.png`（示例速率，无私人桌面数据）。

构建与测试日志在 `.build/network-color-build.log` 和 `.build/network-color-tests.log`。未自动安装应用或修改系统设置；本轮未重新执行风扇硬件和启动项验收，沿用 1.1.35 的验证范围。
