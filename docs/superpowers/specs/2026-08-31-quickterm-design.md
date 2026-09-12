# QuickTerm Design

**Date**: 2026-08-31 · **Status**: ✅ shipped, still iterating (this is the **v8 alignment revision**, 2026-09-03, checked section by section against the code on `main`; facts that moved after 1.5.x are corrected inline)

**Revision history**
- **v2**: Monaco font (SF Symbols for UI icons); workspaces on `Cmd+digit`, 5 by default; `Cmd+arrow` to move between terminals; `Cmd+drag` to move/split/resize a pane
- **v3**: every keybinding rebindable from the config's `[keybinds]` section; the engine config reuses `~/.config/ghostty/config` first (four-layer config chain)
- **v4**: focus follows mouse; dynamic opacity for active/inactive panes
- **v5**: the default workspace layout becomes the **scrolling infinite horizontal canvas** (Omarchy/Hyprland `scrolling`); dwindle kept, `Cmd+L` switches
- **v6**: `pane-padding` (14pt default); gaps unified on Hyprland semantics (10pt both between panes and around the edge); scrolling fill mode
- **v7**: `Cmd+T` floating pane (⌘drag to move / ⌘right-drag to resize); state v3
- **v8 (this revision)**: the opacity system settled (`pane-opacity` 0.92 / `active-opacity` 0.98 / `bar-opacity` 0.75 / frosted blur); floating-pane default geometry and occlusion test (HoverOcclusion, model geometry); `visible-columns`; the viewport follows a swap; background system 2.0 (all Omarchy backgrounds + user-supplied); Apple-style icon; NSHostingView flipped-coordinate convention; §3/§5/§6/§7 rewritten to match the implementation; unimplemented items flagged

In one line: **Omarchy's Hyprland tiling desktop packed into one native macOS window, filled with terminals.** Pure Swift (AppKit + SwiftUI), terminal engine is libghostty (GhosttyKit, pinned to Ghostty v1.3.1), UI and keybindings copied faithfully from Omarchy.

---

## 1. Omarchy research findings (the basis for this design)

Checked against the `omarchy` repo (basecamp/omarchy) sources and the official manual. This section records **what Omarchy does**; QuickTerm's own values are in §4, and every difference is flagged.

### 1.1 Visual language (the "flavour" QuickTerm reproduces)

| Element | What Omarchy does | What QuickTerm does |
|---|---|---|
| Corners | **0 (square throughout)** — windows, top bar, menus and OSD are all square | same |
| Borders | 2px; active = theme accent, inactive = grey `rgba(595959aa)` | same (the inactive border colour is hard-coded, it does not follow the theme) |
| Gaps | `gaps_in = 5`, `gaps_out = 10` | 5 per pane edge + 5 outer ring → 10 both between panes and around the edge |
| Opacity | active 0.985 / inactive 0.96 | three layers composited: 0.92 engine baseline + an active backing layer compositing up to 0.98 + inactive dimmed to 0.96 + frosted blur (§4.9) |
| Font | JetBrainsMono Nerd Font: top bar 12px, menus 18px | Monaco for the UI: status bar 12, panels 15/13/11; **the terminal font is left to the ghostty config** (§4.12) |
| Animation | window open popin 87%; no animation when switching workspaces | popin 0.87 scale + fade in, 0.2s easeOut; workspace switches are instant |
| Top bar | 26px, solid theme-coloured strip, monochrome icons | 26pt, **0.75 translucent** (the wallpaper shows through), monochrome SF Symbols |
| Layout | dwindle + switchable scrolling (`column_width = 0.49`) | **scrolling by default** (column width (1−2×1.5%)/columns = 0.485, 1.5% peek on each side), dwindle kept, `Cmd+L` switches |

### 1.2 Top bar (Waybar) structure

- **Left**: logo + workspace numbers `1–5`, always present (the active workspace is a solid square, empty workspaces are 50% transparent, all clickable)
- **Middle**: clock `Sunday 14:32`; the alternate format shows the full date
- **Right**: bluetooth, network, volume, CPU, battery — monochrome icons

### 1.3 Theme system

- Upstream currently ships **22 themes** (5 light ones: catppuccin-latte / flexoki-light / lupine / rose-pine / white), Tokyo Night is the default
- One `colors.toml` per theme + a `backgrounds/` directory of images (ordered by the `0-`, `1-` prefix)
- Theme picker on `Super+Ctrl+Shift+Space`; background menu on `Super+Ctrl+Space`

### 1.4 Menus (omarchy-menu / Walker)

Centred panel, monospace font, 2px solid theme-coloured border, 0.95 opaque background, no rounded corners.

### 1.5 Keybinding catalogue

About 130 desktop-level bindings verified. **Omarchy's `Super+C/V` was already imitating macOS's `Cmd+C/V`** — the Super→Cmd mapping falls out naturally.

---

## 2. Technology choice

### Option A (adopted): embed all of libghostty (GhosttyKit)

The internal C API that Ghostty's own macOS app consumes: `ghostty_app_new/tick`, `ghostty_surface_new` (Metal rendering happens inside the library), input/size/scale, clipboard and action callbacks, per-surface live config reload.

- ✅ Highest fidelity: GPU rendering, ligatures, Kitty graphics, complete VT — on a par with Ghostty itself
- ✅ MIT licensed; there is commercial precedent (OrbStack and others)
- ⚠️ That API is **internal, unstable and carries no compatibility promise**: pin a tag plus the matching Zig version and build the xcframework yourself; upgrading Ghostty is its own porting project
- **How it actually landed**: the embedding layer is Ghostty's `macos/Sources/Ghostty/` ported straight into `Sources/GhosttyEmbed/` (MIT), with **no `TerminalEngine` protocol abstraction** (v1 depends on the ported layer directly; reconsider isolating it once an official Swift package exists)

### Option B: SwiftTerm — the fallback, not taken. Option C: libghostty-vt + our own renderer — the most work, not taken.

---

## 3. Overall architecture

**AppKit owns the state and the lifecycle, SwiftUI only renders.** The layout model is entirely immutable value types (`Codable`), so persisting and switching cost nothing.

```
AppDelegate (AppKit lifecycle; test-host isolation via isRunningTests)
├─ Ghostty.App                                     ← ported engine wrapper (ghostty_app)
├─ ThemeManager                                    ← theme/background/opacity state; generates engine-overlay.conf
└─ MainWindowController : BaseTerminalController   ← sole owner of the state, every WM action, mouse/keyboard monitors
   ├─ HiddenTitlebarWindow : NSWindow              ← hidden-titlebar recipe
   ├─ WorkspaceModel (ObservableObject)            ← [WorkspaceLayout] + [[FloatingPane]] + activeIndex
   │    WorkspaceLayout = .scrolling(ScrollingStrip) | .dwindle(SplitTree)
   ├─ KeybindingMap (value type) + ConfigStore/Watcher  ← key table + config.toml live reload
   └─ contentView = NSHostingView(RootView)        ← SwiftUI (note: flipped coordinates, §4.3)
        ZStack {
          theme.background + WallpaperThumb        ← window-wide wallpaper (extends behind the status bar)
          VStack { StatusBarView (26pt, translucent)
                   ZStack { ScrollingStripView | TerminalSplitTreeView   ← the two layout branches
                            floating layer (ForEach FloatingPane → ScrollingPaneCell)
                            Scratchpad overlay
                            OverlayPanelView scrim + panel } }
        }
```

**Since 1.5.6 this tree exists once per "screen"**: `AppDelegate` keeps a registry of `MainWindowController`s (`Sources/App/AppDelegate+Screens.swift`, `Sources/Windowing/ScreenRegistry.swift`), each with its own window, workspaces, status bar, floating layer and Scratchpad. Process-wide: the engine, `ThemeManager`, `AppSession` (config / keybindings / system stats), `BrowserExtensionManager` and the saved state. Plan: `docs/superpowers/plans/2026-09-08-multi-screen.md`.

### 3.1 Component list

| Component | Responsibility | Key interface / notes |
|---|---|---|
| `Ghostty.App` / `Ghostty.SurfaceView` (`Sources/GhosttyEmbed/`) | engine wrapper, surface hosting (Metal is handled inside the library), key/IME/mouse forwarding, focus state, cwd persistence | ported from Ghostty (MIT); QuickTerm's changes are marked with a `// QuickTerm:` comment |
| `SplitTree<Pane>` | immutable binary tree: insert/remove/swap/resize/equalize/zoom/spatial navigation, `Codable` | ported (~1400 lines); `SplitTree+QuickTerm` adds the dwindle direction rule and flipping |
| `ScrollingStrip` | immutable column strip: a column is a vertical stack of panes; insert column/close/focus/swap/merge and split out/resize width/equalize/zoom/drag and drop; viewport geometry as pure functions (`columnWidths`/`targetOffset`); `layoutSignature` | converting to and from dwindle keeps every pane and its order |
| `WorkspaceModel` | per-workspace layout + floating layer; `switchTo`, `setWorkspaceCount`, `layoutsMatch(factor:)`; the single Scratchpad surface; panel state | `Sources/Windowing/RootView.swift` |
| `FloatingPane` / `HoverOcclusion` | normalized rect for a floating pane (`defaultRect`, `clamped`); occlusion decided from model geometry | §4.4 / §4.3 |
| `MainWindowController` | dispatches every WM action (`perform(_:)`); three local `NSEvent` monitors (keyboard / ⌘mouse / scroll wheel); floating move and resize; panel navigation; state v3 persistence; applying config | inherits the `BaseTerminalController` shim (`focusFollowsMouse`, `surfaceIsOccluded`) |
| `StatusBarView` + `SystemStatsService` | waybar-style top bar; CPU / volume / battery sampled every 2s, network driven by NWPathMonitor events, clock every 30s | `StatusBarView.height = 26` |
| `ThemeManager` | theme discovery (bundle ∪ user directory), switching, the background list (the theme's own + the user directory), the four opacity values, `overlayExtra()` generating the engine overlay | `apply`/`selectBackground`/`addUserBackground`/`toggleOpacity`/`toggleGaps` |
| `OverlayPanelView` | the four-in-one centred panel: themes / background grid / cheat sheet / main menu | `backgroundsColumns = 3` |
| `ConfigStore` + `ConfigWatcher` + `EngineOverlay` | minimal TOML parsing of `config.toml`, directory-level watching for live reload (0.2s debounce), writing the overlay file | a parse failure silently falls back to the defaults (**no warning in the status bar**) |
| `KeybindingMap` + `WMAction` | default key table, merging user overrides and unbinds, key-name normalization, data source for the cheat sheet | anything that does not match is passed straight through to the terminal |

### 3.2 Key mechanisms

- **Hidden titlebar**: the styleMask keeps `.titled + .fullSizeContentView + .resizable + .closable + .miniaturizable`, with the title and the traffic lights hidden and system tabs disabled; keeping `.titled` is what gives you a normal shadow and normal restore behaviour.
- **Key interception**: a window-level `NSEvent.addLocalMonitorForEvents(.keyDown)`: (1) while a panel is open, `handlePanelKey` takes ↑↓←→/↩/⎋ first; (2) look the event up in `KeybindingMap`; (3) on a miss, `return event` and let it reach the surface. The menu bar mirrors 9 common actions (their keyEquivalents are hard-coded and do not follow rebinds — they exist to be visible). **WM-level keys are resolved by QuickTerm; terminal-level keys (copy/paste/font size) are resolved by libghostty's own config.**
- **A workspace is just another layout value being rendered**: `[WorkspaceLayout]` + index; switching is instant, no animation.
- **zoom = render only that pane**: any structural change clears zoom automatically.
- **Continuous wallpaper**: the window itself is opaque; `RootView`'s outermost ZStack lays down `theme.background` + `WallpaperThumb`, and the status bar and every pane sit on top of the wallpaper; surfaces let it through via the engine's `background-opacity`.
- **Live theme switching**: `ThemeManager.writeOverlay()` rewrites `engine-overlay.conf` → the `onOverlayChanged` hook: app-level `reloadConfig` + one reload per surface + `applyAppearance()` (a light theme also drives `NSAppearance` and `ghostty_app_set_color_scheme`).
- **Engine config chain**: four layers (§4.10).
- **Non-native fullscreen** (stripped-down version): save the frame + `presentationOptions = [.autoHideDock, .autoHideMenuBar]` + a synchronous `setFrame(screen.frame)`, without touching the styleMask; `Ctrl+Cmd+F` toggles, `Cmd+Esc` is the dedicated exit.
- **Coordinate convention**: `contentView` (an NSHostingView) has `isFlipped == true`, so what `convert(locationInWindow)` returns is already a top-left coordinate; every window-coordinate → content-area normalization goes through `normalizedContentPoint` (which is isFlipped-aware), locked down by a regression test.
- **Test-host isolation**: `AppDelegate.isRunningTests` (detected from `XCTestConfigurationFilePath`) — under test, state is neither restored nor saved, and an empty tree does not close the window.

### 3.3 Error handling

- The engine fails to initialize → alert at launch, then quit
- A surface fails to be created → that `SurfaceView` enters the tree in an error state (`error = .apiFailed`) rather than taking the whole tree down
- Config/theme fails to parse → silently fall back to the defaults (no UI warning)
- The saved state is corrupt or its version is incompatible → discard it and start fresh

---

## 4. Feature spec (aligned with the implementation)

### 4.1 Creating a terminal quickly

- `Cmd+Return`: scrolling = **insert a new column to the right** of the focused column; dwindle = split by the rule (wider than tall splits right, otherwise down — the geometry comes from SplitTree's spatial layout inside the content area, not from view frames). **Inherits the focused pane's cwd.** A new dwindle split only animates locally: the original pane shrinks from full size down to its ratio while the new one fades in (0.28s), and the tree view is no longer rebuilt wholesale (leaves are identified by surface id, and the pop-in animation only plays the first time a pane appears).
- New-pane pop-in: 0.87 scale + fade, 0.2s easeOut; a new pane starts with `focused = false` and is driven by the first-responder callback (this avoids two panes showing an active border at once).
- `Cmd+S`: Scratchpad (§4.4). The main menu can create terminals too.

### 4.2 Layouts: scrolling (default) and dwindle

**scrolling (the default for a new workspace)**: a workspace is an infinite horizontal strip of columns, each column a vertical stack of panes.
- The column width factor defaults to `(1 − 2×peek) / visible-columns`, with `peek = 1.5%` (2 columns by default → 0.485); adjustable between 0.25 and 0.90, ±0.05 from the keyboard.
  The peek only needs to show the neighbouring column's gap, border and a sliver of background to hint "there is more over there" (≈15pt in a 1000pt viewport); 6% was tried, and users found it far too wide.
- **Fill mode**: when the nominal total width fits, scale it up proportionally to fill (a single column goes full screen, two columns get even gaps left/middle/right); only on overflow does it fall back to the nominal width with **minimal scrolling + peek** — the scroll target is "the focused column fully visible with one peek outside it", so when the focus is in the middle the two inner columns show in full and the left and right neighbours each show a sliver (symmetrically), and at either end it naturally sits flush. The viewport follows in 0.15s easeOut.
- **What triggers a viewport realign**: a focus change / a change in `layoutSignature` (the structural signature of column order and row order) / a workspace switch / a two-finger pan. The signature **deliberately excludes column width** — feeding per-event width changes from a right-drag into the signature would hijack a manually panned viewport back to the focused column.
- Keys: `Cmd+←/→` across columns (landing on the nearest row at the same height), `Cmd+↑/↓` within a column; `Cmd+Shift+arrow` swaps columns or swaps within a column; `Cmd+J` merges a single-pane column into the column on its left ⇄ splits a multi-pane column back out; `Cmd+Ctrl+←/→` resizes width, `Cmd+Ctrl+=` resets every column to the current factor (`Cmd+Ctrl+↑/↓` do nothing); `Cmd+W` closes the pane, removes the column if it is now empty, and moves the focus left.
- Columns visible per screen: config `visible-columns` (1–6) wins, otherwise UserDefaults (default 2); the main menu's "columns per screen" entry cycles 2→3→4→2 on Return, and switching re-lays out **every** scrolling workspace.
- A two-finger horizontal swipe on the trackpad pans the canvas, snapping to the nearest column's left edge on release; ignored when the content does not overflow.

**dwindle (kept)**: Omarchy's split rule; `Cmd+J` flips the direction of the nearest split; dividers are a visible 1pt line with a 6pt hit zone, draggable to change the ratio and **double-clickable to equalize** (fixed in v8: wired up to the engine's `didEqualizeSplits` callback); `Cmd+Ctrl+arrow` resizes by 100px in four directions (`+Shift` for 10px).

`Cmd+L` switches a workspace between the two layouts, keeping every pane in the same order (column → a chain of right splits, the stack inside a column → a chain of down splits).
The round trip remembers: each workspace remembers the layout it last left, and restores it verbatim if the set of panes has not changed (column stacks, widths and order are not lost — the conversion is lossy, and 5 panes arranged in 3 columns flattened to 5 single columns overflow the viewport). Only when panes have been added or removed does it fall back to the conversion above, and the widths that come out of the conversion follow the current columns-per-screen setting.

### 4.3 Focus, swapping, drag and drop, and the occlusion test

- **Focus follows mouse** (always on): `SurfaceView.mouseMoved` → `Ghostty.moveFocus`.
- **The occlusion test (HoverOcclusion, v8)**: a tracking area knows nothing about sibling views covering it, so hover, `mouseEntered` and **the left-click focus transfer** all go through the `surfaceIsOccluded` guard — and only "a floating pane at a higher z / a panel scrim / the Scratchpad" counts as occlusion. **hitTest is deliberately not used**: while ⌘ is held every pane carries a hittable drag-source overlay on top of it, and a flashing overlay scrollbar would be misread too. An occluded pane gets one synthesized `mousePos(-1,-1)` to clear the TUI's hover highlight; the first move after it stops being occluded re-sends the enter state. A drag sequence skips the guard entirely (selecting text across panes is unaffected).
- **Linear cycling**: `Alt+Tab` / `Alt+Shift+Tab` or `Cmd+]` / `Cmd+[`. **Directional and cycling focus from the keyboard only search the tiling layer**; floating panes take focus by hover or click.
- **⌘ + left-drag (a tiled pane)**: while ⌘ is held a drag source floats above the pane; dropping on the left/right edge inserts a new column next to the target column, the top/bottom edge merges into the target column's stack, and the centre 40%×40% swaps. The dwindle equivalents are split-insert and swap.
- **⌘ + right-drag**: in scrolling it changes column width by the horizontal displacement; in dwindle it moves the nearest divider (magnitude 1–200).

### 4.4 Floating panes and the Scratchpad

- `Cmd+T`: the focused pane floats ⇄ drops back into the tiling. Default geometry when it floats (like Omarchy's `togglefloating`): **width = column width factor × 0.75 (clamped 0.15–1.0), height = 45% of the content area, centred**. Dropping back: scrolling appends it as a new column to the right of the last one; dwindle inserts it at the first leaf.
- The rect is normalized (0–1, top-left) and scales with the window; `clamped()` clamps the size to 0.15–1.0 and allows the position to hang at most halfway off the left, right and bottom edges, but never past the top.
- Array order is z order (last is topmost); ⌘+left-press raises it first, then moves it freely; ⌘+right-drag resizes. Pointer hit-testing falls back to a top-down search in z order.
- A floating pane **does not register as a drop target** (which would light up drop zones that cannot work); when inactive it gets **no frosted backing** (what is behind it is another pane, and the blur would smear it into a solid block); it does get a shadow.
- `Cmd+Shift+digit` moves it to the target workspace with its floating state intact. State v3 persists the floating layer and can still read v2.
- **Scratchpad** (`Cmd+S`): a single global surface (created on first use, inheriting the current cwd), centred at 70%×60% of the content area, 2px accent border, with a 0.2 black scrim that closes it on click; **not persisted**.

### 4.5 Workspaces

5 by default (config 1–10; above 5 it automatically adds `Cmd+6…9,0` and the `Cmd+Shift+…` equivalents); `Cmd+digit` switches (instantly), `Cmd+Shift+digit` moves the focused pane and follows it; the scroll wheel over the status bar cycles, and clicking a pill jumps straight there; shrinking the count never drops a workspace that has content; every workspace has its own layout type and floating layer; the window only closes when every workspace (floating layer included) is empty.

### 4.6 Status bar (waybar-style, 26pt)

| Area | Contents | Interaction |
|---|---|---|
| Left | `◆` + workspace pills 1–N (active = `■` in the accent colour; empty = 50% transparent) | click a pill to switch; the scroll wheel anywhere over the bar cycles workspaces |
| Middle | clock `Sunday 14:32` (refreshed every 30s) | click to switch to `31 August W36 2026` |
| Right | CPU%, network (wifi / wired / offline), volume, battery (charging shows as an icon only; ≤20% and not charging turns red) | click the volume icon to mute/unmute |
| The whole strip | Monaco 12, monochrome SF Symbols, square corners, **0.75 translucent** (`bar-opacity`, subject to the `Cmd+Backspace` master switch) | double-click empty space to zoom the window; `Cmd+Shift+Space` shows/hides |

Not implemented (the original design listed them): clicking the logo to open the main menu, clicking CPU to pop up top/btop, clicking the battery for a notification.

### 4.7 Panels (Walker style, four in one `OverlayPanelView`)

Uniform look: centred, 420pt wide (560 for the cheat sheet), 0.95 background, 2px square accent border, Monaco 15; behind it a 0.25 black scrim that closes on click. Keyboard: ↑↓ to select, ↩ to confirm, ⎋ to close (while a panel is open these are taken first, and modifier keys are ignored).

- **Theme picker** (`Cmd+Ctrl+Shift+Space`): name + a light marker + an 8-colour swatch; opens positioned on the current theme; selecting switches live.
- **Background picker** (`Cmd+Ctrl+Space`): a **fixed 3-column** thumbnail grid (76pt tall, scrollable); ↑↓ move by a row (±3), ←→ by ±1; the last entry, "**Choose image…**", imports through NSOpenPanel (§4.8). **Pressing the same key again while the panel is open = next background** (wrapping).
- **Keybinding cheat sheet** (`Cmd+K`): generated live from the map currently in effect (user overrides included), rendered with symbols.
- **Main menu** (`Cmd+Alt+Space`), 10 flat entries: New terminal / Themes… / Backgrounds… / Columns per screen (Return cycles 2→3→4 in place, the panel stays open) / Show or hide the status bar / Gaps toggle / Opacity toggle / Keybinding cheat sheet / Settings / About. **No hierarchy, no search field, no Font entry.**

### 4.8 Themes and backgrounds

- Theme packages have the same shape as Omarchy's: `<name>/{colors.toml, backgrounds/*}`. **22** are built in (`Themes/`, kept in sync with upstream in full by `scripts/fetch-themes.sh`; colors.toml is in git, **background images are not** — they are baked into the bundle at build time); a same-named theme in the user directory `~/.config/quickterm/themes/` wins. Default tokyo-night.
- Switching: rewrite the overlay (colours / palette 0–15 / cursor / selection) → live engine reload + a UI palette refresh; a light theme also drives the system appearance. `theme = "ghostty"` means QuickTerm does not take over the colours (padding is still injected; while the master opacity switch is off the opaque override is still injected too, see §4.10).
- **Background candidates = the current theme's own + the user directory `~/.config/quickterm/backgrounds/` (flat, shared by every theme; png/jpg/jpeg/webp/heic/gif/tiff)**, sharing one index (persisted in UserDefaults, reset to 0 when the theme changes). "Choose image…" copies the file into the user directory (adding a timestamp on a name clash) and selects it immediately. Changing the background does not reload the engine.

### 4.9 Opacity, frosted blur and spacing

| Value | Key | Default | Mechanism |
|---|---|---|---|
| pane baseline | `pane-opacity` | 0.92 | injected as the engine's `background-opacity` (every pane) |
| active pane | `active-opacity` | 0.98 | pure UI: the theme's background colour is laid behind the active pane with alpha = `(active − pane) / (1 − pane)`, no engine reload |
| inactive dimming | — (hard-coded) | 0.96 | the engine's `unfocused-split-opacity` |
| status bar | `bar-opacity` | 0.75 | pure UI |
| pane spacing | `pane-gap` | 5 | pure UI; pt of space on each edge of each pane, identical for scrolling / dwindle / floating (between panes = 2×gap = 10pt; dwindle's 1pt divider is drawn on the boundary and takes no layout space); the outer ring uses the same value; the old key `dwindle-gap` is an alias |
| Browser home / search / UA / Inspector | `browser-home` / `browser-search` / `browser-user-agent` / `browser-inspectable` | google / google search / safari / false | browser-pane behaviour; the UA is `safari` (spoofed) / `webkit` (not spoofed) / a custom string |
| Browser extensions | `browser-extensions` | true | browser panes load WebExtensions (`WKWebExtension`, macOS 15.4+): Web Store pages get an "Add to QuickTerm" injection, and the puzzle menu can import from the local Chrome / enable and disable / remove; false unloads everything and never attaches the controller |
| Browser download directory | `browser-download-dir` | ~/Downloads | where browser-pane downloads land (`~` is expanded; anything that is not an existing directory falls back to `~/Downloads`); the download progress ring sits at the right of the address bar, and the popover it opens can cancel / show in Finder / remove / clear completed |
| Where links open | `link-opener` | browser-pane | for http(s) links ⌘-clicked in a terminal: browser-pane opens a new tab in the most recently activated browser pane of the current workspace (the one that took focus or was last sent a link), or opens a new one if there is none; system hands it to the default browser. mailto/ssh/file paths always go to the system |
| File manager command | `file-manager-command` | yazi | the program the `file-manager` action runs: a bare name is looked up on PATH plus the usual Homebrew/cargo directories, or give an absolute path; yazi/lf/ranger write their last directory out on exit (--cwd-file / -last-dir-path / --choosedir) |
| dwindle divider | `divider-opacity` | 0.2 | pure UI; SplitView's 1pt hairline divider (coloured by the engine's split-divider-color) is drawn at this opacity, subject to the master switch (switched off = a solid line) |
| Inactive frosted blur | `inactive-blur` | 2.5 | an `NSVisualEffectView(.hudWindow, .withinWindow)` backdrop — what gets blurred is the wallpaper, the text stays sharp. **The number currently acts only as a switch (> 0 enables it)**, it is not used as a radius |

The `Cmd+Backspace` master switch: panes go to engine 1.0 / 1.0, the status bar becomes opaque, the blur is turned off. `Cmd+Shift+Backspace` toggles gaps (pure UI). Borders are 2px (accent / grey), square, and `pane-padding` is 14pt (0–32, injected as `window-padding-x/y`).

### 4.10 The config file and the engine config chain

`~/.config/quickterm/config.toml`, watched at directory level (which catches an editor's atomic replace), 0.2s debounce, reloaded only when the contents actually changed. `Cmd+,` opens it (writing the template first if it does not exist; if `~/.config/ghostty/config` exists, that is opened as well).

```toml
# theme = "tokyo-night"     # or "ghostty": do not override the colours, follow the ghostty config entirely
# workspaces = 5            # 1–10
# pane-padding = 14         # 0–32
# visible-columns = 2       # 1–6; unset falls back to the main menu / UserDefaults
# pane-opacity = 0.92       # 0.5–1.0
# active-opacity = 0.98     # 0.5–1.0
# bar-opacity = 0.75        # 0–1
# divider-opacity = 0.2     # 0–1, the dwindle hairline divider
# pane-gap = 5              # 0–20 pt, space on each edge of each pane (same for scrolling and dwindle)
# file-manager-command = "yazi"   # the program the file-manager action runs
# link-opener = "browser-pane"    # ⌘+click on a terminal link: browser-pane | system
# browser-home = "https://www.google.com"
# browser-search = "https://www.google.com/search?q=%s"
# browser-user-agent = "safari"
# browser-inspectable = false
# browser-tab-bar = "auto"
# browser-extensions = true       # browser panes load WebExtensions (macOS 15.4+)
# browser-download-dir = "~/Downloads"   # where browser-pane downloads land
# inactive-blur = 2.5       # > 0 enables the frosted blur

[keybinds]                  # values are "modifier+key"; "none" unbinds; the action list is the Cmd+K cheat sheet
# new-terminal = "cmd+return"

[ghostty]                   # any ghostty option, passed through verbatim, highest priority
# cursor-style = block
```

**Moved since 1.5.9**: the template above is flat, but the file is now generated from one registry (`Sources/Config/ConfigSchema.swift`) that groups every key under `[appearance]` / `[workspace]` / `[terminal]` / `[browser]` / `[control]` (plus the unchanged `[keybinds]` and `[ghostty]`). Every key that already existed keeps its old top-level spelling as a legacy alias, so an existing config parses unchanged and nothing here needs rewriting.

Parsing semantics: minimal TOML — top-level keys must come before any section header; blank lines and `#` lines are not passed through; a value starting with `"` runs to the next `"`; a number that fails to parse silently keeps the default; unknown sections are ignored. In `[keybinds]`: the key must be a `WMAction` id; modifier aliases are `cmd|command|super` / `shift` / `alt|option|opt` / `ctrl|control`; one action gets one combo (an override removes all of that action's default combos); **there is no conflict detection** (on a collision, the writer wins).

**The engine config chain (low → high)**: (1) libghostty's built-in defaults → (1½) the app's built-in fallback `Resources/ghostty-default.conf` (Monaco 15, Builtin Pastel Dark, copy-on-select, 100M scrollback and so on; loaded **only if** the user has no ghostty config file at all — the XDG `ghostty/config.ghostty`/`config` and the same names under `~/Library/Application Support/com.mitchellh.ghostty/` — re-decided on every reload; relative to the original config the user gave us it drops `shell-integration = none` and the tab keybindings, see the comment at the top of the file) → (2) the user's ghostty config files (**QuickTerm loads the files that exist and are non-empty itself, in libghostty's `loadDefaultFiles` order**, rather than calling `ghostty_config_load_default_files` — with no config present, 1.3.1 writes an unflushed 0-byte template to `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`; `config-file` recursive includes still work as usual) → (3) QuickTerm's overlay file `~/Library/Application Support/QuickTerm/engine-overlay.conf` (generated by `ThemeManager.overlayExtra()`: `window-vsync = false`, `window-padding-x/y`, `background-opacity`, `unfocused-split-opacity`, colours and palette) → (4) the `[ghostty]` section (physically appended to the end of (3)). With `theme = "ghostty"`, (3) only injects the padding and (when opacity is switched off) the opaque override. `~/.config/ghostty/config` is not watched, so after editing it you need to restart or trigger an overlay rewrite. **Note**: the engine processes `config-file` recursive includes after the overlay, so keys written inside an included file override layers 3 and 4.

### 4.11 State restoration

On quit, `state.json` is written (v5 since 1.5.6; v3 in the original design): for each window, the per-workspace layout and type, the floating layer, the active workspace, each pane's cwd, plus the display and frame the window was on; at launch shells reopen on their saved cwd. Theme / background index / columns per screen live in UserDefaults and are saved immediately. The Scratchpad is not restored. A corrupt or too-old archive → start fresh.

### 4.12 Fonts and icons

- UI font is Monaco (status bar 12, panels 15 / 13 / 11); icons are SF Symbols.
- **QuickTerm does not set the terminal font** (the overlay injects neither `font-family` nor `font-size`) — it is left entirely to layers 1–2 of the engine chain.
- The app icon is generated programmatically (`scripts/make-icon.swift` → `make-icon.sh` → `Resources/AppIcon.icns`): an Apple-style single glyph (a round-capped ❯ plus a capsule cursor), Tokyo Night gradient with a rim light / spherical highlight / bottom bounce light / drop shadow.

### 4.13 Known limitations (recorded honestly)

- The `inactive-blur` number is only a switch; the inactive border colour does not follow the theme; there is no keybinding conflict detection; a parse failure raises no UI warning; keyboard focus navigation does not reach floating panes; `~/.config/ghostty/config` is not watched live; after a ⌘ drag-and-drop swap the viewport makes one intermediate scroll of about 50ms (the final position is correct).

---

## 5. Keybinding map (Omarchy → QuickTerm)

The principle: **translate Super→Cmd literally wherever possible**; where that collides with a macOS rule, deviate with a reason. Everything can be rebound in `[keybinds]`. The default table holds 59 combos.

### Terminals / panes / layout

| Omarchy | QuickTerm | Action id | What it does |
|---|---|---|---|
| Super+Return | `Cmd+Return` | `new-terminal` | New pane (scrolling inserts a column to the right / dwindle splits, inheriting the cwd) |
| Super+W | `Cmd+W` | `close-pane` | Close the focused pane (a second confirmation if a process is running; after the last pane is closed the window stays up and shows a "new terminal" hint rather than quitting the app). Where the focus goes: scrolling = the left neighbour (otherwise right/up/down); dwindle = the nearest pane in the sibling subtree that takes over the space (a left/up child → the sibling's first leaf, i.e. "the next one"; a right/down child → the sibling's last leaf, i.e. "the previous one" — Hyprland semantics). The animation (symmetrical with creation, 0.28s): the closing pane fades out, under dwindle its slot collapses and the sibling subtree grows smoothly into it; during the animation the pane is still in the layout (focus has already been handed over, and hovering it does not steal focus), and only when it finishes is it really removed; any layout operation, workspace switch or save first removes a fading pane immediately; with "Reduce motion" on it is removed straight away |
| Super+←→↑↓ | `Cmd+←→↑↓` | `focus-*` | Directional focus |
| Super+Shift+←→↑↓ | `Cmd+Shift+←→↑↓` | `swap-*` | Swap (the viewport follows automatically) |
| Super+J | `Cmd+J` | `toggle-split-dir` | scrolling: merge into ⇄ split out of a column / dwindle: flip the split direction |
| Super+F | `Cmd+F` | `toggle-zoom` | Pane zoom |
| Super+L | `Cmd+L` | `toggle-layout` | scrolling ⇄ dwindle |
| Super+T | `Cmd+T` | `toggle-float` | Floating ⇄ tiled. ⌘+left-click: hit-tested against the floating pane's rect (spacing included) — the middle moves it and raises it, a 14pt band along each edge scales along that axis, the corners scale on both axes with the opposite edge pinned, minimum 0.15; ⌘-hover shows the grab / frameResize cursor and reverts when ⌘ is released or the pointer leaves; ⌘+right-drag anywhere resizes from the bottom-right corner (Hyprland) |
| Super+B | `Cmd+B` | `new-browser` | Browser pane: WKWebView + a thin toolbar (back/forward/reload, address bar, progress), with multiple tabs per pane; keyboard focus lives in the WKWebView (PaneView.focusTarget), and the pane counts as focused whenever the first responder is one of its descendants; WM-level Cmd keys are still caught by the monitor first; the `web-*` actions (back Cmd+Shift+[, forward Cmd+Shift+], reload Cmd+R, address bar Cmd+Shift+L, zoom Cmd+= / - / 0, open externally Cmd+Shift+O) are only consumed when the focus is a browser pane, otherwise they pass through to the terminal. Logins live in WebKit's default data store (shared across panes and across restarts); the UA spoofs Safari by default (for Google sign-in). **Multiple tabs**: one WKWebView per tab, plus a tab bar (`browser-tab-bar` always — the default — keeps it visible, auto hides it when there is a single tab; `+` at the right end opens a new tab; trapezoid tabs, the current tab is the same colour as the toolbar and sits flush against it, inactive tabs reveal a close button on hover, widths are divided evenly between `browser-tab-width` and `browser-tab-min-width`, and the bar scrolls horizontally when they no longer fit), `web-new-tab` Cmd+N, `web-next/prev-tab` Ctrl+Tab / Ctrl+Shift+Tab, Cmd+W closes the current tab while there are several and closes the pane on the last one, ⌘+click opens a link in a background tab, `window.open`/target=_blank create a real tab using the configuration WebKit hands us (so opener/postMessage work), and window.close closes the tab; the archive stores tabs + activeTab (the old single-page format still decodes). **Downloads**: a progress ring at the right of the address bar (aggregated across downloads; an indeterminate total spins an arc; a checkmark when everything finished, an exclamation mark when only failures remain), clicking expands a list to cancel / show in Finder / remove / clear completed; the directory is `browser-download-dir`; the list belongs to the pane, and closing the pane cancels downloads in flight. **Extensions** (`browser-extensions`, macOS 15.4+): `WKWebExtension` runs Chrome / Firefox extensions, with the pane as the window and tabs as tabs in the extension's eyes; extension buttons (icon + badge + popup) sit at the right of the address bar next to the puzzle menu (`web-extensions` = Cmd+Shift+E: open / pin to the toolbar / enable and disable / options page / remove / import from the local Chrome / open the store and the extensions folder). **Pinning to the toolbar** (Chrome semantics): only pinned extensions get a toolbar button, the rest live in the puzzle menu; a store install is pinned by default, and a Chrome import follows `extensions.pinned_extensions` from `<profile>/Preferences`; the address bar keeps a floor of 200pt and the extension bar keeps at least the puzzle button (priorities 300 / 310, both below the 500 SwiftUI measures the width at, so the pane width is unaffected; on a narrower pane the address bar keeps giving way), a squeezed toolbar lays out only the buttons that fit, left to right, with the puzzle always last and flush right; Web Store detail pages get an injected "Add to QuickTerm" button; extensions are installed into `~/Library/Application Support/QuickTerm/Extensions/`. Limits: no Widevine, no system password autofill, passkeys unavailable; on the extension side there is no blocking webRequest, and no identity / history / downloads / management / proxy / debugger / native messaging, and storage.sync does not sync across devices |
| Super+Shift+F | `Cmd+Shift+B` | `file-manager` | Run a TUI file manager in a new pane (yazi by default, changeable with `file-manager-command`; started in the focused pane's directory; if the directory changed on exit, a terminal opens in place — the semantics of yazi's `y` wrapper function; closing it skips the running-process confirmation; a missing program opens a pane explaining that). Cmd+F is already toggle-zoom, hence Cmd+Shift+B |
| — | `Cmd+Shift+K` | `clear-terminal` | Clear the screen and the scrollback: calls the engine's `clear_screen` on the focused terminal surface; only consumed when the focus is a terminal pane (terminalOnly), browser and other panes pass it through ※ deviation 2 |
| Super+‑/= | `Cmd+Ctrl+←→↑↓` | `resize-*` | Resize (+Shift for fine steps) ※ deviation 1 |
| — | `Cmd+Ctrl+=` | `equalize` | Equalize everything / reset column widths |
| Alt+Tab / +Shift | `Alt+Tab` / `+Shift`, `Cmd+]` / `Cmd+[` | `cycle-pane-next/prev` | Linear cycling |
| — | `Ctrl+Cmd+F` / `Cmd+Esc` | `toggle-fullscreen` / `exit-fullscreen` | Non-native fullscreen / exit |

### Workspaces

| Omarchy | QuickTerm | Action id |
|---|---|---|
| Super+1…5 | `Cmd+1…5` (above 5, `Cmd+6…9,0`) | `goto-workspace-N` |
| Super+Shift+1…5 | `Cmd+Shift+1…5` | `move-to-workspace-N` |
| Super+S | `Cmd+S` | `scratchpad` |
| Super+scroll wheel | scroll wheel over the status bar / click a pill | — (hard-coded) |

### Themes / appearance / panels

| Omarchy | QuickTerm | Action id |
|---|---|---|
| Super+Ctrl+Shift+Space | `Cmd+Ctrl+Shift+Space` | `theme-picker` |
| Super+Ctrl+Space | `Cmd+Ctrl+Space` (first press opens the panel, pressing again while it is open = next background) | `next-background` |
| Super+Shift+Space | `Cmd+Shift+Space` | `toggle-bar` |
| Super+Backspace | `Cmd+Backspace` | `toggle-opacity` |
| Super+Shift+Backspace | `Cmd+Shift+Backspace` | `toggle-gaps` |
| Super+Alt+Space | `Cmd+Alt+Space` | `main-menu` |
| Super+K | `Cmd+K` | `keybind-help` ※ deviation 2 |
| — | `Cmd+,` | `open-settings` |

### Mouse gestures (hard-coded)

Hover to focus; ⌘+left-drag (tiled = drag and drop, floating = move and raise); ⌘+right-drag to resize; ⌘+click on a terminal link → the engine's open_url goes to the window controller first (`link-opener` = browser-pane: http(s) opens a new tab in the most recently activated browser pane of the current workspace and focuses it, or opens a new pane next to the terminal if there is none; system, and any other scheme, goes to the system's default app); the scroll wheel over the status bar switches workspaces; a two-finger horizontal swipe in the content area pans the canvas; double-clicking the status bar zooms the window; clicking the clock changes its format; clicking the volume icon mutes; dwindle dividers drag and double-click to equalize; clicking a panel's scrim closes it.

**Why the deviations**: 1) `Cmd+-/=` is an unbreakable macOS terminal convention for font size, so resize moved to `Cmd+Ctrl+arrow`; 2) `Cmd+K` belongs to QuickTerm's cheat sheet, so clear-screen moved to `Cmd+Shift+K` (the WM action `clear-terminal`, which calls the engine's `clear_screen` on the focused terminal; **QuickTerm still injects no keybind into ghostty** — set other terminal-level keys yourself with `keybind =` in the ghostty config).

**Quit semantics** (2026-09-04): `Cmd+Q`, quitting from the menu and the engine's quit action all go through `applicationShouldTerminate` — if any pane is still open (floating panes and the Scratchpad included) it asks for confirmation (quit / cancel), and with none open it quits straight away; state is saved before quitting.

**System behaviour we leave alone**: `Cmd+C/V`, `Cmd++/-/0`, `Cmd+Q/M/H`. Tests pin down that `Cmd+C/V/-`, a bare `Esc`, `Cmd+Q` and any undefined combination are all passed through.

**Fallback keybindings never implemented**: `Cmd+G` pane grouping, `Cmd+O` pop out into a separate window, `Cmd+Ctrl+V` clipboard history, a global hotkey drop-down terminal.

---

## 6. Engineering and build

### 6.1 Directory layout (as it actually is)

```
quickterm/
├─ project.yml            # XcodeGen source; QuickTerm.xcodeproj is generated (gitignored)
├─ Sources/
│  ├─ App/                # main, AppDelegate(+Ghostty, +Screens, +ControlCLI) (test isolation), MainMenu, Info.plist
│  ├─ Windowing/          # HiddenTitlebarWindow, MainWindowController, RootView(WorkspaceModel), WorkspaceLayout,
│  │                      # FloatingPane, HoverOcclusion, AppSession, ScreenRegistry, SessionState
│  ├─ Splits/             # ScrollingStrip(+View), PaneChrome, PaneTitleBadge, SplitTree+QuickTerm
│  ├─ Panes/              # PaneView, PaneContentView, BrowserPaneView(+TabBar/Downloads/Extensions)
│  ├─ Control/            # the control socket, command table, Commands/, Spec/, Wire/ (Wire is shared with the CLI target)
│  ├─ GhosttyEmbed/       # ported from Ghostty macos/Sources/Ghostty (MIT): SurfaceView, SplitTree, Config, Shims…
│  ├─ StatusBar/          # StatusBarView, SystemStatsService, WorkspacePill
│  ├─ Theming/            # ThemeManager, Theme, VisualEffectBlur, Palette (fallback colours)
│  ├─ Palette/            # OverlayPanel (the four-in-one panel)
│  ├─ Localization/       # Localization.swift (the bilingual UI catalogue)
│  └─ Config/             # ConfigStore(+ConfigWatcher), ConfigSchema, KeybindingMap, WMAction, EngineOverlay, ModifierState
├─ CLI/                   # the `quickterm` binary, its own target (the app target compiles all of Sources/)
├─ Tests/                 # 39 files, 614 cases (XCTest, TEST_HOST = app)
├─ Themes/                # colors.toml for 22 themes (in git) + backgrounds/ (not in git)
├─ Resources/AppIcon.icns
├─ vendor/ghostty         # submodule, pinned to v1.3.1
├─ scripts/               # build-ghosttykit.sh, fetch-zig-deps.sh, fetch-themes.sh, make-icon.sh/.swift
- Universal binary: `GHOSTTYKIT_TARGET=universal scripts/build-ghosttykit.sh` (arm64 + x86_64, required for a release DMG; the archive fix is applied per architecture and then lipo'd — see "Universal binary build" in porting-notes); development defaults to `native`.
└─ docs/                  # this document, porting-notes.md, acceptance/, agents/, superpowers/plans/
```

### 6.2 The GhosttyKit build pipeline

1. The submodule is pinned to `v1.3.1`; the exact Zig version from `build.zig.zon`'s `minimum_zig_version` is installed automatically into `.tools/`
2. `zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native` → `vendor/ghostty/macos/GhosttyKit.xcframework` (not in git)
3. `xcodegen generate` → `xcodebuild`; Ghostty's resources (terminfo, shell-integration) are copied into the bundle in a postBuild step
4. **Environment fixes now baked in** (details in `docs/porting-notes.md`): Zig's own network client ignores proxies → `fetch-zig-deps.sh` prefetches offline; the Xcode 26 SDK's `libSystem.tbd` is missing arm64 → the script applies an SDK overlay plus an xcrun shim; libtool drops members of Zig's archives → a Python step repacks a fat archive taking the newest member per archive name; the macOS 26 CVDisplayLink session quota → the overlay injects `window-vsync = false`
5. No build-product cache check: the script runs `zig build` every time (incrementality comes from Zig's own cache); only the Zig toolchain download and the SDK overlay are skipped when already present. Behind a proxy: let the script install Zig first, then run `fetch-zig-deps.sh`, then re-run the script

Deployment target macOS 15.4+ (raised from 15.0 when WKWebExtension landed in 1.5.4); developed and verified on macOS 26 / Xcode 26.6.

### 6.3 Test strategy (what is actually covered)

39 files, 614 cases. `ScrollingStripTests` (geometry: fill / overflow / minimal scroll / signature), `WorkspaceTests` (workspaces, floating clamp and default rect, occlusion geometry, the flipped-coordinate regression, state round trip), `ConfigStoreTests` / `ConfigSchemaTests` (parsing and clamping every key, overlay contents), `SplitTreeQuickTermTests`, `ThemeTests` (discovery, scanning the backgrounds directory), `KeybindingMapTests` (every default binding, Shift fine steps, pass-through, key-name normalization; override and unbind merging live in `ConfigStoreTests`), `MainWindowControllerTests`, `EngineSmokeTests`, plus the browser (`BrowserPaneTests`, `BrowserDownloadTests`, `BrowserExtensionTests`, `BrowserExtensionCompatTests`), multi-screen (`ScreenRegistryTests`, `SessionStateTests`, `AppSessionTests`) and control-plane (`Control*Tests`, `MCPToolMapTests`) suites. The manual acceptance checklists are in `docs/acceptance/`.

### 6.4 Risks and mitigations

| Risk | Mitigation |
|---|---|
| libghostty's internal API promises no stability | pin the tag and the matching Zig version; treat an upgrade as its own porting project; mark QuickTerm's changes with a `// QuickTerm:` comment so rebasing stays possible |
| A complicated build chain | one fully automated script + porting-notes recording every environment trap |
| IME / CJK input | port Ghostty's `NSTextInputClient` implementation instead of writing our own |
| Keybindings colliding with user habits | everything is rebindable + the `Cmd+K` cheat sheet |
| Copyright on background images | the upstream Omarchy repo is MIT; images are fetched at build time and never enter this repo's git |

---

## 7. Delivery timeline

| Version / tag | Contents |
|---|---|
| m0 | engine running: scaffold, GhosttyKit build, a single surface, the four-layer config chain, IME |
| m1 | the dwindle tiling core, ⌘drag, focus follows mouse, hidden titlebar, the WM key framework |
| m2 | 5 workspaces, the waybar status bar, scroll-wheel switching |
| m3 | 22 themes with live switching, the wallpaper layer, panels, the opacity/gaps toggles |
| m4 / v1.0 | main menu, cheat sheet, Scratchpad, config live reload, state restoration, fullscreen, the DisplayLink quota fix |
| v1.1 | the scrolling infinite canvas becomes the default (v5) |
| v1.2 | the `pane-padding` option + Omarchy's scrolling geometry |
| v1.3 | Hyprland gap semantics (10pt), fill mode, padding 14 (v6) |
| v1.3 → v1.4 (the "v8" state of this document) | visible-columns, Cmd+Esc, the icon, the blur/opacity system, floating panes (v7), pane-opacity 0.92 / bar-opacity 0.75, the occlusion test (hover/click/⌘drag), the viewport following a swap, background system 2.0, the Apple-style icon, the double-click-to-equalize fix (v8); release packaging script |
| v1.5 – v1.5.9 | universal binary (arm64 + x86_64); browser panes with multiple tabs and a trapezoid tab bar, the file-manager pane, drag-resizing floating panes (1.5.2); ⌘+click a link into a browser pane, Cmd+Shift+K clear (1.5.3); browser extensions via WKWebExtension, the download progress UI, pinning extensions to the toolbar, macOS 15.4+ (1.5.4); multiple "screens" + one-key restore (1.5.6); in-page embedded extension panels (1.5.7); ⌘-state self-healing (1.5.8); the control plane — the `quickterm` CLI + MCP (1.5.9) |

---

## 8. Decision points (confirmed, with what actually landed)

1. **Terminal engine**: option A, pinned to v1.3.1 ✅ (no protocol abstraction, the ported layer is used directly)
2. **`Cmd+Return`**: creates a pane ✅
3. **Keybinding deviations**: resize → `Cmd+Ctrl+arrow` ✅; `Cmd+K` goes to the cheat sheet ✅ (`Cmd+Shift+K` clear is **no longer injected** into ghostty — QuickTerm injects no terminal-level keybind; it is a WM action instead)
4. **Where backgrounds come from**: changed to fetching all of them from upstream at build time (2–9 per theme) + a user directory ✅
5. **Application shape**: a regular main window + an in-window Scratchpad ✅ (the drop-down global-hotkey terminal was never built)
6. **Minimum OS**: macOS 15+ ✅ (raised to 15.4+ in 1.5.4 for WKWebExtension)
7. **Config format**: TOML (minimal, parsed by hand) ✅
