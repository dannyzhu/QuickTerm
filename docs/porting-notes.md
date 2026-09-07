# GhosttyEmbed 移植笔记（M0）

来源：`ghostty-org/ghostty` **tag v1.3.1**（submodule `vendor/ghostty`）。
移植层 = `macos/Sources/Ghostty/` 整目录拷入 `Sources/GhosttyEmbed/`，MIT 许可、保留版权头。

## 拷入清单

- `Sources/GhosttyEmbed/`（= macos/Sources/Ghostty/ 全部，除下述删除项）
- `Helpers/`：CrossKit、Cursor、Backport、Weak、KeyboardLayout、AppInfo、CodableBridge、AnySortKey、MetalView、Fullscreen（裁剪版）、Extensions/ 全目录、Private/Dock.swift
- `Features/Splits/SplitTree.swift`（值类型分屏树——M1 的核心模型，提前引入）
- `Features/QuickTerminal/`：Position/Screen/Size/SpaceBehavior 四个枚举（Config 引用）
- `Features/Secure Input/`：SecureInput.swift、SecureInputOverlay.swift

## 删除项（app 专属，非嵌入必需）

| 文件 | 原因 |
|---|---|
| `Ghostty.Inspector.swift` → 后又恢复 | SurfaceView 引用 `Ghostty.Inspector` 类型，恢复原文件成本低于裁剪 |
| `Surface View/InspectorView.swift` | ImGui 调试器 UI，未被恢复项引用 |
| `Surface View/SurfaceView_UIKit.swift` | iOS 分支 |
| `Surface View/SurfaceGrabHandle.swift` | 依赖 BaseTerminalController 拖拽；M1 用 SplitTree 拖拽替代（SurfaceView.swift 中调用点一并移除） |

## 裁剪/修改项

| 位置 | 修改 |
|---|---|
| `Helpers/Fullscreen.swift` | 保留 FullscreenMode/协议/NativeFullscreen；NonNativeFullscreen 系列改为 NativeFullscreen 别名（原实现依赖 TerminalWindow/CGSSpace/窗口 tab）。**M1 需按 QuickTerm 窗口类重新移植非原生全屏** |
| `Helpers/Extensions/NSWindow+Extension.swift` | 移除 `addTabbedWindowSafely`（ObjC 异常捕获辅助 `GhosttyAddTabbedWindowSafely`；QuickTerm 不用原生窗口 tab） |
| `Surface View/SurfaceScrollView.swift` | macOS 26.0 专属 NSScrollPocket workaround 的窗口类判断从 `HiddenTitlebarTerminalWindow` 放宽为任意窗口 |
| `Ghostty.Error.swift`、`Helpers/Extensions/String+Extension.swift`、`Features/QuickTerminal/QuickTerminalSize.swift` | 补缺失的 `import Foundation/Cocoa`（原工程可编译疑似依赖同 target 其它文件的可见性差异） |
| `Shims.swift`（新增） | `BaseTerminalController`（surfaceTree/focusedSurface/titleOverride/commandPaletteIsShowing/**focusFollowsMouse**/toggleBackgroundOpacity/promptTabTitle/changeTabTitle）、`TerminalWindow`、`TerminalRestoreError` 最小替身。**M1 的 MainWindowController 继承 BaseTerminalController 并覆写 focusFollowsMouse=true 即得悬停焦点** |
| `Sources/App/AppDelegate+Ghostty.swift`（新增） | 嵌入层要求的委托接口：checkForUpdates/closeAllWindows/toggleVisibility/syncFloatOnTopMenu/setSecureInput/toggleQuickTerminal/performGhosttyBindingMenuKeyEquivalent（M0 空实现） |

## v1.3.1 API 快照（实际用到）

- `int ghostty_init(uintptr_t, char**)` —— **必须在 NSApplicationMain 之前调用**（官方 main.swift 同款；否则 Ghostty.App 初始化路径异常）
- `ghostty_config_new/free/load_default_files/finalize/get` —— `load_default_files` 原生读取 `~/.config/ghostty/config`（XDG），即配置链第 2 层
- `Ghostty.App(configPath: nil)` —— 内部完成 Config 加载 + `ghostty_app_new`（runtime 回调：wakeup/action/clipboard×3/close_surface）
- `Ghostty.SurfaceView(_ app: ghostty_app_t, baseConfig: nil)` —— NSView；引擎内建 Metal 渲染；创建即起 PTY+登录 shell

## 构建管线备忘（scripts/build-ghosttykit.sh 已全部固化）

1. **Zig 依赖离线预取**（`scripts/fetch-zig-deps.sh`）：Zig 0.15 的 HTTP/git 客户端不走代理；用 curl 预取 `build.zig.zon` + `build.zig.zon.txt` 全部 URL 后 `zig fetch` 灌缓存；传递 git 依赖（vaxis→uucode@5f05f8f8）用 GitHub codeload tarball 等价替代
2. **SDK arm64 overlay**：Xcode 26.6（SDK 26.5）的 `libSystem.tbd` 主文档 targets 只有 x86_64/arm64e，Zig 0.15 链接器不做 arm64→arm64e 回退 → 全符号 undefined。构建脚本生成符号链接 overlay（仅拷贝并 patch `usr/lib` 的 tbd 加回 `arm64-macos`）+ xcrun shim 指向它
3. **fat 归档重打**：Xcode 26.6 libtool 因对齐问题丢弃 Zig 生成的归档成员（`libghostty_zcu.o` 等，含 ImGui/freetype 大量成员）→ 脚本检测 `_ghostty_init` 缺失时从 16 个组成档案完整重打
4. **Metal Toolchain**：Xcode 26 需 `xcodebuild -downloadComponent MetalToolchain`（一次性，688MB）
5. 链接需 `-lc++`（spirv-cross）；测试 target 以 app 为 TEST_HOST 并自行链接 xcframework

- **xcodegen 2.46 起默认 `ENABLE_USER_SCRIPT_SANDBOXING = YES`**（2026-09-07）：「Bundle Ghostty Resources」脚本
  要 `rm -rf` / `cp -R` 到产物目录，沙盒下直接 `deny file-read-data`，整个构建失败（现象：`error: Sandbox: rm(…) deny(1)`）。
  `project.yml` 的 `settings.base` 里显式关掉；重新 `xcodegen generate` 后生效。

## M1 增补

- 拷入 `Features/Splits/{TerminalSplitTreeView,SplitView,SplitView.Divider}.swift`
- `TerminalSplitLeaf` 内 `Ghostty.InspectableSurface`（inspector 分屏包装，属已删 InspectorView.swift）替换为纯 `Ghostty.SurfaceWrapper`
- M1 追加：TerminalSplitDropZone 增 `.center`（中心=交换）；TerminalSplitLeaf 挂 PaneChrome 与 ⌘ 拖拽源覆盖层；SurfaceView.focusDidChange 补 objectWillChange.send()（`focused` 非 @Published）；InspectableSurface→SurfaceWrapper

## DisplayLink 会话配额（macOS 26 环境坑，已缓解）

现象：开发过程中某时刻起，所有构建（含此前验收通过的 M0）`ghostty_surface_new` 全部失败，
日志 `embedded_window: error initializing surface err=error.OutOfMemory`。

定位：给 `src/apprt/embedded.zig` 的 surface_new 临时加 `@errorReturnTrace()` 输出（Debug 构建），
栈指向 `video.display_link.DisplayLink.createWithActiveCGDisplays`（renderer.Metal.init）。
CVDisplayLink 是已废弃 API，macOS 26 对其存在**登录会话级配额**：一次会话内大量创建
（本项目测试循环累计数百个 surface）后 Create 开始失败；ghostty 自身 release 正确（generic.zig:810），
配额不随进程退出恢复，注销重登才复位——这解释了"同代码昨天行今天不行"。

缓解：engine overlay 注入 `window-vsync = false`（generic.zig:693 仅 vsync=true 才建 DisplayLink；
无 vsync 渲染仍由 CoreAnimation 节流）。若用户希望 vsync=true，注销重登后在
config.toml `[ghostty]` 写 `window-vsync = true` 覆盖即可。

附带：`scripts/build-ghosttykit.sh` 的 fat 归档 repack 升级为"每档案名取最新"，
避免 .zig-cache 中多优化级别档案共存时混装。
- M5：新增 ScrollingStrip/ScrollingStripView（scrolling 布局）；StripDropDelegate 镜像 TerminalSplitLeaf 私有 SplitDropDelegate 的行为（zone 计算复用 TerminalSplitDropZone）；焦点跟随滚动经 PreferenceKey 上报（悬停焦点天然驱动视口）
- 焦点修正：SurfaceView.focused 初始值 true→false（原值使新建 pane 未获焦点即亮边框，双激活竞态）；焦点态完全由 become/resignFirstResponder 回调驱动

## NSHostingView 坐标系是 flipped（top-left）

`window.contentView`（NSHostingView）`isFlipped == true`：`content.convert(locationInWindow, from: nil)`
返回的 y 已是**自顶向下**基准，不是 AppKit 传统 bottom-left。按 bottom-left 假设再翻转会得到
垂直镜像坐标——曾使 hover 遮挡判定镜像（浮动 pane 拖离垂直中心即错判）、顶栏滚轮切工作区
实际命中窗口底部 26pt。统一走 `MainWindowController.normalizedContentPoint`（isFlipped 感知），
回归测试 `testNormalizedContentPointTopLeft` 对真实宿主视图锁定语义。

## hover 遮挡 = 模型几何而非 hitTest（spec v7 修订）

NSTrackingArea 不感知兄弟视图遮挡（`.inVisibleRect` 只裁剪自身祖先链），浮动 pane 叠在平铺
pane 上时两层都收到 mouseMoved/mouseEntered。hitTest 方案不可行：⌘ 按住时每个 pane 上都有
铺满的 SurfaceDragSource 浮层（可命中普通 NSView），overlay 滚动条短暂显示时同理——hitTest
会把毫无遮挡的 pane 误判为被遮挡（⌘ 期间全局 hover 停摆）。现行方案 `HoverOcclusion.isOccluded`
纯几何判定（更高 z 浮动 rect / 面板遮罩 / Scratchpad），SurfaceView 在遮挡时合成一次
mouseExited(-1,-1)（否则 core 悬停坐标冻结在遮挡边界，TUI hover 高亮滞留），脱离遮挡的首次
mouseMoved 补进入状态；拖拽序列（type != .mouseMoved）不走守卫，跨 pane 选中文本不受影响。
点击同理：SurfaceView 的 localEventLeftMouseDown 焦点转移监视器原以
`hitTest == self` 判定命中（只测自己子树），被浮动 pane 盖住的下层 pane
会抢走点击焦点——同走 surfaceIsOccluded 守卫。

## 测试宿主退出时的 ghostty 崩溃（既有、与用例逻辑无关）

`xcodebuild test` 结束后宿主 app 退出时，若某用例刚创建过 `Ghostty.SurfaceView`
（`ghostty_surface_new` 在 init 里即执行并异步起 shell）而用例结束即释放，退出阶段
ghostty 可能崩溃：表现为日志里多一次宿主启动、`sentry: crash report written`（由下一次
启动的进程补报上一进程的崩溃）、两行 `Executed 0 tests`，crash 文件落在
`~/.local/state/ghostty/crash/`。`-only-testing` 单跑任一创建 surface 的用例必现
（2026-09-03 在 main 上用改动前代码验证），全套运行偶发。**不影响测试判定**
（XCTest 结果已在崩溃前汇总，仍报 TEST SUCCEEDED）；断言失败要看 `.swift:N: error:` 行，
不要被 `Executed 0 tests` 误导。根治方向：用例显式 close 创建的 surface，或
AppDelegate.isRunningTests 下退出时跳过 surface 释放。

## libghostty 1.3.1 `load_default_files` 会写出 0 字节模板

`ghostty_config_load_default_files` → `Config.loadDefaultFiles`：macOS 上四个候选文件
（XDG `ghostty/config`/`config.ghostty`、Application Support 同名）都不存在时，会调用
`writeConfigTemplate` 往 `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`
写模板；1.3.1 用 Zig 0.15 缓冲 writer 但没有 flush，落盘为 **0 字节**。引擎自己读时按
`FileIsEmpty` 不加载，但任何"文件存在即有配置"的判断都会被它骗过（QuickTerm 兜底层第一版
正是这样失效的）。现在 QuickTerm 不调该 API，由 `GhosttyDefaultConfig.userConfigFiles()`
按同样顺序只加载存在且非空的常规文件；一个都没有才加载内置兜底。

## 通用二进制（arm64 + x86_64）构建

`GHOSTTYKIT_TARGET=universal scripts/build-ghosttykit.sh` → ghostty 的 `-Dxcframework-target=universal`
（`GhosttyLib.initMacOSUniversal`：aarch64 与 x86_64 各 `initStatic` 再 `LipoStep`），Zig 交叉编译
x86_64-macos 无需 Rosetta；SDK overlay 的 tbd 本就含 `x86_64-macos` 目标。xcframework 切片目录变为
`macos-arm64_x86_64`，归档名由 `libghostty-fat.a` 变为 `libghostty.a`——脚本按 `ls macos-*/*.a` 动态定位。
libtool 丢成员的修复改为**按架构**：`lipo -thin` 拆开逐一检查 `_ghostty_init`，缺失的架构从缓存中
同架构的组成档案重打（(档案名, 架构) 取最新，且只取单架构、**macOS 平台**的归档——universal 目标
顺带编 iOS/模拟器切片，其 arm64 归档与 macOS 同名更新，混入会报 `built for 'iOS'`；平台看 Mach-O
`LC_BUILD_VERSION`），再 `lipo -create` 合回。Xcode Release 默认
`ARCHS = arm64 x86_64`、`ONLY_ACTIVE_ARCH = NO`，xcframework 含双架构后 app 自动为通用二进制；
`scripts/make-release.sh` 用 `lipo -archs` 校验产物含 `RELEASE_ARCHS`（默认 arm64 x86_64）才继续。
开发迭代仍用默认 `native`（快一倍）。

## AppKit：first responder 视图脱离窗口时不发 resignFirstResponder

独立探针（scratch 脚本）验证：`makeFirstResponder(A)` 后 `A.removeFromSuperview()`，窗口 FR 被
静默重置，A **收不到** `resignFirstResponder`；对不在窗口里的视图 `makeFirstResponder` 返回 true
但不调 `becomeFirstResponder`（什么都不做）。SwiftUI 重建层级（Cmd+L、Cmd+T、切工作区）时
SurfaceView 会从旧 scroll view 移出再装进新建的 scroll view，恰好命中前者——`focused` 残留为
true → 多 pane 同时激活边框/闪烁光标，且悬停守卫 `!focused` 让它们再也收不到焦点。
对策：`viewWillMove(toWindow: nil)` 时若自己是 FR 则记账，`viewDidMoveToWindow` 后夺回——但**只在
FR 仍是窗口/nil 时**（脱离导致的静默重置），期间若别的 responder 已取得焦点绝不抢（否则 dwindle 新建
时原 pane 重挂会把刚给新 pane 的焦点夺走；探针日志证实：moveFocus 成功后紧跟 reclaim 抢回）；
控制器所有聚焦经 `requestFocus(to:from:)`（登记意图 → moveFocus → 0.35s 后校验再交一次）；
`becomeFirstResponder` 通知控制器清掉其他 pane 的残留标志（单焦点不变量）；悬停与
`focusedSurface` 以窗口 FR 为真相；启动聚焦改用 `Ghostty.moveFocus`（等待挂载）。
回归测试 `testToggleLayoutKeepsSingleFocus`。

## 引擎回调的 userdata 可能悬垂（Ghostty.Surface 异步 free）

上游 `Ghostty.Surface.deinit` 用 `Task.detached { @MainActor in ghostty_surface_free }` 异步释放。SurfaceView 释放后、
surface 从引擎表移除前有一个主线程任务跳转的窗口；此时 `wakeup → ghostty_app_tick → drainMailbox → handleMessage`
仍会为该 surface 触发动作回调（`hasSurface` 为真），`surfaceView(from:)` 用 `Unmanaged.takeUnretainedValue()`
取回已释放的视图 → `objc_retain` EXC_BAD_ACCESS（系统 .ips 栈：scrollbar 动作）。测试全套里表现为"用例挂起/宿主
崩溃重启"。对策：① deinit 在主线程时同步 free（窗口归零）；② `Ghostty.App` 维护存活 SurfaceView 登记表
（init 登记、deinit 首行注销），`surfaceView(from:)` 先查表，悬垂则记 stderr 并返回 nil。修 ① 前全套一次运行守卫
命中 135 次（确定性），说明并非偶发。

**登记时机的坑**：存活登记表必须在调用 `ghostty_surface_new` **之前**登记视图——它在返回前就会同步回调
（`set_cell_size` 等）。登记若放在 `surfaceModel = …` 之后，守卫会把创建期的首个回调当悬垂丢弃
（全套 70 用例稳定出现 78 次"假悬垂"，栈顶是 `SurfaceView.init → withCValue → performAction → setCellSize`）。

## 关闭动效与 SwiftUI 视图复用（2026-09-04）

关闭 pane 分两段（`MainWindowController.beginClose/finishClose`）：先标记 `WorkspaceModel.closingPanes`
（pane 仍在布局，焦点已交给接班人），0.28s 动效到点才真正移除。两条坑：

- **同位置 split 换 split 会复用 @State**：dwindle 关闭 A 后，兄弟子树 split(B,C) 顶到原 split(A,…) 的
  视图位置，`TerminalSplitSubtreeView` 的 `switch` 仍走 `.split` 分支 → SwiftUI 复用 `SplitBranchView`
  连同锁存的关闭态（closeProgress=1）→ B 被压成 0 宽。对策不是加 `.id`（会让子树重挂、闪屏），而是
  锁存"关闭中的叶 id"，body 里只在该叶仍是直接子叶时才采用锁存几何，并在 `.onChange(of: CloseKey)`
  里复位。
- **并发关闭不经 perform**：子进程退出走 `ghosttyDidCloseSurface → closePane`，不会 flush 淡出中的
  pane；接班人要在"其他淡出中 pane 已移除"的布局上算，否则焦点交给一个正在消失的 pane。

其它：`ScrollingStrip.Column` 加了稳定 `id`（原用列首 pane id 做 ForEach 身份，列首关掉整列重建，列内
其余 pane 脱离/重挂窗口）。

## 浏览器 pane / PaneView 抽象（2026-09-04）

- **SplitTree 叶子多态解码**：基类 `init(from:)` 造不出子类，所以约束改为 `PaneCodable`，叶子经
  `decodePane(from: superDecoder)` 按 `kind` 分发（v3 存档无 kind = 终端）；JSON 形状与原来一致。
- **焦点真相 = FR 是 pane 或其后代**：浏览器 pane 的 FR 是内部 WKWebView（`focusTarget`），地址栏编辑时
  FR 是字段编辑器（`NSTextView > _NSKeyboardFocusClipView > NSTextField > pane`）。托管视图要把
  become/resign 回报给 pane；控制器判"是否持焦"用 `holdsFirstResponder`，不能只看 `focused` 标志。
- **不能手动对 WKWebView 调 resignFirstResponder**：WebKit 内部 `_newFirstResponderAfterResigning` 只允许在
  makeFirstResponder 流程内调用，否则 NSInternalInconsistencyException。`PaneView.moveFocus` 只对
  "自己就是 FR"的 pane 手动 resign。
- **WKWebView 子类覆写 mouseMoved 收不到事件**：它的 tracking area 由内部观察者对象持有，事件投给观察者。
  非终端 pane 的悬停即焦点由 PaneView 容器自己的 tracking area 驱动（`installsHoverTracking`）。
- **新 pane 插入会合成 mouseMoved**：邻居 tracking area 因尺寸变化重建时 AppKit 合成一次 mouseMoved，鼠标
  停在旧 pane 上就会把刚交出去的焦点抢回。悬停即焦点必须尊重控制器的待聚焦意图（`paneMayReclaimFocus`）。
- **键名归一化**：`charactersIgnoringModifiers` 对符号/数字键保留 Shift（Cmd+Shift+[ → "{"），
  要用 `characters(byApplyingModifiers: [])` 取基础键；合成 NSEvent 没有 CGEvent 背书时回退。
- **Edit 菜单会吞终端的 Cmd+X/Z/A**：`menuHasKeyEquivalent` 返回 false 挡不住 AppKit 继续枚举菜单项
  （禁用项照样消费 + beep）；焦点在终端时要返回 true 并给出 target/action 把按键转交终端 keyDown。
- **libghostty 对带 command 的 surface 强制 wait-after-command**（文件管理器 pane）：退出只发
  SHOW_CHILD_EXITED，不 close；macOS 上以 `login … bash -c "exec -l <cmd>"` 启动，命令必须是单个 exec 目标。
- **WKWebView 错误页**：`loadHTMLString(baseURL:)` 不进历史（后退失效），用 `loadSimulatedRequest`；
  `drawsBackground` 是私有 KVC，先 `responds(to: _setDrawsBackground:)`。
- **SwiftUI 托管的 pane 没有外部宽度约束**：`NSViewRepresentable` 返回的 PaneView 内部若有必需的宽度
  约束（标签项 ≤200 + fillEqually + 两侧钉死），Auto Layout 会反过来把 pane 自身解成 N×200。pane 内部
  所有影响宽度的约束都只能是非必需；标签条最终改为手工布局（`BrowserTabBarView.layout()` 按可用宽度算帧，
  梯形叠放 / 溢出滚动也只有手工布局做得到）。**"非必需"还不够**：NSHostingView 是按 500 的 fitting
  priority 量这块 NSView 的，优先级 >= 500 的宽度约束照样会撑宽窄 pane（实测地址栏 `>= 200 @750` 会把
  250pt 宽的浏览器 pane 撑成 300pt，拼图按钮被顶到 pane 外面）。保底宽度一律用 < 500 的优先级
  （见 `BrowserPaneView.addressFieldMinimumPriority = 300`，扩展条保底 310 比它高一档）。
- **NSTrackingArea 不感知兄弟遮挡**：每个标签自带 tracking area 时，相邻梯形重叠的 8pt 带里两个标签同时收到
  mouseEntered（区域是纯矩形、与 hitTest / z 序无关）。悬停要由容器一个 tracking area + 自己的命中判定裁决。
- **`focusedPane` 只搜 paneList，Scratchpad 不在其中**：Scratchpad 聚焦时它退回到 `paneList.first`（第一块平铺
  pane）。对"作用于焦点终端"的动作（清屏）必须按窗口真 FR 选目标，否则会作用到用户看不见的 pane。
- **ghostty 的 performable 绑定**：`clear_screen` 在 alt screen 上引擎返回 false、期望宿主把按键交给程序；
  宿主不能直接放行给 AppKit（菜单键等价会吞掉），要显式 `surface.keyDown(with:)`。
- **MutationObserver 回调里无条件改 DOM = 微任务死循环**：Web Store 注入脚本曾在观察者回调里每次都赋
  `button.textContent`，赋值本身就是一次 childList 变动 → 再次触发回调，页面 JS 线程被卡死（evaluateJavaScript
  永远不回调）。回调里只做带守卫的 DOM 操作，并用 requestAnimationFrame 合并。
- **⌘ 拖拽源浮层会吞掉 ⌘+点击**：SurfaceDragSource 浮层 acceptsFirstMouse + 吞 mouseDown、不转发 mouseUp，
  引擎永远收不到 PRESS/RELEASE，⌘+点击链接（open_url 在 release 时触发）根本不会发生。浮层和浮动 pane 的 ⌘
  会话都要"没拖过阈值就抬起 = 纯点击，按下 + 抬起一并转交 pane 本体"；不能在按下时就转发（随后拖拽则没有 release）。
- **普通滚轮的 scrollingDelta 是"行"不是 pt**：`hasPreciseScrollingDeltas == false` 时一格 ≈ 1，直接当 pt 用
  等于滚不动；要自行换算步长。scrolling 布局的横向平移监视器跑在视图派发之前，需要按命中放行给子视图。
- **关标签要先记焦点**：被关的 webView `removeFromSuperview` 时 AppKit 静默把 FR 重置为窗口（同上节，
  不发 resign），之后 `holdsFirstResponder` 已是 false；先读焦点再移除，再显式 `makeFirstResponder`。


## WKWebExtension（浏览器扩展，2026-09-06）

- **部署目标抬到 15.4**：WKWebExtension 全家都是 macOS 15.4+，`project.yml` 的 `deploymentTarget.macOS` 与
  `MACOSX_DEPLOYMENT_TARGET` 要一起改，README 的"macOS 15+"同步。
- **Swift 名字与头文件类名不同**（用旧名直接报"已重命名"）：`WKWebExtensionControllerConfiguration` →
  `WKWebExtensionController.Configuration`、`WKWebExtensionTabConfiguration` → `WKWebExtension.TabConfiguration`、
  `WKWebExtensionWindowConfiguration` → `WKWebExtension.WindowConfiguration`、`WKWebExtensionMessagePort` →
  `WKWebExtension.MessagePort`、`context.inspectable` → `isInspectable`。
- **`grantedPermissions` / `grantedPermissionMatchPatterns` 字典里的 Date 是"过期时间"不是"授予时间"**：
  批量赋值时写 `Date()` 等于当场失效（权限白授）。改用单项 `setPermissionStatus(.grantedExplicitly, for:)`
  （不带 expirationDate = distant future）。内容脚本的 `matches` 也要授权，取 `allRequestedMatchPatterns`
  （含 content_scripts），只授 `requestedPermissionMatchPatterns`（= host_permissions）不够。
- **WKWebExtension 的类与协议都带 `WK_SWIFT_UI_ACTOR`（= @MainActor）**：`BrowserPaneView.Tab` 必须标
  `@MainActor` 才能实现 `WKWebExtensionTab`；随之 KVO 回调（@Sendable 闭包）里 `tab.title = …` 会报
  "main actor-isolated property 不能在 Sendable 闭包里改"，用 `MainActor.assumeIsolated`（WebKit 这些 KVO
  一律主线程回调）。反过来，纯函数（CRX 解析 / Web Store URL / Chrome 目录扫描）要标 `nonisolated`，
  否则非 @MainActor 的测试用例调不动。
- **pane 关闭的 `didCloseWindow` 不能放在 deinit**：deinit 是 nonisolated，够不到 MainActor 的 controller。
  改由控制器的移除路径（`removeFromActiveLayout` / `removeFromAnyWorkspace`）调 `paneWillClose()`，内部自带
  "只报一次"标志。
- **XCTest 的 async 用例里 `RunLoop.main.run(until:)` 推不动 WebKit 的页面加载**：同一段 `loadHTMLString`
  在 async 用例里 5s 仍停在 about:blank（连不挂扩展 controller 的对照组也一样），换成非 async 用例 + 主 runloop
  轮询后 0.3s 就完成。非 async 用例里要跑异步安装：起 `Task` 再转 runloop 等标志位。
- **内容脚本对 `loadHTMLString(baseURL:)` 是会注入的**（baseURL 用真实 http 域名即可），不需要自定义
  scheme + `WKWebExtensionMatchPattern.registerCustomURLScheme`。
- **复用 WKWebViewConfiguration 要先摘再挂**：`window.open` 交回来的 configuration 可能已注册过同名
  script message handler，重复 `add(_:name:)` 抛 ObjC 异常；先 `removeScriptMessageHandler(forName:)`。
- **非持久配置不设 `defaultWebsiteDataStore`**：只有持久配置（`Configuration(identifier:)`）才挂
  `.default()` 与浏览标签共享 cookie；测试用的 `.nonPersistent()` 保持隔离。
- **扩展自己的页面要用 `context.webViewConfiguration` 建 WebView**：`webkit-extension://…`（选项页、
  `tabs.create(runtime.getURL(…))`、`runtime.openOptionsPage()`）的主帧加载在普通配置的 WKWebView 里会被
  WebKit 直接拒掉（`NSURLErrorResourceUnavailable`，页面变成我们的错误页），因为它检查的是配置上的
  `requiredWebExtensionBaseURL`；反过来，用扩展配置建的 WebView 也去不了 http(s)。头文件明说"在扩展 URL
  与普通 URL 之间导航时 app 必须换掉 tab 的 web view"——`addTab` 按 URL 挑配置，`decidePolicyFor` 里跨界时
  `rebuildWebView` 原地换（标签身份 / 扩展看到的 tabId 不变）。`controller.extensionContext(for: url)` 只认
  **已加载**的扩展。
- **`context.uniqueIdentifier` 不会连带改 `baseURL`**：不显式设 `baseURL = webkit-extension://<id>/` 的话，
  扩展页面的 origin（`runtime.getURL`、页面侧 storage）每次启动都换一个随机 host。两者要一起设（且只能在
  load 之前设）。
- **页面右键菜单的扩展项 WebKit 自己会加**：`WebContextMenuProxyMac` 见到 page 上挂着 webExtensionController
  就会追加各扩展的 `contextMenus` 项（含分隔线）。再自己 `willOpenMenu` 追加 = 重复项，而且
  `context.menuItems(for: tab)` 给的是**标签条**右键那一套（tab 上下文），不是页面上下文。
- **`didCloseTab` 要在把标签从 pane 上摘下来之前报**：WebKit 在这次调用里同步回调 `tab.window(for:)` 去算
  `tabs.onRemoved` 的 windowId，`tab.pane` 已是 nil 的话扩展收到的是 `windowId = -1`。同理 `indexInWindow`
  不在窗口里要返回 `NSNotFound`（返回 0 等于谎称自己是第一个标签）。
- **关标签时"上一个激活标签"要在数组变短之前取**：`tabs.remove` 之后 `activeTabIndex` 还是旧值，
  `activeTab` 指到的已经是别人，`tabs.onActivated` 要么不发要么带着一个从没激活过的 previousTabId。
- **测试宿主是真 app**：`applicationDidFinishLaunching` 里的 `loadInstalled()` 要用 `isRunningTests` 挡住
  （否则用户真装的扩展会跑进每个测试 WebView，工具条用例也跟着红），`shared` 在测试下用
  `.nonPersistent()` + 临时目录，别改写用户的 `state.json` / `controller-id`。
- **页面 → 原生的安装通道要挡来源**：`add(_:name:)` 注册的 handler 在 page world、所有框架都能调
  （`window.webkit.messageHandlers.<name>`）。注册到私有 `WKContentWorld`，并在收到消息时校验
  `frameInfo.isMainFrame` + `frameInfo.request.url` 是商店详情页 + id 与该页一致，否则任意网页 / iframe 都能
  凭一条 postMessage 拉起原生安装弹窗。

- **后台加载失败只给一个 `WKWebExtensionContextErrorBackgroundContentFailedToLoad`，没有 JS 原因**（2026-09-07）：
  诊断办法是把扩展目录拷一份，在后台脚本最前面塞一段前导——监听 `error` / `unhandledrejection`、包一层
  `console.*`，都写进 `chrome.storage.local`——再从扩展自己的页面（`context.webViewConfiguration` 建的
  WebView 加载 `webkit-extension://<id>/x.html`）用 `callAsyncJavaScript` 读出来。真实扩展这样查出三类根因：
  - **WebKit 缺 `webNavigation.onHistoryStateUpdated` / `onReferenceFragmentUpdated`**：Stylish 在 service worker
    顶层直接 `addListener` → TypeError → 后台永远起不来。
  - **WebKit 的 `importScripts()` 会在每个被导入脚本求值后清空 microtask 队列**（Chrome 不会；用合成扩展验证过：
    导入存在 / 不存在的文件都清，忙等与 `console.log` 不清）。Tampermonkey 用 `let pt=true;(async()=>{await null;pt=false})()`
    判断"监听器是否在启动阶段注册"，而它启动时 `importScripts("/test.js")` 一个空文件——标记就此翻转，随后
    `tabs.onUpdated.addListener` 抛错、`init` 中止，popup 的 `runtime.connect` 报 "No runtime.onConnect listeners"，
    永远转圈。
  - **扩展页面的 scheme 是 `webkit-extension:`，不是 `chrome-extension:`**：Tampermonkey 的 Chrome 构建把
    `INTERNAL_PAGE_PROTOCOLS = ["chrome-extension:"]` 写死，后台用它判断 sender.url 是不是自己的页面，popup 的
    `loadTree` 被当成外来页面拒掉（"this context doesn't have the permission"），popup 空白。垫片把全部 .js 里的
    字面量 `chrome-extension:` 替成 `webkit-extension:`（只碰 .js / .mjs；不碰 html / json；两个 scheme 等长，压缩代码的
    偏移量不受影响）。已知副作用：ChatGPT 扩展把它当 storage key 前缀（`codex:chrome-extension:persisted-atom:`），
    换 scheme 后旧值孤立一次。
  - **嵌在网页里的扩展 iframe 调 `tabs.query` → UI 进程当非法 IPC 杀掉页面进程**（现象：我们的"页面进程反复崩溃"
    错误页；`~/Library/Logs/DiagnosticReports/ExcUserFault_QuickTerm-*.ips` 里栈是
    `WebProcessProxy::didReceiveInvalidMessage`；`log stream --predicate 'process == "QuickTerm"'` 能看到
    `Received an invalid message WebExtensionContext_TabsQuery from WebContent process`——`log show` 反而查不到）。
    Stylish 点图标是往当前页注入一个 `webkit-extension://<id>/index.html` iframe，里面的 React 应用一上来就
    `tabs.query`。用合成扩展逐个 API 二分：从这种 iframe 里调 `tabs.* / windows.* / action.* / scripting.* /
    alarms.* / contextMenus.* / cookies.*` 都会被杀；`runtime.sendMessage`（promise 形式能拿到回复，回调形式拿不到）、
    `runtime.connect`（端口立刻断）、`runtime.getManifest`、`storage.*`、`i18n`、`permissions` 与各种 `onXxx.addListener`
    都正常。修法：网页 WebView 里注入 `BrowserExtensionCompat.frameUserScript`（document start、全部框架、page world），
    在 `webkit-extension:` 框架里把这些命名空间换成经 `runtime.sendMessage({__quickterm_relay})` 转给后台的代理，
    后台垫片代为调用后回传，只接受 sender.url 是扩展自己 origin 的请求。坑：WebKit 的命名空间对象
    （`chrome.tabs`）上 `Object.defineProperty` 静默无效，方法也都在原型上（`Object.keys` 看不到），只能整个
    换掉 `globalThis.chrome` / `browser`（这两个是普通可写数据属性），复制一份普通对象再赋回去。
  前三者都靠 `BrowserExtensionCompat`（第四个还要 pane 侧的 `frameUserScript`） 在安装 / 启动加载时改写扩展目录解决：manifest 的 `background.service_worker`
  指向同目录的 `__quickterm-background.js`（classic 用 `importScripts`、module 用 `import` 先拉 `/__quickterm-compat.js`
  再拉原脚本；放同目录是为了原脚本里相对路径的 importScripts 仍按原目录解析），`background.scripts` 数组则直接在
  前面插一项；原始 `background` 与垫片版本记在 manifest 的 `__quickterm` 下，幂等。垫片里的 `importScripts`
  只跳过安装时扫出来的空 `.js`（求值本来就没有效果），其余照旧走原生。扩展自己的页面（popup / 选项页）目前不注入
  垫片——真实案例里页面侧都有 typeof 守卫。文件扫描用 `enumerator(atPath:)` 拿相对路径：`enumerator(at:)` 返回的是
  解析过符号链接的绝对 URL，store 目录本身是链接（放 Dropbox）时和 `directory.path` 前缀对不上、列表整个空掉。
  manifest 里的 worker 路径带 `..` 的一律不包装（`../../x.js` 不能让我们往扩展目录外写）；判断只看字符串，别拿
  `standardizedFileURL` / `resolvingSymlinksInPath` 比前缀——目标文件还不存在时 /var 与 /private/var 只解析一边，前缀对不上。

- **`externally_connectable`（网页给扩展发消息）WebKit 是实现了的，但网页侧只挂在 `browser` 上**（2026-09-07，
  Stylish 一直显示未登录的根因）：合成扩展实测，普通 http 网页里 `typeof chrome === "undefined"`（连对象都没有），
  而 `typeof browser === "object"`、`Object.keys(browser) === ["runtime"]`，`browser.runtime` 上只有原型方法
  `sendMessage` / `connect`（`Object.keys` 是空的），没有 `id` / `lastError` / `onMessage`——正好是 Chrome 给普通网页的
  那一份。`browser.runtime.sendMessage("<扩展 id>", msg)` 真会打到后台的 `chrome.runtime.onMessageExternal`
  （`onConnectExternal` 同理），`return true` + 异步 `sendResponse` 也正常，sender 带 `url` / `origin`。
  可 Chrome 生态的站点判断"扩展在不在"清一色是 `"chrome" in window` + `chrome.runtime.sendMessage(id, msg, cb)`：
  userstyles.org 登录后就是这样把 Firebase token 递给 Stylish 的，`chrome` 不存在 → 静默什么都没发生 → 扩展永远未登录、
  "No Styles Installed"。修法只需一层别名，不用自己造桥：`BrowserExtensionCompat.externalMessagingScript` 生成的
  page world 用户脚本（document start、全部框架），在地址命中某个已装扩展 `externally_connectable.matches` 时补出
  `chrome.runtime.sendMessage` / `connect`（转给 `browser.runtime`，无回调返回 Promise、有回调按 Chrome 语义调回调），
  已有 `chrome` 时一概不动。注意 WebKit 把这两个网页侧 stub **无条件**挂在每个页面上（没有任何扩展声明
  externally_connectable 时也在），投递本身才鉴权——发给不匹配的来源只会静默 resolve `undefined`（不报错、后台收不到），
  所以匹配判断只是"别在无关站点上凭空多出 `chrome` 这个指纹"，不是安全边界。
- **内容脚本里 `chrome.runtime.getURL()` 返回 `webkit-masked-url://hidden/`**（2026-09-07）：拿它当 `<script src>`
  注入 web_accessible_resource 照样能加载执行（落在页面主世界），但字符串是被屏蔽的，`document.querySelectorAll("script")`
  读回来也是它——扩展如果拿自己的 WAR URL 做字符串比较就会失灵。另外 MV3 的 `"world": "MAIN"` 内容脚本 WebKit 认，
  隔离世界与主世界互相看不见彼此的全局变量（与 Chrome 一致）。

## WKDownload 进度 UI（2026-09-06）

- **连接就失败的下载不会走 `decideDestinationUsing`**：目的地是收到响应之后才谈的，`http://127.0.0.1:9/`
  这种连接被拒的下载直接跳到 `didFailWithError`。所以列表条目要在**挂代理那一刻**（`didBecome download` /
  `startDownload` 的回调里）就建好（文件名先用请求 URL 猜），`decideDestinationUsing` 再回填真正的落盘路径，
  否则失败的下载在界面上根本不存在。
- **进度来自 `WKDownload.progress`**（WKDownload 遵守 `NSProgressReporting`）：KVO 观察
  `fractionCompleted`，回调可能不在主线程，且大文件每收一个包就来一次——统一 `DispatchQueue.main.async`
  再节流到 ≤ 10 Hz 才刷界面（`BrowserDownloadList.notifyInterval`）。总大小未知时
  `totalUnitCount <= 0`，聚合进度要返回 nil（不确定）而不是 0。
- **取消后 WebKit 还会回调一次 `didFailWithError(NSURLErrorCancelled)`**：状态流转要幂等
  （`markFailed` 只作用于仍在进行中的条目），否则"已取消"会被翻成"失败：cancelled"。
- **工具条上的按钮隐藏时要连间距一起收成 0**：`isHidden` 只是不画，Auto Layout 的宽度与间距仍然占位，
  地址栏会平白短一截。按钮插在地址栏与扩展条之间时只切**宽度（22 / 0）与右侧间距（-6 / 0）**，
  左侧 6pt 是地址栏与扩展条之间本来就有的间距，必须一直留着——两侧都切成 0 的话，没有下载时地址栏的
  圆角边框会直接顶到扩展条的拼图按钮上（pane 内不能有必需的宽度约束，见上面的浏览器 pane 一节）。
- **`NSButton.isFlipped == true`**（NSView / NSControl 是 false）：自绘按钮在 `draw(_:)` 里 +y 是**向下**的。
  圆弧 / 箭头 / 勾这类按"y 向上"写的几何会画成上箭头、倒勾、从 6 点开始逆时针的进度环，而圆环本身对称
  看不出来。要么 `override var isFlipped: Bool { false }`（本类完全自绘、不调 `super.draw`，这样最省事），
  要么整套几何改写成 y 向下。回归测试只能走 `cacheDisplay(in:to:)`（它按 isFlipped 设 CTM）后读位图，
  直接调 `draw(_:)` 用的是当前上下文的坐标系，验不出来。
- **`NSPopover.contentViewController` 是强引用**：内容控制器再存一个 `lazy var popover` 反持它就成了两个
  对象互锁的环，谁也不会释放。NSPopover 要由**展示方**（这里是 pane）持有；而且判断"弹出层开着吗"要用
  `host?.isShown == true` 这种可选链，别为了读一个 `isShown` 把 lazy 的弹出层实例化出来。
- **同名并发下载的目的地不能只查磁盘**：WebKit 是收到 `decideDestinationUsing` 的回复之后才在网络进程里
  建文件的，两条同名下载的 decideDestination 可能都赶在建文件之前 → 拿到同一个路径，后一条直接
  `NSURLErrorCannotCreateFile(-3000)` 甚至没有任何回调地卡住。去重时要把"已经交给别的进行中下载"的
  目的地一起算作占用。
- **pane 关闭时进行中的下载明确取消**（`paneWillClose`）：下载列表是 pane 私有的，`WKDownload.delegate`
  又是弱引用（pane 走了自动置空），不取消就是一堆没有界面、没有代理的传输在后台跑。


## scrolling 条带的视口对齐（2026-09-07）

- **"揭示新列"不能挂在焦点上**：`insertNewPane` 只改 `model.layout`，视口滚动由 `ScrollingStripView`
  按焦点决定；而焦点是**异步**落地的（`PaneView.moveFocus` 要等新 pane 挂进窗口才 `makeFirstResponder`，
  浏览器 pane 的 FR 还要再经内部 WKWebView 慢一拍，实测 0.10s vs 终端 0.05s），
  `.onChange(of: layoutSignature)` 触发时焦点通常**还在原 pane 上**。于是新列的揭示完全依赖
  "焦点最终落地并让 PreferenceKey 的聚合值发生变化"这一条链路——中间任何一环被吃掉（悬停焦点抢走、
  焦点往返被合并进同一次 SwiftUI 更新因而聚合值没变、旧 pane 残留 `focused` 标志），视口就停在上一个
  焦点的位置，新列卡在视口右缘外：**看起来像"新建的浏览器宽度不对"（焦点边框是它的，内容被窗口裁掉），
  其实列宽、pane 帧、offset 公式全都是对的**。修法是**按身份揭示**：视图记住上一轮的 pane id 集合，
  结构变化时优先滚到"这一轮新出现的 pane"，与焦点何时落地无关（`ScrollingStripView.revealTarget()`）。
- **同一个 `focused` 标志，两条路径必须挑同一个 pane**：`FocusedStripPaneKey.reduce` 是**末位胜出**，
  而按标志线性扫描的 `first { $0.focused }` 是**首位胜出**。视图重挂期间两个 pane 可能同时挂着 `focused`
  （AppKit 不发 resign，见上文），两条路径就会各滚各的、且之后再也不纠正。判定一律**先看窗口真 FR**
  （`holdsFirstResponder`），退化时取末位，与 reduce 对齐。
- **`layoutSignature` 刻意不含 `widthFactor`**（免得右键拖拽调宽逐帧把视口劫持回焦点列），代价是
  **列宽变了没人重排视口**：切"每屏可见列数" / Cmd+Ctrl+= 之后列变窄、总宽从溢出变成填满，旧 offset
  就把整条带推到视口外（实测 5 列全部被左缘裁掉）。补一条只**夹取**不跟焦点的 `clampOffset`，由列宽数组
  本身触发（窗口改大小同理）。
- **视口对齐的回调不能挂在 zoom 分支里**：`ScrollingStripView` 的主体是
  `if let zoomed = strip.zoomedPane { … } else { HStack … }`，zoom 一开一关就把 `else` 整支拆掉重建；
  而**所有结构操作都顺手清 zoom**（`insertingColumnRight`/`dropping`/`mergingOrSplitting`/`swapping`），
  于是"Cmd+F 之后 Cmd+B（或 ⌘点链接）"的**解除 zoom 与插列落在同一次 SwiftUI 更新**里：
  重建出来的 HStack 只会走 `onAppear`（把刚插进来的 pane 也记成"早就见过"），`onChange` 又不对刚创建的
  视图触发（没写 `initial: true`），按身份揭示整条失效、退回只靠焦点的老路。
  所以 `onAppear` 认身份、`onChange(of: layoutSignature)` 揭示、`onChange(of: widths)` 夹取、
  换工作区归零这几条**一律挂在 zoom 分支外面**（`ZStack` 上），只有 `onPreferenceChange`（焦点）与
  `onChange(of: pan)`（平移）留在 HStack 上——它们只在条带铺开时才有意义。
- **夹取在手势进行中不能带动画**：⌘+右键拖拽调宽是**逐事件**写 `widthFactor`，条带停在右端时每个事件都会
  触发一次 `clampOffset`；带 0.15s easeOut 的话每帧重设动画，视口拖着尾巴、末列右缘漏空、内容还反着手指
  方向滑。判据用**列数有没有变**：变了才是插/删列（动画兜底），没变就是纯宽度手势，直接
  `Transaction.disablesAnimations` 赋值跟手（与 `applyPan` 进行中的处理一致）。
- **回归测试要能"没有焦点也断言"**：只走 `perform(.newBrowser)` 的用例在测试宿主里是绿的——没有真鼠标，
  焦点 0.1s 内就落地并把视口救回来了。真正卡得住的写法是**只插列、不请求焦点**，再断言新列完整落在
  视口内（`testInsertedColumnIsRevealedWithoutFocusLanding`；未修复时实测 pane 位于 x 993.5…1314，
  视口右缘 1020）。zoom 路径另有一条
  （`testInsertedColumnIsRevealedAfterZoomWithoutFocusLanding`：先 Cmd+F 再只插列不请求焦点）。

## 多窗口（「屏幕」，2026-09-08）

- **NSEvent 本地监视器是进程级的**：每个控制器装一份，N 个窗口就有 N 份，每次事件都会全部跑一遍。keyDown /
  scrollWheel 早就有 `event.window === window` 守卫，`.flagsChanged` 与拖动会话分支必须补上。
- **`object: nil` 的 NotificationCenter 观察者会跨窗口执行**：引擎的 close-surface / child-exited 与「全部等分」
  在单窗口下无所谓，多窗口时会让另一个屏幕一起等分、或对不属于自己的 pane 调 paneWillClose。观察者开头按
  `model.allPanes` 判归属。
- **单闭包回调撑不住多窗口**：`ThemeManager.onOverlayChanged` 这类 `var callback: (() -> Void)?` 会被后建的窗口
  覆盖，先建的窗口从此收不到主题热切换。改成按 token 的多监听。
- **关窗口的释放时序**：`windowWillClose` 里先 teardown（监视器 / 观察者 / Combine / 每个 pane 的 paneWillClose），
  但**下一轮 runloop** 才从注册表摘除控制器——引擎回调可能还在栈上，提前释放 surface 会 UAF。teardown 会清空模型，
  所以「关最后一个屏幕」必须先存档再关，否则退出时写出去的是空布局。
- **`NSApp.presentationOptions` 是进程级的**：非原生全屏要按窗口记账 + 引用计数，key 窗口切换时重新贴合；
  「任一窗口全屏时所有显示器的菜单栏都隐藏」是 API 决定的，消不掉。
- **`NSScreen` 实例不能持久化也不能长期持有**：显示器配置一变就重建。菜单项里存
  `CGDisplayCreateUUIDFromDisplayID` 的 UUID 字符串，用时再解析；恢复位置按 UUID → localizedName → 主屏三级回退，
  并一律 `constrainFrameRect` 进目标屏可见区——显示器没了只影响位置，绝不丢窗口和布局。
- **持续写盘要防「写空」**：任何「模型已清空 / 控制器已 teardown / 窗口全关」的时刻都可能被防抖定时器撞上。
  写盘前过滤已关闭的控制器，快照为空直接不写，退出走同步写。
- **版本探测要精确匹配**：`case current...` 这种开区间会把未来版本的存档当成当前版本读（未知 pane kind 解码失败
  还会被「宽松解码」整窗丢掉），再被下一次防抖写盘覆盖。只认相同版本，其余按外来文件备份后重开。
- **终端 pane 的 cwd 只有 shell 发过 OSC 7 才有**：恢复出来的 pane 在用户敲第一条命令前 `pwd` 是 nil，持续写盘
  会把存档里原本正确的目录覆盖成 null。编码时回退到创建时的 `workingDirectory`。
