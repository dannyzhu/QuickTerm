# 浏览器 pane：WKWebExtension 扩展支持 + 下载进度 UI 实现计划

> 方案：Fable 5.1（本文件）。实现：Opus 5 agent。验证：Fable 对抗评审。分支 `feat-browser-extensions`。
> 两个任务顺序做（都改 `BrowserPaneView.buildChrome` 的工具条布局），每个任务：实现 → 定向测试 → 对抗验证 → 修正。

**目标**
- A：浏览器 pane 能加载并运行 WebExtensions（Chrome / Firefox 格式）：从 Chrome Web Store 安装、从本机 Chrome 配置目录导入已装扩展、启用/禁用/移除、扩展动作按钮 + popup、options 页、权限提示、右键菜单项。
- B：下载时地址栏右侧显示进度；多个下载可下拉查看进度、取消、清除、在 Finder 中显示。

**约束（项目既有规则，必须遵守）**
- 所有配置项都要出现在 `ConfigStore.template`（注释行 + 默认值）、`ConfigStore.parse`、README（英/中）配置表与模板、`ConfigStoreTests` 的键清单里。
- 新文件加进 `Sources/`/`Tests/` 后必须 `xcodegen generate`。
- 测试宿主会读用户真实的 `~/.config/quickterm/config.toml`，不要断言控制器上的默认值；`BrowserPaneView.settings` 用前保存、用后还原。
- 跑测试：`xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug test -only-testing:QuickTermTests/<Class>` 必须 `nohup … &` 放后台并轮询日志（前台 Bash 10 分钟会被砍）；同一时刻只能有一个 xcodebuild。全套约 50s，115+ 用例，全绿才算完成；文件管理器子进程用例偶发超时，重跑一次即可。
- 焦点真相 = 窗口 first responder；WKWebView 不能手动 `resignFirstResponder`；SwiftUI 托管的 pane 内部不能有必需的宽度约束（会反过来改 pane 宽度）；NSControl 的 mouseDown 不能在没有真实抬起时直接调用。详见 `docs/porting-notes.md`。
- 不要 `screencapture` 全屏；不要改用户的 config.toml。
- 提交信息用中文、`-F` 文件；结尾 `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`。**实现 agent 不提交**——改动留在工作区，由主会话提交。

**部署目标**：`project.yml` `deploymentTarget.macOS` 15.0 → **15.4**（WKWebExtension 最低要求）。README 两处"macOS 15+" → "macOS 15.4+"。

---

## Task A：WKWebExtension 支持

### A.1 WebKit API（本机 SDK 26.5 已核实，全部 macOS 15.4+）
- `WKWebExtension(resourceBaseURL:)`（Swift async，目录或 ZIP，需含 manifest.json）；属性 `displayName / displayVersion / version / requestedPermissions / optionalPermissions / requestedPermissionMatchPatterns / optionalPermissionMatchPatterns / hasOptionsPage / icon(for:)`。
- `WKWebExtensionContext(for: extension)`：`uniqueIdentifier`（我们设为扩展 id）、`isLoaded`、`grantedPermissions: [WKWebExtensionPermission: Date]`、`grantedPermissionMatchPatterns: [WKWebExtensionMatchPattern: Date]`、`setPermissionStatus(_:for:)`、`optionsPageURL`、`action(for: tab) -> WKWebExtensionAction?`、`performAction(for: tab)`、`menuItems(for: tab) -> [NSMenuItem]`、`loadBackgroundContent`、`inspectable`。
- `WKWebExtensionController(configuration:)`：`WKWebExtensionControllerConfiguration(identifier: UUID)`（持久，扩展 storage 落盘）/ `.nonPersistent()`（测试用）；`configuration.defaultWebsiteDataStore = .default()`（扩展与标签共享 cookie）；`load(_:)`/`unload(_:)`、`extensionContexts`、`delegate`；标签事件：`didOpenWindow/didCloseWindow/didFocusWindow/didOpenTab/didCloseTab(_:windowIsClosing:)/didActivateTab(_:previousActiveTab:)/didSelectTabs/didDeselectTabs/didChangeTabProperties(_:for:)`。
- `WKWebViewConfiguration.webExtensionController`：每个标签的 WebView 配置都要设；`createWebViewWith` 给的 configuration 也要设（window.open 的标签）。
- 代理 `WKWebExtensionControllerDelegate`（全部可选）：`openWindows(for:)`、`focusedWindow(for:)`、`openNewWindow(using: WKWebExtensionWindowConfiguration, for:, completionHandler: (WKWebExtensionWindow?, Error?))`、`openNewTab(using: WKWebExtensionTabConfiguration{window,index,url,shouldBeActive,…}, for:, completionHandler: (WKWebExtensionTab?, Error?))`、`openOptionsPage(for:completionHandler:)`、`promptForPermissions(_:in:for:completionHandler: (Set<Permission>, Date?))`、`promptForPermissionToAccess(urls:…)`、`promptForPermissionMatchPatterns(…)`、`didUpdate(action, for:)`、`presentPopup(for action: WKWebExtensionAction, for:, completionHandler: (Error?))`、`sendMessage(…to applicationWithIdentifier…)` 与 `connectUsing(messagePort…)`（原生消息：回调 error，不支持）。
- `WKWebExtensionAction`：`icon(for:)`、`label`、`badgeText`、`isEnabled`、`presentsPopup`、`popupPopover: NSPopover?`（WebKit 自带的 popup 弹出层，直接 `show(relativeTo:of:preferredEdge:)`）、`popupWebView`、`closePopup()`、`menuItems`。
- 协议 `WKWebExtensionTab`（全部可选；对象须是 NSObject 子类）：`window(for:)`、`indexInWindow(for:)`、`webView(for:)`、`title(for:)`、`url(for:)`、`pendingURL(for:)`、`isLoadingComplete(for:)`、`isSelected(for:)`、`activate(for:completionHandler:)`、`setSelected(_:for:completionHandler:)`、`close(for:completionHandler:)`、`loadURL(_:for:completionHandler:)`、`reload(fromOrigin:for:completionHandler:)`、`goBack/goForward(for:completionHandler:)`、`zoomFactor(for:)`/`setZoomFactor`、`size(for:)`、`shouldGrantPermissionsOnUserGesture(for:)`（返回 true）。
- 协议 `WKWebExtensionWindow`：`tabs(for:)`、`activeTab(for:)`、`windowType(for:)`（.normal）、`windowState(for:)`（.normal）、`isPrivate(for:)`（false）、`frame(for:)`/`screenFrame(for:)`、`focus(for:completionHandler:)`、`close(for:completionHandler:)`。
- 权限常量：ActiveTab Alarms ClipboardWrite ContextMenus Cookies DeclarativeNetRequest(±Feedback/WithHostAccess) Menus NativeMessaging Scripting Storage Tabs UnlimitedStorage WebNavigation WebRequest。`WKWebExtensionMatchPattern(string:)`、`.allURLs()`、`.allHostsAndSchemes()`。

### A.2 文件与职责
1. **`Sources/Panes/BrowserExtensions.swift`** — `@MainActor final class BrowserExtensionManager: NSObject, WKWebExtensionControllerDelegate`
   - `static let shared`；测试可 `init(configuration: WKWebExtensionControllerConfiguration, storeDirectory: URL)`（shared 用 `configurationWithIdentifier(持久 UUID，存 `<store>/controller-id`)` 与 `~/Library/Application Support/QuickTerm/Extensions/`）。
   - 数据：`struct Record: Codable { id, source: "webstore"|"chrome"|"local", version, installedAt, enabled }` 存 `<store>/state.json`；`final class Installed { record, extension: WKWebExtension, context: WKWebExtensionContext }`；`private(set) var installed: [Installed]`（按名字排序）。
   - `var isEnabled: Bool`（config `browser-extensions`；false 时全部 unload、`controller` 不挂到 WebView 配置）。
   - `func loadInstalled() async`：遍历 `<store>/<id>/`，`WKWebExtension(resourceBaseURL:)` → context（`uniqueIdentifier = id`）→ 授予 `requestedPermissions` 与 `requestedPermissionMatchPatterns`（全部，Date.distantFuture 不必，用 `Date()`）→ `enabled` 才 `controller.load`。坏扩展只记日志跳过。
   - `func install(fromWebStore id: String, progress: @escaping (String) -> Void) async throws -> Installed`：`WebStore.downloadURL(id:)` = `https://clients2.google.com/service/update2/crx?response=redirect&prodversion=131.0.0.0&x=id%3D<id>%26installsource%3Dondemand%26uc&acceptformat=crx2,crx3` → `URLSession` 下载 → `CRX.zipData(from:)` → 写临时 zip → `ditto -x -k`（Process，/usr/bin/ditto）解到临时目录 → 校验 manifest.json 存在 → 移到 `<store>/<id>/`（已存在先删 = 更新）→ 加载并记录。
   - `func importFromChrome(profile: URL = ~/Library/Application Support/Google/Chrome/Default) async -> (imported: Int, skipped: Int, failed: [String])`：扫 `Extensions/<id>/<version>/manifest.json`，取最高版本目录（按语义化比较），跳过：已安装、manifest 有 `theme`、`app`、无 `name`；复制目录到 store，加载。
   - `func setEnabled(_:for:)`、`func remove(_:)`（unload + 删目录 + 记录）、`func openOptions(for:)`（`context.optionsPageURL` 在焦点浏览器 pane 新标签打开）。
   - 宿主接口 `protocol BrowserExtensionHost: AnyObject { var browserPanes: [BrowserPaneView] { get }; var focusedBrowserPane: BrowserPaneView? { get }; func openBrowserWindow(url: URL?) -> BrowserPaneView? }`；`weak var host`（MainWindowController 实现：browserPanes = 所有工作区的 BrowserPaneView（含浮动），focused = 持 FR 的，否则最近激活的；openBrowserWindow = openBrowserPane 并返回）。
   - 代理实现：openWindows → host.browserPanes；focusedWindow → host.focusedBrowserPane；openNewTab → (configuration.window as? BrowserPaneView) ?? focused ?? first，`addTab(url: configuration.url ?? home, activate: configuration.shouldBeActive)`，回调 tab；openNewWindow → host.openBrowserWindow(url: configuration.tabURLs.first) 回调 pane；openOptionsPage → 新标签；三个 prompt → NSAlert（sheet 到 key window，否则 runModal）："扩展「X」请求权限：…" [允许][拒绝] → 回调全部或空集；didUpdate(action) → `NotificationCenter.default.post(name: .browserExtensionActionDidUpdate, object: context)`；presentPopup → 找 `action.associatedTab` 所属 pane（`(tab as? BrowserPaneView.Tab)?.pane`）或 focused，`pane.presentExtensionPopup(action)`；sendMessage/connect → `completionHandler(NSError(domain: "QuickTerm", code: 1, …不支持原生消息…))`。
   - `static func extensionID(fromWebStoreURL:) -> String?`：`chromewebstore.google.com/detail/<slug>/<id>` 或 `chrome.google.com/webstore/detail/<slug>/<id>`，id = 32 个 a–p 字母。
   - `enum CRX { static func zipData(from data: Data) -> Data? }`：magic "Cr24"；v2：header = 16 + publicKeyLength + signatureLength（两个 LE UInt32 在 offset 8/12）；v3：header = 12 + headerLength（LE UInt32 在 offset 8）；越界返回 nil。
   - 通知名 `Notification.Name.browserExtensionsDidChange`（安装/移除/启停后 post）。
2. **`Sources/Panes/BrowserExtensionUI.swift`**
   - `final class BrowserExtensionToolbar: NSView`：手工布局（无 Auto Layout 宽度约束！），每个已启用且 `context.action(for: tab) != nil` 的扩展一个 22×22 按钮（图标 `action.icon(for: 16)`，badge 小圆标签，`isEnabled`），点击 → `context.performAction(for: tab)`；末尾拼图按钮（`puzzlepiece.extension` SF Symbol）→ `NSMenu`：每个扩展一项（名字，✓ 表示启用；子菜单：启用/禁用、选项…（有 options 时）、移除…）；分隔；「从 Chrome 导入已安装扩展…」「打开 Chrome Web Store」「打开扩展文件夹」。`intrinsicContentSize` 宽 = 按钮数×24 + 拼图 24；无扩展时只剩拼图。监听两个通知重建。`reload(for tab:)`。
   - `presentExtensionPopup(_ action:)` 在 BrowserPaneView：找到对应按钮（没有则用拼图按钮）→ `action.popupPopover?.show(relativeTo: btn.bounds, of: btn, preferredEdge: .maxY)`。
   - Web Store 注入脚本（`WKUserScript`，documentEnd，主框架）：URL 含 `/detail/` 时在页面右下角加固定按钮「添加到 QuickTerm」，点击 `window.webkit.messageHandlers.quicktermExtension.postMessage({id})`（id 从 location.pathname 取）。BrowserPaneView 为每个标签的 `userContentController` 注册 handler 名 `quicktermExtension`（用弱代理对象避免循环引用）；收到后：先 `WKWebExtension(resourceBaseURL:)` 解包后的目录读 `requestedPermissions` → NSAlert「安装「X」？它将获得：…」[安装][取消] → 安装 → 成功后 alert「已安装」。安装中用 `progress` 回调更新地址栏占位文字或状态。
3. **`Sources/Panes/BrowserPaneView.swift`** 改动
   - `final class Tab: NSObject, WKWebExtensionTab`，加 `weak var pane: BrowserPaneView?`；实现 A.1 列出的方法。`indexInWindow` = pane.tabs 下标。
   - `extension BrowserPaneView: WKWebExtensionWindow`。
   - 建 WebView 配置处（`addTab` 里的 configuration 与 `createWebViewWith` 的 configuration）：`if BrowserExtensionManager.shared.isEnabled { configuration.webExtensionController = manager.controller }`；`userContentController.add(handler, name: "quicktermExtension")` + Web Store 用户脚本。
   - 事件上报（仅 isEnabled）：init → `didOpenWindow(self)`；`tearDownAll`/pane 关闭（`viewWillMove(toWindow: nil)` 且 pane 被移除时——用 `controller.requestClosePane` 路径与 `deinit` 兜底）→ `didCloseWindow`；`paneDidBecomeFirstResponder` → `didFocusWindow(self)`；`addTab` → `didOpenTab`；`closeTab` → `didCloseTab(tab, windowIsClosing: false)`；`selectTab` → `didActivateTab(new, previousActiveTab: old)` + `didSelectTabs([new])`/`didDeselectTabs([old])`；KVO url/title/isLoading → `didChangeTabProperties([.url]/[.title]/[.loading], for: tab)`。
   - 工具条：`extensionBar` 放在地址栏右侧：`addressField.trailing = extensionBar.leading - 6`，`extensionBar.trailing = toolbar.trailing - 6`，宽度由 intrinsicContentSize（hugging 高、compression 高）。**注意**：Task B 还要在同一区域放下载按钮——顺序：地址栏 | 下载按钮 | 扩展条。
   - ~~`BrowserWebView.willOpenMenu(_:with:)` 覆写：追加分隔 + `context.menuItems(for: tab)`~~ **（实现时否掉）**：
     WebKit 的 `WebContextMenuProxyMac` 见到 page 挂着 `webExtensionController` 就已经把各扩展的 `contextMenus`
     项（含分隔线）加进页面右键菜单了，自己再加一遍是重复项；而且 `menuItems(for: tab)` 返回的是**标签条**
     右键那一套（tab 上下文）。
   - 扩展自己的页面（`webkit-extension://…`：选项页、`tabs.create(runtime.getURL(…))`）必须用
     `context.webViewConfiguration` 建 WebView（普通配置的主帧加载会被 WebKit 拒成
     `NSURLErrorResourceUnavailable`），且扩展页 ↔ 普通页跨界导航时要原地换掉标签的 WebView。
4. **`Sources/Windowing/MainWindowController.swift`**：实现 `BrowserExtensionHost`；`applyConfig` 里 `BrowserExtensionManager.shared.isEnabled = settings.browserExtensions`；`openBrowserPane` 返回 pane（`@discardableResult`，Shims 的基类签名同步改）；WM 动作 `web-extensions`（`Cmd+Shift+E`，browserOnly，help「扩展菜单」）→ `browserPane?.showExtensionsMenu()`（弹拼图菜单）。KeybindingMap 默认键、WMAction、README 键位表、KeybindingMapTests 表都要加。
5. **`Sources/App/AppDelegate.swift`**：`applicationDidFinishLaunching` 里配置加载后 `Task { await BrowserExtensionManager.shared.loadInstalled() }`。
6. **`Sources/Config/ConfigStore.swift`**：`browser-extensions = true`（模板注释：`# browser-extensions = true   # 浏览器 pane 加载 WebExtensions（Chrome Web Store 安装 / 从 Chrome 导入；macOS 15.4+）`）。
7. **`project.yml`** 部署目标 15.4；`xcodegen generate`。
8. **文档**：README（英/中）：Features 里加一条；键位表加 `Cmd+Shift+E`；配置表加 `browser-extensions`；新小节「Browser extensions / 浏览器扩展」：怎么装（Web Store 页面的「添加到 QuickTerm」按钮；拼图菜单「从 Chrome 导入」）、存放位置、支持范围（WebKit 实现约 25 个 API 命名空间；不支持 webRequest 阻断、identity、history、downloads、management、proxy、nativeMessaging、debugger；storage.sync 不跨设备）；`docs/superpowers/specs/2026-08-31-quickterm-design.md` 的 Super+B 行补一句、配置表加键；`docs/porting-notes.md` 记录实现中踩到的 WebKit 坑。

### A.3 测试（`Tests/BrowserExtensionTests.swift`，新文件）
- `CRX.zipData`：手工拼 CRX3（"Cr24" + v3 + headerLen + header + zip）与 CRX2 头 → 返回 zip 字节；坏 magic / 截断 → nil。
- `extensionID(fromWebStoreURL:)`：两种域名、带 query、非 detail 页 → nil、id 长度不对 → nil。
- Chrome 导入扫描：临时目录造 `<id>/1.0.0/manifest.json` 与 `<id>/1.2.0/manifest.json`、一个 theme 扩展、一个无 name → 选 1.2.0、跳过 theme 与无 name。
- 管理器（`nonPersistent` 配置 + 临时 store）：本地装一个 fixture 扩展（MV3，`content_scripts` matches `http://example.test/*`，脚本 `document.title = "EXT-OK"`；`action` 带 default_popup）→ `installed.count == 1`、`context.isLoaded`、`controller.extensionContexts.count == 1`；`setEnabled(false)` → unloaded；`remove` → 目录删除、列表空。
- 标签/窗口协议：pane 两个标签 → `tabs(for:)` 2、`activeTab(for:)` 正确、`tab.window(for:) === pane`、`indexInWindow`、`isSelected`；`activate` 切换 activeTabIndex。
- 端到端（尽力，WebKit 应支持）：pane 的 WebView 配置挂了 controller 后 `webView.loadHTMLString("<html><body>x</body></html>", baseURL: URL(string: "http://example.test/"))`，等 ≤ 3s，断言 `webView.title == "EXT-OK"`（内容脚本注入成功）。若 WebKit 对 loadHTMLString 不注入，改用 `WKURLSchemeHandler` 自定义 scheme（`WKWebExtensionMatchPattern.registerCustomURLScheme`）或记录原因并保留其它断言。
- 配置：`ConfigStoreTests` 加 `browser-extensions` 默认 true / 解析 false / 模板键清单；`KeybindingMapTests` 表加 `("e", [.command, .shift], .webExtensions)`。

---

## Task B：下载进度 UI

### B.1 文件与职责
1. **`Sources/Panes/BrowserDownloads.swift`**
   - `final class BrowserDownloadItem: NSObject { let id: UUID; let filename: String; let destination: URL; let progress: Progress（= download.progress，WKDownload 遵守 NSProgressReporting）; var state: State（.downloading / .completed / .failed(String) / .cancelled）; let cancelHandler: () -> Void }`。测试可不带 WKDownload（传假 Progress 与假 cancel）。
   - `final class BrowserDownloadList: NSObject { private(set) var items: [BrowserDownloadItem]; var onChange: (() -> Void)?; func add(_:)、cancel(_:)、remove(_:)、clearFinished()、markCompleted/markFailed；var activeCount; var aggregateFraction: Double?（活动项 completedUnitCount 之和 / totalUnitCount 之和；有任一 total 未知 → nil = 不确定）}`；用 KVO 观察每个 Progress 的 `fractionCompleted`，节流到 ≤ 10 Hz 触发 `onChange`。
   - `final class BrowserDownloadButton: NSButton`：22×22，自绘：圆环进度（`aggregateFraction`，nil 时画旋转虚线或用 NSProgressIndicator spinning），中心向下箭头；全部完成且无活动 → 画勾；`items.isEmpty` → 隐藏。tooltip「下载（N 个进行中）」。点击 → popover。
   - `final class BrowserDownloadPopover`（NSPopover + NSViewController）：`NSStackView` 纵向，每项一行（图标 + 文件名（byTruncatingMiddle）+ 状态文字「1.2 MB / 5.0 MB · 45%」/「已完成 · 5.0 MB」/「已取消」/「失败：…」+ 细进度条 NSProgressIndicator + 右侧按钮：进行中 = ✕ 取消；完成 = 「在 Finder 中显示」（`NSWorkspace.shared.activateFileViewerSelecting`）；完成/失败/取消 = ✕ 移除行）；底部「清除已完成」；宽 320；随列表变化重建行（复用行视图，避免闪烁）。`ByteCountFormatter` 格式化。
2. **`BrowserPaneView`**：`let downloads = BrowserDownloadList()`；`WKDownloadDelegate`：`decideDestinationUsing` 里目录改用 `Settings.downloadDirectory`（config `browser-download-dir`，默认 `~/Downloads`，`~` 展开；不存在则回退 `~/Downloads`），创建 `BrowserDownloadItem(download:destination:)` 加入列表；`downloadDidFinish` → markCompleted；`didFailWithError` → `NSURLErrorCancelled` 视为 cancelled，否则 failed。工具条：`downloadButton` 放在地址栏与扩展条之间（隐藏时宽 0、间距 0）。
3. **配置**：`browser-download-dir = "~/Downloads"`（模板、parse、README、ConfigStoreTests）；`BrowserPaneView.Settings.downloadDirectory: String`，MainWindowController.applyConfig 接线。
4. **文档**：README（英/中）配置表 + 浏览器小节一句「下载进度显示在地址栏右侧，点击展开列表可取消 / 在 Finder 中显示」；spec 配置表。

### B.2 测试（`Tests/BrowserDownloadTests.swift`）
- 模型：两项（total 100 / 完成 50，total 200 / 完成 100）→ aggregate 0.5；一项 total 未知 → nil；cancel 调用 handler 且状态 .cancelled；clearFinished 只删完成/失败/取消；`onChange` 触发。
- 按钮：空列表隐藏；加一项显示；全完成后仍显示（勾）直到清除。
- 真实下载：pane 的 `downloadDirectory` 指到临时目录，`webView.startDownload(using: URLRequest(url: data:application/octet-stream;base64,…))`，等待 ≤ 3s → 列表 1 项、state == .completed、文件存在且内容一致；popover 行数 1。
- 取消：`startDownload` 一个 `http://127.0.0.1:9/`（连接拒绝会失败 → failed）——验证失败状态；取消路径用假 item 覆盖。

---

## 验收
- 全套测试全绿（含新用例）；`xcodebuild … Debug build` 成功。
- 手动冒烟（主会话做）：`open -a QuickTerm --args --open-browser https://chromewebstore.google.com/detail/…` 页面出现「添加到 QuickTerm」；拼图菜单可导入本机 Chrome 扩展；下载一个文件时地址栏右侧出现进度环。
