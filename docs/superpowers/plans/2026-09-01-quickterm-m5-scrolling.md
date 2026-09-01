# QuickTerm M5（scrolling 无限画布）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 工作区默认布局改为 Omarchy `scrolling` 无限横向画布（列宽 0.49、右插新列、视口跟随焦点、边缘露出相邻列），dwindle 保留并可 `Cmd+L` 按工作区切换；v1.1 交付。

**Spec:** `docs/superpowers/specs/2026-08-31-quickterm-design.md` §4.2-bis（v5，用户已确认）

## Global Constraints
- 分支 `m5-scrolling`；dwindle 现有行为一行不破坏（现有 29 测试保持绿）
- 列宽默认 **0.49**、调整步进 5%、范围 25%–90%；滚动动画 ~0.15s easeOut；gaps/PaneChrome/悬停焦点/透明度全部复用
- 新工作区/空工作区默认 scrolling

## Tasks
1. **ScrollingStrip 模型 + 单测**：值类型 `columns: [Column{panes,widthFactor}]` + `focus(col,row)` + `zoomed` + 全套操作（insertColumnRight/close/focus 四向/swap 列与列内/mergeLeft⇄splitOut/resizeWidth/equalize/linear next-prev/Codable）+ `targetOffset(current:viewport:gap:)` 最小滚动纯函数；dwindle⇄scrolling 互转（保 pane 保焦点）
2. **WorkspaceModel 升级**：`[WorkspaceLayout]`（enum dwindle(SplitTree)/scrolling(ScrollingStrip)），兼容访问器与 `setWorkspaceCount`/`isEmpty`/`paneList` 布局无关化；PersistedState v2；现有测试改用布局无关 API
3. **控制器路由**：perform() 按活动布局分派（dwindle 走原路径；scrolling 走新实现）；`Cmd+L` = 布局切换；moveFocusedPane 目标按其布局插入；关窗判定/scratchpad/panel 不变
4. **ScrollingStripView 渲染**：GeometryReader+HStack 列（列内 VStack 等分栈）、offset 动画、ScrollingPaneCell（SurfaceWrapper+PaneChrome+drop zones+⌘拖拽源，复用/开放移植件）；RootView 按布局切换渲染器；双指横滑平移+松手吸附（附带项）
5. **收尾**：速查表/README/§4.2-bis 联动更新；acceptance m5；全量测试绿；merge + tag `v1.1`；artifact 更新

## Self-Review
- §4.2-bis 每句都有归属任务 ✅ 无占位符 ✅ 接口名（ScrollingStrip/WorkspaceLayout/targetOffset）全文一致 ✅
