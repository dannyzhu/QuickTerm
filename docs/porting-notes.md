# GhosttyEmbed porting notes (M0)

Source: `ghostty-org/ghostty` **tag v1.3.1** (submodule `vendor/ghostty`).
The porting layer = the whole of `macos/Sources/Ghostty/` copied into `Sources/GhosttyEmbed/`, MIT licensed, copyright headers kept.

## What was copied in

- `Sources/GhosttyEmbed/` (= all of macos/Sources/Ghostty/, minus the deletions below)
- `Helpers/`: CrossKit, Cursor, Backport, Weak, KeyboardLayout, AppInfo, CodableBridge, AnySortKey, MetalView, Fullscreen (trimmed), all of `Extensions/`, Private/Dock.swift
- `Features/Splits/SplitTree.swift` (the value-type split tree — M1's core model, pulled in early)
- `Features/QuickTerminal/`: the four Position/Screen/Size/SpaceBehavior enums (referenced by Config)
- `Features/Secure Input/`: SecureInput.swift, SecureInputOverlay.swift

## Deletions (app-specific, not needed for embedding)

| File | Why |
|---|---|
| `Ghostty.Inspector.swift` → restored afterwards | SurfaceView references the `Ghostty.Inspector` type; restoring the original file cost less than trimming it out |
| `Surface View/InspectorView.swift` | ImGui debugger UI, nothing in the restored set references it |
| `Surface View/SurfaceView_UIKit.swift` | iOS branch |
| `Surface View/SurfaceGrabHandle.swift` | Depends on BaseTerminalController's drag; M1 replaces it with SplitTree drag (the call site in SurfaceView.swift went with it) |

## Trimmed / modified

| Where | Change |
|---|---|
| `Helpers/Fullscreen.swift` | Kept FullscreenMode / the protocol / NativeFullscreen; the NonNativeFullscreen family became aliases of NativeFullscreen (the original implementation depends on TerminalWindow/CGSSpace/window tabs). **That family was never re-ported. QuickTerm grew its own non-native fullscreen on its own window class instead: `MainWindowController.toggleSimpleFullscreen` plus the refcounted process-level `NSApp.presentationOptions` in `AppSession` — see the multi-window section** |
| `Helpers/Extensions/NSWindow+Extension.swift` | Dropped `addTabbedWindowSafely` (and its ObjC exception-catching helper `GhosttyAddTabbedWindowSafely`; QuickTerm does not use native window tabs) |
| `Surface View/SurfaceScrollView.swift` | The window-class check guarding the macOS 26.0-only NSScrollPocket workaround widened from `HiddenTitlebarTerminalWindow` to any window |
| `Ghostty.Error.swift`, `Helpers/Extensions/String+Extension.swift`, `Features/QuickTerminal/QuickTerminalSize.swift` | Added the missing `import Foundation/Cocoa` (the original project presumably compiles thanks to visibility differences from other files in the same target) |
| `Shims.swift` (new) | Minimal stand-ins for `BaseTerminalController` (surfaceTree/focusedSurface/titleOverride/commandPaletteIsShowing/**focusFollowsMouse**/toggleBackgroundOpacity/promptTabTitle/changeTabTitle), `TerminalWindow` and `TerminalRestoreError`. **M1's MainWindowController inherits BaseTerminalController and overrides focusFollowsMouse=true — that alone gives you hover focus** |
| `Sources/App/AppDelegate+Ghostty.swift` (new) | The delegate interface the embedding layer requires: checkForUpdates/closeAllWindows/toggleVisibility/syncFloatOnTopMenu/setSecureInput/toggleQuickTerminal/performGhosttyBindingMenuKeyEquivalent (no-ops in M0) |

## v1.3.1 API snapshot (what we actually use)

- `int ghostty_init(uintptr_t, char**)` — **must be called before NSApplicationMain** (same as the official main.swift; otherwise Ghostty.App's init path misbehaves)
- `ghostty_config_new/free/load_default_files/finalize/get` — `load_default_files` natively reads `~/.config/ghostty/config` (XDG), i.e. layer 2 of the config chain
- `Ghostty.App(configPath: nil)` — does the Config load + `ghostty_app_new` internally (runtime callbacks: wakeup/action/clipboard×3/close_surface)
- `Ghostty.SurfaceView(_ app: ghostty_app_t, baseConfig: nil)` — an NSView; Metal rendering is built into the engine; creating one starts a PTY + login shell

## Build pipeline notes (all of it is baked into scripts/build-ghosttykit.sh)

1. **Prefetch the Zig dependencies offline** (`scripts/fetch-zig-deps.sh`): Zig 0.15's HTTP/git clients ignore the proxy; curl every URL in `build.zig.zon` + `build.zig.zon.txt` first, then let `zig fetch` fill the cache; transitive git dependencies (vaxis → uucode@5f05f8f8) are substituted with the equivalent GitHub codeload tarball
2. **SDK arm64 overlay**: in Xcode 26.6 (SDK 26.5) the main document of `libSystem.tbd` targets only x86_64/arm64e, and Zig 0.15's linker does not fall back from arm64 to arm64e → every symbol comes out undefined. The build script generates a symlink overlay (copying and patching only the tbds under `usr/lib` to add `arm64-macos` back) plus an xcrun shim pointing at it
3. **Repack the fat archive**: Xcode 26.6's libtool drops archive members Zig produced because of alignment (`libghostty_zcu.o` and friends, which carry a lot of ImGui/freetype members) → when the script detects a missing `_ghostty_init` it repacks in full from the 16 component archives
4. **Metal Toolchain**: Xcode 26 needs `xcodebuild -downloadComponent MetalToolchain` (one time, 688MB)
5. Linking needs `-lc++` (spirv-cross); the test target uses the app as TEST_HOST and links the xcframework itself

- **xcodegen 2.46 turned on `ENABLE_USER_SCRIPT_SANDBOXING = YES` by default** (2026-09-07): the "Bundle Ghostty Resources" script
  has to `rm -rf` / `cp -R` into the products directory, which the sandbox refuses outright with `deny file-read-data`, failing the whole build (symptom: `error: Sandbox: rm(…) deny(1)`).
  Turn it off explicitly in `project.yml`'s `settings.base`; it takes effect after another `xcodegen generate`.

## M1 additions

- Copied in `Features/Splits/{TerminalSplitTreeView,SplitView,SplitView.Divider}.swift`
- Inside `TerminalSplitLeaf`, `Ghostty.InspectableSurface` (the inspector split wrapper, which lives in the deleted InspectorView.swift) was replaced with a plain `Ghostty.SurfaceWrapper`
- Later in M1: TerminalSplitDropZone gained `.center` (center = swap); TerminalSplitLeaf carries PaneChrome and the Cmd drag-source overlay; SurfaceView.focusDidChange now calls objectWillChange.send() (`focused` is not @Published); InspectableSurface → SurfaceWrapper

## DisplayLink session quota (a macOS 26 environment trap, mitigated)

Symptom: at some point during development every build — M0 included, which had passed acceptance earlier — started failing every `ghostty_surface_new`,
logging `embedded_window: error initializing surface err=error.OutOfMemory`.

Diagnosis: added a temporary `@errorReturnTrace()` dump to surface_new in `src/apprt/embedded.zig` (Debug build);
the stack pointed at `video.display_link.DisplayLink.createWithActiveCGDisplays` (renderer.Metal.init).
CVDisplayLink is a deprecated API and macOS 26 puts a **per-login-session quota** on it: after enough creations within one session
(our test loops add up to hundreds of surfaces) Create starts failing. ghostty itself releases correctly (generic.zig:810),
but the quota does not come back when the process exits — only logging out and back in resets it, which is what explains "the same code worked yesterday and not today".

Mitigation: the engine overlay injects `window-vsync = false` (generic.zig:693 only builds a DisplayLink when vsync=true;
without vsync, rendering is still throttled by CoreAnimation). A user who wants vsync=true can log out, log back in and override it
with `window-vsync = true` under `[ghostty]` in config.toml.

On the side: the fat-archive repack in `scripts/build-ghosttykit.sh` was upgraded to "newest archive per name",
so it cannot mix optimization levels when several of them coexist in .zig-cache.
- M5: added ScrollingStrip/ScrollingStripView (the scrolling layout); StripDropDelegate mirrors the behaviour of TerminalSplitLeaf's private SplitDropDelegate (the zone computation reuses TerminalSplitDropZone); focus-follows-scroll is reported up through a PreferenceKey (hover focus drives the viewport for free)
- Focus fix: SurfaceView.focused's initial value went true → false (the old value lit a new pane's border before it had focus, a double-activation race); focus state is driven entirely by the become/resignFirstResponder callbacks

## NSHostingView's coordinate system is flipped (top-left)

`window.contentView` (an NSHostingView) has `isFlipped == true`: the y that `content.convert(locationInWindow, from: nil)`
returns is already measured **top-down**, not AppKit's traditional bottom-left. Flipping it again on the bottom-left assumption gives you
vertically mirrored coordinates — which mirrored the hover occlusion test (a floating pane dragged off the vertical centre was judged wrong)
and made the top-bar scroll-to-switch-workspace gesture land in the bottom 26pt of the window instead. Everything goes through
`MainWindowController.normalizedContentPoint` (which is isFlipped-aware); the regression test `testNormalizedContentPointTopLeft` pins the
semantics against a real host view.

## Hover occlusion is model geometry, not hitTest (spec v7 revision)

NSTrackingArea does not know about sibling views covering it (`.inVisibleRect` only clips against its own ancestor chain), so when a floating
pane sits on top of a tiled one, both layers get mouseMoved/mouseEntered. A hitTest approach does not work: while Cmd is held, every pane is
covered by a full-bleed SurfaceDragSource overlay (an ordinary NSView, so it is hit-testable), and the same goes for the overlay scrollbar
while it is briefly visible — hitTest would report a completely unobstructed pane as occluded (global hover dies for as long as Cmd is down).
The current approach, `HoverOcclusion.isOccluded`, is pure geometry (a floating rect with a higher z / a panel mask / the Scratchpad); when
occluded, SurfaceView synthesizes one mouseExited(-1,-1) (otherwise the core's hover coordinate freezes at the occlusion boundary and TUI hover
highlights stay stuck), and the first mouseMoved after leaving the occlusion re-enters. Drag sequences (type != .mouseMoved) skip the guard, so
selecting text across panes is unaffected.
Clicks work the same way: SurfaceView's localEventLeftMouseDown focus-transfer monitor used to decide a hit with
`hitTest == self` (which only tests its own subtree), so a pane covered by a floating pane
would steal the click focus — it now goes through the same surfaceIsOccluded guard.

## ghostty crashes when the test host exits (pre-existing, unrelated to the test logic)

After `xcodebuild test` finishes and the host app exits, ghostty can crash during shutdown if some case had just created a `Ghostty.SurfaceView`
(`ghostty_surface_new` runs inside init and starts the shell asynchronously) and released it as the case ended. It shows up as an extra host
launch in the log, `sentry: crash report written` (the next process to start files the previous process's crash), two
`Executed 0 tests` lines, and a crash file under `~/.local/state/ghostty/crash/`. Running any surface-creating case alone with `-only-testing`
reproduces it every time (verified on main with the pre-change code on 2026-09-03); a full run hits it occasionally. **It does not affect the
test verdict** (XCTest has already summed up its results before the crash and still reports TEST SUCCEEDED); for assertion failures look for the
`.swift:N: error:` lines and do not let `Executed 0 tests` mislead you. Real fixes would be: have the cases close the surfaces they create, or
skip surface release on exit when AppDelegate.isRunningTests.

## libghostty 1.3.1's `load_default_files` writes a 0-byte template

`ghostty_config_load_default_files` → `Config.loadDefaultFiles`: on macOS, when none of the four candidate files
(XDG `ghostty/config` / `config.ghostty`, and the same two under Application Support) exist, it calls
`writeConfigTemplate` to write a template to `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`; 1.3.1 uses a
Zig 0.15 buffered writer and never flushes it, so what lands on disk is **0 bytes**. The engine's own read skips it as
`FileIsEmpty`, but any "the file exists, therefore there is config" test is fooled by it (that is exactly how QuickTerm's first fallback layer
broke). QuickTerm no longer calls that API: `GhosttyDefaultConfig.userConfigFiles()` walks the same order and loads only regular files that
exist and are non-empty; the built-in fallback is loaded only when there is not a single one.

## Universal binary (arm64 + x86_64) builds

`GHOSTTYKIT_TARGET=universal scripts/build-ghosttykit.sh` → ghostty's `-Dxcframework-target=universal`
(`GhosttyLib.initMacOSUniversal`: `initStatic` for aarch64 and for x86_64, then a `LipoStep`). Zig cross-compiles
x86_64-macos without Rosetta, and the SDK overlay's tbds already carry the `x86_64-macos` target. The xcframework slice directory becomes
`macos-arm64_x86_64` and the archive name changes from `libghostty-fat.a` to `libghostty.a` — the script locates it dynamically with `ls macos-*/*.a`.
The fix for libtool dropping members is now **per architecture**: `lipo -thin` splits it and each slice is checked for `_ghostty_init`; a missing
architecture is repacked from the same-architecture component archives in the cache ((archive name, architecture) takes the newest, and only
single-architecture, **macOS-platform** archives count — a universal target also builds iOS/simulator slices whose arm64 archives share the name
and are newer, and mixing them in gets you `built for 'iOS'`; read the platform from the Mach-O `LC_BUILD_VERSION`), then `lipo -create` puts it
back together. Xcode Release defaults to `ARCHS = arm64 x86_64` and `ONLY_ACTIVE_ARCH = NO`, so once the xcframework holds both architectures
the app becomes a universal binary automatically; `scripts/make-release.sh` checks the product with `lipo -archs` for `RELEASE_ARCHS`
(arm64 x86_64 by default) before it goes on.
Day-to-day iteration still uses the default `native` (twice as fast).

## AppKit: a first responder view that leaves the window gets no resignFirstResponder

Verified with a standalone probe (a scratch script): after `makeFirstResponder(A)` and then `A.removeFromSuperview()`, the window's first
responder is silently reset and A **never receives** `resignFirstResponder`; calling `makeFirstResponder` on a view that is not in a window
returns true but never calls `becomeFirstResponder` (it does nothing at all). When SwiftUI rebuilds the hierarchy (Cmd+L, Cmd+T, switching
workspaces), SurfaceView is moved out of the old scroll view and into a freshly created one — exactly the first case. `focused` stays
true → several panes show an active border and a blinking cursor at once, and the hover guard `!focused` means they can never get focus again.
The fix: in `viewWillMove(toWindow: nil)`, note it down if we are the first responder, and take it back after `viewDidMoveToWindow` — but **only
while the first responder is still the window or nil** (the silent reset caused by the detach). If another responder has taken focus in the
meantime, never steal it (otherwise re-mounting the original pane during a dwindle insert takes back the focus just handed to the new pane;
the probe logs confirm it: a successful moveFocus followed immediately by a reclaim). All focusing in the controller goes through
`requestFocus(to:from:)` (record the intent → moveFocus → re-check 0.35s later and hand it over once more);
`becomeFirstResponder` tells the controller to clear the stale flags on the other panes (the single-focus invariant); hover and
`focusedSurface` treat the window's first responder as the truth; startup focus uses `Ghostty.moveFocus` (which waits for the mount).
Regression test `testToggleLayoutKeepsSingleFocus`.

## The userdata in engine callbacks can dangle (Ghostty.Surface frees asynchronously)

Upstream's `Ghostty.Surface.deinit` releases asynchronously with `Task.detached { @MainActor in ghostty_surface_free }`. Between the SurfaceView
being released and the surface being removed from the engine's table there is a window the width of one main-thread task hop; during it
`wakeup → ghostty_app_tick → drainMailbox → handleMessage` still fires action callbacks for that surface (`hasSurface` is true), and
`surfaceView(from:)` uses `Unmanaged.takeUnretainedValue()` to get back an already-released view → `objc_retain` EXC_BAD_ACCESS (in the system
.ips stack: a scrollbar action). In a full test run it looks like "a case hangs / the host crashes and restarts". The fix: (1) deinit frees
synchronously when it is already on the main thread (the window shrinks to zero); (2) `Ghostty.App` keeps a registry of live SurfaceViews
(registered in init, deregistered on the first line of deinit) and `surfaceView(from:)` consults it first, logging to stderr and returning nil
for a dangling entry. Before fix (1), one full run hit the guard 135 times (deterministically), so this was never a rare race.

**The trap is when you register**: the live registry has to record the view **before** `ghostty_surface_new` is called — it calls back
synchronously before it returns (`set_cell_size` and friends). Registering after `surfaceModel = …` makes the guard throw away the first
callback of the creation path as a dangling one (across the 70-case suite this produced 78 "false dangles" reliably, with
`SurfaceView.init → withCValue → performAction → setCellSize` on top of the stack).

## Close animation and SwiftUI view reuse (2026-09-04)

Closing a pane happens in two stages (`MainWindowController.beginClose/finishClose`): first mark `WorkspaceModel.closingPanes`
(the pane is still in the layout, focus has already gone to its successor), and only remove it for real once the 0.28s animation is done.
Two traps:

- **Replacing a split with a split at the same position reuses @State**: after dwindle closes A, the sibling subtree split(B,C) moves up into
  the view position of the original split(A,…), `TerminalSplitSubtreeView`'s `switch` still takes the `.split` branch → SwiftUI reuses
  `SplitBranchView` along with its latched closing state (closeProgress=1) → B is squeezed to zero width. The answer is not to add an `.id`
  (that remounts the subtree and flashes), but to latch the id of the leaf being closed, adopt the latched geometry in body only while that leaf
  is still a direct child leaf, and reset it in `.onChange(of: CloseKey)`.
- **A concurrent close does not go through perform**: a child process exiting goes `ghosttyDidCloseSurface → closePane`, which does not flush
  panes that are still fading out; the successor has to be computed against a layout where the other fading panes are already removed, or focus
  goes to a pane that is disappearing.

Also: `ScrollingStrip.Column` got a stable `id` (it used to take its ForEach identity from the first pane in the column, so closing that pane
rebuilt the whole column and detached/remounted every other pane in it).

## Browser panes / the PaneView abstraction (2026-09-04)

- **Polymorphic decoding of SplitTree leaves**: a base class `init(from:)` cannot construct a subclass, so the constraint became `PaneCodable`
  and leaves are dispatched by `kind` through `decodePane(from: superDecoder)` (a v3 archive with no kind is a terminal); the JSON shape is unchanged.
- **The truth about focus is "the first responder is the pane or one of its descendants"**: a browser pane's first responder is the internal
  WKWebView (`focusTarget`), and while the address bar is being edited it is the field editor
  (`NSTextView > _NSKeyboardFocusClipView > NSTextField > pane`). Hosting views have to report become/resign back to the pane, and the controller
  decides "does it hold focus" with `holdsFirstResponder`, not with the `focused` flag alone.
- **Never call resignFirstResponder on a WKWebView by hand**: WebKit's internal `_newFirstResponderAfterResigning` may only be called inside the
  makeFirstResponder flow, otherwise you get an NSInternalInconsistencyException. `PaneView.moveFocus` only resigns by hand for a pane that
  **is itself** the first responder.
- **Overriding mouseMoved in a WKWebView subclass gets you nothing**: its tracking area is owned by an internal observer object, and the events
  go to the observer. Hover-to-focus for non-terminal panes is driven by the PaneView container's own tracking area (`installsHoverTracking`).
- **Inserting a new pane synthesizes a mouseMoved**: when a neighbour's tracking area is rebuilt because its size changed, AppKit synthesizes one
  mouseMoved, and a mouse sitting over the old pane takes back the focus that was just handed away. Hover-to-focus has to respect the
  controller's pending focus intent (`paneMayReclaimFocus`).
- **Key-name normalization**: `charactersIgnoringModifiers` keeps Shift for symbol and number keys (Cmd+Shift+[ → "{"),
  so take the base key with `characters(byApplyingModifiers: [])`; fall back for synthesized NSEvents that have no CGEvent behind them.
- **The Edit menu swallows the terminal's Cmd+X/Z/A**: returning false from `menuHasKeyEquivalent` does not stop AppKit from enumerating menu
  items further (a disabled item consumes the key and beeps all the same); when focus is in the terminal you have to return true and give a
  target/action that hands the key to the terminal's keyDown.
- **libghostty forces wait-after-command on a surface that has a command** (file-manager panes): on exit it only sends
  SHOW_CHILD_EXITED and never closes; on macOS it launches through `login … bash -c "exec -l <cmd>"`, so the command has to be a single exec target.
- **WKWebView error pages**: `loadHTMLString(baseURL:)` does not enter history (Back stops working) — use `loadSimulatedRequest`;
  `drawsBackground` is private KVC, so check `responds(to: _setDrawsBackground:)` first.
- **A SwiftUI-hosted pane has no external width constraint**: if the PaneView returned by `NSViewRepresentable` contains a required width
  constraint internally (tab items <= 200 + fillEqually + pinned on both sides), Auto Layout turns it around and solves the pane itself to
  N x 200. Every constraint inside a pane that affects width has to be non-required; the tab bar ended up hand-laid-out
  (`BrowserTabBarView.layout()` computes frames from the available width — the trapezoid stacking and the overflow scrolling are only possible by
  hand anyway). **"Non-required" is not enough**: NSHostingView measures that NSView at a fitting priority of 500, so a width constraint at
  priority >= 500 still stretches a narrow pane (measured: an address bar at `>= 200 @750` stretched a 250pt-wide browser pane to 300pt and
  pushed the puzzle-piece button outside the pane). Minimum widths always use a priority below 500
  (see `BrowserPaneView.addressFieldMinimumPriority = 300`; the extension bar's minimum of 310 is one notch above it).
- **NSTrackingArea does not know about sibling occlusion**: when every tab carries its own tracking area, both tabs get mouseEntered inside the
  8pt band where adjacent trapezoids overlap (the area is a plain rectangle and has nothing to do with hitTest or z order). Hover has to be
  decided by a single tracking area on the container plus its own hit test.
- **`focusedPane` only searches paneList, and the Scratchpad is not in it**: with the Scratchpad focused it falls back to `paneList.first` (the
  first tiled pane). Actions that "apply to the focused terminal" (clear screen) have to pick their target from the window's real first
  responder, or they hit a pane the user cannot see.
- **ghostty's performable bindings**: on the alt screen the engine returns false for `clear_screen` and expects the host to hand the key to the
  program; the host cannot just let it through to AppKit (a menu key equivalent would eat it) — it has to call `surface.keyDown(with:)` explicitly.
- **Modifying the DOM unconditionally inside a MutationObserver callback = a microtask infinite loop**: the Web Store injection script used to
  assign `button.textContent` on every observer callback, and the assignment is itself a childList mutation → the callback fires again and the
  page's JS thread wedges (evaluateJavaScript never calls back). Do only guarded DOM work in the callback, and coalesce it with requestAnimationFrame.
- **The Cmd drag-source overlay swallows Cmd+click**: SurfaceDragSource's overlay sets acceptsFirstMouse, swallows mouseDown and never forwards
  mouseUp, so the engine never sees PRESS/RELEASE and Cmd+clicking a link (open_url fires on release) simply cannot happen. Both the overlay and
  the floating pane's Cmd session need "lifted without crossing the drag threshold = a plain click, forward the press and the release together to
  the pane itself"; you cannot forward on the press, because a drag may follow and then there is no release.
- **An ordinary scroll wheel's scrollingDelta is in lines, not points**: with `hasPreciseScrollingDeltas == false` one notch is about 1, so
  treating it as points means nothing scrolls; convert to a step size yourself. The horizontal pan monitor of the scrolling layout runs before
  view dispatch, so it has to let events through to the subview based on the hit test.
- **Read the focus before closing a tab**: when the closed webView is removed with `removeFromSuperview` AppKit silently resets the first
  responder to the window (same as the section above — no resign is sent), and by then `holdsFirstResponder` is already false; read the focus
  first, then remove, then `makeFirstResponder` explicitly.


## WKWebExtension (browser extensions, 2026-09-06)

- **Deployment target raised to 15.4**: the whole WKWebExtension family is macOS 15.4+, so `project.yml`'s `deploymentTarget.macOS` and
  `MACOSX_DEPLOYMENT_TARGET` have to move together, and the README's minimum with them (it now says macOS 15.4+).
- **The Swift names differ from the header class names** (the old names report "has been renamed" outright): `WKWebExtensionControllerConfiguration` →
  `WKWebExtensionController.Configuration`, `WKWebExtensionTabConfiguration` → `WKWebExtension.TabConfiguration`,
  `WKWebExtensionWindowConfiguration` → `WKWebExtension.WindowConfiguration`, `WKWebExtensionMessagePort` →
  `WKWebExtension.MessagePort`, `context.inspectable` → `isInspectable`.
- **The Dates in the `grantedPermissions` / `grantedPermissionMatchPatterns` dictionaries are expiry times, not grant times**:
  assigning `Date()` in bulk expires them on the spot (the permission is granted to nobody). Use the single-item
  `setPermissionStatus(.grantedExplicitly, for:)` instead (with no expirationDate = distant future). Content script `matches` need granting too:
  take `allRequestedMatchPatterns` (which includes content_scripts); granting only `requestedPermissionMatchPatterns` (= host_permissions) is not enough.
- **Every WKWebExtension class and protocol carries `WK_SWIFT_UI_ACTOR` (= @MainActor)**: `BrowserPaneView.Tab` has to be marked
  `@MainActor` to conform to `WKWebExtensionTab`, and then `tab.title = …` inside a KVO callback (a @Sendable closure) complains that a
  main-actor-isolated property cannot be mutated in a Sendable closure — use `MainActor.assumeIsolated` (these WebKit KVO callbacks always come in
  on the main thread). Conversely, pure functions (CRX parsing, Web Store URLs, scanning the Chrome directory) have to be marked `nonisolated`,
  or non-@MainActor test cases cannot call them.
- **A pane's `didCloseWindow` cannot live in deinit**: deinit is nonisolated and cannot reach the MainActor controller.
  The controller's removal paths (`removeFromActiveLayout` / `removeFromAnyWorkspace`) call `paneWillClose()` instead, which carries its own
  "report only once" flag.
- **`RunLoop.main.run(until:)` inside an async XCTest case does not drive WebKit's page loads**: the same `loadHTMLString`
  was still on about:blank after 5s in an async case (including a control group with no extension controller attached); a non-async case polling
  the main runloop finished it in 0.3s. To run an async install from a non-async case, start a `Task` and then spin the runloop waiting on a flag.
- **Content scripts do get injected into `loadHTMLString(baseURL:)`** (a real http domain as baseURL is enough); no custom
  scheme plus `WKWebExtensionMatchPattern.registerCustomURLScheme` is needed.
- **Reusing a WKWebViewConfiguration means detaching before attaching**: the configuration `window.open` hands back may already have a script
  message handler registered under the same name, and a second `add(_:name:)` throws an ObjC exception; call `removeScriptMessageHandler(forName:)` first.
- **Do not set `defaultWebsiteDataStore` on a non-persistent configuration**: only a persistent configuration (`Configuration(identifier:)`) attaches
  `.default()` and shares cookies with browsing tabs; the `.nonPersistent()` one used in tests stays isolated.
- **An extension's own pages need a WebView built from `context.webViewConfiguration`**: a main-frame load of `webkit-extension://…` (the options page,
  `tabs.create(runtime.getURL(…))`, `runtime.openOptionsPage()`) inside a WKWebView with an ordinary configuration is rejected outright by
  WebKit (`NSURLErrorResourceUnavailable`, and the page turns into our error page), because what it checks is
  `requiredWebExtensionBaseURL` on the configuration; conversely, a WebView built with an extension configuration cannot go to http(s). The header
  says it plainly: the app must swap the tab's web view when navigating between extension URLs and ordinary URLs — `addTab` picks the
  configuration by URL, and in `decidePolicyFor` a boundary crossing calls `rebuildWebView` to swap it in place (the tab identity and the tabId the
  extension sees stay the same). `controller.extensionContext(for: url)` only knows about **loaded** extensions.
- **`context.uniqueIdentifier` does not carry `baseURL` with it**: without setting `baseURL = webkit-extension://<id>/` explicitly, the origin of
  the extension's pages (`runtime.getURL`, page-side storage) gets a fresh random host on every launch. Set both, and only before load.
- **WebKit adds the extension items to a page's context menu itself**: when `WebContextMenuProxyMac` sees a webExtensionController attached to the
  page, it appends each extension's `contextMenus` items (separator included). Appending them again in your own `willOpenMenu` gives you duplicates,
  and besides, `context.menuItems(for: tab)` returns the **tab bar** right-click set (the tab context), not the page context.
- **`didCloseTab` has to be reported before the tab is detached from the pane**: WebKit synchronously calls back into `tab.window(for:)` during that
  call to work out the windowId for `tabs.onRemoved`, and if `tab.pane` is already nil the extension gets `windowId = -1`. For the same reason
  `indexInWindow` has to return `NSNotFound` when the tab is not in a window (returning 0 is claiming to be the first tab).
- **When closing a tab, read the "previously active tab" before the array gets shorter**: after `tabs.remove`, `activeTabIndex` is still the old value
  and `activeTab` already points at someone else, so `tabs.onActivated` either does not fire or fires with a previousTabId that was never active.
- **The test host is a real app**: `loadInstalled()` in `applicationDidFinishLaunching` has to be gated on `isRunningTests`
  (otherwise the extensions the user really installed end up in every test WebView and the toolbar cases go red with them), and under tests `shared`
  uses `.nonPersistent()` + a temp directory, so it never overwrites the user's `state.json` / `controller-id`.
- **The page → native install channel has to check its origin**: a handler registered with `add(_:name:)` lives in the page world and any frame can
  call it (`window.webkit.messageHandlers.<name>`). Register it in a private `WKContentWorld`, and on receiving a message verify
  `frameInfo.isMainFrame` + that `frameInfo.request.url` is a store detail page + that the id matches that page; otherwise any web page or iframe can
  raise the native install dialog with a single postMessage.

- **A failed background load gives you exactly one `WKWebExtensionContextErrorBackgroundContentFailedToLoad` and no JS reason** (2026-09-07):
  the way to diagnose it is to copy the extension directory, prepend a preamble to the background script — listen for `error` / `unhandledrejection`,
  wrap `console.*`, write it all into `chrome.storage.local` — and then read it back from one of the extension's own pages (a
  WebView built with `context.webViewConfiguration` loading `webkit-extension://<id>/x.html`) with `callAsyncJavaScript`. On real extensions this
  turned up three root causes:
  - **WebKit lacks `webNavigation.onHistoryStateUpdated` / `onReferenceFragmentUpdated`**: Stylish calls `addListener` at the top level of its service
    worker → TypeError → the background never starts.
  - **WebKit's `importScripts()` drains the microtask queue after evaluating each imported script** (Chrome does not; verified with a synthetic extension:
    importing an existing file and a missing one both drain it, while busy-waiting and `console.log` do not). Tampermonkey decides "were the listeners
    registered during the startup phase" with `let pt=true;(async()=>{await null;pt=false})()`, and at startup it does `importScripts("/test.js")` on an
    empty file — the flag flips right there, `tabs.onUpdated.addListener` then throws, `init` aborts, the popup's `runtime.connect` reports
    "No runtime.onConnect listeners", and it spins forever.
  - **Extension pages use the `webkit-extension:` scheme, not `chrome-extension:`**: Tampermonkey's Chrome build hard-codes
    `INTERNAL_PAGE_PROTOCOLS = ["chrome-extension:"]` and the background uses it to decide whether sender.url is one of its own pages, so the popup's
    `loadTree` is rejected as a foreign page ("this context doesn't have the permission") and the popup stays blank. The shim rewrites the literal
    `chrome-extension:` to `webkit-extension:` in every .js (only .js / .mjs; never html or json — the two schemes are the same length, so offsets in
    minified code are unaffected). Known side effect: the ChatGPT extension uses it as a storage key prefix (`codex:chrome-extension:persisted-atom:`),
    so after the scheme change its old values are orphaned once.
  - **An extension iframe embedded in a web page calling `tabs.query` → the UI process kills the page process for an invalid IPC** (symptom: our
    "the page process keeps crashing" error page; in `~/Library/Logs/DiagnosticReports/ExcUserFault_QuickTerm-*.ips` the stack is
    `WebProcessProxy::didReceiveInvalidMessage`; `log stream --predicate 'process == "QuickTerm"'` shows
    `Received an invalid message WebExtensionContext_TabsQuery from WebContent process` — `log show` does not find it at all).
    Clicking Stylish's icon injects a `webkit-extension://<id>/index.html` iframe into the current page, and the React app inside calls
    `tabs.query` immediately. Bisecting the APIs with a synthetic extension: from such an iframe, `tabs.* / windows.* / action.* / scripting.* /
    alarms.* / contextMenus.* / cookies.*` all get you killed, while `runtime.sendMessage`, `runtime.connect`, `runtime.getManifest`,
    `storage.*`, `i18n`, `permissions` and every `onXxx.addListener` work fine (**corrected 2026-09-08**: this used to say "the callback form
    gets no reply" and "the connect port disconnects immediately"; re-testing with a synthetic extension, neither holds — the callback form fires
    under all three background styles (a synchronous `sendResponse`, `return true` plus a delayed `sendResponse`, and a listener returning a
    Promise), and a port does carry a round trip. We were most likely led astray by the real disease, the storage partitioning below).
    The fix: inject `BrowserExtensionCompat.frameUserScript` into web page WebViews (document start, all frames, page world), which inside a
    `webkit-extension:` frame swaps those namespaces for proxies that relay through `runtime.sendMessage({__quickterm_relay})` to the background,
    where the shim makes the call and sends the result back, accepting only requests whose sender.url is the extension's own origin. The trap:
    `Object.defineProperty` on WebKit's namespace objects (`chrome.tabs`) silently does nothing, and the methods all live on the prototype
    (`Object.keys` does not see them), so the only way is to replace `globalThis.chrome` / `browser` wholesale (those two are ordinary writable data
    properties) — copy them into a plain object and assign it back.
  The first three are all solved by `BrowserExtensionCompat` (the fourth also needs the pane-side `frameUserScript`) rewriting the extension directory
  at install / startup load time: the manifest's `background.service_worker` points at `__quickterm-background.js` in the same directory
  (classic uses `importScripts`, module uses `import`, pulling `/__quickterm-compat.js` first and the original script second; keeping it in the same
  directory means relative importScripts paths inside the original still resolve against the original directory), while a `background.scripts` array
  simply gets an entry inserted at the front. The original `background` and the shim version are recorded under `__quickterm` in the manifest, so it is
  idempotent. `importScripts` inside the shim only skips the empty `.js` files found during the install scan (evaluating them does nothing anyway);
  everything else goes through the native one. The extension's own pages (popup, options page) are not injected with the shim for now — in the real
  cases the page side always had typeof guards. The file scan uses `enumerator(atPath:)` for relative paths: `enumerator(at:)` returns absolute URLs
  with symlinks resolved, and when the store directory is itself a link (kept in Dropbox) they do not match the `directory.path` prefix and the listing
  comes back empty. A worker path in the manifest containing `..` is never wrapped (`../../x.js` must not let us write outside the extension directory);
  the check is purely on the string — do not compare prefixes with `standardizedFileURL` / `resolvingSymlinksInPath`, because while the target file does
  not exist yet only one side of /var vs /private/var gets resolved and the prefixes stop matching.

- **For an extension iframe embedded in a web page, IndexedDB is a different, empty database, because WebKit partitions it by top-level site**
  (2026-09-08, the root cause of Stylish's sidebar showing "Login / Current Website 0 / No Styles Installed"): for one and the same
  `webkit-extension://<id>` origin, the service worker and the pages in the extension process share one IndexedDB (they can read each other's data and
  both list it in `indexedDB.databases()`), while the iframe inside a web page opening a database of the same name gets **a different, empty one** —
  `databases()` returns `[]`, `navigator.storage` is undefined, and `document.requestStorageAccess()` is refused outright
  ("The request is not allowed by the user agent…"); `localStorage` is separate in exactly the same way. `chrome.storage.*` is not affected
  (that is an extension API) and messaging works perfectly, which makes the symptom deeply misleading: the background has the token and the styles,
  the styles are injected into pages as usual, and the panel still shows you logged out with nothing installed. Stylish's sidebar happens to read both
  straight out of IndexedDB — installed styles from `stylishMV3/styles`, the login state from Firebase Auth's `firebaseLocalStorageDb`.
  The fix: in such a frame, `frameScript` replaces the whole of `indexedDB` with a facade (`BrowserExtensionCompat.frameIndexedDBScript`) that sends
  every request through `runtime.sendMessage({__quickterm_idb: …})` to the background shim (`backgroundIndexedDBScript`), which runs it in the
  extension's real partition (the service worker has both `indexedDB` and `indexedDB.databases()`). Several things you have to get right:
  - **The facade has to survive `instanceof`**: wrapper libraries like `idb` (both Stylish and Firebase use it) decide how to wrap a value by
    `value instanceof IDBRequest / IDBDatabase / IDBObjectStore / IDBIndex / IDBCursor / IDBTransaction`, and a value they do not recognize breaks the
    whole chain. The way to do it is `Object.setPrototypeOf(FacadeClass.prototype, NativeConstructor.prototype)` — the native prototype chains to
    `EventTarget.prototype` on its own, so `addEventListener` / `dispatchEvent` keep working (the instances really are `EventTarget`s: the classes
    `extends EventTarget`).
  - **After splicing the prototype, override the read-only getters with writable data properties**: `IDBDatabase.prototype.name` and the like are
    getter-only, and `this.name = …` inside a class constructor (strict mode) throws a TypeError outright; a `defineProperty(…, { writable: true })` on
    your own prototype to hold the slot is enough.
  - **A transaction does not survive one message round trip, but a batch does**: an IDB transaction auto-commits as soon as the microtask queue drains
    with no pending requests, and forwarding necessarily crosses a macrotask, so the transaction on the background side can only be short-lived. The
    first version made "one call = one independent transaction on the background", at the cost of transaction semantics collapsing entirely — measured
    with a synthetic extension (the same probe run against native IDB in the background and through the bridged iframe): `put ×2` followed by
    `tx.abort()` in a readwrite transaction left 0 records natively and 2 through the bridge; `put({id:1})` followed by an `add({id:9})` that is bound to
    raise ConstraintError rolled the whole transaction back natively (leaving only 9) while the bridge kept `[1, 9]`.
    What it does now is **batch**: the iframe-side `BridgeTransaction` no longer sends a message per request; it collects the requests issued within the
    same microtask into `_queue` and sends them at the end of the microtask as one `{ op: "batch", ops: [...] }`. The background's `runBatch` issues them
    in order inside **one real transaction** (a request's `onerror` does not `preventDefault`, so the transaction aborts exactly as it would natively),
    and the reply carries which request failed plus the results of the requests before it. The iframe side then replays the native event order: `success`
    for everything before the failure → `error` on the one that failed → `error` on the transaction → one `AbortError` for each request that had not
    finished → `abort` on the transaction. `abort()` simply voids the batch that has not been sent yet (nothing goes to the background), and inside an
    upgrade transaction `abort()` likewise replays not a single recorded operation and fails the `open` request with `AbortError`.
    Besides "which one failed", the reply also has to carry a **`done` mask**: when the whole batch rolls back, the requests ahead of the failure have not
    necessarily completed — a cursor's request goes to the back of the transaction queue after `continue()`, and when something throws synchronously none
    of the earlier requests have come back at all — and holes in `results` turn into `null` over the message channel, indistinguishable from a result that
    really is null. The ones that did not complete stay native-like and receive `AbortError`; they must not be reported as `success`.
    **What still differs**: a request issued from an event callback is already the next batch = the next transaction on the background, so
    "read a result, then decide what to write" is not one atomic transaction over the bridge; `abort()` cannot stop a batch that is already in flight;
    calling `preventDefault()` in a request's `error` event to keep the transaction going is not supported (the background aborted long ago);
    inside an upgrade transaction, calling `abort()` from the `success` callback of one of the recorded writes is also too late (those operations are
    already on their way); and **throwing** from the `upgradeneeded` callback does not stop it either (`dispatchEvent` does not rethrow a listener's
    exception to the caller) — only an explicit `abort()` counts. A `versionchange` transaction is still "the iframe records createObjectStore /
    createIndex / put …, and hands the lot to the background to replay inside its own `onupgradeneeded`", while cursors are run to completion by the
    background and the flattened result is sent back (capped at 5000 rows) and walked as a snapshot on the iframe side.
  - **The background cannot push `versionchange` into an extension iframe inside a web page**: measured, a background
    `chrome.runtime.sendMessage({...})` broadcast **does not reach** such an iframe (the iframe can register `chrome.runtime.onMessage` but never
    receives anything, and the background's Promise never gets a reply either). `runtime.connect` ports can push the other way, but a long-lived
    connection would pin the MV3 service worker forever, and our port would land in the extension's own `onConnect` listener. So we do only the two
    things we can: when another connection in this frame upgrades or deletes the database, send `versionchange` to the facade connections still open,
    as the native one would (`announceVersionChange`, with a weak registry — firebase-auth opens a new connection for every operation and never
    `close()`s, so strong references would pile up forever); and when the version changed on the background side, send one after the fact based on the
    `version` carried in each `batch` reply. **What we cannot do**: block someone else's upgrade while a connection stays open, the way the native one
    does — the background has no lifecycle signal for the iframe, so actually blocking it would let one crashed or navigated-away frame lock the
    database forever.
  - **Decode a cursor snapshot only once**: `send()` has already run the whole reply through `decode`, so `BridgeCursor` must not `decode(row.key)` a
    second time — `decode` walks a real `Date` instance as a plain object and a `Date` record turns into `{}`.
  - **`open(name)` without a version has to ask `databases()` first**: natively, when the database does not exist you get `upgradeneeded(0→1)`.
    Forwarding a bare `indexedDB.open(name)` to the background makes it create an empty v1 database out of nothing with `upgradeneeded` swallowed, so the
    extension's store-creating callback never runs — every later `transaction("store")` is a NotFoundError, that empty v1 database is left behind in the
    extension's real partition, and the `oldVersion` a later `open(name, 2)` sees has gone from 0 to 1 (so the upgrade switch skips the store-creating
    branch).
  - **Reaching the end of the snapshot is not the end of the iteration**: the background fetches one extra row to tell whether it was truncated
    (`rows.length > limit`; exactly limit rows is not truncation), and when the iframe walks off the end of a truncated snapshot it reports an error
    explicitly rather than `success(null)` — that would quietly erase the remaining records.
  - **`continue(key)` on a reverse cursor**: the snapshot is in descending order, so you want the first row `<= key`; with the forward `>= 0` comparison
    the very first candidate already satisfies it, and `continue(key)` degrades into `continue()` (no skip) — or, the other way round, reports the end of
    the iteration early.
  - **The bridge is only installed when the background really has the shim attached**: for extensions with no `background`, with only `background.page`
    (HTML, which we do not rewrite), with a `service_worker` path out of bounds, or whose shim write failed (`applyCompatShim` deliberately only logs),
    `__quickterm-compat.js` was never loaded by the background, the bridge has no far end, and installing it only makes every IDB call fail with
    "no response from the extension background" — worse than not installing it. `frameScript` first checks `runtime.getManifest().background` for signs
    of the rewrite (measured: WKWebExtension's `getManifest()` returns the rewritten manifest), and leaves the native partitioned database alone when
    there are none; when the manifest cannot be read it assumes the shim is there (better to keep the bridge).
  - **Values cross the channel with JSON semantics**: `Date` becomes a string, `undefined` is dropped, and a circular reference turns the whole reply into
    undefined, so keys, values and `IDBKeyRange` share one codec on both sides (`valueCodecScript`); `Blob` / `File` / `ArrayBuffer` do not make it across.
  `localStorage` is partitioned the same way, but it is a synchronous API and cannot be forwarded like this (the background is a worker, and there is no
  localStorage there at all), so it stays one copy per top-level site. The shim version number (`BrowserExtensionCompat.version`) goes up by one and
  installed extensions regenerate on their next launch, with no reinstall needed.
  Regression tests: `testEmbeddedExtensionFrameSharesIndexedDBWithBackground` (reads/writes, indexes, cursors, upgrade transactions, `open` without a
  version), `testEmbeddedExtensionFrameWorksWithIdbStyleWrapper` (the `instanceof` + `tx.done` the `idb` wrapper relies on),
  `testEmbeddedExtensionFrameRunsFirebaseStyleAuthPersistence` (the shape of firebase-auth's `persistence/indexed_db`: an
  `fbase_key` keyPath, `addEventListener` only, an availability probe of open→put→delete, polling, `InvalidStateError` after
  `close()`), `testEmbeddedExtensionFrameTransactionsAreAtomic` (rollback from `abort()` and from a failing request,
  event order, `versionchange`).

- **WebKit does implement `externally_connectable` (a web page messaging an extension), but on the page side it only hangs off `browser`** (2026-09-07,
  the root cause of Stylish permanently showing as logged out): measured with a synthetic extension, in an ordinary http page
  `typeof chrome === "undefined"` (the object is not even there), while `typeof browser === "object"`, `Object.keys(browser) === ["runtime"]`, and
  `browser.runtime` carries only the prototype methods `sendMessage` / `connect` (`Object.keys` is empty), with no `id` / `lastError` / `onMessage` —
  exactly the set Chrome gives an ordinary web page. `browser.runtime.sendMessage("<extension id>", msg)` really does reach the background's
  `chrome.runtime.onMessageExternal` (`onConnectExternal` likewise), `return true` plus an async `sendResponse` works, and sender carries `url` / `origin`.
  But sites in the Chrome ecosystem test for "is the extension there" with `"chrome" in window` + `chrome.runtime.sendMessage(id, msg, cb)`, every last
  one of them: that is exactly how userstyles.org hands the Firebase token to Stylish after login, and with no `chrome` nothing happens, silently → the
  extension stays logged out forever and shows "No Styles Installed". The fix needs only an alias, not a bridge of our own: the page-world user script
  generated by `BrowserExtensionCompat.externalMessagingScript` (document start, all frames) fills in
  `chrome.runtime.sendMessage` / `connect` (forwarding to `browser.runtime`; returning a Promise with no callback, calling the callback with Chrome
  semantics when there is one) whenever the address matches the `externally_connectable.matches` of some installed extension, and never touches an
  existing `chrome`. Note that WebKit attaches those two page-side stubs to every page **unconditionally** (even when no extension declares
  externally_connectable); it is delivery that checks authorization — a message to a non-matching origin just silently resolves to `undefined` (no error,
  and the background never sees it). So the match test only exists to avoid conjuring a `chrome` fingerprint on unrelated sites; it is not a security boundary.
- **The web WebView's UA spoofing leaks into the extension iframes embedded in web pages** (2026-09-08, the root cause of Stylish's sidebar showing
  "Login" while logged in): `browser.user_agent` spoofs Safari for web pages by default (`BrowserPaneView.Settings.safariUserAgent`),
  while the extension's background worker and the extension's own pages get WebKit's default UA (`…AppleWebKit/605.1.15 (KHTML, like Gecko)`,
  with no `Version/…` `Safari/…`). The `webkit-extension://…/index.html` iframe inside a web page runs in the web page's WebView, so
  **the two halves of one extension think they are in two different browsers**; Chrome has no such split (an extension's frames always report the
  browser's own UA).
  The real consequence: firebase-auth inside the Stylish panel decides `_shouldInitProactively` from the UA (`ua.includes("safari/") && !chrome/`),
  and on the Safari branch auth init has to `await` that gapi popup/redirect resolver, while in an MV3 build `_loadJS`, which loads the remote script,
  is an **empty implementation** (MV3 forbids remote code) — `gapi` never calls that `iframefcb…` back and the promise never settles:
  `_initializationPromise` hangs forever → `onAuthStateChanged` never fires once → the panel's `getCurrentUser()` never resolves.
  On the panel side the `userState` atom defaults to null, the only thing that writes it is a single `lf.getUser().then(...)` with no `.catch` and no
  retry, and the "fall back to the background's GET_USER" path only runs when `sf.getUser()` **resolves to a falsy value** — hence a permanent, silent
  "Login", while styles are injected as usual and the panel's "My Styles" works fine (those two go through storage / IndexedDB and never touch auth).
  Confirmed with an instrumented copy of the real extension: on an extension page, `init:proactive=false` → `onAuthStateChanged fired user` within 746ms;
  the same code in an iframe inside a web page gives `init:proactive=true` → not one event in the 30s after `init:resolver start`.
  Two fixes: (1) an extension's own pages opened as tabs do not get the spoof (`applySettings(to:extensionPage:)`) —
  on the `window.open` / `target=_blank` path WebKit hands the opener's configuration back, and only the opener knows which extension the popup belongs
  to, so it has to be passed in by `addTab(…, inheriting:)` **before** `install` (assigning it afterwards is too late, the UA is already stamped on);
  (2) inject `BrowserExtensionCompat.userAgentUserScript` (document start, all frames) into web page WebViews,
  which inside a `webkit-extension:` frame puts `navigator.userAgent` / `appVersion` back to WebKit's own
  (`BrowserPaneView.webKitUserAgent`: the fallback is WKWebView's default UA on macOS, measured once with a clean
  WKWebView when the first pane comes up, and overridden and broadcast as `browserExtensionsDidChange` so every tab re-attaches its scripts if it
  differs). Web pages still see the spoof; the HTTP request headers still carry it too (an extension cannot see its own request headers, so that is good enough).
  Regression tests: `testEmbeddedExtensionFrameKeepsTheBrowserUserAgent`, `testExtensionPageTabKeepsTheBrowserUserAgent`.
  **Not done yet**: an extension iframe inside a web page does not get the extension's CORS exemption (measured with a probe: `host_permissions` has no
  effect there, a JSON POST is preflighted, and without an `Access-Control-Allow-Origin` in the response it fails with `TypeError: Load failed`,
  even though the request did go out and the server did answer; the background worker and the extension's own top-level pages do have the exemption).
  Google's auth endpoints send CORS headers themselves, so the login chain is unaffected; Stylish's CDN config (`assets.userstyles.org`, no CORS headers)
  genuinely cannot be fetched from the panel, and it falls back to the built-in `LOCAL_CONFIG_JSON`. Fixing it would mean relaying fetch/XHR to the
  background as well, the same way as the IndexedDB bridge.

- **`chrome.runtime.getURL()` returns `webkit-masked-url://hidden/` inside a content script** (2026-09-07): using it as a `<script src>`
  to inject a web_accessible_resource still loads and runs (in the page's main world), but the string is masked, and `document.querySelectorAll("script")`
  reads it back the same way — an extension that string-compares against its own WAR URL breaks. Also, WebKit does honour MV3's `"world": "MAIN"` content
  scripts, and the isolated world and the main world cannot see each other's globals (same as Chrome).

## WKDownload progress UI (2026-09-06)

- **A download that fails at connect time never reaches `decideDestinationUsing`**: the destination is only negotiated after a response arrives, so a
  download to something like `http://127.0.0.1:9/` whose connection is refused jumps straight to `didFailWithError`. The list entry therefore has to be
  created **at the moment the delegate is attached** (in the `didBecome download` / `startDownload` callback), guessing the file name from the request
  URL first, with `decideDestinationUsing` filling in the real on-disk path afterwards;
  otherwise a failed download simply does not exist in the UI.
- **Progress comes from `WKDownload.progress`** (WKDownload conforms to `NSProgressReporting`): KVO on
  `fractionCompleted`, where the callback may not be on the main thread and a large file delivers one per packet — funnel it all through
  `DispatchQueue.main.async` and throttle to <= 10 Hz before touching the UI (`BrowserDownloadList.notifyInterval`). When the total size is unknown
  `totalUnitCount <= 0`, and the aggregate progress has to return nil (indeterminate) rather than 0.
- **WebKit calls `didFailWithError(NSURLErrorCancelled)` once more after a cancel**: the state machine has to be idempotent
  (`markFailed` only applies to entries that are still in flight), or "cancelled" gets flipped into "failed: cancelled".
- **Hiding a toolbar button means collapsing its spacing to 0 as well**: `isHidden` only stops the drawing; Auto Layout still reserves the width and the
  spacing, and the address bar comes out short for no visible reason. For a button sitting between the address bar and the extension bar, collapse only
  the **width (22 / 0) and the trailing spacing (-6 / 0)**; the 6pt on the leading side is the spacing that already exists between the address bar and the
  extension bar and has to stay — collapse both sides to 0 and, with no downloads, the address bar's rounded border runs straight into the extension bar's
  puzzle-piece button (a pane must contain no required width constraints; see the browser pane section above).
- **`NSButton.isFlipped == true`** (NSView / NSControl are false): in a custom-drawn button's `draw(_:)`, +y goes **down**.
  Arcs, arrows and checkmarks written for "y is up" come out as an up arrow, an upside-down checkmark and a progress ring that starts at 6 o'clock and
  runs counter-clockwise — and the ring itself is symmetric, so you cannot see it. Either `override var isFlipped: Bool { false }`
  (easiest when the class draws everything itself and never calls `super.draw`), or rewrite the whole geometry for y-down. A regression test can only go
  through `cacheDisplay(in:to:)` (which sets the CTM according to isFlipped) and read the bitmap;
  calling `draw(_:)` directly uses the current context's coordinate system and proves nothing.
- **`NSPopover.contentViewController` is a strong reference**: have the content controller hold the popover back in a `lazy var popover` and you have two
  objects locked in a cycle that never releases. The NSPopover has to be owned by **whoever presents it** (here, the pane); and testing "is the popover
  open" has to use an optional chain like `host?.isShown == true`, rather than instantiating the lazy popover just to read one `isShown`.
- **The destination for concurrent same-named downloads cannot be resolved from the disk alone**: WebKit creates the file in the networking process only
  after the reply to `decideDestinationUsing`, so two same-named downloads can both reach decideDestination before either file exists → both get the same
  path, and the second one fails with `NSURLErrorCannotCreateFile(-3000)` or simply hangs with no callback at all. Deduplication has to count destinations
  already handed to another in-flight download as taken.
- **Cancel in-flight downloads explicitly when the pane closes** (`paneWillClose`): the download list is private to the pane, and `WKDownload.delegate`
  is a weak reference (cleared automatically once the pane is gone), so without the cancel you get a pile of transfers running in the background with no
  UI and no delegate.


## Viewport alignment in the scrolling strip (2026-09-07)

- **"Reveal the new column" cannot hang off focus**: `insertNewPane` only changes `model.layout`, and the viewport scroll is decided by
  `ScrollingStripView` from focus — but focus lands **asynchronously** (`PaneView.moveFocus` has to wait for the new pane to be mounted in the window
  before it can `makeFirstResponder`, and a browser pane's first responder takes another beat through the internal WKWebView; measured 0.10s vs 0.05s for
  a terminal), so when `.onChange(of: layoutSignature)` fires, focus is usually **still on the old pane**. Revealing the new column then depends entirely
  on the chain "focus eventually lands and changes the PreferenceKey's reduced value" — and if any link in it is eaten (hover focus steals it, a focus
  round trip is coalesced into one SwiftUI update so the reduced value never changes, an old pane still carries the `focused` flag), the viewport stays
  where the previous focus was and the new column is stuck off the right edge: **it looks like "the new browser has the wrong width" (the focus border is
  its, the content is clipped by the window), when in fact the column widths, the pane frames and the offset formula are all correct**. The fix is to
  **reveal by identity**: the view remembers the set of pane ids from the previous round and, on a structural change, prefers scrolling to "the pane that
  appeared this round", regardless of when focus lands (`ScrollingStripView.revealTarget()`).
- **One `focused` flag, and the two paths have to pick the same pane**: `FocusedStripPaneKey.reduce` is **last one wins**,
  while a linear scan over the flag, `first { $0.focused }`, is **first one wins**. While views are being remounted, two panes can carry `focused` at once
  (AppKit sends no resign, see above), and then the two paths scroll to different places and never correct each other again. The decision always
  **starts from the window's real first responder** (`holdsFirstResponder`), and falls back to the last one, matching reduce.
- **`layoutSignature` deliberately excludes `widthFactor`** (so that right-drag width resizing does not hijack the viewport back to the focused column on
  every frame), at the cost of **nobody re-laying out the viewport when the column widths change**: after switching "columns visible per screen" or
  Cmd+Ctrl+=, the columns get narrower and the total width goes from overflowing to merely filling, and the old offset pushes the whole strip out of the
  viewport (measured: all 5 columns clipped off the left edge). There is a separate `clampOffset` that only **clamps** and does not follow focus, triggered
  by the column-width array itself (same for a window resize).
- **The viewport-alignment callbacks cannot live inside the zoom branch**: the body of `ScrollingStripView` is
  `if let zoomed = strip.zoomedPane { … } else { HStack … }`, so toggling zoom tears down and rebuilds the entire `else` branch;
  and **every structural operation clears zoom on the way past** (`insertingColumnRight`/`dropping`/`mergingOrSplitting`/`swapping`),
  which means that for "Cmd+B (or Cmd+clicking a link) after Cmd+F" the **zoom exit and the column insert land in the same SwiftUI update**:
  the rebuilt HStack only runs `onAppear` (recording the pane that was just inserted as "seen long ago"), and `onChange` does not fire for a
  just-created view (no `initial: true`), so reveal-by-identity fails completely and falls back to the old focus-only path.
  That is why `onAppear` (learning identities), `onChange(of: layoutSignature)` (reveal), `onChange(of: widths)` (clamp) and the reset on
  workspace switch **all hang outside the zoom branch** (on the `ZStack`); only `onPreferenceChange` (focus) and
  `onChange(of: pan)` (panning) stay on the HStack — they mean nothing unless the strip is laid out.
- **Clamping must not animate while a gesture is in progress**: Cmd + right-drag resizing writes `widthFactor` **per event**, and with the strip parked
  at the right end every event triggers a `clampOffset`; with a 0.15s easeOut the animation is restarted every frame, the viewport lags behind, the last
  column's right edge leaks empty space, and the content even slides against the finger. The test is **whether the column count changed**: if it did, a
  column was inserted or removed (let the animation cover it); if it did not, this is a pure width gesture, so assign with
  `Transaction.disablesAnimations` and stay under the finger (the same treatment as an in-progress `applyPan`).
- **Regression tests have to be able to assert with no focus at all**: a case that only calls `perform(.newBrowser)` is green in the test host — with no
  real mouse, focus lands within 0.1s and rescues the viewport. The version that actually catches the bug **inserts a column without requesting focus**,
  then asserts that the new column lies entirely inside the viewport (`testInsertedColumnIsRevealedWithoutFocusLanding`; before the fix the pane measured
  x 993.5…1314 against a viewport right edge of 1020). The zoom path has one of its own
  (`testInsertedColumnIsRevealedAfterZoomWithoutFocusLanding`: Cmd+F first, then insert a column without requesting focus).

## Multiple windows ("screens", 2026-09-08)

- **NSEvent local monitors are process-wide**: every controller installs one, so N windows means N of them, and every event runs through all of them.
  keyDown / scrollWheel had an `event.window === window` guard long ago; the `.flagsChanged` and drag-session branches needed one too.
- **A NotificationCenter observer with `object: nil` runs across windows**: the engine's close-surface / child-exited and "equalize all"
  did not matter with one window, but with several they equalize another screen too, or call paneWillClose on a pane that is not theirs. Each observer
  starts by checking ownership against `model.allPanes`.
- **A single-closure callback does not survive multiple windows**: a `var callback: (() -> Void)?` like `ThemeManager.onOverlayChanged` gets overwritten
  by the window created later, and the one created first never sees a live theme change again. Changed to token-based multi-listener.
- **The release order when closing a window**: `windowWillClose` tears down first (monitors, observers, Combine, paneWillClose for each pane),
  but the controller is removed from the registry only on the **next runloop** — engine callbacks may still be on the stack, and releasing a surface early
  is a UAF. Teardown clears the model, so "closing the last screen" has to archive before it closes, or what gets written on exit is an empty layout.
- **`NSApp.presentationOptions` is process-wide**: non-native fullscreen has to be accounted per window and refcounted, and re-applied when the key window
  changes; "the menu bar hides on every display while any window is fullscreen" is what the API does, and cannot be helped.
- **`NSScreen` instances cannot be persisted, and must not be held for long**: they are rebuilt whenever the display configuration changes. Menu items
  store the UUID string from `CGDisplayCreateUUIDFromDisplayID` and resolve it at use time; restoring a position falls back UUID → localizedName → main
  screen, and always `constrainFrameRect`s into the target screen's visible area — a display that is gone affects the position only, and never loses the
  window or its layout.
- **Continuous writes to disk have to guard against writing nothing**: any moment where "the model was cleared / the controller was torn down / every
  window is closed" can collide with the debounce timer. Filter out closed controllers before writing, skip the write entirely when the snapshot is empty,
  and write synchronously on exit.
- **Version detection has to match exactly**: an open range like `case current...` reads an archive from a future version as if it were the current one
  (and an unknown pane kind that fails to decode then loses the whole window to "lenient decoding"), and the next debounced write overwrites it.
  Accept only the identical version; back anything else up as a foreign file and start over.
- **A terminal pane only has a cwd once the shell has sent OSC 7**: a restored pane's `pwd` is nil until the user runs their first command, and continuous
  writes would overwrite the correct directory in the archive with null. Fall back to the `workingDirectory` it was created with when encoding.

## The blind spot in local NSEvent monitors (2026-09-09, the shared background of three bugs)

- **`addLocalMonitorForEvents` only sees the events delivered to this app**. `ModifierState.commandHeld` used to be written only by
  MainWindowController's `.flagsChanged` branch: when the Cmd **key-up** lands in another app (Cmd+Tab, Cmd+Space for
  Spotlight/Raycast, Cmd+Shift+3/4/5 screenshots, Cmd+H to hide, Cmd+clicking another window or the Dock, locking the screen, fast user switching),
  the local monitor never sees it and the flag is **stuck at true forever**. The user sees two things, which are really one:
  1. every tiled pane is covered by a `SurfaceDragSource` overlay whose `resetCursorRects` installs openHand /
     pointingHand **cursor rects** (not a one-shot `NSCursor.set()`, so moving the mouse does not heal it) → "the little hand never goes away";
  2. the overlay is a plain NSView, and without a `scrollWheel` override the wheel travels up **the overlay's own** responder chain (the SwiftUI
     container), while the terminal surface / WKWebView is its **sibling** subtree → "the terminal will not scroll any more",
     and `browserPaneClaimingScroll(under:)` walking superviews for a pane comes up empty for the same reason.
  Three fixes, all of them needed: **clear it on deactivate and rebuild from `NSEvent.modifierFlags` when coming back to the front** (no accessibility
  permission required — do not go installing a global monitor), **`sync(event.modifierFlags)` on the way past any mouse or wheel event** (the floating
  cursor path had been healing itself this way for ages; the tiled path had forgotten to), and **have the overlay forward the wheel to `clickTarget`**
  (so that even a briefly out-of-sync state cannot mean "it will not scroll").
- **Do not tear the overlay down by Cmd state while a drag is in progress**: releasing Cmd before the left button is a very common order, and the overlay
  is the live `NSDraggingSource` — remove it and `draggingSession(endedAt:)` has no view in the window to land on, so `PaneDragState` never gets to finish.
  The mounting condition is `commandHeld || dragSourceDragging`.

## A pane can briefly leave the window — `window == nil` does not mean "no controller" (2026-09-09)

While SwiftUI rebuilds the hierarchy (the new/close pane animation, switching workspaces, zoom, collapsing the Scratchpad), a pane's
`window` is nil for several runloop turns (`PaneView.moveFocus`'s exponential-backoff retry, `pendingCloseRequest` and
`if browser.window == nil { clearZoom() }` in `openLink` are all patches left behind by this).
The engine's `open_url` callback used to resolve only `surfaceView.controller` (= `window?.windowController`), and when it could not, it
**fell straight through to `NSWorkspace.shared.open(url)` — a Cmd+clicked link handed to the system default browser** (the "sometimes it opens in
Safari" the user reported). And `SurfaceDragSource.mouseUp` and `MainWindowController.floatingSessionEvent`
**synthesize** the click into PRESS/RELEASE and call it straight into the pane (bypassing AppKit's view dispatch; `clickTarget` only checks `superview`),
so clicks really do land during that window.

- `PaneView.controller` remembers the controller from **the last time it was mounted in a window** as a fallback; the controller gained
  `acceptsPaneOperations` (MainWindowController overrides it as `!isClosed`), so a closed screen cannot be resurrected.
  That also makes the multi-screen semantics more accurate: a pane that has left its window belongs to **its own screen**, not to whichever window is key
  right now.
- Anything that "only means something while really mounted in a window" has to check `window != nil` explicitly:
  `BrowserPaneView.requestPaneClose` is one — `closePane` only knows panes in the active workspace,
  so closing through the fallback controller is a silent no-op and it has to keep going through `pendingCloseRequest`.
- One more layer on the engine side: `Ghostty.App.routeLink` asks, in order, the pane's own controller → key → main → any terminal window,
  and the system exit is funnelled into a replaceable `Ghostty.App.systemOpener` (so tests can assert that nothing ever leaks out).
- A neighbouring defect: `SurfaceView.localEventLeftMouseDown` swallows the mouse-down that exists "only to transfer focus",
  and it must not swallow it while Cmd is held — the overlay needs that press to record `pendingClick`, and swallowing it makes the link vanish without
  a trace.

## WKWebExtension: a cached focusedWindow and silent background load failures (2026-09-09)

- **`WKWebExtensionContext.focusedWindow` is a cached value**: only `didFocusWindow(_:)` changes it, and WebKit never goes back and asks the delegate.
  `chrome.tabs.query({active:true,currentWindow:true})` is asking that value. Clicking an extension button in the toolbar
  **does not change the first responder**, so that click used to not make its own pane the "current window" — the message went to a tab in some other
  pane (on a different display, even, with multiple screens), and what the user saw was "clicking the icon does nothing". It is now reported in three
  places: on taking keyboard focus, **at the moment the button is clicked**, and in `windowDidBecomeKey` (multiple screens); and when the window being
  closed is the current one, the next turn hands it to a browser pane that is still alive rather than leaving it empty.
- **WebKit reclaims an MV3 background service worker after roughly 30 seconds idle**, and `performAction(for:)` does not guarantee waking it up.
  An extension that is pure `action.onClicked` (`default_popup: ""`, which is what Stylish is) cannot be woken = the icon is a dud.
  We now call `loadBackgroundContent` explicitly before the click and dispatch anyway on failure (one with a popup should still pop).
- **WebKit records these failures only in `context.errors` and never throws them at you**: measured on the user's machine, in 12 hours,
  **302** `WKWebExtensionContextErrorBackgroundContentFailedToLoad` (Code=6) with zero log output the whole time.
  You have to subscribe to `WKWebExtensionContext.errorsDidUpdateNotification` and log them deduplicated, or this class of problem is not investigable at all.
- **`NSButton.isEnabled = false` swallows clicks silently**: an extension action's enabled state is a snapshot from the last reload
  (the extension can change it at any time, and without a reload after navigation it is still showing the previous page's state). The button always stays
  clickable, disabled only dims it visually, and whether it can actually run is computed **at the moment of the click** against the current tab;
  navigation (`didChangeTabProperties(.URL)`) triggers one more reload.
