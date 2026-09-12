# QuickTerm M4 (polish and wrap-up) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The main menu (Cmd+Alt+Space), the keybinding cheat sheet (Cmd+K), the Scratchpad (Cmd+S), config.toml live reload + rebinding + `[ghostty]` pass-through (layer 4 of the config chain), state restoration, non-native fullscreen (Ctrl+Cmd+F), and the app icon — M4 done means v1 is fully delivered.

**Spec:** `docs/superpowers/specs/2026-08-31-quickterm-design.md` (§4.6/§4.7/§4.8, §5.4, §7 the M4 row)

## Global Constraints
- Branch `m4-polish`; the existing constraints still apply
- Simplifications (recorded): non-native fullscreen is QuickTerm's own stripped-down version (save the frame → hide the Dock and menu bar → set the fullscreen frame; the `.titled` mask is left alone, dodging the tab/accessory restore complexity of Ghostty's version); the graphical settings panel is deferred (Settings = open config.toml), consistent with spec §4.6

## Tasks
1. **Cheat sheet + main menu panels**: `Cmd+K` → OverlayPanel.keybindings (rendering already exists); `Cmd+Alt+Space` → OverlayPanel.menu (flat entries: new terminal / themes… / backgrounds… / status bar / gaps / opacity / cheat sheet / settings / about), reusing the panel navigation
2. **Scratchpad**: `Cmd+S` toggles a floating terminal overlay (centred 70%×60%, accent border, session kept across workspaces, cleaned up automatically when the process exits)
3. **ConfigStore (layer 4 of the config chain)**: minimal parsing of `~/.config/quickterm/config.toml` (top level + [keybinds] + [ghostty]); apply theme / workspaces (1–10, extending the action enum with 6–10) / keybind overrides / append [ghostty] to the end of the overlay; live reload via DispatchSource; fall back to the defaults on a parse failure; unit tests
4. **State restoration**: serialize trees+activeIndex on quit (SurfaceView is already Codable: uuid+pwd rebuild it); restore the layout at launch and start shells on their cwd; a version mismatch is discarded without crashing
5. **Non-native fullscreen + icon + wrap-up**: SimpleNonNativeFullscreen (Ctrl+Cmd+F); a script that generates the icns; README/acceptance/porting-notes; merge + tag `m4` + `v1.0`

## Self-review
- Every item in spec §7's M4 row is covered (the simplified settings panel is recorded) ✅ no placeholders ✅ actions and types follow the existing naming ✅
