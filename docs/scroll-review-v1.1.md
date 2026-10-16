# 长截图 v1.1 独立代码审查

2026-10-14。范围：ScrollCaptureController、ScrollCaptureFlow、ScrollFrameSource、RegionSelector、App、ScrollStitcher、CaptureService，以及 v1.1 spec 和相关测试。仅写本报告，未修改生产源码/测试。已重新检查根任务新加的 CaptureSelection.output、Enter/Space/O 输出与 App 路由。下面行号来自报告写入前源码快照。

当前状态：下列原审查P1/P2均已修正并独立复验关闭，详见末尾“修正复审”；限定变更未发现新确定性问题。

## 确定性问题

### [P1] 连续采集仍被旧版 200 帧上限过早截断

位置：`Sources/FreeMouse/ScrollStitcher.swift:84`；触发与错误处理：`ScrollCaptureController.swift:104`（每120ms消费）及 `:139–145`（尺寸错误永久禁用继续采集）。

复现：以同尺寸、确定性非周期纹理，先采第一帧，再持续每帧仅向下8px。200个有效帧之后，下一帧直接 `.limitReached`，即使总像素与高度都远低于安全预算。新连续模式在每120ms有有效进展时，约24秒即可触发。静止重复帧不计数，因此触发前提是持续发生小幅可匹配滚动。

独立验证使用真实生产 CaptureTypes.swift 与 ScrollStitcher.swift，通过标准输入编译最小 runner。96×120 输入、8px步进，输出为：

```text
compile exit=0
FAILED frame=201 error=limitReached
accepted=200 size=96x1712 pixels=164352
REPRODUCED premature frame-count limit
run exit=0
```

建议：连续模式以现有24M像素和60000高度预算约束内存，去掉“200有效帧”限制或改成与新增内容大小对应的限制。回归应覆盖至少221帧、小幅步进，及最终真实像素顺序。根任务已收到问题，并正在先做221帧回归的 RED，再修正上限；本报告不将待执行修正误报为已通过。

### [P2] 自动滚动一步未截到剩余预算，小高度有效选区会直接失配

位置：`Sources/FreeMouse/ScrollCaptureController.swift:158`、`:168`；允许的图像高度与重叠要求：`ScrollStitcher.swift:53`、`:72–74`。

复现：使用有效的24px高采集视口（96×24，1x；或Retina逻辑12pt、24px），将控制条放在选区外并选择快档。20ms步进计算出8个滚动单位，但当前背压只在投递前判断 `unconsumedMotion < height*0.2`，没有将步幅截到剩余预算。24px视口最少要求20px重叠，只允许4px位移，首个8px步幅已经超出。随后8大于预算4.8，不能继续滚动，也无法接受已失配的新帧，最后回退手动。

独立真实 stitcher 验证：初始96×24有效帧成功，位移8px返回 `noOverlap`。这是有效选区内确定性失败，不依赖权限拒绝或假设系统卡顿。小选区是边界条件；正常高度视口也会超出“最多20%”注释声明，但通常仍有足够重叠。

建议：计算剩余预算并截断每次步幅，预算应考虑最小20px重叠及Retina换算；不足一个安全滚动单位时等待下一帧。另一种明确方案是选区阶段拒绝过低的长截图视口并解释原因。回归应覆盖各速度、1x/2x和剩余预算不足一个完整步幅的情况。

## 经检查未发现新的确定性问题

- 结束首先进入 `.finishing`，停自动滚动、取消消费循环并等待它完成，再采末帧；阶段阻止重复完成。取消立即更换generation，旧的拼接/停止/输出回调在关键await后都检查令牌。窗口delegate先解除，再关闭，避免递归cancel。
- 源缓冲仅保留最新完整帧；sink串行转换，actor串行拼接；预览取尾部，不每帧生成完整长图。输出时才复制完整像素。没有发现无界帧队列或每次预览累计完整图片。
- 自动滚动目标点避开可交互控制条；边框与预览忽略鼠标事件。投递坐标由所选显示器的局部点转换为全局Quartz坐标，并标记事件；自己的事件不会被当作手动接管。
- Carbon长截图处理器检查自己的signature，当前Return/Space/O/Esc的code不会碰撞主应用A/S/R的id。fallback只处理未注册的键。新区域选择的输出路由分别传入.copy/.save/.recognize，S传入长截图；App分别复制或交给编辑器动作，没有发现新增输出错路由。
- RegionSelector记录之前前台应用，移除所有覆盖窗口后再恢复该应用、再resume；跨显示器新拖动清除其他屏幕旧选区，令牌隔离取消。按Esc不会重复resume。

这些是限定代码审查结论，不把原版公开资料未说明的速度/暂停/恢复逻辑说成已完全复制，也不把未执行的系统UI动作说成实测成功。根任务报告的43测试通过不是本审查独立执行的整套结果。

## 验证执行说明

最小runner仅在`/private/tmp`生成编译缓存和可执行文件，未修改仓库；生产源码从文件读取并通过stdin交给编译器。最终成功编译使用原生arm64 CLT swiftc、`-O -swift-version 5 -target arm64-apple-macos15.0`、显式MacOSX SDK及临时module-cache，然后原生arm64执行。两个先行Swift解释器尝试分别被Rosetta工具链架构和默认macOS27标准库解析阻断；没有将这些环境错误当作功能失败，实际问题由最终成功runner输出证实。

## 修正复审：两项已关闭

本轮重新读取并执行真实生产源码，确认上述 P1/P2 均已解决：

- ScrollStitcher 去掉200帧限制，保留24M总像素和60000高度预算。独立runner连续221帧、每次8px，成功得到`accepted=221 size=96x1880`，没有限额异常。
- ScrollMotionBudget.step 按剩余预算及`max(20/scale, viewportHeight/6)`最小重叠限幅。独立结果：24px/1x首步=4，12pt/2x首步=2，900pt/2x剩余2pt预算时步幅=2。Controller使用该函数并拒绝投递零步幅。
- 结束路径新增includeTail，暂停期间完成不再消耗暂停期间的页面；最终采集前检查source.failure。上述限定修正未发现新的确定性错误。

独立runner编译和执行均exit 0。此结论关闭两项代码问题，不声称已完成真实浏览器滚动/系统权限/主观流畅度验收。
