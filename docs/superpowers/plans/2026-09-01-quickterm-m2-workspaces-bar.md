# QuickTerm M2 (workspaces + status bar) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 5 workspaces by default (`Cmd+1…5` to jump, `Cmd+Shift+1…5` to move a pane and follow it, switching is instant) + a 26pt waybar-style status bar (logo/pills/clock/CPU/Wi-Fi/volume/battery, hidden with `Cmd+Shift+Space`).

**Architecture:** WorkspaceModel grows into 5 SplitTrees + an activeIndex (value semantics make switching instant and animation-free, faithful to Omarchy); the status bar is a 26pt SwiftUI strip at the top of RootView, with SystemStatsService publishing system state from a 2s timer; the new WM actions slot into the existing KeybindingMap/perform framework.

**Tech Stack:** as M1, plus IOKit (battery) / Network.framework (network) / CoreAudio (volume).

**Spec:** `docs/superpowers/specs/2026-08-31-quickterm-design.md` (§4.4 the status bar, §5.2 workspaces, §7 the M2 row)

## Global Constraints

- Branch `m2-workspaces`; every visual and keybinding constraint from M1 still applies
- **5 workspaces by default** (decision confirmed); an empty workspace shows the background colour, and `Cmd+Return` opens the first pane in it
- Status bar: **26pt tall, two theme colours (bg/fg), Monaco 12pt, monochrome SF Symbols icons, no rounded corners**; the active pill is `■`, empty pills are 50% transparent; the clock reads `Sunday 14:32` and clicking switches to the full format; the battery turns `#a55555` at ≤20%
- Simplifications (recorded): clicking CPU to pop up a floating top terminal depends on the Scratchpad plumbing → deferred to M4; clicking the volume in the status bar toggles mute, while the battery and network are display-only

## Tasks

### Task 1: WorkspaceStore (model layer) + unit tests
- WorkspaceModel holds `trees: [SplitTree<Ghostty.SurfaceView>]` (5 of them), `activeIndex` and `barVisible`; `var tree` proxies to the active tree (so every M1 call site keeps working)
- Semantics: `switchTo(i)` (out of range is ignored); `moveFocusedPane(to: i)` = pull the focused pane out of the active tree → insert it into the target tree by the dwindle rule (it becomes the root if the target is empty) → switch and follow
- Tests: switching keeps the trees independent; after a move the source tree has released the pane and the target contains it; out-of-range is safe

### Task 2: Keybindings + controller wiring
- Add `goto-workspace-1…5`, `move-to-workspace-1…5` and `toggle-bar` to WMAction; add `cmd+1…5`, `cmd+shift+1…5` and `cmd+shift+space` to KeybindingMap
- MainWindowController.perform implements all three kinds of action; the tests assert the new table entries

### Task 3: The status bar (StatusBarView + SystemStatsService)
- SystemStatsService (ObservableObject, 2s Timer): cpuPercent (differencing host_processor_info), batteryPercent/charging (IOPSCopyPowerSourcesInfo), networkUp (NWPathMonitor), volume/muted (the CoreAudio default output) + `toggleMute()`
- StatusBarView: left, the `◆` logo + pills 1–5 (click to switch, scroll wheel over the area cycles); middle, the clock (TimelineView on the minute, click to switch to the `31 August W36 2026` format); right, cpu/wifi/volume (click to mute)/battery icons
- RootView: VStack { if barVisible { StatusBar } ; the tree area }; with the bar hidden the content fills the window

### Task 4: Acceptance + merge
- Write the manual checklist into docs/acceptance/m2.md; full suite green; merge into main + tag `m2`

## Self-review
- §4.4/§5.2/§7-M2 fully covered (the deferral of click-CPU-for-a-terminal is recorded explicitly) ✅ no placeholders ✅ types match the M1 interfaces (the model.tree proxy keeps compatibility) ✅
