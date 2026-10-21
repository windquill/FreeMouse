# 实施计划

1. CArchiveBridge：系统 libarchive 头文件和许可、C 写入/安全解压桥、格式能力探测；ArchiveFormats.swift 目录与 ArchiveService.swift 事务封装；先写引擎回归用例再实现。
2. 菜单：MenuCatalog 添加 extract/compress；FinderMenuPreferences 固定新 tag；FinderMenuBuilder/ContextTools 添加压缩二级菜单、解压一级动作，保持现有排序隐藏；菜单测试先验证新结构及路由。
3. 主应用接入：AppModel 收集选中文件、后台任务、冲突命名、状态与失败处理；不阻塞主线程、不执行 shell 字符串。
4. 构建：Package.swift 和 scripts/build.py 同时支持 C 桥接，Finder 扩展共享 ArchiveFormats；版本升级，第三方声明与 README、验证记录更新。
5. 集成：检查代理代码，运行归档/菜单回归与相关现有测试；独立代码审查与安全样例验证；构建 DMG，验证签名和映像。
