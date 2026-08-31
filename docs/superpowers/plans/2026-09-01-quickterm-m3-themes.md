# QuickTerm M3（主题 + 背景）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 移植全部 Omarchy 主题（colors.toml + 每主题 1 张官方背景），主题选择器 / 背景选择与循环 / 连续壁纸层 / 透明度与 gaps toggle / 浅色主题联动；任意主题热切换 < 200ms 无重启。

**Architecture:** ThemeManager 为唯一主题状态（@Published palette + background）；切换 = 重写 engine-overlay.conf（配置链第 3 层）→ 嵌入层 `reloadConfig` 逐 surface 热更新 + SwiftUI 调色板同步刷新。主题包与 Omarchy 同构（`Themes/<name>/{colors.toml, backgrounds/…, light.mode?}`），用户目录 `~/.config/quickterm/themes` 优先。

**Spec:** `docs/superpowers/specs/2026-08-31-quickterm-design.md`（§4.3/§4.5、§3.2 主题热切换/连续壁纸、§5.3、§7 M3 行）

## Global Constraints
- 分支 `m3-themes`；决策点 4 已确认：**移植 Omarchy 官方 colors + 每主题 1 张官方背景图**（MIT 仓库；图片不进 git，`scripts/fetch-themes.sh` 拉取缓存，构建期拷入 bundle）
- 键位（§5.3）：`Cmd+Ctrl+Shift+Space` 主题选择器、`Cmd+Ctrl+Space` 背景选择/下一张、`Cmd+Backspace` 透明度、`Cmd+Shift+Backspace` gaps
- 选择器视觉：Walker 风格居中面板（Monaco 18、2px accent 边框、直角、0.95 透明背景）

## Tasks
1. **主题资产管道**：`scripts/fetch-themes.sh` 从 omarchy master 拉全部主题的 `colors.toml`/`light.mode` 进 git（`Themes/`），每主题第 1 张背景到 `Themes/<name>/backgrounds/`（gitignore）；xcodegen 把 Themes 打进 bundle resources
2. **Theme 模型 + ThemeManager + 测试**：colors.toml 极简解析（`key = "#RRGGBB"`）；`Theme { name, colors, isLight, backgrounds }`；`ThemeManager { current, backgrounds, apply(theme:), nextBackground(), overlayContents() }`；生成 overlay（配色 palette=0..15 + background/foreground/cursor/selection + 透明度）写入 EngineOverlay + 调 `ghostty.reloadConfig`（嵌入层现成路径）
3. **UI 动态化 + 壁纸层**：Palette 静态值 → ThemeManager 驱动（StatusBar/PaneChrome/RootView 注入 EnvironmentObject）；RootView 底层放当前背景 Image（fill）；toggle-opacity / toggle-gaps 动作与键位
4. **选择器面板**：通用 PaletteView（居中列表/网格 + 键盘上下/回车/Esc）→ 主题选择器（名称 + 8 色色板条 + light 标记）与背景选择器（缩略图网格）；接键位
5. **浅色联动 + 收尾**：apply 时按 isLight 设 `window.appearance` + `ghostty_app_set_color_scheme`；acceptance 文档；merge + tag `m3`

## Self-Review
- §7 M3 行全覆盖；popin 动画 M1 已有；"19 主题"以 fetch 脚本实际拉到的官方清单为准（仓库演进以 master 为事实来源）✅ 无占位符 ✅ ThemeManager/Theme 接口在 T2 定义、T3/T4 消费一致 ✅
