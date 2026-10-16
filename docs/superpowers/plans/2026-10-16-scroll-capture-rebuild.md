# 长截图采集重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 消除自动滚动与采集脱节、完成时丢尾帧和过载时重复转换。

**Architecture:** 保留 ScrollStitcher 的经过回归的像素匹配。抽出纯时序策略，控制器协调串行消费者与自动滚动；帧源在转换前执行容量准入。

**Tech Stack:** Swift、AppKit、ScreenCaptureKit、Swift Testing。

**Spec:** docs/superpowers/specs/2026-10-16-scroll-capture-rebuild.md

## Global Constraints

- macOS 15+，不新增第三方依赖。
- 默认手动；保留现有输出动作，普通快捷键仅控制条内生效，全局输出使用 Ctrl+Option+Command 组合键。
- 缓存 8 帧/2400万像素；长图输出不增加尺寸上限。
- 原始画质及严格匹配保持；不复制参考项目源码。
- 用户已授权连续执行，采用主代理整合及独立子代理定向实现/最终审查，不等待重复审批。

## Review Focus

- 原生帧时间戳必须与单调系统时钟一致，积压帧不能确认新滚动。
- 页面长时间静止且 SCK 不再发 complete 帧，自动滚动和完成都必须有界结束。
- 小视口及高分辨率下，每步必须保留有效重叠。
- 完成/取消/重新开始竞态不能输出旧会话或关掉新会话。
- 暂停时滚动或尾帧超时必须提示可能不完整。

### Task 1: 帧转换准入

**Files:** Sources/FreeMouse/ScrollFrameSource.swift; Tests/FreeMouseTests/ScrollFrameAdmissionTests.swift

**Interfaces:** 新增 buffer.prepareFrame(width:height:token:) -> Bool 与 setPaused(_:token:)；source.setPaused(_:) 转发。现有 publish/nextFrame 的序号与容量语义保留。

- [x] 写测试：满缓存拒绝转换仍保留前两帧并记录 sequence=3 缺口；消费后恢复；暂停不占缓存；旧 token 无法暂停新会话；过大原生帧立即失败。
- [x] 运行定向测试并观察缺少接口失败。
- [x] 在 sink 的 CI 转换前调用准入，暂停时不转换；恢复不清除原有 gap。
- [x] 运行 Admission/Queue/Backpressure 测试，预期全部通过。

### Task 2: 自动滚动与结束时序

**Files:** Sources/FreeMouse/ScrollCaptureTiming.swift; Tests/FreeMouseTests/ScrollCaptureTimingTests.swift

**Interfaces:** ScrollAutomaticPacer.nextStep(at:viewportHeight:scale:speed:) -> Int32，posted(at:)，matched(frameTime:at:advanced:)，reset()；ScrollFinishSettler.started(at:)、observed(at:changed:)、decision(at:hasPending:) -> waiting/settled/timedOut。

- [x] 写测试：旧帧不确认新步；最小 150ms 响应等待；确认后下一步；未确认 1.4s 后不自动继续；短视口4px和Retina2px；结束至少300ms、变化后250ms、2s超时。
- [x] 运行定向测试观察失败。
- [x] 实现纯状态策略，所有时间由调用方注入，不能用 Timer 或 sleep。
- [x] 运行定向测试，预期通过。

### Task 3: 控制器整合与交付

**Files:** Sources/FreeMouse/ScrollCaptureController.swift; Sources/FreeMouse/ScrollCaptureFlow.swift; Tests/FreeMouseTests/ScrollFlowTests.swift; README.md

**Interfaces:** 消费 Task 持续至 finishing，最终串行排空；时序策略用于唯一自动滚动投递入口。hasPending 由 source 快照提供。

- [x] 先写 Flow 回归：暂停时滚动后必须标记未确认；恢复不偷偷清除未确认；取消/finish不恢复滚动。
- [x] 用 pacing 替换每20ms不受帧确认约束的预算归零；收到有效帧时传原始 timestamp。
- [x] 完成时持续消费，按 settler 等待尾帧；超时标记不完整；立即移除结束阶段输入。
- [x] 暂停/诊断/恢复使用 source 暂停转换，更新预览状态与用户说明。
- [x] 运行全部测试与 Release 构建；记录所有已知失败；独立审查并修复重要问题。

## Progress

- 最终改动位于当前项目目录，分支 codex/scroll-capture-rebuild；构建、日志和交付包只写项目内。
- 基线 223/223 通过。最终完整回归 251/251、35 suites 通过（.build/scroll-validation/final-tests.log）。
- Task 1：转换前准入、暂停门控、在途/队列/原生暂停变化缺口及封流竞态已实现。新增反例经历断言级 RED 后通过；所有既有队列/背压/尺寸回归通过。
- Task 2：新帧因果确认、自动滚动安静间隔、结束稳定等待策略及暂停组装在途保护完成。
- Task 3：结束持续排空并取得原生最终截图；暂停完成逐像素只读核对。普通 Return/Space/O 只在控制条聚焦时生效，全局使用 Ctrl+Option+Command。
- 实际 SCK 合成窗口：16 步，1268×4548，零拒绝；末尾64行像素一致。
- 实际 Controller：点击后220ms尾帧进入1268×4548输出；完成中取消不输出；暂停页面自行移动后警告；实际自动滚动264pt，输出高度1476px与预期一致。
- 验收脚本修正：以绝对点击时间调度延迟帧、仅访问可见且就绪的窗口控件、同步监听警告窗口，避免按钮动画和旧窗口污染验收。
- 独立代码审查及针对尾帧、暂停和快捷键的增量复核均通过，无未处理的重要发现。
- 安装包构建/签名和校验记录见 docs/VALIDATION-1.1.16.md。
