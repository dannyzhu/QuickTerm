# 多「屏幕」（Screen）支持 实现计划（Phase 1–3）

> 用户已确认：① 每个屏幕各自独立的一组工作区；② Scratchpad 每屏一个；③ Phase 4（跨屏移动 pane / Spaces 恢复）**不做**。
> 分工：方案与对抗验证 Fable，实现 Opus。详细的单窗口假设盘点见
> `/private/tmp/claude-501/-Users-Danny-Documents-workspace-quickterm/e6fdbbbb-fb93-44bb-86da-29bcc5a0b0b0/scratchpad/multiscreen-analysis.txt`（含 file:line）。

## 0. 形状

单进程、多窗口。一个「屏幕」= 一个 `HiddenTitlebarWindow` + 一个 `MainWindowController` + 一个 `WorkspaceModel`（自己的 1..N 工作区、状态栏、浮动层、Scratchpad、面板）。
进程级只留一份：Ghostty 引擎、ThemeManager、ConfigStore/ConfigWatcher/KeybindingMap、BrowserExtensionManager（宿主聚合所有窗口）、SystemStatsService、`BrowserPaneView.settings`、state.json。
一个 pane 同一时刻只属于一个窗口（`PaneHostView` 返回同一个 NSView 实例）。跨窗口拖放**明确拒绝**（不做静默失败）。

**不变量（每个阶段都必须保持）**：现有全部用例通过；第一个窗口标题保持 `QuickTerm`（`EngineSmokeTests` 按标题找窗口）；`AppDelegate.controller` 保留为「key 窗口的控制器 ?? 第一个」的计算属性（6 个测试文件依赖）；焦点真相仍是窗口 first responder；SwiftUI 托管的 pane 内不得出现优先级 ≥ 500 的宽度约束。

---

## Phase 1 — 第二个屏幕能开到另一台显示器

### 1.1 App 级注册表与路由
- `Sources/App/AppDelegate.swift`：
  - `private(set) var controllers: [MainWindowController] = []`（唯一强引用）；`var controller: MainWindowController!` 改为计算属性 `NSApp.keyWindow?.windowController as? MainWindowController ?? controllers.first`。
  - `@discardableResult func newScreen(on screen: NSScreen?, inheritingFrom pane: PaneView?) -> MainWindowController`；`func closeScreen(_ c: MainWindowController)`；`func moveScreen(_ c: MainWindowController, to screen: NSScreen)`。
  - `applicationShouldTerminate`：对**所有**控制器 `flushPendingCloses()`，pane 计数求和。
  - `applicationWillTerminate`：保存所有控制器（Phase 3 换成 SessionStore；Phase 1 先只保存 primary，行为不变）。
  - `ghosttySurface(id:)`：遍历所有控制器的 `allPanes`。
  - `--open-browser`：作用于 primary。
- `Sources/App/MainMenu.swift`：`performWMAction` / `menuShortcutAllowed` 从固定 controller 改为 key 窗口的控制器（回退 primary）。

### 1.2 窗口创建与放置
- `MainWindowController.init` 增加参数：`screen: NSScreen?`、`index: Int`、`restoring: Bool`（Phase 3 用）。
  - 不再无条件 `window.center()`：给定 screen 时在其 `visibleFrame` 内居中；同屏已有窗口时 `cascadeTopLeft` 偏移；始终 `constrainFrameRect`。
  - 标题：index 0 = `QuickTerm`，其后 `QuickTerm 2`…（序号复用最小空位）。
  - 只有 primary 做 `restoreState()` / `ensureTemplateKeys`（Phase 2 上提）。
- `NSWindowDelegate`：`windowShouldClose`（有活跃 pane 时复用退出确认的计数与文案）、`windowWillClose`（`flushPendingCloses()` → 从注册表移除 → 让 key 交还 AppKit）。释放时序：`DispatchQueue.main.async` 后再移除注册表项，避免引擎回调栈上的 surface 被提前 free。

### 1.3 Window 菜单（无快捷键）
挂在系统标准 Window 菜单（`NSApp.windowsMenu` 已设，AppKit 自动追加窗口列表）。项：
```
新建屏幕
在显示器上新建屏幕 ▸      （NSMenuDelegate.menuNeedsUpdate 动态重建，列 NSScreen.localizedName，当前显示器加「（当前）」）
将此屏幕移到显示器 ▸      （当前显示器打勾且禁用）
在所有桌面显示            （切换 collectionBehavior 的 .canJoinAllSpaces；勾选态）
关闭屏幕
──────
最小化 ⌘M（已有） / 缩放 / 前置全部窗口
```
显示器项的 `representedObject` 携带 **displayUUID 字符串**（不是 NSScreen 实例——配置变化会重建）。`validateMenuItem`：无 key 窗口时禁用「移到显示器 / 关闭屏幕」。

### 1.4 本阶段必须一并修掉的三个单例（否则开第二个窗口立刻可见）
1. `ThemeManager.onOverlayChanged` 单闭包 → 多监听（`addListener(token:)` 或 `NotificationCenter`）：否则只有最后创建的窗口响应主题热切换与 `window.appearance`。
2. `BrowserExtensionManager.shared.host` 单 weak 指针 → App 级聚合宿主：`browserPanes` 合并所有控制器，`focusedBrowserPane` 取 key 窗口的，`openBrowserWindow` 开在 key 窗口。协议签名不变（测试里的桩不受影响）。
3. 配置重载：Phase 1 先让**只有 primary** 安装 ConfigWatcher，重载后 fan-out 到所有控制器（Phase 2 正式上提到 AppSession）。

### 1.5 通知与监视器串扰
- `MainWindowController` 里三个 `object: nil` 的观察者（`ghosttyCloseSurface` / `ghosttyChildExited` / `didEqualizeSplits`）开头加归属判断：`guard model.allPanes.contains(where: { $0 === view })`（`didEqualizeSplits` 用 `focusedPane` 属于本窗口）。
- 鼠标监视器 `.flagsChanged` 与会话分支补 `event.window === window` 守卫。
- 跨窗口拖放：`validateDrop` 里源 pane 不属于本控制器 → 拒绝（禁止光标），不做静默 no-op。

### 1.6 测试（新增 `Tests/ScreenRegistryTests.swift`）
- `newScreen(on:)` 后 `controllers.count == 2`，第二个窗口 frame 落在指定 `NSScreen.visibleFrame` 内，标题为 `QuickTerm 2`。
- `closeScreen` 后回到 1，且 weak 引用在一轮 runloop 后为 nil（监视器/观察者已释放）。
- 两个窗口时 `AppDelegate.controller` 随 key 窗口变化。
- 第二个窗口的工作区与 primary 相互独立（在 B 里 `perform(.newTerminal)` 不影响 A 的 `paneList`）。
- 通知过滤：A 里 `didEqualizeSplits` 不改变 B 的列宽。
- 扩展宿主：两个窗口各开一个浏览器 pane 后，`browserPanes` 计数 == 2。
- 用例结束必须关闭第二个窗口并把 key 交还 primary（避免污染后续用例）。

---

## Phase 2 — 进程级职责上提（AppSession）+ 全屏按窗口

- 新建 `Sources/Windowing/AppSession.swift`：持有 ConfigStore 加载、唯一 ConfigWatcher（含 `lastConfigContent` 去重）、`KeybindingMap`（控制器改为注入只读引用）、`SystemStatsService`（注入 `RootView`）、`fileManagerCommand` / `linkOpener` 等全局设置。
- `applyConfig` 拆分：`applyGlobalConfig(settings)`（每次重载**只执行一次**：KeybindingMap 重建、`BrowserPaneView.settings`、`BrowserExtensionManager.isEnabled`、`themeManager.updateFromConfig`、引擎 overlay 写盘）与 `controller.applyWindowConfig(settings)`（fan-out：`newTerminalCombo`、工作区数、`visibleColumns`、pane 间距等）。
- 非原生全屏改为按窗口：每窗口自己的 `savedFrame`，`NSApp.presentationOptions` 用引用计数（`acquire/release`，GhosttyEmbed 里已有同名机制可复用），并在 key 窗口切换时重算。残余现象（A 全屏时 B 所在显示器菜单栏也隐藏）写进 README。
- `SurfaceView` 初始 `scale_factor` 取自 `NSScreen.main`：新 pane 挂进非主显示器窗口后主动触发一次 `viewDidChangeBackingProperties`（混合 DPI 正确性）。
- 测试：改一次 config.toml，两个窗口的工作区数都变、`applyGlobalConfig` 只调用一次（计数桩）；两个控制器共享同一个 KeybindingMap 实例；窗口 A 全屏、B 成为 key 时 `presentationOptions` 正确恢复。

---

## Phase 3 — 存档 v5：多屏幕 + 显示器/frame 恢复 + 一键复原

### 3.1 结构
新建 `Sources/Windowing/SessionState.swift`（把 `PersistedState` 从控制器搬出来）：
```swift
struct DisplayRef: Codable { var uuid: String?; var name: String?; var frame: CGRect? }
struct WindowState: Codable {
    var id: UUID
    var layouts: [WorkspaceLayout]
    var floatings: [[FloatingPane]]?
    var activeIndex: Int
    var visibleColumns: Int?
    var display: DisplayRef?
    var frame: CGRect?          // 非全屏 frame，全局坐标
    var isFullscreen: Bool
    var joinAllSpaces: Bool
}
struct PersistedState: Codable { var version = 5; var windows: [WindowState]; var keyWindowID: UUID? }
```
**pane / layout 的编码字节不变**（`WorkspaceLayout`、`ScrollingStrip.Column`、`SplitTree`、`FloatingPane`、`PaneCodable` 一律不动）——终端 pane 的 `pwd`、浏览器 pane 的 tabs(url/title)+activeTab 已经在存了，这就是"一键复原"的内容。

### 3.2 迁移与降级
- 读档先探 `version`：`2...4` 走现有解码路径（含 legacy widthFactor 归一、floatings 补齐），包成 `windows[0]`（`display = nil`、`frame = nil` → 保持今天的主屏居中行为）。
- 首次迁移前把旧文件复制为 `state.pre-v5.json`（v5 不可降级：1.5.x 会拒读并在退出时用 v4 覆盖）。
- 解码失败 / 全空 → 全新开始（现状行为）。

### 3.3 显示器解析
`resolveScreen(for: DisplayRef) -> NSScreen?`：UUID（`CGDisplayCreateUUIDFromDisplayID`，`NSScreen.deviceDescription` 的 `NSScreenNumber` 取 displayID）→ `localizedName` → 主屏。恢复的 frame 一律 `constrainFrameRect` 进目标屏 `visibleFrame`；**绝不因为位置解析失败而丢窗口或布局**。

### 3.4 写盘时机（修掉"只在退出时存一次"）
- `SessionStore.scheduleSave()`：防抖 1.5s，触发点——布局变化（`model.layouts` / `floatings` / `activeIndex` 的 Combine sink）、窗口 move/resize 结束（`windowDidEndLiveResize` / `windowDidMove`）、屏幕开关、全屏切换、`applicationWillTerminate`（立即写）。
- 写盘仍是 `.atomic`；测试宿主（`AppDelegate.isRunningTests`）不写。

### 3.5 显示器热插拔
监听 `NSApplication.didChangeScreenParametersNotification`，**防抖 0.5s**（插拔/唤醒会连发多次）：把每个窗口重新约束进其目标屏（目标屏消失 → 主屏），全屏窗口重贴合。

### 3.6 测试
- v5 往返：两个窗口 → save → restore 得到两个窗口，`activeIndex`、floatings、列宽、pane 种类、终端 `pwd`、浏览器 tabs 一致。
- v4（以及无 floatings 的 v2）文件解码为单窗口且逐 pane 相等；迁移后 `state.pre-v5.json` 存在。
- `DisplayRef` 解析：UUID 命中 / 名称命中 / 全不命中回退主屏；frame 超出屏幕被约束回可见区域。
- 防抖保存：连续 10 次布局变化只写一次盘（用计数桩 / 观察文件 mtime）。
- 现有 `PersistedState` 版本断言（ConfigStoreTests / WorkspaceTests）随之更新为 v5。

---

## 交付
每个 Phase：分支 → 实现 → 定向测试 → 全套 → 对抗验证 → 修正 → 全套 → 提交 → 合入 main。三个 Phase 全部完成后重新 Debug 构建并重启应用；README（英/中）补「多屏幕」小节与硬限制（Spaces 不可程序化指定、全屏 presentationOptions 是进程级、v5 不可降级）；`docs/porting-notes.md` 记录多窗口相关的 AppKit 坑。
