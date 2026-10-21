# README 界面图

`generate.py` 从产品 SwiftUI 视图生成应用管理、输入法、风扇和翻译面板图片，并根据实际菜单配置绘制压缩解压菜单结构示意图。所有生成结果写入 `docs/images/`。

在 Apple Silicon Mac 的图形登录会话中，安装 Command Line Tools 并先成功运行 `python3 scripts/build.py`，随后在项目根目录执行：

```bash
/usr/bin/arch -arm64 /usr/bin/python3 scripts/readme-screenshots/generate.py
```

生成器在 `.build/readme-screenshots/` 中创建视图源文件的临时副本并注入示例数据，不修改产品源码。生成时会短暂显示演示窗口，不读取私人桌面，不启动或结束其他应用，不修改登录项、输入法或风扇，也不发起翻译请求。

应用运行状态、PID、登录开关、输入法计数、转速和翻译文本均为演示数据。压缩解压图片是菜单结构示意，不是 Finder 原生弹出菜单截图。更新产品布局后应重新生成图片并检查可读性。
