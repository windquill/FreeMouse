# FreeMouse 1.1.16 build 18 验证记录

日期：2026-10-16。Apple Silicon，macOS 15+ 目标。改动在当前项目的 `codex/scroll-capture-rebuild` 分支；产物在项目 `.build` 和 `outputs`，没有替换已安装应用。

## 自动回归

- 修改前基线：223 项通过。
- 最终完整 Swift Testing 回归：**251 项，35 个套件，全部通过**。最终运行耗时约9秒，仅代表本机这次测试。
- 新增覆盖自动滚动新旧帧确认、尾帧稳定等待、转换前准入、暂停/在途/封流缺口、暂停组装、只读视口核对和快捷键焦点隔离。
- 原有真实非私人帧、固定首尾/侧栏、重复内容、抗混叠、持续多页、超长尺寸与原始像素回归全部保留并通过。
- 运行命令：`swift test -c release`，此机增量构建需显式传 `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`；scratch/cache/config/security 均指定到本项目 `.build`。
- 最终日志：`.build/scroll-validation/final-tests.log`。

本机 CLT 有既有摄像头 Sendable 警告、链接搜索路径警告；没有测试失败。未改系统工具链或摄像头实现。

## 实际原生窗口采集

运行 `scripts/scroll-validation/run.py`，用独立进程展示固定种子的 AppKit 文字与色块页面。选区完全位于该不透明窗口内；没有使用私人会话或其他应用内容。

正式 ScrollFrameSource + ScrollStitcher 经 ScreenCaptureKit 实际采集16个已知位置：

- 原生视口：1268 × 948 px，2×分辨率。
- 最终长图：**1268 × 4548 px**，16次成功追加，0次拒绝。
- 每一步实际高度与已知滚动位移一致。
- 长图末尾64行与最后原生截图逐像素一致。

正式 ScrollCaptureController 的实际浮层和按钮验收：

- 点击完成后220ms才移动到最终位置，最终输出仍为1268 × 4548 px。
- 完成过程中取消，输出交付次数不增加。
- 暂停后由测试页面自行移动48pt，完成时出现末尾未确认警告；只输出暂停前已截内容。
- 已有辅助功能权限下，自动滚动实际驱动 NSScrollView 下移264pt，输出高度1476px，等于948 + 264×2。
- 当前最终原生日志：`.build/scroll-validation/live-validation.log`，同时包含具体证据目录。

验收脚本使用完整 AppKit 事件循环、绝对点击时间、当前可见且就绪的控件及警告窗口通知。它不主动申请权限；测试结束关闭自己创建的窗口。

## 审查与交付

独立审查发现的旧帧清滚动额度、收尾消费空窗、转换前背压、暂停缺口及裸全局快捷键已修复。对修复的增量复核通过，无未处理的重要发现。

构建采用 `scripts/build.py`，最终二进制刷新后重新执行本地 ad-hoc 签名及 `codesign --verify --deep --strict`。应用和 Finder 扩展版本均为1.1.16/build18。安装包采用 `scripts/package.py` 生成，SHA256随包提供。

验证覆盖自建原生页面及既有回归，不代表所有网站的动画、吸顶元素、懒加载或任意速度滚动都能可靠拼接。没有用本次验收证明用户私人应用内容的所有场景，也没有修改屏幕录制/辅助功能权限。
