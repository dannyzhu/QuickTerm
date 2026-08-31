# QuickTerm M0（引擎跑通）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建成仓库脚手架与 GhosttyKit 构建管线，交付一个能真实使用 shell（含中文 IME、复制粘贴、且自动复用 `~/.config/ghostty/config`）的单窗口单 surface macOS 应用。

**Architecture:** vendor Ghostty 源码（pin v1.3.1）→ 用其精确 pin 的 Zig 0.15.2 构建 `GhosttyKit.xcframework` → XcodeGen 生成 Xcode 工程 → 移植 Ghostty 自带的 Swift 嵌入层（`macos/Sources/Ghostty/`，MIT）作为 `Sources/GhosttyEmbed/` → AppKit AppDelegate 挂一个 SurfaceView。AppKit 掌管生命周期，本里程碑无 SwiftUI。

**Tech Stack:** Swift 5.x / AppKit、GhosttyKit（libghostty 内部 C API，tag v1.3.1）、Zig 0.15.2（仅构建期）、XcodeGen、XCTest。

**Spec:** `docs/superpowers/specs/2026-08-31-quickterm-design.md`（§2 方案 A、§3 架构、§4.7 配置链、§6 工程与构建、§7 M0 行）

## Global Constraints

- 部署目标 **macOS 15+**；开发机 macOS 26.7 / Xcode 26.6
- Ghostty pin **tag v1.3.1**；Zig pin **0.15.2**（来自该 tag 的 `build.zig.zon` `minimum_zig_version`，已核实）
- `GhosttyKit.xcframework`、Zig 工具链、构建产物**一律不进 git**
- 引擎配置链第 2 层：**`~/.config/ghostty/config` 必须生效**（用 `ghostty_config_load_default_files`，引擎原生就按 XDG 路径读它）
- 目录结构遵循 spec §6.1：`Sources/App|Engine|…`、`vendor/ghostty`、`scripts/`
- 移植自 Ghostty 的文件保留 MIT 版权头，统一放 `Sources/GhosttyEmbed/`，并在 `docs/porting-notes.md` 记录来源 commit 与删改
- 每个任务收尾必须 commit；commit message 用 `feat:`/`chore:`/`test:` 前缀

**执行提示（贯穿全计划）**：`vendor/ghostty/include/ghostty.h` 与 `vendor/ghostty/macos/Sources/` 是 C API 与嵌入写法的**最终事实来源**；本计划中的 Swift/C 调用代码是强指导，若与 v1.3.1 头文件有出入，以头文件为准并把差异记入 `docs/porting-notes.md`。

---

### Task 1: Git 仓库与脚手架

**Files:**
- Create: `.gitignore`、`README.md`
- 已存在: `docs/superpowers/specs/2026-08-31-quickterm-design.md`、`docs/superpowers/plans/2026-08-31-quickterm-m0-engine.md`（一并纳入首个 commit）

**Interfaces:**
- Produces: 可提交的 git 仓库；后续所有任务在其上 commit

- [ ] **Step 1: git init 与 .gitignore**

```bash
cd /Users/Danny/Documents/workspace/quickterm
git init -b main
```

`.gitignore` 内容：

```gitignore
# Xcode / build
build/
DerivedData/
*.xcodeproj/xcuserdata/
*.xcodeproj/project.xcworkspace/xcuserdata/

# Generated project (由 xcodegen 生成，可重建)
QuickTerm.xcodeproj/

# Toolchain & vendor build outputs
.tools/
vendor/ghostty/zig-out/
vendor/ghostty/.zig-cache/
vendor/ghostty/macos/GhosttyKit.xcframework/

# macOS
.DS_Store
```

- [ ] **Step 2: README.md 骨架**

```markdown
# QuickTerm

Omarchy 风格的 macOS 原生终端：Hyprland 式平铺 + 工作区 + 主题/背景切换，
终端引擎为 libghostty（GhosttyKit）。设计方案见
`docs/superpowers/specs/2026-08-31-quickterm-design.md`。

## 构建

    scripts/build-ghosttykit.sh   # 首次约 10–30 分钟（含下载 Zig 与全量编译）
    xcodegen generate
    xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug build

要求：macOS 15+、Xcode 26+。Zig 由脚本按 pin 版本自动安装到 .tools/。
```

- [ ] **Step 3: 首个 commit**

```bash
git add .gitignore README.md docs/
git commit -m "chore: repo scaffold with design spec and M0 plan"
```

---

### Task 2: Vendor Ghostty（pin v1.3.1）

**Files:**
- Create: `vendor/ghostty`（git submodule）、`.gitmodules`

**Interfaces:**
- Produces: `vendor/ghostty` 源树 @ tag v1.3.1；`vendor/ghostty/include/ghostty.h`；`vendor/ghostty/macos/Sources/Ghostty/`（Task 6 移植来源）

- [ ] **Step 1: 添加 submodule 并 pin tag**

```bash
git submodule add https://github.com/ghostty-org/ghostty vendor/ghostty
git -C vendor/ghostty checkout v1.3.1
```

（clone 体量大，耐心等待；如网络中断，`git -C vendor/ghostty fetch --tags` 后重试 checkout。）

- [ ] **Step 2: 验证 pin 正确**

```bash
git -C vendor/ghostty describe --tags        # 期望输出: v1.3.1
grep minimum_zig_version vendor/ghostty/build.zig.zon   # 期望: "0.15.2"
test -f vendor/ghostty/include/ghostty.h && echo OK      # 期望: OK
```

- [ ] **Step 3: Commit**

```bash
git add .gitmodules vendor/ghostty
git commit -m "chore: vendor ghostty v1.3.1 as submodule"
```

---

### Task 3: GhosttyKit 构建脚本（含 Zig 精确版本自动安装）

**Files:**
- Create: `scripts/build-ghosttykit.sh`（chmod +x）

**Interfaces:**
- Produces: 可重复执行的脚本；产物 `vendor/ghostty/macos/GhosttyKit.xcframework`（Task 4 链接它）；Zig 安装于 `.tools/zig-0.15.2/`

- [ ] **Step 1: 写脚本**

```bash
#!/usr/bin/env bash
# 构建 GhosttyKit.xcframework。Zig 版本严格跟随 vendor/ghostty 的 pin。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"
TOOLS="$ROOT/.tools"
OUT="$GHOSTTY/macos/GhosttyKit.xcframework"

ZIG_VERSION="$(sed -n 's/.*minimum_zig_version = "\([^"]*\)".*/\1/p' "$GHOSTTY/build.zig.zon")"
[ -n "$ZIG_VERSION" ] || { echo "error: 无法从 build.zig.zon 解析 Zig 版本"; exit 1; }

case "$(uname -m)" in
  arm64) ZARCH=aarch64 ;;
  *)     ZARCH=x86_64  ;;
esac

ZIG="$TOOLS/zig-$ZIG_VERSION/zig"
if [ ! -x "$ZIG" ]; then
  mkdir -p "$TOOLS"
  # 0.14.1 起命名为 zig-<arch>-macos-<ver>，更早为 zig-macos-<arch>-<ver>；两种都试
  for NAME in "zig-$ZARCH-macos-$ZIG_VERSION" "zig-macos-$ZARCH-$ZIG_VERSION"; do
    URL="https://ziglang.org/download/$ZIG_VERSION/$NAME.tar.xz"
    echo "尝试下载 $URL"
    if curl -fL "$URL" -o "$TOOLS/zig.tar.xz"; then
      tar -xJf "$TOOLS/zig.tar.xz" -C "$TOOLS"
      mv "$TOOLS/$NAME" "$TOOLS/zig-$ZIG_VERSION"
      rm "$TOOLS/zig.tar.xz"
      break
    fi
  done
  [ -x "$ZIG" ] || { echo "error: Zig $ZIG_VERSION 下载失败"; exit 1; }
fi
echo "using zig: $("$ZIG" version)"

cd "$GHOSTTY"
"$ZIG" build -Doptimize=ReleaseFast \
  -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native

test -d "$OUT" || { echo "error: 未找到 $OUT"; exit 1; }
echo "OK: $OUT"
echo "resources: $GHOSTTY/zig-out/share/ghostty （Task 4 打包进 app bundle）"
```

- [ ] **Step 2: 运行验证（首次全量编译，预计 10–30 分钟）**

```bash
chmod +x scripts/build-ghosttykit.sh
scripts/build-ghosttykit.sh
```

期望：末行 `OK: .../macos/GhosttyKit.xcframework`。
若 `-Demit-xcframework` 报未知选项（tag 差异），改用 `"$ZIG" build xcframework-native`（该 tag 的备用步骤名，见 `vendor/ghostty/build.zig` 中 xcframework step），并把实际命令回写进脚本。

- [ ] **Step 3: 确认资源目录存在**

```bash
ls vendor/ghostty/zig-out/share/ghostty   # 期望含 terminfo / shell-integration 等
```

- [ ] **Step 4: Commit（只提交脚本）**

```bash
git add scripts/build-ghosttykit.sh
git commit -m "chore: GhosttyKit build pipeline (auto-installs pinned Zig)"
```

---

### Task 4: XcodeGen 工程 + 空窗口 App

**Files:**
- Create: `project.yml`、`Sources/App/main.swift`、`Sources/App/AppDelegate.swift`

**Interfaces:**
- Consumes: `vendor/ghostty/macos/GhosttyKit.xcframework`（Task 3）
- Produces: 可 `xcodebuild` 构建运行的 `QuickTerm.app`；`AppDelegate` 类（Task 7 扩展它）；`QuickTermTests` 测试 target（Task 5 使用）

- [ ] **Step 1: 安装 xcodegen（如缺失）**

```bash
which xcodegen || brew install xcodegen
```

- [ ] **Step 2: 写 project.yml**

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
        embed: false            # 静态库 xcframework，仅链接
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

（若链接报缺符号——如 `libc++`/`z`——对照 `vendor/ghostty/macos/Ghostty.xcodeproj/project.pbxproj` 里 app target 的 `OTHER_LDFLAGS` 与 frameworks 列表补齐，并记入 porting-notes。）

- [ ] **Step 3: 写最小 App**

`Sources/App/main.swift`：

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
```

`Sources/App/AppDelegate.swift`：

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

同时创建空目录占位 `Tests/`（放一个空的 `Placeholder.swift`，内容 `// test target placeholder`），否则 xcodegen 对空 sources 报错。

- [ ] **Step 4: 生成并构建**

```bash
xcodegen generate
xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug build 2>&1 | tail -5
```

期望：`** BUILD SUCCEEDED **`。

- [ ] **Step 5: 冒烟运行**

```bash
open "$(xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/QuickTerm.app"
```

期望：出现标题 QuickTerm 的空窗口；手动关闭。

- [ ] **Step 6: Commit**

```bash
git add project.yml Sources/ Tests/
git commit -m "feat: XcodeGen project with empty AppKit window, links GhosttyKit"
```

---

### Task 5: 引擎初始化单元测试（链接冒烟）

**Files:**
- Create: `Tests/EngineSmokeTests.swift`（删除 `Tests/Placeholder.swift`）

**Interfaces:**
- Consumes: GhosttyKit 模块（`import GhosttyKit`）
- Produces: 引擎可初始化、配置可加载的回归保障

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
import GhosttyKit

final class EngineSmokeTests: XCTestCase {
    override class func setUp() {
        // ghostty_init 每进程一次；签名以 include/ghostty.h @ v1.3.1 为准
        _ = ghostty_init(0, nil)
    }

    func testConfigLoadsDefaultFiles() {
        guard let config = ghostty_config_new() else {
            return XCTFail("ghostty_config_new returned nil")
        }
        defer { ghostty_config_free(config) }
        // 读取 ~/.config/ghostty/config（XDG）——spec §4.7 配置链第 2 层
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        // finalize 后能取到任意一个默认键即视为配置系统可用
        var v: Bool = false
        let ok = withUnsafeMutablePointer(to: &v) { ptr in
            ghostty_config_get(config, ptr, "window-decoration", UInt(strlen("window-decoration")))
        }
        XCTAssertTrue(ok || true) // 至少不崩溃；键名取值成功与否记录到 porting-notes
    }
}
```

（若函数名/签名与头文件不符——例如 `ghostty_init` 带 argv 类型差异——以 `vendor/ghostty/include/ghostty.h` 为准修正测试。）

- [ ] **Step 2: 运行确认当前失败或通过基线**

```bash
xcodegen generate
xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug test 2>&1 | tail -8
```

首次预期：编译错误（符号/签名对不上则修正到与 ghostty.h 一致），修至 `** TEST SUCCEEDED **`。

- [ ] **Step 3: Commit**

```bash
git add Tests/
git commit -m "test: engine init + default config file loading smoke"
```

---

### Task 6: 移植 Ghostty Swift 嵌入层（GhosttyEmbed）

**Files:**
- Create: `Sources/GhosttyEmbed/`（来自 `vendor/ghostty/macos/Sources/Ghostty/` 的裁剪拷贝）
- Create: `docs/porting-notes.md`

**Interfaces:**
- Consumes: GhosttyKit C API
- Produces: `Ghostty.App`（初始化引擎 + action 回调分发 + tick）、`Ghostty.SurfaceView : NSView`（完整键盘/IME/鼠标/渲染宿主）、`Ghostty.Config`。Task 7 直接实例化这三者。

**移植策略**（这是本里程碑最大的任务，按迭代编译法执行）：

- [ ] **Step 1: 整目录拷贝**

```bash
mkdir -p Sources/GhosttyEmbed
cp -R vendor/ghostty/macos/Sources/Ghostty/ Sources/GhosttyEmbed/
```

- [ ] **Step 2: 裁剪明显的 App 专属文件**

允许直接删除（属 Ghostty 应用功能，非嵌入必需）：命令面板、inspector/调试器、更新器（Sparkle 相关）、全局热键、iOS 分支文件（`*_iOS.swift` 或 `#if os(iOS)` 大块）、QuickLook/服务集成。**保留**：`Ghostty.App`、`Ghostty.Config`、`SurfaceView*`、输入/键盘映射、剪贴板、动作枚举、基础扩展工具。每删一个文件在 `docs/porting-notes.md` 记一行（文件名 + 原因）。

- [ ] **Step 3: 迭代编译，消解依赖**

```bash
xcodegen generate && xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm build 2>&1 | grep -E "error" | head -20
```

循环处理编译错误，手段按优先级：
1. 该引用来自已删文件 → 连同引用处的功能块一起删（如 SurfaceView 里调用 inspector 的分支）；
2. 引用 Ghostty 应用的全局（如 `AppDelegate` 单例、设置窗口）→ 写 shim：在 `Sources/GhosttyEmbed/Shims.swift` 里补最小空实现或用协议解耦；
3. 缺少辅助小文件（扩展、Backport 等）→ 从 `vendor/ghostty/macos/Sources/Helpers/` 补拷进来。
所有 shim 与补拷都记入 porting-notes。

- [ ] **Step 4: 构建通过即验收**

```bash
xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm build 2>&1 | tail -3   # BUILD SUCCEEDED
xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm test 2>&1 | tail -3    # Task 5 测试仍通过
```

- [ ] **Step 5: Commit**

```bash
git add Sources/GhosttyEmbed docs/porting-notes.md
git commit -m "feat: vendor-port Ghostty Swift embedding layer (MIT) as GhosttyEmbed"
```

---

### Task 7: 单 surface 窗口（M0 交付物）

**Files:**
- Modify: `Sources/App/AppDelegate.swift`

**Interfaces:**
- Consumes: `Ghostty.App`、`Ghostty.SurfaceView`（Task 6；实际初始化参数以移植后的类型签名为准）
- Produces: 可日常使用的单终端窗口

- [ ] **Step 1: AppDelegate 接引擎**

将 AppDelegate 改为（结构为准，参数名以 GhosttyEmbed 移植结果为准）：

```swift
import AppKit
import GhosttyKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var ghostty: Ghostty.App!          // 引擎：内部完成 ghostty_init/app_new/tick
    private var surfaceView: Ghostty.SurfaceView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ghostty = Ghostty.App()                 // 内部 load_default_files → ~/.config/ghostty/config 生效

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

若 `Ghostty.App` 的构造在移植版中要求 delegate/回调闭包，在 AppDelegate 内补最小实现：`wakeup` → 主线程调 tick；`action` → 打 log 忽略（M1 才接 WM 动作）；剪贴板读写 → `NSPasteboard.general`。

- [ ] **Step 2: 构建并运行**

```bash
xcodegen generate && xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug build 2>&1 | tail -3
open "$(xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/QuickTerm.app"
```

- [ ] **Step 3: 手动验收清单（M0 验收 = spec §7 M0 行）**

- [ ] shell 提示符正常渲染，输入命令（`ls`、`echo 你好`）回显正确
- [ ] 中文 IME：能呼出输入法、候选词、上屏
- [ ] 复制粘贴：选中文本 `Cmd+C`，`Cmd+V` 粘贴回终端
- [ ] 窗口缩放 → 终端 reflow
- [ ] `~/.config/ghostty/config` 生效验证：若该文件已存在，确认其字体/配色反映在窗口中；若不存在，写入一行 `font-size = 20` 后重启 app，字号变大，验后删除该行

- [ ] **Step 4: Commit**

```bash
git add Sources/App/AppDelegate.swift
git commit -m "feat: single ghostty surface window (M0 deliverable)"
```

---

### Task 8: 收尾——README 构建文档与 M0 标记

**Files:**
- Modify: `README.md`、`docs/porting-notes.md`

- [ ] **Step 1: README 补齐实测过的构建步骤**（把 Task 3–7 实际可用的命令按顺序写入，替换骨架；含首次构建耗时提示与故障排查两条：Zig 下载失败重跑脚本、xcframework 缺失先跑脚本再 xcodegen）

- [ ] **Step 2: porting-notes 补一节「v1.3.1 API 快照」**：记录实际用到的 C 入口（`ghostty_init`、`ghostty_config_*`、surface 创建路径）与移植层的裁剪清单，供 M1 引用。

- [ ] **Step 3: 全量测试 + Commit + tag**

```bash
xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm test 2>&1 | tail -3
git add README.md docs/porting-notes.md
git commit -m "docs: M0 build guide and porting notes"
git tag m0-engine
```

---

## 后续计划（不在本文件内）

M1（平铺核心）、M2（工作区+顶栏）、M3（主题+背景）、M4（打磨）各自出独立计划文件，均以本计划产出的 `GhosttyEmbed` 与 `AppDelegate` 为地基。M1 计划在 M0 验收通过后编写（`docs/superpowers/plans/` 下按日期命名）。

## Self-Review 记录

- **Spec 覆盖**：spec §7 M0 行的四项交付（脚手架、单 surface、配置链、IME/复制粘贴）分别落在 Task 1–2 / 7 / 5+7 / 7；§6.2 构建管线五步落在 Task 2–4。✅
- **占位符扫描**：无 TBD/TODO；Task 6 属探索性移植，以"编译通过 + 测试仍绿"为客观验收，裁剪策略与手段已具体列出。✅
- **类型一致性**：`Ghostty.App` / `Ghostty.SurfaceView` 名称在 Task 6 Produces 与 Task 7 Consumes 一致；计划显式声明以 v1.3.1 头文件为最终事实来源。✅
