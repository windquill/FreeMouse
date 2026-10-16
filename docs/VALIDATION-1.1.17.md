# 1.1.17 / build 19 验证记录

## 实现来源

直接导入 Capso revision 9ecb30b0a0f9dfeacae62aa30f2359451c0e823d 的采集控制器、Vision配准、HeaderDetector、ScrollStitcher、HUD及浮层布局。FreeMouse 当前入口使用 CapsoScrolling；旧算法代码仅留作历史兼容测试。完整 BSL 1.1、来源和本地适配记录随应用/DMG/源码分发。

## 自动回归

导入5项上游测试：固定标题不重复、固定标题/底栏检测与位移、逆向位移、连续滚动图像逐像素一致、无重叠拒绝。最初因CapsoScrolling不存在而失败，导入后全部通过。

最终全套256项/37组测试通过。旧算法测试属于兼容回归，不代表新引擎覆盖范围。

## 原生合成页面

使用独立进程 AppKit NSScrollView、634×474点/2倍缩放，只采集已知合成内容区。16步滚动0至1800点，每步预览高度均与期望一致；完成前立即追加48点，最终输出1268×4644像素，回调仅1次。完成后取消不输出、旧会话回调不影响新会话。生成图已目视检查行序连续。

末尾跳过整屏失去重叠时，确认出现未接上警告；选择取消后不输出。最终证据目录：`.build/scroll-validation/ControllerRunner-5508e22c`，日志包含CAPSO_UNMATCHED_TAIL_PASS及RESULT_PASS。

命令：`/usr/bin/python3 scripts/scroll-validation/run.py`。原始日志及生成图保存在项目 `.build/scroll-validation`；不包含用户页面或凭据。

## 构建

Apple Silicon、macOS 15+；应用及Finder扩展1.1.17/build19。本地ad-hoc签名，通过codesign --verify --deep --strict。未安装或替换已安装应用，未更改系统权限。

## 限制

未针对用户实际卡顿页面进行验收；动画、重复内容、快速跨屏滚动及内存不足仍可能失败。未验证商业使用许可适用性；BSL的商业Screen Capture Service限制见完整许可证。本版为上游手动采集流程，不提供旧自动滚动控件。不得将合成页面测试描述为所有应用均稳定。
