# 1.1.27 build29 进程Kill与菜单栏右侧留白

网络进程列表每行前新增红色Kill按钮，单击直接发送SIGKILL。禁止PID<=1、FreeMouse自身、未捕获身份或身份变化的目标；不会请求管理员权限。进程已退出/身份变化/无权限等错误在面板显示；成功发送信号后从当前列表移除。未保存内容可能丢失，后台服务也可能自行重启。

读取列表前记录wall-clock采样开始时间。仅对启动时间不晚于采样开始且名称匹配的进程绑定身份（PID、启动秒/微秒和名称）；仅允许已知15字节以上截断前缀，不接受任意短前缀。点击前再次查询身份并核对仍在当前列表，避免采样期间PID被同名实例复用时绑定到旧流量。macOS按PID发送信号，身份核对属于尽力保护，不宣称有pidfd式原子性。

菜单栏取消网速区固定72点的预留宽度，按两行实际文字的较大宽度绘制；录屏计时单独测量并追加。新增“通用设置 → 菜单栏 → 网速右侧留白”0–12点，默认2点，自动保存并立即更新。保留内部图标/网速间距0–20点；macOS自身菜单栏系统间距不在本应用控制范围。

验证：
- 定向28项测试通过：16项NetworkSpeedTests、5项NetworkMonitorTests、7项NetworkProcessKillTests。
- Kill测试覆盖精确PID/SIGKILL、保留PID和自身拒绝、启动时间变化拒绝、退出目标拒绝、EPERM单次失败不重试、名称截断校验、采样期间PID复用身份绑定拒绝。
- 右留白测试覆盖按内容收紧、0/2/12点宽度差、非法设置回退、录屏计时不裁切、点击命中保持正确。
- 原生验证程序只启动自己的/bin/sleep 60子进程，读取真实身份，再通过生产NetworkProcessKiller发送SIGKILL，waitUntilExit确认terminationReason和信号均符合预期。未终止任何用户已有或系统进程。
- 离线浅/深色面板及右侧留白预览均使用虚构数据，未截取用户屏幕。预览.build/network-panel-validation/kill-spacing。
- 独立审查指出PID身份绑定窗口，已增加采样前时间戳和回归测试，复查无新发现。
- 应用及Finder扩展本地ad-hoc签名；没有Apple公证；未自动安装或修改系统配置。

完整release回归301项/43组，报告此前同样的10个问题：
1. blinkingCaretDoesNotReportMissingTail()
2. Scrolling back up gives a negative offset
3. Sticky header and footer are found and ignored when matching
4. Stitched page matches the real page, with header and footer once
5. heicExportProducesAnActualDecodableHEICWithOriginalDimensions(width:opaque:)的6组参数编码失败。
本次未改这些拼接/HEIC路径，不能声称完整回归全绿。日志.build/network-kill-full-tests.log，原基线.build/ocr-baseline-tests.log。编译仍有旧摄像头Sendable及旧测试返回值警告。

定向红绿日志：.build/network-kill-red.log、.build/network-trailing-red.log、.build/network-kill-identity-red.log、.build/network-kill-spacing-green.log。构建日志.build/network-kill-build-1.1.27.log。
