# QuickTerm M3 (themes + backgrounds) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port every Omarchy theme (colors.toml + one official background per theme), the theme picker / background selection and cycling / the continuous wallpaper layer / the opacity and gaps toggles / light-theme system linkage; any theme switches live in under 200ms with no restart.

**Architecture:** ThemeManager is the single source of theme state (@Published palette + background); switching = rewrite engine-overlay.conf (layer 3 of the config chain) → the embedding layer's `reloadConfig` updates every surface live + the SwiftUI palette refreshes in step. Theme packages have the same shape as Omarchy's (`Themes/<name>/{colors.toml, backgrounds/…, light.mode?}`), with the user directory `~/.config/quickterm/themes` taking priority.

**Spec:** `docs/superpowers/specs/2026-08-31-quickterm-design.md` (§4.3/§4.5, §3.2 live theme switching / continuous wallpaper, §5.3, §7 the M3 row)

## Global Constraints
- Branch `m3-themes`; decision point 4 is confirmed: **port Omarchy's official colors plus one official background image per theme** (MIT repo; images stay out of git, `scripts/fetch-themes.sh` fetches and caches them, and the build copies them into the bundle)
- Keybindings (§5.3): `Cmd+Ctrl+Shift+Space` theme picker, `Cmd+Ctrl+Space` background selection / next, `Cmd+Backspace` opacity, `Cmd+Shift+Backspace` gaps
- Picker visuals: a Walker-style centred panel (Monaco 18, 2px accent border, square corners, 0.95 opaque background)

## Tasks
1. **Theme asset pipeline**: `scripts/fetch-themes.sh` pulls every theme's `colors.toml`/`light.mode` from omarchy master into git (`Themes/`), plus each theme's first background into `Themes/<name>/backgrounds/` (gitignored); xcodegen bundles Themes as resources
2. **Theme model + ThemeManager + tests**: minimal colors.toml parsing (`key = "#RRGGBB"`); `Theme { name, colors, isLight, backgrounds }`; `ThemeManager { current, backgrounds, apply(theme:), nextBackground(), overlayContents() }`; generate the overlay (colours palette=0..15 + background/foreground/cursor/selection + opacity), write it through EngineOverlay and call `ghostty.reloadConfig` (the path the embedding layer already has)
3. **Make the UI dynamic + the wallpaper layer**: replace Palette's static values with ThemeManager (inject the EnvironmentObject into StatusBar/PaneChrome/RootView); put the current background Image (fill) at the bottom of RootView; add the toggle-opacity / toggle-gaps actions and their keys
4. **Picker panels**: a generic PaletteView (a centred list/grid + up/down/return/Esc from the keyboard) → the theme picker (name + an 8-colour swatch strip + a light marker) and the background picker (a thumbnail grid); wire up the keys
5. **Light-theme linkage + wrap-up**: on apply, set `window.appearance` and `ghostty_app_set_color_scheme` from isLight; the acceptance document; merge + tag `m3`

## Self-review
- Spec §7's M3 row is fully covered; the popin animation already landed in M1; "19 themes" means whatever the fetch script actually pulls from the official list (the upstream repo evolves, master is the source of truth) ✅ no placeholders ✅ the ThemeManager/Theme interfaces are defined in T2 and consumed consistently by T3/T4 ✅
