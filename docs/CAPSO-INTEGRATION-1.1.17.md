# Capso 导入方案及实施记录

按用户要求直接使用 Capso 长截图源码。固定上游 revision 在 ThirdParty/Capso/REVISION，完整原件和许可证随源码保存。

1. 导入上游配准/拼接测试，先确认因缺少 CapsoScrolling 类型而失败。
2. 将上游采集、拼接、固定区域检测、HUD 和布局放入 CapsoScrolling 命名空间；旧拼接器保留兼容测试，但不再由长截图入口调用。
3. FreeMouse 适配层只处理框选坐标、开始/完成/取消、会话隔离和编辑器输出。拼接器只在采集任务访问，UI 接收不可变快照；停止标记用锁同步。
4. 运行上游测试、完整回归及合成 AppKit 页面实际采集；完成后构建应用和 DMG。详细结果见 VALIDATION-1.1.17.md。

本地调整见 THIRD_PARTY_NOTICES.md。没有安装或替换用户已安装应用。
