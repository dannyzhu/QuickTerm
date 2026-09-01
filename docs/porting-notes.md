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
