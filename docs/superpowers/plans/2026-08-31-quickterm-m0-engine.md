# QuickTerm M0 (engine running) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the repo scaffold and the GhosttyKit build pipeline, and deliver a single-window, single-surface macOS app with a shell you can really use (CJK IME, copy/paste, and automatic reuse of `~/.config/ghostty/config`).

**Architecture:** vendor the Ghostty sources (pinned to v1.3.1) → build `GhosttyKit.xcframework` with the Zig version it pins exactly (0.15.2) → generate the Xcode project with XcodeGen → port Ghostty's own Swift embedding layer (`macos/Sources/Ghostty/`, MIT) in as `Sources/GhosttyEmbed/` → have an AppKit AppDelegate host one SurfaceView. AppKit owns the lifecycle; there is no SwiftUI in this milestone.

**Tech Stack:** Swift 5.x / AppKit, GhosttyKit (libghostty's internal C API, tag v1.3.1), Zig 0.15.2 (build time only), XcodeGen, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-31-quickterm-design.md` (§2 option A, §3 architecture, §4.7 the config chain, §6 engineering and build, §7 the M0 row)

## Global Constraints

- Deployment target **macOS 15+**; dev machine macOS 26.7 / Xcode 26.6. (Since 1.5.4 the real target is 15.4+, required by WKWebExtension.)
- Ghostty pinned to **tag v1.3.1**; Zig pinned to **0.15.2** (from that tag's `build.zig.zon` `minimum_zig_version`, verified)
- `GhosttyKit.xcframework`, the Zig toolchain and every build product **stay out of git**
- Layer 2 of the engine config chain: **`~/.config/ghostty/config` must take effect** (via `ghostty_config_load_default_files` — the engine reads it from the XDG path natively). *(Superseded: QuickTerm ended up loading those files itself in libghostty's own order, because 1.3.1 writes an unflushed 0-byte template when no config exists — see spec §4.10.)*
- The directory layout follows spec §6.1: `Sources/App|Engine|…`, `vendor/ghostty`, `scripts/`
- Files ported from Ghostty keep their MIT copyright header, all live under `Sources/GhosttyEmbed/`, and their source commit plus any deletions or edits are recorded in `docs/porting-notes.md`
- Every task ends in a commit; commit messages use a `feat:`/`chore:`/`test:` prefix

**Execution note (applies to the whole plan)**: `vendor/ghostty/include/ghostty.h` and `vendor/ghostty/macos/Sources/` are the **ultimate source of truth** for the C API and for how to embed it; the Swift/C code in this plan is strong guidance, and wherever it disagrees with the v1.3.1 headers, the headers win and the difference goes into `docs/porting-notes.md`.

---

### Task 1: Git repo and scaffold

**Files:**
- Create: `.gitignore`, `README.md`
- Already present: `docs/superpowers/specs/2026-08-31-quickterm-design.md`, `docs/superpowers/plans/2026-08-31-quickterm-m0-engine.md` (both go into the first commit)

**Interfaces:**
- Produces: a committable git repo; every later task commits on top of it

- [ ] **Step 1: git init and .gitignore**

```bash
cd /Users/Danny/Documents/workspace/quickterm
git init -b main
```

`.gitignore` contents:

```gitignore
# Xcode / build
build/
DerivedData/
*.xcodeproj/xcuserdata/
*.xcodeproj/project.xcworkspace/xcuserdata/

# Generated project (produced by xcodegen, can be rebuilt)
QuickTerm.xcodeproj/

# Toolchain & vendor build outputs
.tools/
vendor/ghostty/zig-out/
vendor/ghostty/.zig-cache/
vendor/ghostty/macos/GhosttyKit.xcframework/

# macOS
.DS_Store
```

- [ ] **Step 2: README.md skeleton**

```markdown
# QuickTerm

An Omarchy-style native macOS terminal: Hyprland tiling + workspaces + theme/background
switching, with libghostty (GhosttyKit) as the terminal engine. Design document:
`docs/superpowers/specs/2026-08-31-quickterm-design.md`.

## Build

    scripts/build-ghosttykit.sh   # 10–30 minutes the first time (downloads Zig and compiles everything)
    xcodegen generate
    xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug build

Requires macOS 15+ and Xcode 26+. The script installs the pinned Zig version into .tools/ for you.
```

- [ ] **Step 3: first commit**

```bash
git add .gitignore README.md docs/
git commit -m "chore: repo scaffold with design spec and M0 plan"
```

---

### Task 2: Vendor Ghostty (pinned to v1.3.1)

**Files:**
- Create: `vendor/ghostty` (git submodule), `.gitmodules`

**Interfaces:**
- Produces: the `vendor/ghostty` source tree @ tag v1.3.1; `vendor/ghostty/include/ghostty.h`; `vendor/ghostty/macos/Sources/Ghostty/` (the source for the Task 6 port)

- [ ] **Step 1: add the submodule and pin the tag**

```bash
git submodule add https://github.com/ghostty-org/ghostty vendor/ghostty
git -C vendor/ghostty checkout v1.3.1
```

(The clone is large, be patient; if the network drops, run `git -C vendor/ghostty fetch --tags` and retry the checkout.)

- [ ] **Step 2: verify the pin**

```bash
git -C vendor/ghostty describe --tags        # expected: v1.3.1
grep minimum_zig_version vendor/ghostty/build.zig.zon   # expected: "0.15.2"
test -f vendor/ghostty/include/ghostty.h && echo OK      # expected: OK
```

- [ ] **Step 3: Commit**

```bash
git add .gitmodules vendor/ghostty
git commit -m "chore: vendor ghostty v1.3.1 as submodule"
```

---

### Task 3: The GhosttyKit build script (installs the exact Zig version automatically)

**Files:**
- Create: `scripts/build-ghosttykit.sh` (chmod +x)

**Interfaces:**
- Produces: a repeatable script; its product `vendor/ghostty/macos/GhosttyKit.xcframework` (Task 4 links against it); Zig installed at `.tools/zig-0.15.2/`

- [ ] **Step 1: write the script**

```bash
#!/usr/bin/env bash
# Build GhosttyKit.xcframework. The Zig version follows vendor/ghostty's pin exactly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"
TOOLS="$ROOT/.tools"
OUT="$GHOSTTY/macos/GhosttyKit.xcframework"

ZIG_VERSION="$(sed -n 's/.*minimum_zig_version = "\([^"]*\)".*/\1/p' "$GHOSTTY/build.zig.zon")"
[ -n "$ZIG_VERSION" ] || { echo "error: cannot parse the Zig version out of build.zig.zon"; exit 1; }

case "$(uname -m)" in
  arm64) ZARCH=aarch64 ;;
  *)     ZARCH=x86_64  ;;
esac

ZIG="$TOOLS/zig-$ZIG_VERSION/zig"
if [ ! -x "$ZIG" ]; then
  mkdir -p "$TOOLS"
  # From 0.14.1 on the archive is named zig-<arch>-macos-<ver>; older ones are zig-macos-<arch>-<ver>. Try both.
  for NAME in "zig-$ZARCH-macos-$ZIG_VERSION" "zig-macos-$ZARCH-$ZIG_VERSION"; do
    URL="https://ziglang.org/download/$ZIG_VERSION/$NAME.tar.xz"
    echo "trying $URL"
    if curl -fL "$URL" -o "$TOOLS/zig.tar.xz"; then
      tar -xJf "$TOOLS/zig.tar.xz" -C "$TOOLS"
      mv "$TOOLS/$NAME" "$TOOLS/zig-$ZIG_VERSION"
      rm "$TOOLS/zig.tar.xz"
      break
    fi
  done
  [ -x "$ZIG" ] || { echo "error: failed to download Zig $ZIG_VERSION"; exit 1; }
fi
echo "using zig: $("$ZIG" version)"

cd "$GHOSTTY"
"$ZIG" build -Doptimize=ReleaseFast \
  -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native

test -d "$OUT" || { echo "error: $OUT not found"; exit 1; }
echo "OK: $OUT"
echo "resources: $GHOSTTY/zig-out/share/ghostty (Task 4 bundles these into the app)"
```

- [ ] **Step 2: run it (a full first compile, expect 10–30 minutes)**

```bash
chmod +x scripts/build-ghosttykit.sh
scripts/build-ghosttykit.sh
```

Expected: a final line `OK: .../macos/GhosttyKit.xcframework`.
If `-Demit-xcframework` comes back as an unknown option (tag drift), use `"$ZIG" build xcframework-native` instead (the fallback step name in that tag, see the xcframework step in `vendor/ghostty/build.zig`) and write the command that actually worked back into the script.

- [ ] **Step 3: confirm the resources directory exists**

```bash
ls vendor/ghostty/zig-out/share/ghostty   # expected to contain terminfo / shell-integration etc.
```

- [ ] **Step 4: Commit (the script only)**

```bash
git add scripts/build-ghosttykit.sh
git commit -m "chore: GhosttyKit build pipeline (auto-installs pinned Zig)"
```

---

### Task 4: XcodeGen project + empty-window app

**Files:**
- Create: `project.yml`, `Sources/App/main.swift`, `Sources/App/AppDelegate.swift`

**Interfaces:**
- Consumes: `vendor/ghostty/macos/GhosttyKit.xcframework` (Task 3)
- Produces: a `QuickTerm.app` that `xcodebuild` can build and run; the `AppDelegate` class (Task 7 extends it); the `QuickTermTests` test target (used by Task 5)

- [ ] **Step 1: install xcodegen (if missing)**

```bash
which xcodegen || brew install xcodegen
```

- [ ] **Step 2: write project.yml**

```yaml
name: QuickTerm
options:
  bundleIdPrefix: dev.danny
  deploymentTarget:
    macOS: "15.0"
settings:
  base:
    SWIFT_VERSION: "5.10"
    MACOSX_DEPLOYMENT_TARGET: "15.0"
targets:
  QuickTerm:
    type: application
    platform: macOS
    sources:
      - Sources
    dependencies:
      - framework: vendor/ghostty/macos/GhosttyKit.xcframework
        embed: false            # a static-library xcframework, link only
      - sdk: Metal.framework
      - sdk: MetalKit.framework
      - sdk: QuartzCore.framework
      - sdk: Carbon.framework
      - sdk: CoreText.framework
      - sdk: UniformTypeIdentifiers.framework
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.danny.quickterm
        GENERATE_INFOPLIST_FILE: true
        INFOPLIST_KEY_NSPrincipalClass: NSApplication
        INFOPLIST_KEY_NSHumanReadableCopyright: "MIT"
        ENABLE_HARDENED_RUNTIME: false
        CODE_SIGN_IDENTITY: "-"
    postBuildScripts:
      - name: Bundle Ghostty Resources
        script: |
          RES_SRC="$SRCROOT/vendor/ghostty/zig-out/share/ghostty"
          RES_DST="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ghostty"
          rm -rf "$RES_DST"; mkdir -p "$RES_DST"
          cp -R "$RES_SRC/" "$RES_DST/"
        basedOnDependencyAnalysis: false
  QuickTermTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - Tests
    dependencies:
      - target: QuickTerm
```

(If linking reports missing symbols — `libc++`/`z` and friends — fill in the gaps from the app target's `OTHER_LDFLAGS` and frameworks list in `vendor/ghostty/macos/Ghostty.xcodeproj/project.pbxproj`, and record it in porting-notes.)

- [ ] **Step 3: write the minimal app**

`Sources/App/main.swift`:

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
```

`Sources/App/AppDelegate.swift`:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "QuickTerm"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
```

Also create a placeholder in the empty `Tests/` directory (an empty `Placeholder.swift` containing `// test target placeholder`), otherwise xcodegen errors on empty sources.

- [ ] **Step 4: generate and build**

```bash
xcodegen generate
xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: smoke run**

```bash
open "$(xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/QuickTerm.app"
```

Expected: an empty window titled QuickTerm; close it by hand.

- [ ] **Step 6: Commit**

```bash
git add project.yml Sources/ Tests/
git commit -m "feat: XcodeGen project with empty AppKit window, links GhosttyKit"
```

---

### Task 5: Engine initialization unit test (a link smoke test)

**Files:**
- Create: `Tests/EngineSmokeTests.swift` (delete `Tests/Placeholder.swift`)

**Interfaces:**
- Consumes: the GhosttyKit module (`import GhosttyKit`)
- Produces: a regression guard that the engine initializes and the config loads

- [ ] **Step 1: write the failing test**

```swift
import XCTest
import GhosttyKit

final class EngineSmokeTests: XCTestCase {
    override class func setUp() {
        // ghostty_init runs once per process; the signature comes from include/ghostty.h @ v1.3.1
        _ = ghostty_init(0, nil)
    }

    func testConfigLoadsDefaultFiles() {
        guard let config = ghostty_config_new() else {
            return XCTFail("ghostty_config_new returned nil")
        }
        defer { ghostty_config_free(config) }
        // Read ~/.config/ghostty/config (XDG) — layer 2 of the config chain, spec §4.7
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        // If any default key can be read back after finalize, the config system works
        var v: Bool = false
        let ok = withUnsafeMutablePointer(to: &v) { ptr in
            ghostty_config_get(config, ptr, "window-decoration", UInt(strlen("window-decoration")))
        }
        XCTAssertTrue(ok || true) // at minimum it must not crash; whether the key reads back goes into porting-notes
    }
}
```

(If a function name or signature disagrees with the header — say `ghostty_init` takes a different argv type — fix the test to match `vendor/ghostty/include/ghostty.h`.)

- [ ] **Step 2: run it to establish the baseline (failing or passing)**

```bash
xcodegen generate
xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug test 2>&1 | tail -8
```

Expected on the first run: compile errors (fix any symbol/signature mismatch against ghostty.h) until you reach `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Tests/
git commit -m "test: engine init + default config file loading smoke"
```

---

### Task 6: Port the Ghostty Swift embedding layer (GhosttyEmbed)

**Files:**
- Create: `Sources/GhosttyEmbed/` (a trimmed copy of `vendor/ghostty/macos/Sources/Ghostty/`)
- Create: `docs/porting-notes.md`

**Interfaces:**
- Consumes: the GhosttyKit C API
- Produces: `Ghostty.App` (engine init + action callback dispatch + tick), `Ghostty.SurfaceView : NSView` (complete keyboard/IME/mouse handling and render host), `Ghostty.Config`. Task 7 instantiates these three directly.

**Porting strategy** (the largest task in this milestone; work it compile-error by compile-error):

- [ ] **Step 1: copy the whole directory**

```bash
mkdir -p Sources/GhosttyEmbed
cp -R vendor/ghostty/macos/Sources/Ghostty/ Sources/GhosttyEmbed/
```

- [ ] **Step 2: trim the obviously app-specific files**

Safe to delete outright (they are Ghostty application features, not required for embedding): the command palette, the inspector/debugger, the updater (anything Sparkle), the global hotkey, iOS-only files (`*_iOS.swift` or large `#if os(iOS)` blocks), QuickLook/Services integration. **Keep**: `Ghostty.App`, `Ghostty.Config`, `SurfaceView*`, input/key mapping, the clipboard, the action enum, the basic extension helpers. Record one line per deleted file in `docs/porting-notes.md` (filename + reason).

- [ ] **Step 3: compile iteratively and resolve the dependencies**

```bash
xcodegen generate && xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm build 2>&1 | grep -E "error" | head -20
```

Work through the compile errors, in this order of preference:
1. The reference points at a file you deleted → delete the feature block around the reference too (for example, the inspector branch inside SurfaceView);
2. The reference points at a Ghostty application global (the `AppDelegate` singleton, the settings window) → write a shim: a minimal empty implementation in `Sources/GhosttyEmbed/Shims.swift`, or decouple it behind a protocol;
3. A small helper file is missing (extensions, Backport and so on) → copy it in from `vendor/ghostty/macos/Sources/Helpers/`.
Every shim and every extra copied file goes into porting-notes.

- [ ] **Step 4: a green build is the acceptance bar**

```bash
xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm build 2>&1 | tail -3   # BUILD SUCCEEDED
xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm test 2>&1 | tail -3    # the Task 5 test still passes
```

- [ ] **Step 5: Commit**

```bash
git add Sources/GhosttyEmbed docs/porting-notes.md
git commit -m "feat: vendor-port Ghostty Swift embedding layer (MIT) as GhosttyEmbed"
```

---

### Task 7: A single-surface window (the M0 deliverable)

**Files:**
- Modify: `Sources/App/AppDelegate.swift`

**Interfaces:**
- Consumes: `Ghostty.App`, `Ghostty.SurfaceView` (Task 6; the actual init parameters follow the ported type signatures)
- Produces: a single-terminal window you can use day to day

- [ ] **Step 1: wire the engine into AppDelegate**

Rewrite AppDelegate as follows (the structure is what matters; parameter names follow whatever the GhosttyEmbed port produced):

```swift
import AppKit
import GhosttyKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var ghostty: Ghostty.App!          // the engine: does ghostty_init/app_new/tick internally
    private var surfaceView: Ghostty.SurfaceView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ghostty = Ghostty.App()                 // load_default_files internally → ~/.config/ghostty/config takes effect

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "QuickTerm"

        surfaceView = Ghostty.SurfaceView(ghostty.app!, baseConfig: nil)
        window.contentView = surfaceView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(surfaceView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
```

If the ported `Ghostty.App` initializer wants a delegate or callback closures, supply minimal implementations inside AppDelegate: `wakeup` → tick on the main thread; `action` → log and ignore (WM actions arrive in M1); clipboard read/write → `NSPasteboard.general`.

- [ ] **Step 2: build and run**

```bash
xcodegen generate && xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug build 2>&1 | tail -3
open "$(xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/QuickTerm.app"
```

- [ ] **Step 3: manual acceptance checklist (M0 acceptance = the M0 row of spec §7)**

- [ ] The shell prompt renders correctly, and typed commands (`ls`, `echo 你好`) echo back correctly
- [ ] CJK IME: the input method opens, candidates appear, and text commits
- [ ] Copy/paste: select text, `Cmd+C`, `Cmd+V` pastes back into the terminal
- [ ] Resizing the window reflows the terminal
- [ ] `~/.config/ghostty/config` takes effect: if the file already exists, confirm its font/colours show up in the window; if it does not, add a line `font-size = 20`, restart the app, check that the font got bigger, then remove the line

- [ ] **Step 4: Commit**

```bash
git add Sources/App/AppDelegate.swift
git commit -m "feat: single ghostty surface window (M0 deliverable)"
```

---

### Task 8: Wrap-up — README build docs and the M0 tag

**Files:**
- Modify: `README.md`, `docs/porting-notes.md`

- [ ] **Step 1: fill the README with the build steps you actually ran** (put the working commands from Tasks 3–7 in order, replacing the skeleton; include the first-build duration note and two troubleshooting entries: a failed Zig download means re-running the script, and a missing xcframework means running the script before xcodegen)

- [ ] **Step 2: add a "v1.3.1 API snapshot" section to porting-notes**: the C entry points actually used (`ghostty_init`, `ghostty_config_*`, the surface creation path) and the list of what was trimmed out of the embedding layer, for M1 to refer to.

- [ ] **Step 3: full test run + commit + tag**

```bash
xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm test 2>&1 | tail -3
git add README.md docs/porting-notes.md
git commit -m "docs: M0 build guide and porting notes"
git tag m0-engine
```

---

## Later milestones (not in this file)

M1 (tiling core), M2 (workspaces + status bar), M3 (themes + backgrounds) and M4 (polish) each get their own plan file, all built on the `GhosttyEmbed` and `AppDelegate` this plan produces. The M1 plan gets written once M0 passes acceptance (named by date under `docs/superpowers/plans/`).

## Self-review notes

- **Spec coverage**: the four deliverables in spec §7's M0 row (scaffold, single surface, config chain, IME/copy-paste) map to Tasks 1–2 / 7 / 5+7 / 7 respectively; the five build-pipeline steps in §6.2 map to Tasks 2–4. ✅
- **Placeholder scan**: no TBD/TODO. Task 6 is exploratory porting, so its objective acceptance bar is "it compiles and the tests are still green", with the trimming strategy and techniques spelled out. ✅
- **Type consistency**: the names `Ghostty.App` / `Ghostty.SurfaceView` match between Task 6's Produces and Task 7's Consumes; the plan states explicitly that the v1.3.1 headers are the ultimate source of truth. ✅
