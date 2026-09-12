# QuickTerm M5 (the scrolling infinite canvas) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Omarchy's `scrolling` infinite horizontal canvas the default workspace layout (column width 0.49, new columns inserted to the right, the viewport follows the focus, neighbouring columns peek in at the edges), with dwindle kept and switchable per workspace via `Cmd+L`; ships as v1.1.

**Spec:** `docs/superpowers/specs/2026-08-31-quickterm-design.md` §4.2-bis (v5, confirmed by the user)

## Global Constraints
- Branch `m5-scrolling`; not a single line of existing dwindle behaviour may break (all 29 existing tests stay green)
- Column width defaults to **0.49**, adjusted in 5% steps, range 25%–90%; scroll animation ~0.15s easeOut; gaps/PaneChrome/hover focus/opacity are all reused as-is
- New and empty workspaces default to scrolling

## Tasks
1. **The ScrollingStrip model + unit tests**: a value type `columns: [Column{panes,widthFactor}]` + `focus(col,row)` + `zoomed` + the full operation set (insertColumnRight/close/focus in four directions/swap columns and swap within a column/mergeLeft⇄splitOut/resizeWidth/equalize/linear next-prev/Codable) + the `targetOffset(current:viewport:gap:)` minimal-scroll pure function; converting between dwindle and scrolling (preserving panes and focus)
2. **WorkspaceModel upgrade**: `[WorkspaceLayout]` (enum dwindle(SplitTree)/scrolling(ScrollingStrip)), with compatibility accessors and `setWorkspaceCount`/`isEmpty`/`paneList` made layout-agnostic; PersistedState v2; existing tests move to the layout-agnostic API
3. **Controller routing**: perform() dispatches on the active layout (dwindle keeps its original path; scrolling goes to the new implementation); `Cmd+L` = switch layout; moveFocusedPane inserts according to the target's layout; the window-close check, scratchpad and panels are unchanged
4. **ScrollingStripView rendering**: GeometryReader+HStack of columns (each column a VStack of evenly split panes), animated offset, ScrollingPaneCell (SurfaceWrapper+PaneChrome+drop zones+the ⌘ drag source, reusing and opening up the ported pieces); RootView picks the renderer by layout; two-finger horizontal pan + snap on release (a bonus item)
5. **Wrap-up**: update the cheat sheet/README/§4.2-bis together; acceptance m5; full suite green; merge + tag `v1.1`; update the artifact

## Self-review
- Every sentence of §4.2-bis has an owning task ✅ no placeholders ✅ the interface names (ScrollingStrip/WorkspaceLayout/targetOffset) are consistent throughout ✅
