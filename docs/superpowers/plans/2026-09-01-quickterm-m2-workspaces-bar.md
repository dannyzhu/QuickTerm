# QuickTerm M2（工作区 + 顶栏）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 默认 5 个工作区（`Cmd+1…5` 直达、`Cmd+Shift+1…5` 移动 pane 并跟随、瞬时切换）+ 26pt 仿 waybar 顶栏（logo/胶囊/时钟/CPU/Wi-Fi/音量/电池，`Cmd+Shift+Space` 隐藏）。

**Architecture:** WorkspaceModel 升级为 5 棵 SplitTree + activeIndex（值语义切换 = 瞬时无动画，忠实 Omarchy）；顶栏为 RootView 顶部 26pt SwiftUI 条，SystemStatsService 以 2s 定时器发布系统状态；新 WM 动作并入既有 KeybindingMap/perform 框架。

**Tech Stack:** 同 M1 + IOKit（电池）/ Network.framework（网络）/ CoreAudio（音量）。

**Spec:** `docs/superpowers/specs/2026-08-31-quickterm-design.md`（§4.4 顶栏、§5.2 工作区、§7 M2 行）

## Global Constraints

- 分支 `m2-workspaces`；沿用 M1 全部视觉/键位约束
- **默认 5 个工作区**（决策已确认）；空工作区显示底色，`Cmd+Return` 在其中开首个 pane
- 顶栏：**26pt 高、主题 bg/fg 两色、Monaco 12pt、SF Symbols 单色图标、无圆角**；活动胶囊 `■`、空胶囊 50% 透明；时钟 `Sunday 14:32` 点击切完整格式；电池 ≤20% 变 `#a55555`
- 简化决定（记录）：CPU 点击弹浮动 top 终端依赖 Scratchpad 基建 → 顺延 M4；顶栏音量点击=静音切换、电池/网络为展示

## Tasks

### Task 1: WorkspaceStore（模型层）+ 单元测试
- WorkspaceModel → 持有 `trees: [SplitTree<Ghostty.SurfaceView>]`（5 个）、`activeIndex`、`barVisible`；`var tree` 代理到活动树（兼容 M1 所有调用点）
- 语义：`switchTo(i)`（越界忽略）；`moveFocusedPane(to: i)` = 从活动树摘除焦点 pane → 目标树按 dwindle 插入（目标空则成根）→ 跟随切换
- 测试：切换保持各树独立；移动 pane 后源树回收/目标树含它；越界安全

### Task 2: 键位 + 控制器接线
- WMAction 增 `goto-workspace-1…5`、`move-to-workspace-1…5`、`toggle-bar`；KeybindingMap 增 `cmd+1…5`、`cmd+shift+1…5`、`cmd+shift+space`
- MainWindowController.perform 落地三类动作；测试断言新表项

### Task 3: 顶栏（StatusBarView + SystemStatsService）
- SystemStatsService（ObservableObject，2s Timer）：cpuPercent（host_processor_info 差分）、batteryPercent/charging（IOPSCopyPowerSourcesInfo）、networkUp（NWPathMonitor）、volume/muted（CoreAudio 默认输出）+ `toggleMute()`
- StatusBarView：左 `◆` logo + 胶囊 1–5（点击切换、区域滚轮循环）；中时钟（TimelineView 每分钟，点击切 `31 August W36 2026` 格式）；右 cpu/wifi/音量（点击静音）/电池图标
- RootView：VStack { if barVisible { StatusBar } ; 树区 }；顶栏隐藏时内容占满

### Task 4: 验收 + 合并
- 手验清单写入 docs/acceptance/m2.md；全量测试绿；merge main + tag `m2`

## Self-Review
- §4.4/§5.2/§7-M2 全覆盖（CPU 点击弹终端顺延已显式记录）✅ 无占位符 ✅ 类型与 M1 接口一致（model.tree 代理保持兼容）✅
