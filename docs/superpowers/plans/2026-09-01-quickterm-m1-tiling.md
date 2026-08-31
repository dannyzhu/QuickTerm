# QuickTerm M1（平铺核心）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 单窗口内的 Hyprland 式平铺：dwindle 分裂、方向焦点/交换/关闭/resize/等分/zoom、悬停激活、动态透明度、Cmd+鼠标拖拽移动/分裂/调整、隐藏标题栏 + gaps + accent 边框、WM 键位框架 + 菜单栏。

**Architecture:** MainWindowController（继承 M0 的 BaseTerminalController shim）持有 `SplitTree<Ghostty.SurfaceView>` 作为唯一状态；SwiftUI 纯渲染（移植 Ghostty 的 TerminalSplitTreeView/SplitView）；WM 键位经 NSEvent 局部监视器在到达 surface 前拦截；悬停焦点与非焦点变暗直接复用嵌入层现成机制（`focusFollowsMouse` 覆写 + `unfocused-split-opacity` 配置）。

**Tech Stack:** Swift/AppKit + SwiftUI、GhosttyKit、移植的 Ghostty Splits 组件（MIT）、XCTest。

**Spec:** `docs/superpowers/specs/2026-08-31-quickterm-design.md`（§3 架构、§4.1/4.2 功能、§5.1 键位表、§7 M1 行）

## Global Constraints

- 分支 `m1-tiling`（从 main 切出）；每任务收尾 commit
- 视觉参数（spec §1.1/§4.2）：**gaps_in=5、gaps_out=10、活动边框 2px accent `#7aa2f7`、非活动边框灰 `rgba(0x59,0x59,0x59,0.67)`、圆角 0、透明度 活动 0.985/非活动 0.96**
- 键位（spec §5.1，两处偏移已确认）：Cmd+Return 新建、Cmd+W 关 pane、Cmd+方向 焦点、Cmd+Shift+方向 交换、Cmd+J 切方向、Cmd+F zoom、Cmd+Ctrl+方向 resize 100px（+Shift 10px）、Cmd+Ctrl+= 等分、Alt+Tab/Cmd+[/] 循环 pane、Cmd+左/右拖 移动/调整
- **不拦截**终端级键（Cmd+C/V、Cmd+加减 0 等）——不在 WM 映射表内的组合一律放行给 surface
- 移植文件保留 MIT 头；删改记 `docs/porting-notes.md`
- `vendor/ghostty/macos/Sources/` 为移植事实来源；计划中的移植类代码若与 v1.3.1 源码有出入，以源码为准

**执行提示**：Ghostty 组件对新 pane 的插入语义是 `SplitTree.inserting(view:at:direction:)`（direction: `.left/.right/.up/.down`，ratio 0.5，自动清 zoom）；焦点空间导航 `focusTarget(for: .spatial(.left…), from:)`；resize `resizing(node:by:in:with:)`。签名以 `Sources/GhosttyEmbed/Features/Splits/SplitTree.swift` 为准。

---

### Task 1: 移植 Splits SwiftUI 渲染组件

**Files:**
- Create: `Sources/GhosttyEmbed/Features/Splits/{TerminalSplitTreeView.swift, SplitView.swift, SplitView.Divider.swift}`（拷自 `vendor/ghostty/macos/Sources/Features/Splits/`）
- Modify: `docs/porting-notes.md`（新增 M1 小节）

**Interfaces:**
- Produces: `TerminalSplitTreeView(tree: SplitTree<Ghostty.SurfaceView>, action: (TerminalSplitOperation) -> Void)`（需 `.environmentObject(_: Ghostty.App)`）；`TerminalSplitOperation` enum（`.resize(node:ratio:)`、`.drop(payload:destination:zone:)` 形态以源码为准）

- [ ] **Step 1: 拷贝三个文件**

```bash
cp vendor/ghostty/macos/Sources/Features/Splits/{TerminalSplitTreeView.swift,SplitView.swift,SplitView.Divider.swift} Sources/GhosttyEmbed/Features/Splits/
```

- [ ] **Step 2: 迭代编译**（`xcodegen generate && xcodebuild … build`，处理编译错误：缺辅助文件从 Helpers 补拷；引用已删的 app 功能按 M0 模式裁剪/加 shim，全部记 porting-notes）

- [ ] **Step 3: 全量测试仍绿后 commit**

```bash
git add Sources/GhosttyEmbed docs/porting-notes.md && git commit -m "feat: port Ghostty split tree SwiftUI renderers (MIT)"
```

---

### Task 2: SplitTree QuickTerm 扩展（dwindle/交换/切方向）+ 单元测试

**Files:**
- Create: `Sources/Splits/SplitTree+QuickTerm.swift`
- Test: `Tests/SplitTreeQuickTermTests.swift`

**Interfaces:**
- Consumes: `SplitTree`（Ghostty 移植版：`.inserting/.removing/.replacing/.resizing/.equalized/.focusTarget`、`Node.leaf/.split`、`Spatial`）
- Produces:
  - `func dwindleDirection(for view: ViewType) -> SplitTree.NewDirection`——焦点 pane 宽>高 → `.right`，否则 `.down`（Omarchy dwindle + force_split=2 语义）
  - `func swapping(_ a: ViewType, _ b: ViewType) -> SplitTree`——交换两叶位置
  - `func togglingSplitDirection(around view: ViewType) -> SplitTree`——就近父 split 的 direction 取反（horizontal↔vertical）

- [ ] **Step 1: 写失败测试**（要点：dwindle 方向按 frame 宽高比；swap 后两叶互换且树形不变；toggle 后父 split 方向取反；空树/单叶的边界不崩溃。测试用真 SurfaceView——TEST_HOST 内可创建，参照 `Tests/EngineSmokeTests.swift` 的 SurfaceHostingTests 写法）

```swift
@MainActor
func testSwappingExchangesLeaves() throws {
    let (a, b) = try makeTwoSurfaces()          // 辅助：创建两个 SurfaceView
    let tree = SplitTree(view: a).inserting(view: b, at: .right, of: a)  // 签名以源码为准
    let swapped = tree.swapping(a, b)
    // 交换后：左叶是 b，右叶是 a
    guard case .split(let s) = swapped.root else { return XCTFail() }
    XCTAssertEqual((s.left as? SplitTree<Ghostty.SurfaceView>.Node)?.leftmostLeaf(), b)  // 以源码实际 API 断言
}
```

- [ ] **Step 2: 跑测试确认失败** → **Step 3: 实现三个扩展函数** → **Step 4: 全绿** → **Step 5: commit `feat: dwindle/swap/toggle-direction SplitTree extensions`**

---

### Task 3: 隐藏标题栏窗口 + RootView 外壳（gaps）

**Files:**
- Create: `Sources/Windowing/HiddenTitlebarWindow.swift`（参照 `vendor/ghostty/macos/Sources/Features/Terminal/Window Styles/HiddenTitlebarTerminalWindow.swift` 的配方，为 QuickTerm 简化重写——无 tab、无 accessory）
- Create: `Sources/Windowing/RootView.swift`
- Modify: `Sources/App/AppDelegate.swift`（改用新窗口与 RootView；本任务仍渲染单 surface 树）

**Interfaces:**
- Produces: `HiddenTitlebarWindow: TerminalWindow`；`RootView(model: WorkspaceModel, ghostty: Ghostty.App, action: (TerminalSplitOperation) -> Void)`；`WorkspaceModel: ObservableObject { @Published var tree: SplitTree<Ghostty.SurfaceView> }`（Task 4 的 controller 持有并改写它）

- [ ] **Step 1: HiddenTitlebarWindow**（配方要点，照 Ghostty 源文件核对）：

```swift
import AppKit

/// 隐藏标题栏配方（源自 Ghostty HiddenTitlebarTerminalWindow，MIT；去 tab/accessory）
class HiddenTitlebarWindow: TerminalWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .fullSizeContentView, .resizable, .closable, .miniaturizable],
                   backing: backing, defer: flag)
        reapplyHiddenStyle()
    }
    override var title: String { didSet { reapplyHiddenStyle() } }  // macOS 15 set title 会取消隐藏
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

- [ ] **Step 2: WorkspaceModel + RootView**：

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
            Color(red: 0x1a/255.0, green: 0x1b/255.0, blue: 0x26/255.0)  // M3 前的固定底色（Tokyo Night bg）
            TerminalSplitTreeView(tree: model.tree, action: action)
                .padding(10)                     // gaps_out = 10（spec §1.1）
        }
        .ignoresSafeArea(.container, edges: .top)  // 内容延伸到隐藏的标题栏区
        .environmentObject(ghostty)
    }
}
```

- [ ] **Step 3: AppDelegate 换壳**——窗口改 `HiddenTitlebarWindow`；`model.tree = SplitTree(view: surfaceView)`（初始化单叶签名以源码为准）；`window.contentView = NSHostingView(rootView: RootView(model:…, ghostty:…, action: { _ in }))`。**注意**：叶子由 TerminalSplitLeaf → SurfaceScrollView 链渲染（Ghostty 组件内部已含尺寸同步），AppDelegate 不再直接持有 SurfaceScrollView；同步更新 `Tests` 里 `testWindowHostsSurfaceScrollView` 回归测试为「contentView 是 NSHostingView 且树非空」+「窗口 resize 后焦点 surface 的 frame 跟随」。

- [ ] **Step 4: 手动冒烟**（窗口无标题栏红绿灯、终端可用、resize 跟随、外圈 10px 底色缝）→ **Step 5: 全量测试绿 + commit `feat: hidden-titlebar window and RootView shell with gaps`**

---

### Task 4: MainWindowController（树状态 + surface 生命周期 + 悬停焦点 + 透明度）

**Files:**
- Create: `Sources/Windowing/MainWindowController.swift`
- Modify: `Sources/App/AppDelegate.swift`（瘦身为：建 controller、转发嵌入层接口）
- Modify: `Sources/App/AppDelegate+Ghostty.swift`（closeAllWindows/toggleVisibility 接到 controller）
- Test: `Tests/MainWindowControllerTests.swift`

**Interfaces:**
- Consumes: Task 2 扩展、Task 3 的 WorkspaceModel/RootView/HiddenTitlebarWindow
- Produces:
  ```swift
  final class MainWindowController: BaseTerminalController {
      let model: WorkspaceModel
      override var focusedSurface: Ghostty.SurfaceView? // 真实实现：跟踪 SurfaceView.focusInstant 最新者
      override var focusFollowsMouse: Bool { true }     // 悬停即焦点（spec §4.2）
      override var surfaceTree: SplitTree<Ghostty.SurfaceView> // 代理到 model.tree
      func newSurface(inheritingFrom: Ghostty.SurfaceView?) -> Ghostty.SurfaceView  // cwd 继承：baseConfig.workingDirectory = source.pwd
      func perform(_ action: WMAction)                  // Task 5 的动作入口
      func handleSplitOperation(_ op: TerminalSplitOperation)
  }
  ```

- [ ] **Step 1: 失败测试**（新建 pane 继承 cwd 字段；关闭最后 pane 树为空；`focusFollowsMouse == true`）
- [ ] **Step 2: 实现**要点：
  - `newSurface`: `var cfg = Ghostty.SurfaceConfiguration(); cfg.workingDirectory = inheritingFrom?.pwd; return Ghostty.SurfaceView(ghostty.app!, baseConfig: cfg)`（SurfaceConfiguration 字段名以源码为准）
  - 焦点跟踪：监听 `Ghostty.Notification.didFocusSurface`（嵌入层已有的通知名以源码为准，`moveFocus(to:)` 发的那个）维护 `focusedSurfaceRef`
  - 关 pane：`model.tree = model.tree.removing(view)`；surface 的进程退出回调（`close_surface_cb` → 嵌入层通知）同样走此路径；最后一个 pane 关闭 → `window.close()`
  - **动态透明度**：Ghostty.App 配置加载后追加 QuickTerm 覆盖——在 `Ghostty.Config` 加载链末尾 `ghostty_config_load_string`（若该 C API 不存在则用 `ghostty_config_load_cli_args` 等价方案，查 `include/ghostty.h`）注入：`background-opacity = 0.985`、`unfocused-split-opacity = 0.96`、`window-padding-x/y = 0`。嵌入层 SurfaceView 的 unfocused overlay（`SurfaceView.swift:228`）自动生效
  - `handleSplitOperation`: `.resize` → `model.tree = tree.resizing(...)`；`.drop` → remove+insert（Task 7 联调）
- [ ] **Step 3: AppDelegate 委托转发** → **Step 4: 手动验收**（开两个 pane 后鼠标悬停即高亮激活可输入、非焦点 pane 变暗）→ **Step 5: 测试绿 + commit `feat: MainWindowController with hover focus and dynamic opacity`**

---

### Task 5: WM 键位框架 + 菜单栏（§5.1 全表接线）

**Files:**
- Create: `Sources/Config/WMAction.swift`、`Sources/Config/KeybindingMap.swift`
- Create: `Sources/App/MainMenu.swift`（程序化主菜单）
- Modify: `Sources/Windowing/MainWindowController.swift`（`perform(_:)` 落全表动作 + 安装局部监视器）
- Test: `Tests/KeybindingMapTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum WMAction: String, CaseIterable {
      case newTerminal, closePane
      case focusLeft, focusRight, focusUp, focusDown
      case swapLeft, swapRight, swapUp, swapDown
      case toggleSplitDirection, toggleZoom, equalize
      case resizeLeft, resizeRight, resizeUp, resizeDown   // 100px；Shift 变体 10px
      case cyclePaneNext, cyclePanePrev
  }
  struct KeyCombo: Hashable { let key: String; let modifiers: NSEvent.ModifierFlags.RawValue }
  struct KeybindingMap {
      static let defaults: [KeyCombo: WMAction]
      func action(for event: NSEvent) -> (WMAction, precise: Bool)?  // precise = 带 Shift 的 resize 微调
  }
  ```
- 默认表（spec §5.1 逐条）：`cmd+return→newTerminal`、`cmd+w→closePane`、`cmd+←→↑↓→focus*`、`cmd+shift+←→↑↓→swap*`、`cmd+j→toggleSplitDirection`、`cmd+f→toggleZoom`、`cmd+ctrl+←→↑↓→resize*`（`+shift` 10px）、`cmd+ctrl+=→equalize`、`alt+tab/alt+shift+tab→cyclePaneNext/Prev`、`cmd+]/cmd+[→cyclePaneNext/Prev`

- [ ] **Step 1: 失败测试**（默认表覆盖 §5.1 全部条目；`action(for:)` 正确解析合成 NSEvent；**Cmd+C 返回 nil**——终端键放行）
- [ ] **Step 2: 实现 KeybindingMap**（NSEvent 解析用 `charactersIgnoringModifiers` + `keyCode` 处理方向键/return/tab）
- [ ] **Step 3: 监视器**（MainWindowController 安装 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`：窗口为 key 且映射命中 → `perform(action)` 返回 nil 消费；否则原样放行）
- [ ] **Step 4: perform(_:) 全表落地**（调 Task 2/嵌入层 API：`inserting(view: newSurface(...), at: dwindleDirection(...), of: focused)`、`removing`、`focusTarget(.spatial(...))` + `Ghostty.moveFocus(to:)`、`swapping`、`togglingSplitDirection`、zoom = `tree.zoomed==node ? nil : node`（以 SplitTree 的 zoom API 为准）、`equalized()`、`resizing(node: focusedNode, by: precise ? 10 : 100, in: direction, ...)`）
- [ ] **Step 5: MainMenu**（App/File/Pane/View 菜单，条目带同 key equivalent 作快捷键可见注册表；监视器先消费不影响菜单点击路径）
- [ ] **Step 6: 手动验收 §5.1 逐条** → **Step 7: 测试绿 + commit `feat: WM keybinding framework wired to full spec 5.1 table`**

---

### Task 6: Pane 视觉（accent 边框 + gaps_in + popin 动画）

**Files:**
- Modify: `Sources/GhosttyEmbed/Features/Splits/TerminalSplitTreeView.swift`（TerminalSplitLeaf 内加 QuickTerm chrome modifier——改动最小化并记 porting-notes）
- Create: `Sources/Splits/PaneChrome.swift`

**Interfaces:**
- Produces: `struct PaneChrome: ViewModifier`——`@ObservedObject surfaceView` 的 `focused` 驱动：2px 边框（焦点 `#7aa2f7` / 非焦点 `Color(white: 0x59/255.0).opacity(0.67)`）、`.padding(2.5)`（gaps_in=5 的一半，两叶相邻合成 5）、圆角 0；出现动画 `.scaleEffect(appeared ? 1 : 0.87)` + `.animation(.easeOut(duration: 0.2))`（popin 87% easeOutQuint 近似）

- [ ] **Step 1: 实现 PaneChrome + 挂到 TerminalSplitLeaf** → **Step 2: 手动验收**（分屏后焦点边框正确随悬停切换；新 pane 有弹入动画；gaps 视觉 5/10）→ **Step 3: 测试绿 + commit `feat: pane chrome — accent border, gaps, popin animation`**

---

### Task 7: Cmd+鼠标拖拽（移动/分裂 + 右键调整大小）

**Files:**
- Modify: `Sources/Windowing/MainWindowController.swift`（扩展局部监视器处理 `leftMouseDown/rightMouseDragged` + Cmd）
- Modify: `Sources/GhosttyEmbed/Features/Splits/TerminalSplitTreeView.swift`（若 drop 目标代码有 BaseTerminalController 依赖则通过 `handleSplitOperation` 解耦）

**Interfaces:**
- Consumes: 移植组件的 drop-zone 实现（`TerminalSplitLeaf` 的 `.dropDestination`/onDrop + `SurfaceView+Transferable`、`SurfaceDragSource`）、`handleSplitOperation(.drop(...))`
- Produces: Cmd+左键在 pane 上按下 → 以该 pane 为 payload 发起 NSDraggingSession（image 用 `surfaceView.snapshot` 或纯色块）；drop 中心 = `swapping`，drop 边缘 = `removing` + `inserting(at: 对应方向)`；Cmd+右键拖动 → 按拖动主轴换算 `resizing(node:by:in:)`（跟手，无步进）

- [ ] **Step 1: 接通 drop 路径**（`.drop` op → controller：中心 zone swap、边缘 zone remove+insert；zone 枚举名以移植源码为准）
- [ ] **Step 2: Cmd+左键发起拖拽**（监视器捕获 `.leftMouseDown` 且 `modifierFlags.contains(.command)` 且命中某叶 → `beginDraggingSession`；未按 Cmd 完全放行给 surface）
- [ ] **Step 3: Cmd+右键 resize**（`.rightMouseDown/.rightMouseDragged` + Cmd → 累计 delta 调 `resizing`；抬起结束）
- [ ] **Step 4: 手动验收**（拖到中心交换、四边分裂插入、右键拖平滑调整、不影响正常鼠标选中文本）→ **Step 5: commit `feat: cmd+drag pane move/split and cmd+right-drag resize`**

---

### Task 8: M1 收尾（验收清单 + 文档 + 合并）

- [ ] **Step 1: §5.1 + §4.2 全表手动验收**（逐条记录到 `docs/acceptance/m1.md`：每条 通过/说明）
- [ ] **Step 2: README 快捷键小节** + porting-notes M1 小节补全
- [ ] **Step 3: 全量测试绿 → commit → 合并 main → `git tag m1`**（注意 tag 与分支不同名的教训）

## Self-Review 记录

- **Spec 覆盖**：§7 M1 行的每一项——SplitTree 全套操作（T2/T5）、Cmd+拖拽（T7）、悬停焦点+动态透明度（T4）、隐藏标题栏+gaps+边框（T3/T6）、WM 按键+菜单同步（T5）——均有归属；§5.1 表由 T5 Step 1 测试逐条锁定。✅
- **占位符扫描**：无 TBD；移植类步骤以"编译绿+测试绿+porting-notes 记录"为客观验收，API 细节显式声明以 v1.3.1 源码为准。✅
- **类型一致性**：`WorkspaceModel/WMAction/KeybindingMap/PaneChrome/handleSplitOperation` 在 Produces/Consumes 两侧名称一致；SplitTree 扩展函数名 `dwindleDirection/swapping/togglingSplitDirection` 全文统一。✅
