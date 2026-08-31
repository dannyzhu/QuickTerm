# QuickTerm M4（打磨收尾）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 主菜单（Cmd+Alt+Space）、快捷键速查（Cmd+K）、Scratchpad（Cmd+S）、config.toml 热重载 + 改键 + [ghostty] 透传（配置链第 4 层）、状态恢复、非原生全屏（Ctrl+Cmd+F）、App 图标——M4 完成即 v1 全量交付。

**Spec:** `docs/superpowers/specs/2026-08-31-quickterm-design.md`（§4.6/§4.7/§4.8、§5.4、§7 M4 行）

## Global Constraints
- 分支 `m4-polish`；沿用既有约束
- 简化决定（记录）：非原生全屏为 QuickTerm 自写精简版（保存 frame → 隐藏 Dock/菜单栏 → 全屏 frame；不摘 .titled，规避 Ghostty 版的 tab/accessory 恢复复杂度）；图形化设置面板后置（Settings=打开 config.toml），与 spec §4.6 一致

## Tasks
1. **速查 + 主菜单面板**：`Cmd+K` → OverlayPanel.keybindings（渲染已就绪）；`Cmd+Alt+Space` → OverlayPanel.menu（扁平条目：新建终端/主题…/背景…/顶栏/gaps/透明度/速查/设置/关于），复用面板导航
2. **Scratchpad**：`Cmd+S` toggle 浮动终端覆盖层（居中 70%×60%、accent 边框、跨工作区保持会话、进程退出自动清理）
3. **ConfigStore（配置链第 4 层）**：`~/.config/quickterm/config.toml` 极简解析（顶层 + [keybinds] + [ghostty]）；应用 theme/workspaces(1–10，动作枚举补 6–10)/keybinds 覆盖/[ghostty] 追加进 overlay 尾部；DispatchSource 热重载；解析失败回退默认；单元测试
4. **状态恢复**：退出序列化 trees+activeIndex（SurfaceView 已 Codable：uuid+pwd 重建）；启动恢复布局并按 cwd 起 shell；版本不匹配丢弃不崩溃
5. **非原生全屏 + 图标 + 收尾**：SimpleNonNativeFullscreen（Ctrl+Cmd+F）；脚本生成 icns；README/验收/porting-notes；merge + tag `m4` + `v1.0`

## Self-Review
- §7 M4 行全项覆盖（设置面板简化已记录）✅ 无占位符 ✅ 动作/类型沿用既有命名 ✅
