# 1.1.26 build28 网络详情面板与间距

按用户提供截图接入完整网络面板，使用固定Stats版本b796af44541a6e1802e58918d301aa8c7c07572d的网络popup、readers、Kit图表源码及布局常量适配FreeMouse。原始源码及MIT许可保留于ThirdParty/Stats。面板宽280点，内容264点，左右边距8点，顶部42点，实时值90点，负载图90点，连接格30×3；图表沿用原缩放/半轴/路径/渐变/峰值代码，SwiftUI布局桥接AppKit绘图。仅省略上游图表自定义设置、悬浮提示和动画，不声称完整Stats逐字原样编译。

图标和网速默认间距2点，文字靠左，通用设置可调0–20点、立即生效并保留。点击工具箱图标/右键打开原菜单，点击网速区域切换NSPopover。关闭和退出取消详情任务；录屏停止指示及计时保留。

面板提供上下行、180点负载历史、90格连接历史、持久化累计上传/下载和重置、接口状态/连通性、HTTPS请求耗时/抖动、接口名/MAC/WiFi、本机IPv4/有值时IPv6、公网IP/国家以及前8进程。WiFi名称授权仅按钮申请，Info.plist带定位用途说明；拒绝后按钮打开系统定位设置。公网IP和Apple成功页HTTPS检测仅面板展开时请求，延迟不是ICMP ping。数据缺失显示未知，不伪造线上值。

进程计数使用原Stats nettop参数，按PID和真实时间差分；首次和新PID建立基线，计数回退归零，最多8项排序。子进程后台读取并限时，超时仅终止自己创建的子进程。单一stdout reader到EOF后通过semaphore交付，避免CSV乱序。唤醒时重置总流量速率基线和进程基线，取消旧generation任务后按面板状态重启，防止旧结果回写。

验证：
- 15项NetworkSpeedTests及5项NetworkMonitorTests通过，包含间距默认/边界/非法偏好、图标/网速命中区域、录屏图像宽度、PID真实差分/新PID/回退/排序前8、历史上限、累计持久化与唤醒重建。
- 间距和点击测试先观察到缺少实现失败；历史长度对齐先观察到120与180/90预期不符，再修复并验证。独立数据层首次TDD红阶段曾受缓存权限限制，未声称完整红绿记录。
- 原生离线浅色/深色完整面板渲染通过并完成视觉检查，全部预览值为虚构，未采集用户屏幕。预览位于.build/network-panel-validation/final。
- 原生nettop读取及两次按实际时间差分成功，返回8项有限非负速率；输出仅记录数量，不输出用户进程清单或IP。
- 独立审查提出唤醒未重置进程基线、stdout读取竞争两项，均修复并复查无发现。
- 应用及Finder扩展本地ad-hoc签名校验通过。没有Apple公证，未自动安装，未改系统配置，未提交或推送。

完整release回归293项/42组，仍报告此前基线相同的10个问题：
1. blinkingCaretDoesNotReportMissingTail()
2. Scrolling back up gives a negative offset
3. Sticky header and footer are found and ignored when matching
4. Stitched page matches the real page, with header and footer once
5. heicExportProducesAnActualDecodableHEICWithOriginalDimensions(width:opaque:)的6组参数编码失败。
没有把全量回归称为全绿。本次未修改这些失败涉及的拼接/HEIC代码。日志.build/network-panel-full-final.log；原基线.build/ocr-baseline-tests.log。编译仍有原摄像头Sendable和旧测试未使用返回值警告、SwiftPM用户缓存不可写提示。

限制：未做真实跨进程鼠标点击和WiFi授权弹窗手工验收；公网IP/HTTPS服务的可用性取决于当前网络；连接历史在面板关闭期间记录未知，不进行后台外部探测。
