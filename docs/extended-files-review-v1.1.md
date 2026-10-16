# 扩展文件操作与模板独立审查

2026-10-14。仅审查并记录，未修改源码或测试。主范围：ExtendedFileActions.swift、TemplateImageTools.swift；辅助检查FileTools.swift与AppDelegate退出保护。并行开发中短暂stub或未接入UI不作为缺陷。

## 结论

本次发现的一项P1剪切身份问题已由实现代理修正，并通过独立生产代码复验关闭。当前限定范围未发现其余可明确复现的P1/P2问题。永久删除路径规范化疑点经实测排除。该结论不等于所有外置卷、系统分享、桌面替身、安装后Finder服务或Office GUI均完成真实验收。

## 已修正并关闭：[P1] 不隐藏剪切会移动同路径替换文件

原触发路径：ExtendedCutSession.restore在没有originalHidden时直接返回，AppModel粘贴只调用restore后普通move，保存的剪切身份没有参与移动。复现过程仅作用于`/private/tmp`自建普通文件：

1. 剪切A且hide=false；先保留A到另一个路径。
2. 将不同inode的B移到A原路径。
3. 原生产调用restore+move成功移动B，独立输出`CUT PASTED CONTENT=replacement fixture`。

最新修正将粘贴交给cut.move，并始终验证构造时device/inode；transfer规划和每次执行继续带原身份。最新行号：ExtendedFileActions.swift:401–410、:136–150、:155–168；AppModel使用cut.move见:458。

独立重新编译真实生产源码并执行同一场景，得到：

```text
compile exit=0
CUT REPLACEMENT REJECTED: 原剪切文件已被替换，未移动替代文件
source preserved=true destinationEmpty=true
run exit=0
```

隐含复验范围包括restore已清除隐藏状态后仍需验证原身份；最新cut.move保留身份核对，与是否隐藏无关。

## 已检查的文件保护

- 复制/移动先检查全批目标、重复名称、目录自身/子目录及原身份；现有目标包括悬空符号链接均不替换。每项执行前再次核对。
- 回滚仅处理已完成且目标身份匹配的项；跨卷不完整目标无法确认所有权时保留并报告路径，避免清理别人的数据。移动回原路径由FileManager拒绝已有目标。
- 根据文件名建目录先预检，失败时仅移除空的新目录；别名和图标组采用独立暂存目录、最终move拒绝已有目标。模板及图片写入使用withoutOverwriting。
- 永久删除完整批预检先于任何remove；根目录、home及其祖先、系统树和卷根受保护。确认默认按钮为取消，永久删除按钮不绑定Return；部分失败报告已删除目标，未伪造回滚。
- 对`/etc`、`/private/etc`、`/var`、`/private/var`仅执行只读永久删除校验：四者均正确拒绝。本机Foundation将/private/etc规范为/etc、/private/var规范为/var，因此保护常量疑点不成立；未执行实际系统删除。
- 新剪切恢复记录在隐藏前写入并同步；恢复校验记录类型/大小/数量/路径及源身份；只移除身份相符的自有记录。正常退出先恢复隐藏，未恢复时阻止退出；busy阻止退出中断文件操作。
- 未发现主动扫描或读取凭据目录的代码。哈希/图片/模板操作只处理显式选中的文件；记录恢复读取应用自有journal及目标元数据，不读取目标文件内容。

## 模板与导出验证

独立读取TemplateImageTools真实源码，生成三种Office文件至`/private/tmp`，用工作区自带文档库解析：

```text
docx: ZIP CRC valid
xlsx: ZIP CRC valid
pptx: ZIP CRC valid
docx parsed paragraphs=1
xlsx parsed sheets=['Sheet1']
pptx parsed slides=1 masters=1 layouts=1
parser exit=0
```

说明其是包含真实包结构与关系的可解析文档，不是空数据伪装扩展名。没有据此宣称全部Office版本的GUI打开或schema验证通过。

已检查：文件名阻止路径逃逸；自定义模板导入保存独立副本，拒绝普通目录和叶符号链接；metadata记录filename再次验证。图片尺寸按除法避免乘法溢出，单张40M预算；图标逐尺寸导出与暂存发布，原图不覆盖。HEIC依本机编码器能力明确返回失败；未冒称本机所有编码都成功。

批量图片转换保留原图，单项失败可能保留之前已输出的图像，当前不提供整批事务回滚；这是剩余行为边界，不将其等同于破坏或覆盖原文件。

## 方法与边界

最小验证通过stdin读取生产代码并使用原生arm64 CLT swiftc编译，源码/测试文件未修改；临时可执行程序和普通fixture均位于/private/tmp。文档解析使用工具返回的bundled Python库。未重复运行根任务整套测试；报告只对上述独立结果和读过的最终修正负责。
