# OmniDesk 1.1.32 验证记录

- Apple Silicon / macOS 15+，版本 1.1.32，构建 34。
- 新增 Finder 一级「解压到同名文件夹」和「压缩」二级格式菜单；保留排序、隐藏设置和既有稳定 action tag，旧配置自动追加新入口。
- 本机实测创建10种格式：ZIP、7z、TAR、tar.gz、tar.bz2、tar.xz、tar.lzma、tar.Z、CPIO、cpio.gz。能力探测执行内存双文件往返；不支持的外部过滤器不会调用命令行回退。
- XAR 系统 writer 存在多文件后续短文件补零问题，禁用创建、保留读取；本机 Zstandard/LZ4 无原生写入支持，因此菜单不显示这两种创建格式。
- 读取注册 ZIP/7z/TAR/CPIO/XAR/RAR/RAR5/ISO9660/CAB/LHA/AR/WARC，由本机系统库和归档具体内容决定；不宣称所有变种、加密和分卷均可解压。禁用可引用本机外部文件的 MTREE。
- 74 项相关测试（10组）全部通过，包括10种可用格式往返、Unicode、空目录、多选、元数据过滤、保留普通隐藏文件、标准 ./ TAR 路径、损坏归档、绝对/越界路径、链接/特殊文件、重名拒绝覆盖、超限、菜单结构和配置迁移，以及既有 Finder/翻译/快捷键/网络回归。
- 独立 Python zipfile/tarfile 读取验证 ZIP、TAR、tar.gz、tar.bz2、tar.xz，文件内容一致；.DS_Store 被过滤，普通隐藏文件保留。
- C 桥接经 -Wall -Wextra -Werror 检查；独立代码审查发现并修复源目录符号链接竞态、隐式目录预算以及 errno 分支问题。
- 源目录通过 openat/fdopendir 固定目录描述符；解压通过目录描述符与 O_NOFOLLOW 创建目标；私有暂存、失败清理、RENAME_EXCL 发布不覆盖已有结果。
- 限制：拒绝所有归档链接和特殊文件；每次20 GiB、100000项、目录深度256；不提供裸gzip/bzip2/xz单文件流、加密或分卷支持。
- 原生应用和 Finder 扩展编译成功，codesign 深度严格校验通过；未在用户机器安装或注册新版 Finder 扩展，实际 Finder 启用由安装后操作。
- 本轮未重跑全量测试；既有全量失败见 VALIDATION-1.1.27.md，不宣称全量通过。
- 未安装、覆盖用户现有应用或推送代码，全部归档验证只使用项目构建目录的自建样例。
