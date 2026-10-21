# Network Panel Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans to implement task-by-task.

**Goal:** 按 Stats 原版网络面板代码和布局接入完整网络详情，提供菜单栏间距设置。

**Architecture:** 独立 NetworkMonitor 维护采样、历史和按需详情任务；NetworkPanel 适配 Stats popup；AppDelegate 区分图标和网速点击，管理 NSPopover 生命周期。Dashboard 使用持久化间距设置。

**Tech Stack:** Swift/AppKit/SwiftUI/SystemConfiguration/CoreWLAN/CoreLocation/URLSession/nettop。

**Spec:** docs/superpowers/specs/2026-10-21-network-panel.md

## Tasks

- [x] 间距：先运行失败测试，修复右对齐空白，设置0–20点，验证布局及异常值。
- [x] 数据层：固定来源，复用Stats读取逻辑；测试差分/累计流量/历史边界/进程解析/取消与失败。
- [x] 面板：按Stats popup原布局实现，真实数据绑定，缺值和权限按钮，模拟数据视觉验证。
- [x] 集成：NSStatusBarButton按点击位置打开原菜单或popover，打开/关闭启动停止详情任务，保留录屏及wake处理。
- [x] 验证：针对性与完整release测试、代码审查、原生模拟面板预览、DMG构建和校验；如旧测试失败如实记录。

代码改动仅在本项目；不自动安装，不修改系统设置，不读取凭据，不提交或推送，除非另有要求。
