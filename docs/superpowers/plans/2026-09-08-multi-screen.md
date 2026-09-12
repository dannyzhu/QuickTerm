# Multi-"screen" support — implementation plan (Phases 1–3)

> User decisions, confirmed: (1) each screen gets its own independent set of workspaces; (2) one Scratchpad per screen; (3) Phase 4 (moving panes across screens / restoring Spaces) is **not happening**.
> Split of work: plan and adversarial verification by Fable, implementation by Opus. The detailed inventory of single-window assumptions is in
> `/private/tmp/claude-501/-Users-Danny-Documents-workspace-quickterm/e6fdbbbb-fb93-44bb-86da-29bcc5a0b0b0/scratchpad/multiscreen-analysis.txt` (with file:line references).

## 0. The shape

One process, many windows. A "screen" = one `HiddenTitlebarWindow` + one `MainWindowController` + one `WorkspaceModel` (its own 1..N workspaces, status bar, floating layer, Scratchpad and panels).
Exactly one copy of each of these stays process-wide: the Ghostty engine, ThemeManager, ConfigStore/ConfigWatcher/KeybindingMap, BrowserExtensionManager (whose host aggregates every window), SystemStatsService, `BrowserPaneView.settings`, and state.json.
A pane belongs to exactly one window at a time (`PaneHostView` returns the same NSView instance). Cross-window drag and drop is **explicitly refused** (no silent no-op).

**Invariants (every phase must hold them)**: the existing test suite keeps passing; the first window keeps the title `QuickTerm` (`EngineSmokeTests` finds the window by title); `AppDelegate.controller` stays available as a computed property meaning "the key window's controller ?? the first one" (6 test files depend on it); the truth about focus is still the window's first responder; a SwiftUI-hosted pane must not contain a width constraint with priority ≥ 500.

---

## Phase 1 — a second screen can be opened on another display

### 1.1 An app-level registry and routing
- `Sources/App/AppDelegate.swift`:
  - `private(set) var controllers: [MainWindowController] = []` (the only strong reference); `var controller: MainWindowController!` becomes the computed property `NSApp.keyWindow?.windowController as? MainWindowController ?? controllers.first`.
  - `@discardableResult func newScreen(on screen: NSScreen?, inheritingFrom pane: PaneView?) -> MainWindowController`; `func closeScreen(_ c: MainWindowController)`; `func moveScreen(_ c: MainWindowController, to screen: NSScreen)`.
  - `applicationShouldTerminate`: call `flushPendingCloses()` on **every** controller and sum the pane counts.
  - `applicationWillTerminate`: save every controller (Phase 3 replaces this with SessionStore; in Phase 1 only the primary is saved, so behaviour does not change).
  - `ghosttySurface(id:)`: walk every controller's `allPanes`.
  - `--open-browser`: applies to the primary.
- `Sources/App/MainMenu.swift`: `performWMAction` / `menuShortcutAllowed` switch from a fixed controller to the key window's controller (falling back to the primary).

### 1.2 Creating and placing windows
- `MainWindowController.init` gains parameters: `screen: NSScreen?`, `index: Int`, `restoring: Bool` (used in Phase 3).
  - No more unconditional `window.center()`: with a screen given, centre inside its `visibleFrame`; if there is already a window on that screen, offset with `cascadeTopLeft`; always `constrainFrameRect`.
  - Title: index 0 is `QuickTerm`, then `QuickTerm 2` and so on (numbers are reused from the lowest free slot).
  - Only the primary does `restoreState()` / `ensureTemplateKeys` (Phase 2 hoists these out).
- `NSWindowDelegate`: `windowShouldClose` (with live panes, reuse the quit confirmation's counting and wording), `windowWillClose` (`flushPendingCloses()` → remove it from the registry → let AppKit hand key status on). Deallocation order: remove the registry entry after a `DispatchQueue.main.async`, so a surface sitting on an engine callback stack is not freed early.

### 1.3 The Window menu (no shortcuts)
Hangs off the standard system Window menu (`NSApp.windowsMenu` is already set, and AppKit appends the window list itself). Items:
```
New Screen
New Screen on Display ▸      (rebuilt dynamically in NSMenuDelegate.menuNeedsUpdate, listing NSScreen.localizedName, with "(current)" on the current display)
Move This Screen to Display ▸  (the current display is checked and disabled)
Show on All Desktops         (toggles .canJoinAllSpaces in collectionBehavior; shows a checkmark)
Close Screen
──────
Minimize ⌘M (existing) / Zoom / Bring All to Front
```
A display item's `representedObject` carries the **display UUID string** (not an NSScreen instance — those are rebuilt when the configuration changes). `validateMenuItem`: with no key window, disable "Move to Display / Close Screen".

### 1.4 Three singletons that must be fixed in this phase (otherwise a second window breaks them visibly)
1. `ThemeManager.onOverlayChanged`, a single closure → multiple listeners (`addListener(token:)` or `NotificationCenter`): otherwise only the most recently created window responds to live theme switches and `window.appearance`.
2. `BrowserExtensionManager.shared.host`, a single weak pointer → an app-level aggregating host: `browserPanes` merges every controller's, `focusedBrowserPane` takes the key window's, `openBrowserWindow` opens in the key window. The protocol signature does not change (so the stubs in the tests are unaffected).
3. Config reload: in Phase 1, only the **primary** installs a ConfigWatcher and fans the reload out to every controller (Phase 2 hoists it properly into AppSession).

### 1.5 Notification and monitor crosstalk
- The three `object: nil` observers in `MainWindowController` (`ghosttyCloseSurface` / `ghosttyChildExited` / `didEqualizeSplits`) start with an ownership check: `guard model.allPanes.contains(where: { $0 === view })` (for `didEqualizeSplits`, check that `focusedPane` belongs to this window).
- The mouse monitor's `.flagsChanged` and session branches get an `event.window === window` guard.
- Cross-window drag and drop: in `validateDrop`, a source pane that does not belong to this controller is refused (forbidden cursor), not silently turned into a no-op.

### 1.6 Tests (new file `Tests/ScreenRegistryTests.swift`)
- After `newScreen(on:)`, `controllers.count == 2`, the second window's frame falls inside the given `NSScreen.visibleFrame`, and its title is `QuickTerm 2`.
- After `closeScreen` it is back to 1, and a weak reference is nil after one runloop turn (monitors and observers were released).
- With two windows, `AppDelegate.controller` follows the key window.
- The second window's workspaces are independent of the primary's (`perform(.newTerminal)` in B does not change A's `paneList`).
- Notification filtering: `didEqualizeSplits` in A does not change B's column widths.
- The extension host: with one browser pane open in each of two windows, `browserPanes` counts 2.
- Every case has to close the second window at the end and hand key status back to the primary (so it does not pollute later cases).

---

## Phase 2 — hoisting process-level responsibilities (AppSession) + per-window fullscreen

- New file `Sources/Windowing/AppSession.swift`: owns loading ConfigStore, the single ConfigWatcher (including `lastConfigContent` deduplication), the `KeybindingMap` (controllers switch to an injected read-only reference), `SystemStatsService` (injected into `RootView`), and global settings such as `fileManagerCommand` / `linkOpener`.
- Split `applyConfig` in two: `applyGlobalConfig(settings)` (runs **exactly once** per reload: rebuild the KeybindingMap, `BrowserPaneView.settings`, `BrowserExtensionManager.isEnabled`, `themeManager.updateFromConfig`, write the engine overlay) and `controller.applyWindowConfig(settings)` (fanned out: `newTerminalCombo`, the workspace count, `visibleColumns`, pane spacing and so on).
- Non-native fullscreen becomes per-window: each window has its own `savedFrame`, `NSApp.presentationOptions` gets reference counted (`acquire/release` — GhosttyEmbed already has a mechanism by that name to reuse), and it is recomputed whenever the key window changes. The leftover artefact (with A fullscreen, the menu bar on B's display hides too) goes into the README.
- `SurfaceView`'s initial `scale_factor` comes from `NSScreen.main`: after a new pane is attached to a window on a non-primary display, trigger `viewDidChangeBackingProperties` once by hand (mixed-DPI correctness).
- Tests: edit config.toml once and both windows' workspace counts change, with `applyGlobalConfig` called exactly once (a counting stub); the two controllers share one KeybindingMap instance; with window A fullscreen and B becoming key, `presentationOptions` is restored correctly.

---

## Phase 3 — archive v5: multiple screens + display/frame restoration + one-key restore

### 3.1 Structure
New file `Sources/Windowing/SessionState.swift` (moving `PersistedState` out of the controller):
```swift
struct DisplayRef: Codable { var uuid: String?; var name: String?; var frame: CGRect? }
struct WindowState: Codable {
    var id: UUID
    var layouts: [WorkspaceLayout]
    var floatings: [[FloatingPane]]?
    var activeIndex: Int
    var visibleColumns: Int?
    var display: DisplayRef?
    var frame: CGRect?          // the non-fullscreen frame, in global coordinates
    var isFullscreen: Bool
    var joinAllSpaces: Bool
}
struct PersistedState: Codable { var version = 5; var windows: [WindowState]; var keyWindowID: UUID? }
```
**The encoded bytes of panes and layouts do not change** (`WorkspaceLayout`, `ScrollingStrip.Column`, `SplitTree`, `FloatingPane` and `PaneCodable` are all left alone) — a terminal pane's `pwd` and a browser pane's tabs (url/title) + activeTab are already being stored, and that is exactly what "one-key restore" restores.

### 3.2 Migration and downgrade
- Probe `version` before reading: `2...4` take the existing decode path (legacy widthFactor normalization, filling in floatings) and get wrapped as `windows[0]` (`display = nil`, `frame = nil` → today's centre-on-the-main-screen behaviour is preserved).
- Before the first migration, copy the old file to `state.pre-v5.json` (v5 cannot be downgraded: 1.5.x refuses to read it and overwrites it with v4 on quit).
- A decode failure, or an entirely empty archive → start fresh (current behaviour).

### 3.3 Resolving displays
`resolveScreen(for: DisplayRef) -> NSScreen?`: UUID (`CGDisplayCreateUUIDFromDisplayID`, with the displayID from `NSScreen.deviceDescription`'s `NSScreenNumber`) → `localizedName` → the main screen. A restored frame is always `constrainFrameRect`'d into the target screen's `visibleFrame`; **never lose a window or a layout because the position could not be resolved**.

### 3.4 When we write to disk (fixing "saved only on quit")
- `SessionStore.scheduleSave()`: 1.5s debounce, triggered by a layout change (a Combine sink on `model.layouts` / `floatings` / `activeIndex`), a window move/resize finishing (`windowDidEndLiveResize` / `windowDidMove`), a screen opening or closing, a fullscreen toggle, and `applicationWillTerminate` (written immediately).
- Writes stay `.atomic`; the test host (`AppDelegate.isRunningTests`) does not write.

### 3.5 Display hot-plugging
Observe `NSApplication.didChangeScreenParametersNotification` with a **0.5s debounce** (plugging, unplugging and waking all fire several times): re-constrain every window into its target screen (a vanished target falls back to the main screen), and re-fit fullscreen windows.

### 3.6 Tests
- v5 round trip: two windows → save → restore gives two windows with identical `activeIndex`, floatings, column widths, pane kinds, terminal `pwd`s and browser tabs.
- A v4 file (and a v2 one with no floatings) decodes as a single window, pane for pane; after the migration `state.pre-v5.json` exists.
- `DisplayRef` resolution: a UUID hit / a name hit / neither, falling back to the main screen; a frame that is off-screen gets constrained back into the visible area.
- Debounced saving: 10 layout changes in a row write the file once (a counting stub, or watch the file mtime).
- The existing `PersistedState` version assertions (ConfigStoreTests / WorkspaceTests) are updated to v5.

---

## Delivery
Every phase: branch → implement → targeted tests → the full suite → adversarial verification → fix → the full suite → commit → merge into main. Once all three phases are done, rebuild Debug and restart the app; add a "Multi-screen" section to both READMEs along with the hard limits (Spaces cannot be chosen programmatically, fullscreen presentationOptions are process-level, v5 cannot be downgraded); record the multi-window AppKit traps in `docs/porting-notes.md`.
