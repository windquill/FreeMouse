# OmniDesk 1.1.31 验证记录

- Apple Silicon / macOS 15+，版本 1.1.31，构建 33。
- 应用目录 OmniDesk.app；CFBundleName、CFBundleDisplayName 和主可执行文件均为 OmniDesk。
- 主窗口、菜单、服务菜单、Finder 菜单及扩展显示名称统一为 OmniDesk。
- 应用标识、URL scheme、偏好设置键和 Finder 扩展标识沿用既有值，保持已有设置和调用兼容。
- 含此前系统翻译性能优化；具体性能样本及限制见 VALIDATION-1.1.30.md。
- 本轮不更改功能逻辑；翻译、快捷键、网络及 Finder 菜单回归测试共 62 项（7 组）全部通过。
- 原生 arm64 发行应用构建成功；主应用和 Finder 扩展名称、版本、服务菜单检查通过，codesign 深度严格验证通过。
- 不宣称全量测试通过：既有全量失败见 VALIDATION-1.1.27.md。
- 未安装或覆盖用户现有应用，未推送代码。
