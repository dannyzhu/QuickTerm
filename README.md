# QuickTerm

**An Omarchy-style tiling terminal for macOS, powered by libghostty.**

QuickTerm puts the feel of [Omarchy](https://omarchy.org)'s Hyprland desktop inside a single native macOS window — and fills it with terminals. Infinite horizontal scrolling layout, workspaces, floating panes, a waybar-style status bar, 22 Omarchy themes with wallpapers, and the same `Super` → `Cmd` keybindings. The terminal engine is [Ghostty](https://ghostty.org)'s own library (GhosttyKit, pinned to v1.3.1), so rendering, ligatures, and VT fidelity are identical to Ghostty itself.

[中文说明](README.zh-CN.md)

![Scrolling canvas: a full-height column on the left, a stacked column (htop over a CLI agent) on the right, and the next column peeking in at the right edge](docs/images/screenshot-01.png)

![Scrolled one column to the right — the focused pane wears the accent border, inactive panes turn frosted, and the previous column peeks in on the left](docs/images/screenshot-02.png)

---

## Highlights

- **Scrolling canvas by default** — each workspace is an endless horizontal strip of columns (Hyprland `scrolling` layout: two columns per screen by default, with a sliver of each neighbouring column peeking in at the edges). New terminals open to the right of the focused column; the viewport follows focus with minimal scrolling. Classic **dwindle** tiling is one `Cmd+L` away.
- **Hover to focus** — move the mouse over a pane and it's active. Border turns to the theme accent, keystrokes go straight in.
- **Floating panes** — `Cmd+T` lifts a pane out of the tiling; `⌘`+drag moves it, `⌘`+right-drag resizes it.
- **Five workspaces** — `Cmd+1…5` to switch, `Cmd+Shift+1…5` to move a pane along. Scroll the status bar to cycle.
- **waybar-style status bar** — workspaces, clock, CPU, network, volume, battery. 26pt, monochrome SF Symbols, translucent.
- **22 Omarchy themes** with all their wallpapers, hot-switched in under a frame; pick any image of your own as a background.
- **Glass** — panes at 0.92 opacity over a continuous wallpaper, active pane composites to 0.98, inactive tiled panes get a frosted backdrop (text stays sharp). One key toggles it all off.
- **Your Ghostty config just works** — fonts, cursor, scrollback, shell integration and terminal-level keybinds are read from `~/.config/ghostty/config`. QuickTerm only layers theme colours and padding on top.
- **Everything rebindable** — every window-manager action is a key in `config.toml`; `Cmd+K` shows the live cheat sheet.
- **Browser panes with extensions** — `Cmd+B` opens a tabbed WebKit browser pane; Chrome/Firefox WebExtensions install straight from the Chrome Web Store or import from your local Chrome (macOS 15.4+).
- **State restore** — layouts, floating panes, active workspace and each pane's working directory come back on launch.
- **Scriptable, agent-ready** — a Unix-socket control plane and a `quickterm` CLI: query state, compose a whole workspace from one JSON spec, long-poll for events, or mount it as an MCP server. Reads are free, mutations are visible and undoable, destructive ones ask you first (see [Control plane](#control-plane-cli-and-ai-agents)).

## Install

Pre-built DMGs are on the [Releases](https://github.com/dannyzhu/QuickTerm/releases) page (universal binary for Apple Silicon and Intel, macOS 15.4+).

1. Open the DMG and drag **QuickTerm** into **Applications**.
2. The app is ad-hoc signed and not notarized, so macOS blocks the first launch. Double-click it once and dismiss the "Apple could not verify…" dialog, then either:
   - open **System Settings → Privacy & Security**, scroll down to the QuickTerm entry and click **Open Anyway**, or
   - clear the quarantine flag from a terminal (no more dialogs after this):
     ```bash
     xattr -dr com.apple.quarantine /Applications/QuickTerm.app
     ```
3. Launch it again. The first window opens a shell in your home directory.

Optional: with the DMG and its `.sha256` file in the same folder, run `shasum -a 256 -c QuickTerm-<version>.dmg.sha256` to verify the download. To build your own DMG from source, follow [Build](#build) and then run `scripts/make-release.sh`.

## Build requirements

Only needed to build from source. The DMG from Releases runs on any Mac (Apple Silicon or Intel) with macOS 15.4+ and needs none of this.

- macOS 15.4 or later (developed on macOS 26 / Xcode 26.6, Apple Silicon)
- Xcode 26+ with the Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Zig is installed automatically into `.tools/` at the exact version Ghostty pins

## Build

```bash
git clone --recurse-submodules <this repo>
cd quickterm
scripts/build-ghosttykit.sh      # installs the pinned Zig into .tools/, then builds vendor/ghostty/macos/GhosttyKit.xcframework (10–30 min first time)
# GHOSTTYKIT_TARGET=universal scripts/build-ghosttykit.sh   # arm64 + x86_64 universal library (needed for release DMGs; ~2× build time)
scripts/fetch-themes.sh          # pulls Omarchy theme wallpapers (not in git, ~50 MB)
xcodegen generate
xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug build
```

Behind a proxy, Zig's dependency fetch inside `build-ghosttykit.sh` may fail with HTTP 400 — Zig's fetcher ignores system proxy settings. Run `scripts/fetch-zig-deps.sh` (it uses the Zig the build script just installed and seeds Zig's cache through curl), then re-run `scripts/build-ghosttykit.sh`.

Run the built app:

```bash
open "$(xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/QuickTerm.app"
```

Tests (59 cases, run inside the app as test host):

```bash
xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug test
```

## Using QuickTerm

### Layouts

**Scrolling** (default for every workspace). Columns are 49% of the viewport wide by default — that's "2 visible columns" (`0.98 / N`). When everything fits, columns scale up to fill the width (a single column is full-screen, two columns have equal gaps left/middle/right). When they don't, the viewport scrolls the minimum needed to keep the focused column fully visible. Change the number of visible columns from the main menu (cycles 2 → 3 → 4) or set `visible-columns` in config. Two-finger horizontal swipe pans the canvas; it snaps to a column edge on release.

`Cmd+J` merges a single-pane column into the column on its left (as a vertical stack) or splits the focused pane out of a multi-pane column into its own column.

**Dwindle** (`Cmd+L` toggles per workspace). Recursive binary splitting like Omarchy: the focused pane splits right if it's wider than tall, otherwise down. `Cmd+J` flips the last split direction. Drag dividers to resize; double-click a divider to equalise.

Switching layouts keeps every pane in order (columns become right-splits, stacks become down-splits).

### Floating panes and Scratchpad

`Cmd+T` floats the focused pane at 75% of the default column width × 45% of the content height, centred. Hold `⌘` and drag with the left button to move (it comes to the front), right button to resize. Press `Cmd+T` again to tile it back. Floating panes move between workspaces with `Cmd+Shift+N` and are saved with the layout.

`Cmd+S` opens the Scratchpad — one global terminal that overlays any workspace (70% × 60%, centred). Click outside to hide it.

### Screens (multiple windows)

A *screen* is a QuickTerm window with its own workspaces, status bar, floating layer and Scratchpad — put one on each display and they work independently. Everything lives in the **Window** menu (no keybindings, since you rarely need it):

| Item | What it does |
|---|---|
| 新建屏幕 / New screen | Opens a screen on the current display, inheriting the focused pane's directory |
| 在显示器上新建屏幕 ▸ | Same, on a display you pick (the submenu is rebuilt each time it opens, so hot-plugged and virtual displays show up) |
| 将此屏幕移到显示器 ▸ | Moves the current screen to another display (the window has no title bar to drag) |
| 在所有桌面显示 | Makes this screen appear on every Space |
| 关闭屏幕 | Closes it (asks first if processes are still running); closing the last one quits |

The session is restored on the next launch: every screen, on the display it was on, with its workspaces, layouts, floating panes, each terminal's directory and each browser pane's open tabs. State is written continuously (debounced), not only at quit, and the archive is `state.json` v5 — an older QuickTerm will refuse to read it, so the first launch of this version leaves a `state.pre-v5.json` copy beside it.

Two honest limits, both from macOS itself: **a window cannot be sent to a specific Space** (no public API — new screens open on the Space you are on, and Mission Control drags are remembered by macOS but not restorable by us), and non-native fullscreen hides the Dock and menu bar **on every display** while any screen is fullscreen, because `presentationOptions` is process-wide.

### Mouse

| Gesture | Effect |
|---|---|
| Hover | Focus follows the mouse |
| `⌘` + left-drag a tiled pane | Drop on a pane's centre to swap. Drop on an edge: in scrolling, insert a column beside it (left/right) or stack into it (top/bottom); in dwindle, split on that side |
| `⌘` + left-drag a floating pane | Move (raises to front) |
| `⌘` + right-drag | Resize: column width in scrolling, nearest divider in dwindle, the pane itself if floating |
| `⌘` + click a link in a terminal | Opens it in a browser pane — a new tab in the most recently focused browser pane of the workspace, or a new browser pane beside the terminal if there is none (`link-opener = "system"` restores the default browser) |
| Scroll wheel over the status bar | Cycle workspaces |
| Two-finger horizontal swipe | Pan the scrolling canvas. Over the **focused** browser pane the swipe goes to the page instead (horizontal scroll / back-forward gesture) |
| Double-click empty status bar | Zoom window to the visible screen area |
| Click clock / speaker / workspace pill | Toggle date format / mute / jump to workspace |

### Panels

All panels are centred, Walker-style: `↑`/`↓` to move, `Return` to choose, `Esc` or click outside to close.

- **Theme picker** (`Cmd+Ctrl+Shift+Space`) — name, a `light` tag on light themes, and an 8-colour swatch per theme.
- **Background picker** (`Cmd+Ctrl+Space`) — 3-column thumbnail grid; `←`/`→` move one, `↑`/`↓` move a row. Press the same key again while it's open to jump to the next background. The last tile, **Choose image…**, opens a file dialog; the image is copied to `~/.config/quickterm/backgrounds/` and applied immediately. Your own images stay available across all themes.
- **Keybinding cheat sheet** (`Cmd+K`) — generated from the live keymap, so it always reflects your overrides.
- **Main menu** (`Cmd+Alt+Space`) — New terminal · Themes · Backgrounds · Visible columns · Toggle bar · Toggle gaps · Toggle opacity · Keybindings · Settings · About.

### Transparency

| Setting | Default | What it does |
|---|---|---|
| `pane-opacity` | 0.92 | Terminal background opacity (engine `background-opacity`) |
| `active-opacity` | 0.98 | The focused pane is composited over a theme-coloured underlay up to this value |
| `bar-opacity` | 0.75 | Status bar background |
| `divider-opacity` | 0.2 | Opacity of the 1pt divider line between dwindle splits (1 = solid, 0 = hidden) |
| `pane-gap` | 5 | Padding around each pane in pt, same in scrolling and dwindle (neighbours are 2×gap apart; the dwindle divider line takes no space). `dwindle-gap` is still read as a legacy alias |
| `file-manager-command` | yazi | Program run by the `file-manager` action (a name looked up in PATH plus the usual Homebrew/cargo dirs, or an absolute path; `lf` and `ranger` work too). Install with `brew install yazi` |
| `browser-home` | https://www.google.com | Page a new browser pane opens |
| `browser-search` | https://www.google.com/search?q=%s | Search template used when the address bar input is not a URL (`%s` = query) |
| `browser-user-agent` | safari | `safari` masquerades as Safari (Google sign-in rejects embedded browsers), `webkit` sends the stock WebKit UA, or any custom string |
| `browser-inspectable` | false | Enable Web Inspector in browser panes |
| `browser-tab-bar` | always | `always` keeps the tab bar visible; `auto` hides it while a pane has a single tab. The strip ends in a `+` button that opens a new tab |
| `browser-tab-width` | 200 | Maximum tab width in pt (40–600); tabs share the strip equally below that |
| `link-opener` | browser-pane | Where `⌘`-clicked http(s) links in a terminal open: `browser-pane` opens a new tab in the workspace's most recently focused browser pane (or a new browser pane beside the terminal if there is none); `system` uses the default browser. Other schemes (mailto, ssh, file paths) always go to the system |
| `browser-tab-min-width` | 80 | Minimum tab width in pt (40–600); once every tab is at the minimum the strip scrolls sideways (mouse wheel; the active tab is always scrolled into view) |
| `browser-extensions` | true | Load WebExtensions in browser panes (see [Browser extensions](#browser-extensions)). `false` unloads them all and stops attaching the extension controller to new tabs |
| `browser-download-dir` | ~/Downloads | Where browser panes save downloads (`~` is expanded; falls back to `~/Downloads` when the path is not an existing directory). Progress shows right of the address bar — click the ring for the list (cancel, reveal in Finder, clear finished) |

Downloads land in `browser-download-dir` (`~/Downloads` by default): a progress ring appears right of the address bar while anything is downloading, and clicking it opens the list — cancel, reveal in Finder, remove a row, or clear the finished ones.
The list belongs to the pane: closing the pane cancels whatever is still downloading in it.

Browser pane limits: no Widevine DRM (Netflix/Spotify web) and no system password autofill or passkeys (use `Cmd+Shift+O` to finish such flows in the system browser).

| `inactive-blur` | 2.5 | `> 0` puts a frosted-glass backdrop behind inactive tiled panes (blurs the wallpaper, not the text; floating panes are exempt; the numeric value is currently on/off only) |

`Cmd+Backspace` turns all of it off at once (panes and bar go opaque); `Cmd+Shift+Backspace` toggles the gaps.

### Browser extensions

Browser panes run Chrome/Firefox WebExtensions through WebKit's `WKWebExtension` (macOS 15.4+). Set `browser-extensions = false` to turn the whole thing off.

- **Install from the Chrome Web Store** — open an extension's store page in a browser pane and click the **添加到 QuickTerm** button injected in the bottom-right corner. QuickTerm downloads the CRX, shows what the extension asks for, and installs it once you confirm.
- **Import from Chrome** — the puzzle-piece menu at the right end of the toolbar (`Cmd+Shift+E`) has *从 Chrome 导入已安装扩展…*: it copies the newest version of every extension in `~/Library/Application Support/Google/Chrome/Default/Extensions`, skipping themes, packaged apps and anything already installed.
- **Manage** — the same menu lists every installed extension (disabled ones marked *（已停用）*); its submenu opens the extension, pins it to the toolbar, enables/disables it, opens its options page, or removes it.
- **Pin to the toolbar** — as in Chrome, only *pinned* extensions get a button (badge included) left of the puzzle icon; everything else lives in the puzzle menu, where *打开* does the same thing as clicking the button. Web Store installs are pinned by default, imports keep whatever was pinned in Chrome, and the address bar keeps at least 200pt — pinned extensions that no longer fit are hidden from the toolbar and stay reachable from the menu. In a pane too narrow even for that, the address bar keeps giving way instead: the puzzle button is always visible and clickable.
- **Popups and context menus** — clicking an extension's button opens its popup, and page context menus gain the extension's own items.
- **Where things live** — `~/Library/Application Support/QuickTerm/Extensions/<id>/`, with `state.json` holding the enabled and pinned flags. Extensions share cookies and login state with your tabs.
- **Compatibility shim** — on install (and once, on the next launch, for extensions installed earlier) QuickTerm rewrites the extension's `background` entry so `__quickterm-compat.js` runs first. It adds no-op `webNavigation.onHistoryStateUpdated` / `onReferenceFragmentUpdated` events (missing in WebKit; Stylish's background threw on them and never started) and makes `importScripts()` skip empty files (WebKit drains the microtask queue after every imported script, which flipped Tampermonkey's startup flag and left its popup spinning forever). It also rewrites the literal `chrome-extension:` to `webkit-extension:` in the extension's `.js` / `.mjs` files, since WebKit serves extension pages from `webkit-extension://` and Chrome builds that hard-code the scheme otherwise treat their own popup as a foreign page (Tampermonkey's background refused every popup request). Extension pages embedded in ordinary web pages (Stylish's side panel is a `webkit-extension://` iframe) run in the page's process, and WebKit kills that process if they call `tabs`, `windows`, `action`, `scripting`, `alarms`, `contextMenus` or `cookies` directly, so every namespace except `runtime`, `storage`, `i18n` and `permissions` is replaced there by proxies that relay each call through the extension's background (extensions without a background script get proxies whose calls fail instead of crashing). Sites that hand data to an extension through Chrome's `externally_connectable` channel (userstyles.org signs you into Stylish that way) call `chrome.runtime.sendMessage(<extension id>, …)`; WebKit implements that channel but exposes it to pages only as `browser.runtime`, so pages whose URL matches an installed extension's `externally_connectable.matches` also get a minimal `chrome.runtime` alias (`sendMessage` / `connect` and nothing else) — never on other sites, and never over a `chrome` object the page already has. The original entry is kept under `__quickterm` in the manifest; updates regenerate the shim.
- **Scope** — WebKit implements roughly 25 WebExtension API namespaces. Not supported: blocking `webRequest` (use `declarativeNetRequest`), `identity`, `history`, `downloads`, `management`, `proxy`, `debugger` and native messaging; `storage.sync` is local, not synced across devices. Permissions listed in the manifest are granted at install time; anything an extension asks for later raises a confirmation dialog.

## Default keybindings

Every action below can be rebound in `config.toml` (see [Configuration](#configuration)). Keys not in this table are passed straight to the terminal — `Cmd+C`/`Cmd+V`, font-size keys, `Cmd+Q` etc. are untouched. `Cmd+Q` asks for confirmation while any pane is open and quits immediately when there are none.

| Key | Action id | What it does |
|---|---|---|
| `Cmd+Return` | `new-terminal` | New terminal (right of the focused column / dwindle split), inherits cwd |
| `Cmd+W` | `close-pane` | Close focused pane (confirms if a process is running). Closing the last pane keeps the window open with a hint; the app does not quit |
| `Cmd+←↑↓→` | `focus-*` | Move focus |
| `Cmd+Shift+←↑↓→` | `swap-*` | Swap pane / column; viewport follows |
| `Cmd+J` | `toggle-split-dir` | Merge/split column (scrolling) · flip split (dwindle) |
| `Cmd+F` | `toggle-zoom` | Zoom pane to fill the content area |
| `Cmd+Ctrl+←↑↓→` | `resize-*` | Resize — column width in scrolling (left/right only), all four directions in dwindle; `Shift` gives fine steps in dwindle |
| `Cmd+Ctrl+=` | `equalize` | Equalise all / reset column widths |
| `Alt+Tab` / `Alt+Shift+Tab`, `Cmd+]` / `Cmd+[` | `cycle-pane-next` / `-prev` | Cycle panes |
| `Cmd+L` | `toggle-layout` | Scrolling ⇄ dwindle |
| `Cmd+T` | `toggle-float` | Float ⇄ tile. With ⌘ held: drag the middle to move, drag an edge to resize on that axis, drag a corner to resize both (opposite side stays put); the cursor shows what will happen. ⌘+right-drag resizes from the bottom-right corner |
| `Cmd+S` | `scratchpad` | Scratchpad terminal |
| `Cmd+Shift+B` | `file-manager` | File manager ([yazi](https://github.com/sxyazi/yazi)) in a new pane, starting in the focused pane's directory; quitting in another directory opens a terminal there |
| `Cmd+B` | `new-browser` | Browser pane (WebKit) opening `browser-home` |
| `Cmd+Shift+K` | `clear-terminal` | Terminal pane only: clear the screen and scrollback (ghostty's `clear_screen`; `Cmd+K` is taken by the cheat sheet) |
| `Cmd+Shift+L` / `Cmd+R` | `web-focus-address` / `web-reload` | Browser pane only: address bar / reload (other panes pass these keys through) |
| `Cmd+Shift+[` / `Cmd+Shift+]` | `web-back` / `web-forward` | Browser pane only: history navigation |
| `Cmd+=` / `Cmd+-` / `Cmd+0` | `web-zoom-in` / `web-zoom-out` / `web-zoom-reset` | Browser pane only: page zoom (terminal font size keys are untouched) |
| `Cmd+Shift+O` | `web-open-external` | Browser pane only: open the current page in the system browser |
| `Cmd+N` / `Ctrl+Tab` / `Ctrl+Shift+Tab` | `web-new-tab` / `web-next-tab` / `web-prev-tab` | Browser pane only: tabs. `Cmd+W` closes the current tab (the last tab closes the pane); ⌘-click a link for a background tab; `window.open` opens a tab |
| `Cmd+Shift+E` | `web-extensions` | Browser pane only: the extensions menu (install, enable/disable, import from Chrome) |
| `Cmd+1…5` | `goto-workspace-N` | Switch workspace (`Cmd+6…9,0` when `workspaces > 5`) |
| `Cmd+Shift+1…5` | `move-to-workspace-N` | Move pane to workspace and follow |
| `Cmd+Shift+Space` | `toggle-bar` | Show/hide status bar |
| `Cmd+Ctrl+Shift+Space` | `theme-picker` | Theme picker |
| `Cmd+Ctrl+Space` | `next-background` | Background picker / next background |
| `Cmd+Backspace` | `toggle-opacity` | Transparency on/off |
| `Cmd+Shift+Backspace` | `toggle-gaps` | Gaps on/off |
| `Cmd+K` | `keybind-help` | Cheat sheet |
| `Cmd+Alt+Space` | `main-menu` | Main menu |
| `Cmd+,` | `open-settings` | Open `config.toml` (and your ghostty config if present) |
| `Ctrl+Cmd+F` / `Cmd+Esc` | `toggle-fullscreen` / `exit-fullscreen` | Non-native fullscreen (hides Dock and menu bar) |

Two deliberate deviations from Omarchy: resizing uses `Cmd+Ctrl+arrows` because `Cmd+-`/`Cmd+=` are font-size keys in every macOS terminal, and `Cmd+K` is the cheat sheet rather than "clear screen" — clearing is `Cmd+Shift+K` (`clear-terminal`, rebindable like everything else).

The Shell and Pane menus in the macOS menu bar show the default shortcuts for a few actions; the labels don't follow rebinds, but the shortcuts themselves obey `[keybinds]` (an unbound or rebound combo no longer fires from the menu). The cheat sheet (`Cmd+K`) always reflects the live map.

## Control plane (CLI and AI agents)

QuickTerm listens on a Unix-domain socket in `~/Library/Application Support/QuickTerm/` and ships a `quickterm` command line that speaks to it. Everything a keybinding can do, a command can do — plus a curated noun-verb layer whose defining rule is **absolute setters, never toggles**, because an agent cannot observe state cheaply and a retried toggle silently undoes itself.

```sh
quickterm install-cli --alias qt     # symlinks into /usr/local/bin, or ~/.local/bin — never asks for an admin password
quickterm describe --json            # the whole surface as machine schema; agents read this once per session
```

The CLI parser, `--help`, `describe --json`, the security classes and the MCP tool list are all generated from one command table, so the surface cannot drift.

```
quickterm state | list | get | action <wm-action> | describe | version
quickterm pane      new | close | focus | move | swap | set | resize
quickterm workspace goto | set-layout | equalize | clear | count
quickterm screen    new | close | move | focus | set
quickterm app       get | set
quickterm spec      dump | validate | apply
quickterm events    poll | follow
quickterm input     send-text
quickterm mcp
```

Inside any pane, `QUICKTERM_SOCKET` / `QUICKTERM_PANE` / `QUICKTERM_SCREEN` / `QUICKTERM_WORKSPACE` / `QUICKTERM_TOKEN` / `QUICKTERM_PANE_TOKEN` are already in the environment, so `-t @self` works with no configuration.

### Laying out a workspace in one call

To arrange a whole workspace, use `spec apply` rather than a loop of `pane new`: N commands mean N relayouts, N animations and N failure points, and a failure halfway leaves a workspace nobody can describe. A spec is computed once and assigned once.

```sh
cat > dev.json <<'JSON'
{ "schema": "quickterm.workspace/1", "layout": "scrolling", "visibleColumns": 3,
  "columns": [
    {"panes": [{"cwd": "~/proj", "cmd": "nvim ."}]},
    {"panes": [{"cwd": "~/proj", "cmd": "npm run dev", "hold": true}, {"cwd": "~/proj"}]},
    {"panes": [{"kind": "browser", "url": "http://localhost:3000"}]}],
  "focus": {"column": 0, "row": 0} }
JSON

quickterm spec apply -f dev.json -t :4 --dry-run   # prints the diff, changes nothing
quickterm spec apply -f dev.json -t :4            # --into-empty is the default: refuses a non-empty workspace
```

`spec dump` prints the document itself (no response envelope), so `dump → edit → apply --reuse` round-trips: panes that still match are left alone, so a running dev server is not restarted.

### `[control]` configuration

```toml
[control]
# socket = true             # false: do not listen at all (neither the CLI nor MCP can connect)
# mcp = true                # false makes `quickterm mcp` refuse to serve (the CLI socket stays available)
# mode = "ask"              # off | readonly | ask ("on" is an alias for ask). There is no "never ask" mode.
# expose-browser = "token"  # token | always | never — who may read browser pane URLs and titles
# send-text = false         # typing into a terminal pane on behalf of a caller; off by default
```

`socket`, the old `enabled` and `mode` are three switches over the same listener and **the most restrictive one wins**: `socket = false`, `enabled = false` or `mode = "off"` — any single one of them means no socket is bound at all. `mcp` is separate on purpose: the threat surfaces differ, and you may well want the CLI for yourself without letting any MCP host (and everything it reads) in. With `mcp = false`, `quickterm mcp` refuses to serve and names the key that refused it; the socket stays available to your own shell.

There is deliberately **no "never ask" mode**: the confirmation gate can only be bypassed by turning the control plane `off` or `readonly`, and an unrecognised value falls back to `ask`.

Every boolean key in the config (here and everywhere else) accepts `true` / `1` / `yes` / `on` and `false` / `0` / `no` / `off`, case-insensitively. Anything else is **not** guessed: the line is ignored, the declared default stays in effect, and a warning naming the key and the value is written to the log — so `socket = off` really does turn the listener off instead of quietly leaving it on.

### Security posture

- Reads are silent — but **browser pane URLs and titles are redacted** for callers that did not inherit `QUICKTERM_TOKEN`. Browser panes hold logged-in sessions, so `quickterm state` is itself a disclosure surface.
- Mutations are silent but **visible**: the status bar flashes the command and its claimed origin pane, everything is recorded in QuickTerm's control activity log, and layout changes register an undo entry (`Cmd+Z`). Mutations are rate-limited per caller, and every mutating command is refused while a modal dialog is up.
- Destructive commands (`pane close`, `workspace clear`, `screen close`, `spec apply --replace`) ask the user **inside QuickTerm**, once per (calling pid, command class). The process name and pid in the dialog come from the kernel (`LOCAL_PEERPID`), so a copied token cannot fake them.
- `input send-text` is off by default and is arbitrary code execution in whatever shell is there — possibly root, possibly a live ssh session. Once enabled, writing into the caller's own pane needs no prompt (that tty is already its own), and the caller has to *prove* that with the per-pane `QUICKTERM_PANE_TOKEN` it inherited — the self-reported `QUICKTERM_PANE` buys nothing, because the server cannot verify it. **Every other pane prompts every single time**, and the dialog shows the exact text that would be typed and whether a newline follows. Control characters are refused, and a newline requires an explicit `--enter`.
- Connections must come from the same uid (`LOCAL_PEERCRED`); the socket is `0600` inside a `0700` directory. There is no TCP listener and no escape-sequence channel, ever.
- **`QUICKTERM_TOKEN` is proof of origin, not a permission boundary.** There is one per app launch, injected into every pane, so it answers "this came from *some* QuickTerm pane" and never skips a confirmation. `QUICKTERM_PANE_TOKEN` is one per pane (`HMAC(per-launch key, paneID)`) and answers the question the first one cannot — *which* pane — but it too is not a boundary: it is used in exactly one place, the `send-text` self-write exemption.

The real threat is not another user on the machine — it is a **confused deputy**: an agent running in a pane reads a poisoned web page, README or CI log and is told to run `quickterm` commands. That is why the gate ships in the first version rather than a later one.

### MCP

`quickterm mcp` is a stdio MCP server whose 11 coarse tools are generated from the same command table (a hand-written one would drift silently).

```sh
claude mcp add quickterm -- /usr/local/bin/quickterm mcp
codex mcp add quickterm -- /usr/local/bin/quickterm mcp
quickterm mcp --list-tools | jq -r '.tools[].name'
```

Tool annotations (`readOnlyHint` / `destructiveHint` / `idempotentHint`) are mapped mechanically from each command's security class, so the host can auto-approve reads and prompt on destructive calls — a second gate, independent of QuickTerm's own. The MCP layer has no privileges of its own: every call goes through the same socket, the same consent and the same rate limits.

### Honest limits

- Short handles (`t7`, `b3`) are stable only for one run of QuickTerm; the only identity that survives a restart is the pane `id` (a UUID).
- Events carry structure, titles and cwd — **never pane output**. Reading what a command printed is not something the control plane does.
- Some changes bump `seq` without a typed event (`app set theme`, `screen set --fullscreen`): you learn your snapshot is stale, then re-read `state`.
- `events follow` is a stream for humans and shell scripts; agents should long-poll with `events poll --since`.
- The MCP tool list is roughly 64 KB of schema — that is the per-session context tax the CLI does not charge, which is why the docs say MCP for interactive one-offs, CLI for bulk composition.
- `spec apply` never moves windows (use `screen move`), and a failure after the first cut reports `partial_apply` rather than pretending nothing happened.

Full agent-facing documentation, including the addressing grammar and the exit-code table: [`docs/agents/quickterm-cli.md`](docs/agents/quickterm-cli.md).

## Configuration

`~/.config/quickterm/config.toml` — created with a commented template the first time you press `Cmd+,`. It hot-reloads on save.

```toml
# Every key is declared once in Sources/Config/ConfigSchema.swift; this block is that registry.
# Keys are grouped by function — one group = one tab in the settings UI.

[appearance]
# theme = "tokyo-night"  # or "ghostty": don't touch colours, follow ~/.config/ghostty/config entirely
# pane-opacity = 0.92    # 0.5–1.0, inactive baseline; text is never affected
# active-opacity = 0.98  # 0.5–1.0, effective opacity of the focused pane
# bar-opacity = 0.75     # 0–1, top status bar background
# divider-opacity = 0.2  # 0–1, dwindle split divider line (0 hides it)
# inactive-blur = 2.5    # > 0 enables frosted inactive panes; 0 turns it off
# pane-padding = 14      # terminal padding in pt, 0–32 (Omarchy's value is 14)
# pane-gap = 5           # 0–20 pt around each pane (neighbours end up 2×gap apart)

[workspace]
# workspaces = 5       # 1–10
# visible-columns = 2  # scrolling columns per screen, 1–6 (unset: follows the main menu)

[terminal]
# file-manager-command = "yazi"  # program for the file-manager action (Cmd+Shift+B); name or absolute path

[browser]
# home = "https://www.google.com"                # page a new browser pane (Cmd+B) opens
# search = "https://www.google.com/search?q=%s"  # used when the address bar text is not a URL (%s = the query)
# user-agent = "safari"                          # safari | webkit | a custom UA string (Google's login page refuses embedded browsers)
# inspectable = false                            # right-click "Inspect Element" in browser panes
# tab-bar = "always"                             # always (default) | auto — auto hides the strip when there is one tab
# tab-width = 200                                # max tab width in pt, 40–600
# tab-min-width = 80                             # min tab width in pt, 40–600; the strip scrolls when they no longer fit
# extensions = true                              # load WebExtensions in browser panes (macOS 15.4+)
# download-dir = "~/Downloads"                   # where browser panes save downloads (~ expands; falls back to ~/Downloads)
# link-opener = "browser-pane"                   # browser-pane | system — where ⌘-clicked terminal links open

[keybinds]                  # action = "modifiers+key"; "none" unbinds. Action ids: Cmd+K
# new-terminal = "cmd+return"
# toggle-float = "cmd+shift+t"
# file-manager = "cmd+shift+b"
# new-browser = "cmd+b"

[ghostty]                   # any Ghostty option, passed through verbatim, highest priority
# cursor-style = block
# font-size = 13
```

**Old spellings keep working, forever.** Everything used to sit at the top level of the file (`theme = …`, `browser-home = …`) and `[control]` used to say `enabled`. Every one of those is still accepted, silently and with no warning — your existing `config.toml` needs no edit. The table below is what QuickTerm writes into a fresh file; inside `[browser]` the `browser-` prefix is dropped because the section already says it, and `[control] enabled` is now `[control] socket` because it is the socket listener that is being switched. When both spellings are present the new name wins, except for `socket`/`enabled`, where the **more restrictive** one wins (see `[control]` above).

Modifier names: `cmd`/`command`/`super`, `shift`, `alt`/`option`/`opt`, `ctrl`/`control`. Key names: single characters, or `left` `right` `up` `down` `return` `tab` `space` `backspace` `escape`. One binding per action — an override replaces all of that action's defaults.

### How the engine is configured

Ghostty's configuration is assembled in five layers, later ones override earlier ones:

1. libghostty built-in defaults
2. QuickTerm's bundled fallback (`ghostty-default.conf`: Monaco 15, the Builtin Pastel Dark theme, copy-on-select, 100M scrollback, option-as-alt …) — loaded **only when you have no Ghostty config file at all**; it steps aside entirely as soon as one exists
3. **`~/.config/ghostty/config`** — loaded with Ghostty's own rules, including `config-file` includes. Fonts, cursor, scrollback, shell integration and terminal-level `keybind =` lines all apply.
4. QuickTerm's overlay (`~/Library/Application Support/QuickTerm/engine-overlay.conf`, regenerated on theme change): colours and palette from the active theme, `window-padding-x/y`, `background-opacity`, `unfocused-split-opacity`, and `window-vsync = false` (see Troubleshooting). Set `theme = "ghostty"` to keep only the padding.
5. The `[ghostty]` section of `config.toml`, appended last.

One quirk of Ghostty's loader: files pulled in through `config-file` includes are applied *after* layers 4 and 5, so a colour set in an included file wins over QuickTerm's theme. Keep colours in the top-level `~/.config/ghostty/config` (or let QuickTerm own them) if you want themes to apply.

### Files and directories

| Path | Purpose |
|---|---|
| `~/.config/quickterm/config.toml` | QuickTerm settings (hot-reloaded) |
| `~/.config/quickterm/themes/<name>/{colors.toml, backgrounds/}` | Your own themes; same name as a built-in overrides it |
| `~/.config/quickterm/backgrounds/` | Your own wallpapers, available in every theme |
| `~/.config/ghostty/config` | Your Ghostty config, reused as-is |
| `~/Library/Application Support/QuickTerm/` | `engine-overlay.conf` and `state.json` (v5: screens, layouts, terminal cwd, browser tabs; `state.pre-v5.json` is the pre-upgrade backup) |

## Troubleshooting

- **Zig dependency fetch fails with 400 / HttpConnectionClosing** — Zig's fetcher ignores the system proxy. Let `scripts/build-ghosttykit.sh` install Zig first (it will stop at the fetch step), then run `scripts/fetch-zig-deps.sh` (pre-fetches through curl and seeds Zig's cache) and re-run the build script.
- **Link errors: many undefined symbols (`_sigaction`, …)** — Xcode 26's SDK ships an arm64-less `libSystem.tbd`. `scripts/build-ghosttykit.sh` applies an SDK overlay automatically; always build through the script, not `zig build` by hand.
- **`cannot execute tool 'metal'`** — install the Metal Toolchain (see Requirements).
- **`xcodebuild` can't find `GhosttyKit.xcframework`** — run `scripts/build-ghosttykit.sh`, then `xcodegen generate`.
- **Background picker only shows the "Choose image…" tile** — theme wallpapers aren't in git; run `scripts/fetch-themes.sh` and rebuild.
- **Every new terminal fails after opening hundreds of panes** — macOS 26 has a per-login-session quota on the deprecated `CVDisplayLink` API. QuickTerm sidesteps it by injecting `window-vsync = false`. If you override it back to `true` and hit the quota, log out and back in.

More background on each of these is in [`docs/porting-notes.md`](docs/porting-notes.md).

## Architecture in one paragraph

AppKit owns state and lifecycle; SwiftUI only renders. `MainWindowController` is the single owner of window-manager state and dispatches every action; layouts are immutable value types (`ScrollingStrip` for the scrolling canvas, Ghostty's `SplitTree` for dwindle) so workspaces are just an array of values and persistence is `Codable`. The Ghostty embedding layer (`Sources/GhosttyEmbed/`) is ported from Ghostty's own macOS app (MIT) with QuickTerm changes marked by `// QuickTerm：` comments (note the full-width colon). Hover and click focus on overlapping panes is resolved by model geometry (`HoverOcclusion`) rather than AppKit `hitTest`, so the drag-source overlays that appear while `⌘` is held can't steal focus; `⌘`-drag targets use `hitTest` with a z-ordered geometric fallback.

- Design document: [`docs/superpowers/specs/2026-08-31-quickterm-design.md`](docs/superpowers/specs/2026-08-31-quickterm-design.md)
- Porting notes and environment gotchas: [`docs/porting-notes.md`](docs/porting-notes.md)
- Acceptance checklists: [`docs/acceptance/`](docs/acceptance/)

## Credits

- [Ghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto — terminal engine and the embedding code in `Sources/GhosttyEmbed/` (MIT).
- [Omarchy](https://github.com/basecamp/omarchy) by DHH and contributors — the design, the keybindings, and the 22 themes with their wallpapers (MIT).

## License

MIT — see [`LICENSE`](LICENSE). Ghostty and Omarchy assets retain their own MIT licences and copyright notices.
