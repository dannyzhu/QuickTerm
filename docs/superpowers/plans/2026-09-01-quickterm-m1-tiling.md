# QuickTerm M1 (tiling core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hyprland-style tiling inside a single window: dwindle splits, directional focus/swap/close/resize/equalize/zoom, hover to activate, dynamic opacity, Cmd+drag to move/split/resize, hidden titlebar + gaps + accent borders, the WM keybinding framework + the menu bar.

**Architecture:** MainWindowController (inheriting M0's BaseTerminalController shim) holds a `SplitTree<Ghostty.SurfaceView>` as the single source of state; SwiftUI only renders (porting Ghostty's TerminalSplitTreeView/SplitView); WM keys are intercepted by a local NSEvent monitor before they reach the surface; hover focus and inactive dimming reuse the mechanisms the embedding layer already has (override `focusFollowsMouse` + the `unfocused-split-opacity` config).

**Tech Stack:** Swift/AppKit + SwiftUI, GhosttyKit, the ported Ghostty Splits components (MIT), XCTest.

**Spec:** `docs/superpowers/specs/2026-08-31-quickterm-design.md` (§3 architecture, §4.1/4.2 features, §5.1 the keybinding table, §7 the M1 row)

## Global Constraints

- Branch `m1-tiling` (cut from main); commit at the end of every task
- Visual parameters (spec §1.1/§4.2): **gaps_in=5, gaps_out=10, active border 2px accent `#7aa2f7`, inactive border grey `rgba(0x59,0x59,0x59,0.67)`, corner radius 0, opacity active 0.985 / inactive 0.96**
- Keybindings (spec §5.1, with the two confirmed deviations): Cmd+Return new pane, Cmd+W close pane, Cmd+arrow focus, Cmd+Shift+arrow swap, Cmd+J flip direction, Cmd+F zoom, Cmd+Ctrl+arrow resize by 100px (+Shift 10px), Cmd+Ctrl+= equalize, Alt+Tab/Cmd+[/] cycle panes, Cmd+left/right-drag move/resize
- **Do not intercept** terminal-level keys (Cmd+C/V, Cmd+plus/minus/0 and so on) — anything not in the WM map is passed straight to the surface
- Ported files keep their MIT header; deletions and edits go into `docs/porting-notes.md`
- `vendor/ghostty/macos/Sources/` is the source of truth for the port; wherever the ported code in this plan disagrees with the v1.3.1 sources, the sources win

**Execution note**: the Ghostty component's insert semantics for a new pane are `SplitTree.inserting(view:at:direction:)` (direction: `.left/.right/.up/.down`, ratio 0.5, clears zoom automatically); spatial focus navigation is `focusTarget(for: .spatial(.left…), from:)`; resize is `resizing(node:by:in:with:)`. The signatures come from `Sources/GhosttyEmbed/Features/Splits/SplitTree.swift`.

---

### Task 1: Port the Splits SwiftUI renderers

**Files:**
- Create: `Sources/GhosttyEmbed/Features/Splits/{TerminalSplitTreeView.swift, SplitView.swift, SplitView.Divider.swift}` (copied from `vendor/ghostty/macos/Sources/Features/Splits/`)
- Modify: `docs/porting-notes.md` (add an M1 section)

**Interfaces:**
- Produces: `TerminalSplitTreeView(tree: SplitTree<Ghostty.SurfaceView>, action: (TerminalSplitOperation) -> Void)` (needs `.environmentObject(_: Ghostty.App)`); the `TerminalSplitOperation` enum (the exact shape of `.resize(node:ratio:)` and `.drop(payload:destination:zone:)` follows the sources)

- [ ] **Step 1: copy the three files**

```bash
cp vendor/ghostty/macos/Sources/Features/Splits/{TerminalSplitTreeView.swift,SplitView.swift,SplitView.Divider.swift} Sources/GhosttyEmbed/Features/Splits/
```

- [ ] **Step 2: compile iteratively** (`xcodegen generate && xcodebuild … build`, working through the errors: copy missing helpers in from Helpers; for references to deleted app features, trim or shim them the same way M0 did, recording everything in porting-notes)

- [ ] **Step 3: commit once the whole suite is green again**

```bash
git add Sources/GhosttyEmbed docs/porting-notes.md && git commit -m "feat: port Ghostty split tree SwiftUI renderers (MIT)"
```

---

### Task 2: SplitTree QuickTerm extensions (dwindle/swap/flip direction) + unit tests

**Files:**
- Create: `Sources/Splits/SplitTree+QuickTerm.swift`
- Test: `Tests/SplitTreeQuickTermTests.swift`

**Interfaces:**
- Consumes: `SplitTree` (the ported Ghostty version: `.inserting/.removing/.replacing/.resizing/.equalized/.focusTarget`, `Node.leaf/.split`, `Spatial`)
- Produces:
  - `func dwindleDirection(for view: ViewType) -> SplitTree.NewDirection` — focused pane wider than tall → `.right`, otherwise `.down` (Omarchy dwindle + force_split=2 semantics)
  - `func swapping(_ a: ViewType, _ b: ViewType) -> SplitTree` — swap the positions of two leaves
  - `func togglingSplitDirection(around view: ViewType) -> SplitTree` — invert the direction of the nearest parent split (horizontal↔vertical)

- [ ] **Step 1: write the failing tests** (the points to cover: the dwindle direction follows the frame's aspect ratio; after a swap the two leaves have traded places and the tree shape is unchanged; after a toggle the parent split's direction is inverted; empty-tree and single-leaf edge cases do not crash. Use real SurfaceViews — they can be created inside the TEST_HOST; follow the SurfaceHostingTests style in `Tests/EngineSmokeTests.swift`)

```swift
@MainActor
func testSwappingExchangesLeaves() throws {
    let (a, b) = try makeTwoSurfaces()          // helper: create two SurfaceViews
    let tree = SplitTree(view: a).inserting(view: b, at: .right, of: a)  // signature follows the sources
    let swapped = tree.swapping(a, b)
    // after the swap: the left leaf is b, the right leaf is a
    guard case .split(let s) = swapped.root else { return XCTFail() }
    XCTAssertEqual((s.left as? SplitTree<Ghostty.SurfaceView>.Node)?.leftmostLeaf(), b)  // assert against the real API
}
```

- [ ] **Step 2: run them and confirm they fail** → **Step 3: implement the three extension functions** → **Step 4: all green** → **Step 5: commit `feat: dwindle/swap/toggle-direction SplitTree extensions`**

---

### Task 3: Hidden-titlebar window + the RootView shell (gaps)

**Files:**
- Create: `Sources/Windowing/HiddenTitlebarWindow.swift` (follow the recipe in `vendor/ghostty/macos/Sources/Features/Terminal/Window Styles/HiddenTitlebarTerminalWindow.swift`, rewritten simpler for QuickTerm — no tabs, no accessory)
- Create: `Sources/Windowing/RootView.swift`
- Modify: `Sources/App/AppDelegate.swift` (switch to the new window and RootView; this task still renders a single-surface tree)

**Interfaces:**
- Produces: `HiddenTitlebarWindow: TerminalWindow`; `RootView(model: WorkspaceModel, ghostty: Ghostty.App, action: (TerminalSplitOperation) -> Void)`; `WorkspaceModel: ObservableObject { @Published var tree: SplitTree<Ghostty.SurfaceView> }` (the Task 4 controller owns it and mutates it)

- [ ] **Step 1: HiddenTitlebarWindow** (the essentials of the recipe, checked against the Ghostty source file):

```swift
import AppKit

/// The hidden-titlebar recipe (from Ghostty's HiddenTitlebarTerminalWindow, MIT; tabs/accessory removed)
class HiddenTitlebarWindow: TerminalWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .fullSizeContentView, .resizable, .closable, .miniaturizable],
                   backing: backing, defer: flag)
        reapplyHiddenStyle()
    }
    override var title: String { didSet { reapplyHiddenStyle() } }  // on macOS 15, setting the title un-hides it
    private func reapplyHiddenStyle() {
        styleMask.insert(.fullSizeContentView)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach {
            standardWindowButton($0)?.isHidden = true
        }
        tabbingMode = .disallowed
    }
}
```

- [ ] **Step 2: WorkspaceModel + RootView**:

```swift
import SwiftUI

final class WorkspaceModel: ObservableObject {
    @Published var tree: SplitTree<Ghostty.SurfaceView> = .init()
}

struct RootView: View {
    @ObservedObject var model: WorkspaceModel
    let ghostty: Ghostty.App
    let action: (TerminalSplitOperation) -> Void

    var body: some View {
        ZStack {
            Color(red: 0x1a/255.0, green: 0x1b/255.0, blue: 0x26/255.0)  // fixed background until M3 (Tokyo Night bg)
            TerminalSplitTreeView(tree: model.tree, action: action)
                .padding(10)                     // gaps_out = 10 (spec §1.1)
        }
        .ignoresSafeArea(.container, edges: .top)  // let the content extend into the hidden titlebar area
        .environmentObject(ghostty)
    }
}
```

- [ ] **Step 3: reshell AppDelegate** — switch the window to `HiddenTitlebarWindow`; `model.tree = SplitTree(view: surfaceView)` (the single-leaf initializer's signature follows the sources); `window.contentView = NSHostingView(rootView: RootView(model:…, ghostty:…, action: { _ in }))`. **Note**: leaves are rendered by the TerminalSplitLeaf → SurfaceScrollView chain (the Ghostty component already synchronizes sizes internally), so AppDelegate no longer holds a SurfaceScrollView directly; update the `testWindowHostsSurfaceScrollView` regression test in `Tests` accordingly, to "contentView is an NSHostingView and the tree is non-empty" plus "after a window resize the focused surface's frame follows".

- [ ] **Step 4: manual smoke test** (the window has no titlebar or traffic lights, the terminal works, resizing follows, there is a 10px seam of background around the outside) → **Step 5: full suite green + commit `feat: hidden-titlebar window and RootView shell with gaps`**

---

### Task 4: MainWindowController (tree state + surface lifecycle + hover focus + opacity)

**Files:**
- Create: `Sources/Windowing/MainWindowController.swift`
- Modify: `Sources/App/AppDelegate.swift` (slim it down to: build the controller, forward the embedding-layer interfaces)
- Modify: `Sources/App/AppDelegate+Ghostty.swift` (route closeAllWindows/toggleVisibility to the controller)
- Test: `Tests/MainWindowControllerTests.swift`

**Interfaces:**
- Consumes: the Task 2 extensions, and Task 3's WorkspaceModel/RootView/HiddenTitlebarWindow
- Produces:
  ```swift
  final class MainWindowController: BaseTerminalController {
      let model: WorkspaceModel
      override var focusedSurface: Ghostty.SurfaceView? // the real implementation: whichever SurfaceView.focusInstant is newest
      override var focusFollowsMouse: Bool { true }     // hover is focus (spec §4.2)
      override var surfaceTree: SplitTree<Ghostty.SurfaceView> // proxied to model.tree
      func newSurface(inheritingFrom: Ghostty.SurfaceView?) -> Ghostty.SurfaceView  // cwd inheritance: baseConfig.workingDirectory = source.pwd
      func perform(_ action: WMAction)                  // the action entry point from Task 5
      func handleSplitOperation(_ op: TerminalSplitOperation)
  }
  ```

- [ ] **Step 1: failing tests** (a new pane inherits the cwd field; closing the last pane leaves the tree empty; `focusFollowsMouse == true`)
- [ ] **Step 2: implementation**, the essentials:
  - `newSurface`: `var cfg = Ghostty.SurfaceConfiguration(); cfg.workingDirectory = inheritingFrom?.pwd; return Ghostty.SurfaceView(ghostty.app!, baseConfig: cfg)` (the SurfaceConfiguration field names follow the sources)
  - Focus tracking: observe `Ghostty.Notification.didFocusSurface` (the exact notification name the embedding layer already posts from `moveFocus(to:)` follows the sources) and maintain `focusedSurfaceRef`
  - Closing a pane: `model.tree = model.tree.removing(view)`; the surface's process-exit callback (`close_surface_cb` → the embedding layer's notification) takes the same path; closing the last pane → `window.close()`
  - **Dynamic opacity**: append QuickTerm's overrides after Ghostty.App's config load — at the end of the `Ghostty.Config` load chain, `ghostty_config_load_string` (if that C API does not exist, use the equivalent such as `ghostty_config_load_cli_args`, check `include/ghostty.h`) injects `background-opacity = 0.985`, `unfocused-split-opacity = 0.96`, `window-padding-x/y = 0`. The embedding layer's unfocused overlay in SurfaceView (`SurfaceView.swift:228`) then works by itself
  - `handleSplitOperation`: `.resize` → `model.tree = tree.resizing(...)`; `.drop` → remove+insert (wired up in Task 7)
- [ ] **Step 3: AppDelegate forwards to the controller** → **Step 4: manual acceptance** (open two panes; hovering one highlights it, makes it active and typable, and the unfocused pane dims) → **Step 5: tests green + commit `feat: MainWindowController with hover focus and dynamic opacity`**

---

### Task 5: The WM keybinding framework + menu bar (wire up the whole §5.1 table)

**Files:**
- Create: `Sources/Config/WMAction.swift`, `Sources/Config/KeybindingMap.swift`
- Create: `Sources/App/MainMenu.swift` (the main menu, built in code)
- Modify: `Sources/Windowing/MainWindowController.swift` (`perform(_:)` implements the whole table + installs the local monitor)
- Test: `Tests/KeybindingMapTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum WMAction: String, CaseIterable {
      case newTerminal, closePane
      case focusLeft, focusRight, focusUp, focusDown
      case swapLeft, swapRight, swapUp, swapDown
      case toggleSplitDirection, toggleZoom, equalize
      case resizeLeft, resizeRight, resizeUp, resizeDown   // 100px; the Shift variant is 10px
      case cyclePaneNext, cyclePanePrev
  }
  struct KeyCombo: Hashable { let key: String; let modifiers: NSEvent.ModifierFlags.RawValue }
  struct KeybindingMap {
      static let defaults: [KeyCombo: WMAction]
      func action(for event: NSEvent) -> (WMAction, precise: Bool)?  // precise = the Shift resize fine step
  }
  ```
- The default table (spec §5.1, entry by entry): `cmd+return→newTerminal`, `cmd+w→closePane`, `cmd+←→↑↓→focus*`, `cmd+shift+←→↑↓→swap*`, `cmd+j→toggleSplitDirection`, `cmd+f→toggleZoom`, `cmd+ctrl+←→↑↓→resize*` (`+shift` 10px), `cmd+ctrl+=→equalize`, `alt+tab/alt+shift+tab→cyclePaneNext/Prev`, `cmd+]/cmd+[→cyclePaneNext/Prev`

- [ ] **Step 1: failing tests** (the default table covers every §5.1 entry; `action(for:)` parses synthesized NSEvents correctly; **Cmd+C returns nil** — terminal keys pass through)
- [ ] **Step 2: implement KeybindingMap** (parse NSEvents with `charactersIgnoringModifiers` + `keyCode` for the arrows/return/tab)
- [ ] **Step 3: the monitor** (MainWindowController installs `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`: if the window is key and the map hits → `perform(action)` and return nil to consume it; otherwise pass the event through untouched)
- [ ] **Step 4: implement the whole table in perform(_:)** (calling Task 2 and the embedding layer's APIs: `inserting(view: newSurface(...), at: dwindleDirection(...), of: focused)`, `removing`, `focusTarget(.spatial(...))` + `Ghostty.moveFocus(to:)`, `swapping`, `togglingSplitDirection`, zoom = `tree.zoomed==node ? nil : node` (follow SplitTree's zoom API), `equalized()`, `resizing(node: focusedNode, by: precise ? 10 : 100, in: direction, ...)`)
- [ ] **Step 5: MainMenu** (App/File/Pane/View menus, with entries carrying the same key equivalents so the shortcuts are visible and registered; the monitor consuming events first does not affect clicking a menu item)
- [ ] **Step 6: manual acceptance of §5.1, entry by entry** → **Step 7: tests green + commit `feat: WM keybinding framework wired to full spec 5.1 table`**

---

### Task 6: Pane visuals (accent border + gaps_in + popin animation)

**Files:**
- Modify: `Sources/GhosttyEmbed/Features/Splits/TerminalSplitTreeView.swift` (add the QuickTerm chrome modifier inside TerminalSplitLeaf — keep the change minimal and record it in porting-notes)
- Create: `Sources/Splits/PaneChrome.swift`

**Interfaces:**
- Produces: `struct PaneChrome: ViewModifier` — driven by `focused` on the `@ObservedObject surfaceView`: a 2px border (focused `#7aa2f7` / unfocused `Color(white: 0x59/255.0).opacity(0.67)`), `.padding(2.5)` (half of gaps_in=5, so two adjacent leaves compose to 5), corner radius 0; appearance animation `.scaleEffect(appeared ? 1 : 0.87)` + `.animation(.easeOut(duration: 0.2))` (an approximation of popin 87% easeOutQuint)

- [ ] **Step 1: implement PaneChrome and hang it on TerminalSplitLeaf** → **Step 2: manual acceptance** (after a split, the focus border follows the hover correctly; a new pane pops in; the gaps read as 5/10) → **Step 3: tests green + commit `feat: pane chrome — accent border, gaps, popin animation`**

---

### Task 7: Cmd+drag (move/split + right-drag to resize)

**Files:**
- Modify: `Sources/Windowing/MainWindowController.swift` (extend the local monitor to handle `leftMouseDown/rightMouseDragged` + Cmd)
- Modify: `Sources/GhosttyEmbed/Features/Splits/TerminalSplitTreeView.swift` (if the drop-target code depends on BaseTerminalController, decouple it through `handleSplitOperation`)

**Interfaces:**
- Consumes: the ported component's drop-zone implementation (`TerminalSplitLeaf`'s `.dropDestination`/onDrop + `SurfaceView+Transferable`, `SurfaceDragSource`), `handleSplitOperation(.drop(...))`
- Produces: Cmd+left-press on a pane → start an NSDraggingSession with that pane as the payload (image from `surfaceView.snapshot` or a solid block); a drop in the centre = `swapping`, a drop on an edge = `removing` + `inserting(at: the matching direction)`; Cmd+right-drag → convert the drag's dominant axis into `resizing(node:by:in:)` (follows the pointer, no stepping)

- [ ] **Step 1: wire up the drop path** (a `.drop` op → the controller: centre zone swaps, edge zone removes and re-inserts; the zone enum's names follow the ported sources)
- [ ] **Step 2: Cmd+left-press starts the drag** (the monitor catches `.leftMouseDown` with `modifierFlags.contains(.command)` that hits a leaf → `beginDraggingSession`; without Cmd, pass it straight through to the surface)
- [ ] **Step 3: Cmd+right-drag resize** (`.rightMouseDown/.rightMouseDragged` + Cmd → accumulate the delta and call `resizing`; end on mouse-up)
- [ ] **Step 4: manual acceptance** (dropping in the centre swaps, dropping on the four edges splits and inserts, right-drag resizes smoothly, normal text selection with the mouse is unaffected) → **Step 5: commit `feat: cmd+drag pane move/split and cmd+right-drag resize`**

---

### Task 8: M1 wrap-up (acceptance list + docs + merge)

- [ ] **Step 1: manual acceptance of the whole §5.1 + §4.2 table** (record every entry in `docs/acceptance/m1.md`: pass/notes)
- [ ] **Step 2: a keybindings section in the README** + complete the M1 section of porting-notes
- [ ] **Step 3: full suite green → commit → merge into main → `git tag m1`** (remember the lesson: the tag must not have the same name as the branch)

## Self-review notes

- **Spec coverage**: every item in spec §7's M1 row — the full set of SplitTree operations (T2/T5), Cmd+drag (T7), hover focus + dynamic opacity (T4), hidden titlebar + gaps + borders (T3/T6), WM keys + menu bar sync (T5) — has an owner; the §5.1 table is pinned down entry by entry by T5 Step 1's tests. ✅
- **Placeholder scan**: no TBD; the porting steps use "compiles green + tests green + recorded in porting-notes" as their objective acceptance bar, and state explicitly that the v1.3.1 sources decide the API details. ✅
- **Type consistency**: `WorkspaceModel/WMAction/KeybindingMap/PaneChrome/handleSplitOperation` are named identically on the Produces and Consumes sides; the SplitTree extension names `dwindleDirection/swapping/togglingSplitDirection` are consistent throughout. ✅
