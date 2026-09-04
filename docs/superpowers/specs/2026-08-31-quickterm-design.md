# QuickTerm 设计方案

**日期**：2026-08-31 · **状态**：✅ 已交付并持续迭代（本文为 **v8 对齐修订**，2026-09-03，与 `main` 代码逐节核对）

**修订史**
- **v2**：字体 Monaco（UI 图标 SF Symbols）；工作区 `Cmd+数字`、默认 5 个；`Cmd+方向键` 切终端；`Cmd+鼠标拖拽` 移动/分裂/调整 pane
- **v3**：快捷键全部可经 config `[keybinds]` 改键；引擎配置优先复用 `~/.config/ghostty/config`（四层配置链）
- **v4**：焦点跟随鼠标；激活/非激活 pane 动态透明度
- **v5**：工作区默认布局改为 **scrolling 无限横向画布**（Omarchy/Hyprland `scrolling`），dwindle 保留、`Cmd+L` 切换
- **v6**：`pane-padding`（默认 14pt）；间隙统一 Hyprland 语义（相邻/外圈均 10pt）；scrolling 填充模式
- **v7**：`Cmd+T` 浮动 pane（⌘拖移动 / ⌘右拖调大小）；state v3
- **v8（本版）**：透明度体系定案（`pane-opacity` 0.92 / `active-opacity` 0.98 / `bar-opacity` 0.75 / 磨砂）；浮动 pane 默认几何与遮挡判定（HoverOcclusion 模型几何）；`visible-columns`；换位后视口跟随；背景系统 2.0（全量 Omarchy 背景 + 用户自选）；Apple 风格图标；NSHostingView flipped 坐标约定；§3/§5/§6/§7 全部按实现改写；标注未实现项

一句话定位：**把 Omarchy 的 Hyprland 平铺桌面装进一个 macOS 原生窗口，里面全是终端。** 纯 Swift（AppKit + SwiftUI 混合），终端引擎为 libghostty（GhosttyKit，pin Ghostty v1.3.1），界面与快捷键忠实效仿 Omarchy。

---

## 1. Omarchy 调研结论（设计依据）

以下对照 `omarchy` 仓库（basecamp/omarchy）源码与官方手册核实。本节记录的是 **Omarchy 的做法**；QuickTerm 的落地值以 §4 为准，差异处已标注。

### 1.1 视觉语言（QuickTerm 要复刻的"味道"）

| 元素 | Omarchy 的做法 | QuickTerm 落地 |
|---|---|---|
| 圆角 | **0（全直角）**——窗口、顶栏、菜单、OSD 一律方角 | 同 |
| 边框 | 2px；活动 = 主题 accent，非活动 = 灰 `rgba(595959aa)` | 同（非活动边框色硬编码，不随主题） |
| 间隙 | `gaps_in = 5`，`gaps_out = 10` | 每 pane 边 5 + 外圈 5 → 相邻/外圈均 10 |
| 透明度 | 活动 0.985 / 非活动 0.96 | 三层合成：引擎 0.92 基准 + 激活垫层合成到 0.98 + 非激活压暗 0.96 + 磨砂（§4.9） |
| 字体 | JetBrainsMono Nerd Font：顶栏 12px、菜单 18px | UI 用 Monaco：顶栏 12、面板 15/13/11；**终端字体交给 ghostty 配置**（§4.12） |
| 动画 | 开窗 popin 87%；切工作区无动画 | popin 0.87 缩放淡入 0.2s easeOut；切工作区瞬时 |
| 顶栏 | 26px、主题色实心条、单色图标 | 26pt、**半透明 0.75**（壁纸透出）、SF Symbols 单色 |
| 布局 | dwindle + 可切换 scrolling（`column_width = 0.49`） | **scrolling 默认**（列宽 (1−2×1.5%)/列数 = 0.485，每侧露边 1.5%），dwindle 保留，`Cmd+L` 切换 |

### 1.2 顶栏（Waybar）结构

- **左**：logo + 工作区号 `1–5` 常驻（活动工作区实心方块，空工作区 50% 透明，可点击）
- **中**：时钟 `Sunday 14:32`；备用格式显示完整日期
- **右**：蓝牙、网络、音量、CPU、电池——单色图标

### 1.3 主题系统

- 上游当前 **22 个主题**（5 个浅色：catppuccin-latte / flexoki-light / lupine / rose-pine / white），Tokyo Night 默认
- 每主题一个 `colors.toml` + `backgrounds/` 多张背景图（`0-`、`1-` 前缀排序）
- 主题选择器 `Super+Ctrl+Shift+Space`；背景菜单 `Super+Ctrl+Space`

### 1.4 菜单（omarchy-menu / Walker）

居中面板、等宽字体、主题色 2px 实线边框、0.95 透明度背景、无圆角。

### 1.5 键位目录

约 130 条桌面级绑定已核实。**Omarchy 的 `Super+C/V` 本来就是在模仿 macOS 的 `Cmd+C/V`**——Super→Cmd 映射天然顺滑。

---

## 2. 技术选型

### 方案 A（已采用）：嵌入完整 libghostty（GhosttyKit）

Ghostty 自家 macOS 应用消费的内部 C API：`ghostty_app_new/tick`、`ghostty_surface_new`（Metal 渲染在库内完成）、输入/尺寸/缩放、剪贴板与动作回调、逐 surface 配置热更新。

- ✅ 最高保真：GPU 渲染、连字、Kitty graphics、完整 VT——与 Ghostty 本体同级
- ✅ MIT 许可；有 OrbStack 等商业先例
- ⚠️ 该 API **内部、不稳定、无兼容承诺**：pin tag + 对应 Zig 版本自建 xcframework；升级 Ghostty 视为独立移植任务
- **实际落地**：嵌入层直接移植 Ghostty `macos/Sources/Ghostty/` 到 `Sources/GhosttyEmbed/`（MIT），**未做 `TerminalEngine` 协议抽象**（v1 直接依赖移植层；官方 Swift 包落地后再考虑隔离）

### 方案 B：SwiftTerm — 退路，未取。方案 C：libghostty-vt + 自研渲染 — 工作量最大，未取。

---

## 3. 总体架构

**AppKit 掌管状态与生命周期，SwiftUI 只做纯渲染。** 布局模型全部是不可变值类型（`Codable`），持久化与切换零成本。

```
AppDelegate (AppKit 生命周期；测试宿主隔离 isRunningTests)
├─ Ghostty.App                                     ← 移植层引擎包装（ghostty_app）
├─ ThemeManager                                    ← 主题/背景/透明度状态；生成 engine-overlay.conf
└─ MainWindowController : BaseTerminalController   ← 状态唯一拥有者、全部 WM 动作、鼠标/键盘监视器
   ├─ HiddenTitlebarWindow : NSWindow              ← 隐藏标题栏配方
   ├─ WorkspaceModel (ObservableObject)            ← [WorkspaceLayout] + [[FloatingPane]] + activeIndex
   │    WorkspaceLayout = .scrolling(ScrollingStrip) | .dwindle(SplitTree)
   ├─ KeybindingMap (值类型) + ConfigStore/Watcher  ← 键位表 + config.toml 热重载
   └─ contentView = NSHostingView(RootView)        ← SwiftUI（注意：flipped 坐标，§4.3）
        ZStack {
          theme.background + WallpaperThumb        ← 整窗壁纸（延伸到顶栏身后）
          VStack { StatusBarView (26pt, 半透明)
                   ZStack { ScrollingStripView | TerminalSplitTreeView   ← 双布局分支
                            浮动层 (ForEach FloatingPane → ScrollingPaneCell)
                            Scratchpad 覆盖层
                            OverlayPanelView 遮罩+面板 } }
        }
```

### 3.1 组件清单

| 组件 | 职责 | 关键接口 / 说明 |
|---|---|---|
| `Ghostty.App` / `Ghostty.SurfaceView`（`Sources/GhosttyEmbed/`） | 引擎包装、surface 承载（Metal 由库内建）、按键/IME/鼠标转发、焦点态、cwd 持久化 | 移植自 Ghostty（MIT）；QuickTerm 改动处以 `// QuickTerm：` 注释标记 |
| `SplitTree<Pane>` | 不可变二叉树：insert/remove/swap/resize/equalize/zoom/空间导航，`Codable` | 移植（约 1400 行）；`SplitTree+QuickTerm` 加 dwindle 方向规则与翻转 |
| `ScrollingStrip` | 不可变列条带：列 = 纵向 pane 栈；插列/删除/焦点/换位/併拆/调宽/等分/zoom/拖放；视口几何纯函数（`columnWidths`/`targetOffset`）；`layoutSignature` | 与 dwindle 互转保 pane 保序 |
| `WorkspaceModel` | 每工作区布局 + 浮动层；`switchTo`、`setWorkspaceCount`、`layoutsMatch(factor:)`；Scratchpad 单例 surface；面板状态 | `Sources/Windowing/RootView.swift` |
| `FloatingPane` / `HoverOcclusion` | 浮动 pane 归一化 rect（`defaultRect`、`clamped`）；模型几何遮挡判定 | §4.4 / §4.3 |
| `MainWindowController` | 全部 WM 动作分派（`perform(_:)`）；三个 `NSEvent` 本地监视器（键盘 / ⌘鼠标 / 滚轮）；浮动移动与调大小；面板导航；状态 v3 持久化；配置应用 | 继承 `BaseTerminalController` shim（`focusFollowsMouse`、`surfaceIsOccluded`） |
| `StatusBarView` + `SystemStatsService` | 仿 waybar 顶栏；CPU / 音量 / 电池 2s 采样，网络走 NWPathMonitor 事件；时钟 30s | `StatusBarView.height = 26` |
| `ThemeManager` | 主题发现（bundle ∪ 用户目录）、切换、背景列表（主题自带 + 用户目录）、透明度四值、`overlayExtra()` 生成引擎覆盖层 | `apply`/`selectBackground`/`addUserBackground`/`toggleOpacity`/`toggleGaps` |
| `OverlayPanelView` | 四合一居中面板：主题 / 背景网格 / 速查 / 主菜单 | `backgroundsColumns = 3` |
| `ConfigStore` + `ConfigWatcher` + `EngineOverlay` | `config.toml` 极简 TOML 解析、目录级监听热重载（0.2s 去抖）、覆盖文件写入 | 解析失败静默回退默认（**无顶栏警告**） |
| `KeybindingMap` + `WMAction` | 默认键位表、用户覆盖/解绑合成、键名规范化、速查表数据源 | 未命中一律放行给终端 |

### 3.2 关键机制

- **隐藏标题栏**：styleMask 保留 `.titled + .fullSizeContentView + .resizable + .closable + .miniaturizable`，标题与红绿灯隐藏、禁用系统 tab；保留 `.titled` 才有正常阴影与恢复行为。
- **按键拦截**：窗口级 `NSEvent.addLocalMonitorForEvents(.keyDown)`：① 面板打开时先由 `handlePanelKey` 接管 ↑↓←→/↩/⎋；② 查 `KeybindingMap`；③ 未命中 `return event` 放行给 surface。菜单栏另镜像 9 条常用动作（keyEquivalent 写死、不随改键，仅供可见）。**WM 级键由 QuickTerm 解析；终端级键（复制/粘贴/字号）由 libghostty 自己的配置解析。**
- **工作区 = 多个布局值换着渲染**：`[WorkspaceLayout]` + index；切换瞬时无动画。
- **zoom = 只渲染该 pane**：任何结构性变更自动清 zoom。
- **连续壁纸**：窗口不透明；`RootView` 最外层 ZStack 铺 `theme.background` + `WallpaperThumb`，顶栏与所有 pane 都压在壁纸之上；surface 以引擎 `background-opacity` 透出壁纸。
- **主题热切换**：`ThemeManager.writeOverlay()` 重写 `engine-overlay.conf` → `onOverlayChanged` 钩子：app 级 `reloadConfig` + 每个 surface reload + `applyAppearance()`（浅色主题联动 `NSAppearance` 与 `ghostty_app_set_color_scheme`）。
- **引擎配置链**：四层（§4.10）。
- **非原生全屏**（精简版）：保存 frame + `presentationOptions = [.autoHideDock, .autoHideMenuBar]` + 同步 `setFrame(screen.frame)`，不改 styleMask；`Ctrl+Cmd+F` 切换、`Cmd+Esc` 专用退出。
- **坐标系约定**：`contentView`（NSHostingView）`isFlipped == true`，`convert(locationInWindow)` 得到的已是 top-left 坐标；所有窗口坐标→内容区归一化统一走 `normalizedContentPoint`（isFlipped 感知），有回归测试锁定。
- **测试宿主隔离**：`AppDelegate.isRunningTests`（探测 `XCTestConfigurationFilePath`）——测试下不恢复/保存状态、空树不关窗。

### 3.3 错误处理

- 引擎初始化失败 → 启动 Alert + 退出
- surface 创建失败 → `SurfaceView` 带错误态（`error = .apiFailed`）入树，不拖垮整树
- 配置/主题解析失败 → 静默回退默认值（无 UI 告警）
- 状态存档损坏或版本不兼容 → 丢弃存档全新开始

---

## 4. 功能规格（与实现对齐）

### 4.1 快速创建终端

- `Cmd+Return`：scrolling = 焦点列**右侧插入新列**；dwindle = 按规则分裂（宽>高向右，否则向下——几何取自 SplitTree 在内容区尺寸内的空间布局，不依赖视图 frame）。**继承焦点 pane 的 cwd**。dwindle 新分裂只做局部动效：原 pane 从占满收缩到 ratio、新 pane 渐显（0.28s），树视图不再整树重建（叶子按 surface id 定身份，弹入动画仅 pane 首次出现时播放）。
- 新 pane 弹入动画：0.87 缩放淡入，0.2s easeOut；新 pane 初始 `focused = false`，由 first responder 回调驱动（避免双激活边框）。
- `Cmd+S`：Scratchpad（§4.4）。主菜单亦可新建。

### 4.2 布局：scrolling（默认）与 dwindle

**scrolling（新工作区默认）**：工作区 = 无限横向列条带，每列是纵向 pane 栈。
- 列宽因子默认 `(1 − 2×peek) / visible-columns`，`peek = 1.5%`（默认 2 列 → 0.485）；可调 0.25–0.90，键盘 ±0.05。
  露边只需露出邻列的 gap+边框+一点底色提示"那边还有"（≈15pt @1000pt 视口）；6% 试过，用户反馈太宽。
- **填充模式**：名义总宽装得下时按比例放大填满（单列满屏、两列左中右等隙）；溢出才按名义宽度**最小滚动 + 露边**——滚动目标 = 焦点列完整可见且外侧留一个露边，因此焦点在内部时中间两列全显、左右邻列各露一截（对称），到两端自然贴边。视口跟随 0.15s easeOut。
- **视口对齐触发**：焦点变化 / `layoutSignature`（列序·行序结构签名）变化 / 工作区切换 / 双指平移。签名**刻意不含列宽**——右键拖拽逐事件调宽入签名会把手动平移的视口劫持回焦点列。
- 键位：`Cmd+←/→` 跨列（落到同高度最近行）、`Cmd+↑/↓` 列内；`Cmd+Shift+方向` 列换位/列内换位；`Cmd+J` 单 pane 列併入左列 ⇄ 多 pane 列拆出；`Cmd+Ctrl+←/→` 调宽、`Cmd+Ctrl+=` 全列重置为当前因子（`Cmd+Ctrl+↑/↓` 无操作）；`Cmd+W` 关 pane、空列删除、焦点左移。
- 每屏可见列数：config `visible-columns`（1–6）优先，否则 UserDefaults（默认 2）；主菜单「每屏列数」回车循环 2→3→4→2，切换后**所有** scrolling 工作区重排。
- 触控板双指横滑平移画布，松手吸附最近列左缘；内容不溢出时忽略。

**dwindle（保留）**：Omarchy 规则分裂；`Cmd+J` 翻转最近一层分割方向；分隔条 1pt 可见 + 6pt 热区，拖拽调比例、**双击等分**（v8 修复：接上引擎 `didEqualizeSplits` 回调）；`Cmd+Ctrl+方向` 4 向调整 100px（`+Shift` 10px）。

`Cmd+L` 按工作区在两布局间切换，pane 保留、顺序不变（列 → 右分裂链，列内栈 → 下分裂链）。
往返有记忆：每工作区记住上次离开的布局，pane 集合未变时原样恢复（列栈/列宽/顺序不丢——转换是有损的，5 个 pane 的 3 列排布摊成 5 单列会溢出视口）；pane 有增减才退回上述转换，且转换出的列宽遵循当前每屏列数。

### 4.3 焦点、换位、拖放与遮挡判定

- **焦点跟随鼠标**（常开）：`SurfaceView.mouseMoved` → `Ghostty.moveFocus`。
- **遮挡判定（HoverOcclusion，v8）**：tracking area 不感知兄弟视图遮挡；hover、`mouseEntered`、**左键点击焦点转移**三处都经 `surfaceIsOccluded` 守卫——只有「更高 z 的浮动 pane / 面板遮罩 / Scratchpad」构成遮挡。**刻意不用 hitTest**：⌘ 按住时每个 pane 上都叠着可命中的拖拽源浮层、overlay 滚动条闪现时也会被误判。被遮挡的 pane 合成一次 `mousePos(-1,-1)` 清掉 TUI 悬停高亮；脱离遮挡首次移动补进入状态。拖拽序列不走守卫（跨 pane 选中文本不受影响）。
- **线性循环**：`Alt+Tab` / `Alt+Shift+Tab` 或 `Cmd+]` / `Cmd+[`。**键盘方向/循环焦点只在平铺层查找**；浮动 pane 靠悬停/点击取得焦点。
- **⌘ + 左键拖拽（平铺 pane）**：按住 ⌘ 时 pane 上浮出拖拽源；落区左/右缘 = 目标列旁插新列，上/下缘 = 併入目标列栈，中心 40%×40% = 交换。dwindle 语义对应分裂插入/交换。
- **⌘ + 右键拖拽**：scrolling 按横向位移改列宽；dwindle 调就近分隔条（幅度 1–200）。

### 4.4 浮动 pane 与 Scratchpad

- `Cmd+T`：焦点 pane 浮起 ⇄ 落回平铺。浮起默认几何（类 Omarchy `togglefloating`）：**宽 = 列宽因子 × 0.75（夹 0.15–1.0），高 = 内容区 45%，居中**。落回：scrolling 追加到尾列右侧新列；dwindle 插到首个叶子处。
- 归一化 rect（0–1，top-left），窗口缩放按比例跟随；`clamped()`：尺寸夹 0.15–1.0，位置允许左/右/下缘最多露出一半、顶缘不越界。
- 数组序 = z 序（末位最顶）；⌘+左键按下先置顶再自由移动；⌘+右键拖调大小。指针命中回退查找按 z 序自顶向下。
- 浮动 pane **不注册拖放目标**（避免亮出无效落区色块）；非激活时**不垫磨砂**（身后是其他 pane，磨砂会糊成实心）；有投影。
- `Cmd+Shift+数字` 连浮动状态一起搬到目标工作区。state v3 持久化浮动层，兼容读 v2。
- **Scratchpad**（`Cmd+S`）：全局单例 surface（首次按需创建、继承当前 cwd），内容区 70%×60% 居中、accent 2px 边框、0.2 黑遮罩点击关闭；**不持久化**。

### 4.5 工作区

默认 5 个（config 1–10；>5 时自动补 `Cmd+6…9,0` 与 `Cmd+Shift+…`）；`Cmd+数字` 切换（瞬时）、`Cmd+Shift+数字` 移动焦点 pane 并跟随；顶栏滚轮循环、胶囊点击直达；缩容不丢有内容的工作区；每工作区独立布局类型 + 浮动层；所有工作区（含浮动）皆空才关窗。

### 4.6 顶部状态栏（仿 waybar，26pt）

| 区域 | 内容 | 交互 |
|---|---|---|
| 左 | `◆` + 工作区胶囊 1–N（活动 = `■` accent 色；空 = 50% 透明） | 胶囊点击切换；顶栏区域滚轮循环工作区 |
| 中 | 时钟 `Sunday 14:32`（30s 刷新） | 点击切换 `31 August W36 2026` |
| 右 | CPU%、网络（wifi / 有线 / 断网）、音量、电池（充电仅图标；≤20% 未充电变红） | 音量图标点击静音/取消 |
| 整条 | Monaco 12、SF Symbols 单色、无圆角、**半透明 0.75**（`bar-opacity`，受 `Cmd+Backspace` 总开关） | 空白处双击 = 窗口 zoom；`Cmd+Shift+Space` 显示/隐藏 |

未实现（原方案曾列）：logo 点击开主菜单、CPU 点击弹 top/btop、电池点击通知。

### 4.7 面板（Walker 风格，四合一 `OverlayPanelView`）

统一外观：居中、420pt 宽（速查 560）、0.95 背景、2px accent 直角边框、Monaco 15；背后 0.25 黑遮罩点击关闭。键盘：↑↓ 选择、↩ 确认、⎋ 关闭（面板打开时优先接管，且忽略修饰键）。

- **主题选择器**（`Cmd+Ctrl+Shift+Space`）：名称 + light 标记 + 8 色色板；打开时定位当前主题；选中即热切换。
- **背景选择器**（`Cmd+Ctrl+Space`）：**固定 3 列**缩略图网格（76pt 高，可滚动）；↑↓ 按行 ±3、←→ ±1；末位「**选择图片…**」入口经 NSOpenPanel 导入（§4.8）。**面板已打开时再按同一键 = 切下一张背景**（回绕）。
- **快捷键速查**（`Cmd+K`）：由当前生效映射表实时生成（含用户覆盖），符号化显示。
- **主菜单**（`Cmd+Alt+Space`）10 项平铺：新建终端 / 主题… / 背景… / 每屏列数（回车原地循环 2→3→4，面板保持打开）/ 顶栏显示/隐藏 / Gaps 开关 / 透明度开关 / 快捷键速查 / 设置 / 关于。**无层级导航、无搜索框、无 Font 项。**

### 4.8 主题与背景

- 主题包与 Omarchy 同构：`<name>/{colors.toml, backgrounds/*}`。内置 **22 个**（`Themes/`，`scripts/fetch-themes.sh` 从上游全量同步，colors.toml 进 git、**背景图不进 git**——构建期打入 bundle）；用户目录 `~/.config/quickterm/themes/` 同名优先。默认 tokyo-night。
- 切换：重写 overlay（配色 / palette 0–15 / 光标 / 选区）→ 引擎热重载 + UI 调色板刷新；浅色主题联动系统外观。`theme = "ghostty"` = 不接管配色（padding 仍注入；总开关关闭时仍注入不透明覆盖，见 §4.10）。
- **背景候选 = 当前主题自带 + 用户自选目录 `~/.config/quickterm/backgrounds/`（扁平、全主题共用；png/jpg/jpeg/webp/heic/gif/tiff）**，共用一个 index（UserDefaults 持久化，切主题重置为 0）。「选择图片…」→ 拷入用户目录（重名加时间戳）→ 立即选中。切背景不重载引擎。

### 4.9 透明度、磨砂与间距

| 值 | 键 | 默认 | 机制 |
|---|---|---|---|
| pane 基准 | `pane-opacity` | 0.92 | 注入引擎 `background-opacity`（全 pane） |
| 激活 pane | `active-opacity` | 0.98 | 纯 UI：激活 pane 背后垫主题底色，alpha = `(active − pane) / (1 − pane)`，零引擎 reload |
| 非激活压暗 | —（硬编码） | 0.96 | 引擎 `unfocused-split-opacity` |
| 顶栏 | `bar-opacity` | 0.75 | 纯 UI |
| pane 留白 | `pane-gap` | 5 | 纯 UI；每 pane 每边留白 pt，scrolling / dwindle / 浮动一致（相邻 = 2×gap = 10pt；dwindle 1pt 分隔线画在边界上不占布局）；外圈同值；旧键 `dwindle-gap` 作别名 |
| 浏览器首页 / 搜索 / UA / Inspector | `browser-home` / `browser-search` / `browser-user-agent` / `browser-inspectable` | google / google search / safari / false | 浏览器 pane 行为；UA 为 `safari`（伪装）/ `webkit`（不伪装）/ 自定义 |
| 文件管理器程序 | `file-manager-command` | yazi | `file-manager` 动作运行的程序：名字按 PATH + Homebrew/cargo 常见目录查找，或绝对路径；yazi/lf/ranger 退出写最后目录（--cwd-file / -last-dir-path / --choosedir） |
| dwindle 分隔线 | `divider-opacity` | 0.2 | 纯 UI；SplitView 的 1pt 分隔细线（色 = 引擎 split-divider-color）按此不透明度半透明，受总开关（关闭 = 实线） |
| 非激活磨砂 | `inactive-blur` | 2.5 | `NSVisualEffectView(.hudWindow, .withinWindow)` backdrop——模糊的是壁纸，文字锐利。**数值目前只作开关（> 0 开启）**，未作为半径生效 |

`Cmd+Backspace` 总开关：pane → 引擎 1.0 / 1.0、顶栏不透明、关磨砂。`Cmd+Shift+Backspace` gaps 开关（纯 UI）。边框 2px（accent / 灰）、直角、`pane-padding` 14pt（0–32，注入 `window-padding-x/y`）。

### 4.10 配置文件与引擎配置链

`~/.config/quickterm/config.toml`，目录级监听（捕获编辑器原子替换），0.2s 去抖，内容有变才重载。`Cmd+,` 打开（不存在先写模板；若存在 `~/.config/ghostty/config` 一并打开）。

```toml
# theme = "tokyo-night"     # 或 "ghostty"：不覆盖配色，完全跟随 ghostty 配置
# workspaces = 5            # 1–10
# pane-padding = 14         # 0–32
# visible-columns = 2       # 1–6；未设置走主菜单/UserDefaults
# pane-opacity = 0.92       # 0.5–1.0
# active-opacity = 0.98     # 0.5–1.0
# bar-opacity = 0.75        # 0–1
# divider-opacity = 0.2     # 0–1，dwindle 分隔细线
# pane-gap = 5              # 0–20 pt，每 pane 每边留白（scrolling / dwindle 一致）
# file-manager-command = "yazi"   # file-manager 动作运行的程序
# browser-home = "https://www.google.com"
# browser-search = "https://www.google.com/search?q=%s"
# browser-user-agent = "safari"
# browser-inspectable = false
# inactive-blur = 2.5       # > 0 开启磨砂

[keybinds]                  # 值 "modifier+key"；"none" 解绑；动作清单 = Cmd+K 速查表
# new-terminal = "cmd+return"

[ghostty]                   # 原样透传任意 ghostty 选项，最高优先级
# cursor-style = block
```

解析语义：极简 TOML——顶层键须在任何段头前；空行与 `#` 行不透传；值以 `"` 起则取到下一个 `"`；数值解析失败静默保留默认；未知段忽略。`[keybinds]`：键名必须是 `WMAction` id；修饰键别名 `cmd|command|super` / `shift` / `alt|option|opt` / `ctrl|control`；一个动作一个组合（覆盖会移除该动作全部默认组合）；**不做冲突检测**（撞键后写者赢）。

**引擎配置链（低 → 高）**：① libghostty 内置默认 → ①½ app 内置兜底 `Resources/ghostty-default.conf`（Monaco 15、Builtin Pastel Dark、copy-on-select、100M scrollback 等；**仅当**用户没有任何 ghostty 配置文件——XDG `ghostty/config.ghostty`/`config` 与 `~/Library/Application Support/com.mitchellh.ghostty/` 同名文件——时加载，每次重载重新判定；相对用户给的原始配置删去 `shell-integration = none` 与 tab 键位，见文件头注释）→ ② 用户 ghostty 配置文件（**QuickTerm 自行按 libghostty `loadDefaultFiles` 顺序加载存在且非空的文件**，不调 `ghostty_config_load_default_files`——1.3.1 在无配置时会往 `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty` 写出未 flush 的 0 字节模板；`config-file` 递归 include 照常）→ ③ QuickTerm 覆盖文件 `~/Library/Application Support/QuickTerm/engine-overlay.conf`（`ThemeManager.overlayExtra()` 生成：`window-vsync = false`、`window-padding-x/y`、`background-opacity`、`unfocused-split-opacity`、配色与 palette）→ ④ `[ghostty]` 段（物理上追加在 ③ 末尾）。`theme = "ghostty"` 时 ③ 只注 padding 与（关闭透明时的）不透明覆盖。`~/.config/ghostty/config` 无监听，改后需重启或触发一次 overlay 重写。**注意**：引擎在 overlay 之后才处理 `config-file` 递归包含，因此写在被包含文件里的键会压过第 3、4 层。

### 4.11 状态恢复

退出保存 `state.json`（v3）：每工作区布局与类型、浮动层、活动工作区、各 pane cwd；启动按 cwd 重开 shell。主题 / 背景索引 / 每屏列数走 UserDefaults 即时保存。Scratchpad 不恢复。存档损坏或过旧 → 全新开始。

### 4.12 字体与图标

- UI 字体 Monaco（顶栏 12、面板 15 / 13 / 11）；图标 SF Symbols。
- **终端字体 QuickTerm 不设置**（overlay 不注入 `font-family`/`font-size`），完全交给引擎链第 1–2 层。
- 应用图标程序化生成（`scripts/make-icon.swift` → `make-icon.sh` → `Resources/AppIcon.icns`）：Apple 风格单符号（圆头 ❯ + 胶囊光标），Tokyo Night 渐变体 + 轮廓光 / 球面高光 / 底部反光 / 投影。

### 4.13 已知限制（如实记录）

- `inactive-blur` 数值仅作开关；非激活边框色不随主题；无键位冲突检测；解析失败无 UI 告警；键盘焦点导航不覆盖浮动 pane；`~/.config/ghostty/config` 不热监听；⌘ 拖放交换后视口有一次约 50ms 的中间滚动（最终位置正确）。

---

## 5. 快捷键映射表（Omarchy → QuickTerm）

原则：**Super→Cmd 直译优先**；与 macOS 铁律冲突处做有依据的偏移；全部可在 `[keybinds]` 改键。默认表 44 条组合。

### 终端 / pane / 布局

| Omarchy | QuickTerm | 动作 id | 功能 |
|---|---|---|---|
| Super+Return | `Cmd+Return` | `new-terminal` | 新建（scrolling 右插新列 / dwindle 分裂，继承 cwd） |
| Super+W | `Cmd+W` | `close-pane` | 关闭焦点 pane（有活动进程二次确认；最后一个 pane 关闭后窗口保留并显示"新建终端"提示，不退出程序）。焦点去向：scrolling = 左邻（否则右/上/下）；dwindle = 接管空间的兄弟子树中最近的 pane（左/上孩子→兄弟首叶即"下一个"，右/下孩子→兄弟末叶即"上一个"，Hyprland 语义）。动效（与创建对称，0.28s）：关闭方渐隐、dwindle 下其槽位收拢、兄弟子树平滑长满；动效期间 pane 仍在布局（焦点已交出、悬停不夺焦点），到点后才真正移除；任何布局操作/工作区切换/存档前先把淡出中的 pane 立即移除；系统"减弱动态效果"时直接移除 |
| Super+←→↑↓ | `Cmd+←→↑↓` | `focus-*` | 方向焦点 |
| Super+Shift+←→↑↓ | `Cmd+Shift+←→↑↓` | `swap-*` | 换位（视口自动跟随） |
| Super+J | `Cmd+J` | `toggle-split-dir` | scrolling 併列⇄拆列 / dwindle 翻转分裂方向 |
| Super+F | `Cmd+F` | `toggle-zoom` | pane zoom |
| Super+L | `Cmd+L` | `toggle-layout` | scrolling ⇄ dwindle |
| Super+T | `Cmd+T` | `toggle-float` | 浮动 ⇄ 平铺。⌘+左键：按浮动 pane 矩形命中（含留白），中间 = 移动并置顶，四边 14pt 带 = 沿该轴缩放，四角 = 双轴缩放，对边不动，最小 0.15；⌘ 悬停显示抓手 / frameResize 光标，松 ⌘ 或离开复位；⌘+右键任意处拖动 = 右下角缩放（Hyprland） |
| Super+B | `Cmd+B` | `new-browser` | 浏览器 pane：WKWebView + 薄工具条（后退/前进/刷新、地址栏、进度），一 pane 一页；键盘焦点在 WKWebView（PaneView.focusTarget），FR 为其后代即视为 pane 持焦；WM 级 Cmd 键仍先被监视器拦截；`web-*` 动作（后退 Cmd+Shift+[、前进 Cmd+Shift+]、重载 Cmd+R、地址栏 Cmd+Shift+L、缩放 Cmd+= / - / 0、外部打开 Cmd+Shift+O）只在焦点是浏览器 pane 时消费，否则放行给终端。登录态在 WebKit 默认数据存储（跨 pane、跨重启）；默认伪装 Safari UA（Google 登录）。边界：无 Widevine、无系统密码填充、通行密钥不可用 |
| Super+Shift+F | `Cmd+Shift+B` | `file-manager` | 新 pane 运行 TUI 文件管理器（默认 yazi，`file-manager-command` 可改；以焦点 pane 目录启动；退出时目录已变则原位开终端，即 yazi `y` 包装函数语义；关闭不弹进程确认；程序缺失开提示 pane）。Cmd+F 已是 toggle-zoom，故用 Cmd+Shift+B |
| Super+‑/= | `Cmd+Ctrl+←→↑↓` | `resize-*` | 调整大小（+Shift 微调）※偏移 1 |
| — | `Cmd+Ctrl+=` | `equalize` | 全部等分 / 列宽重置 |
| Alt+Tab / +Shift | `Alt+Tab` / `+Shift`、`Cmd+]` / `Cmd+[` | `cycle-pane-next/prev` | 线性循环 |
| — | `Ctrl+Cmd+F` / `Cmd+Esc` | `toggle-fullscreen` / `exit-fullscreen` | 非原生全屏 / 退出 |

### 工作区

| Omarchy | QuickTerm | 动作 id |
|---|---|---|
| Super+1…5 | `Cmd+1…5`（>5 时 `Cmd+6…9,0`） | `goto-workspace-N` |
| Super+Shift+1…5 | `Cmd+Shift+1…5` | `move-to-workspace-N` |
| Super+S | `Cmd+S` | `scratchpad` |
| Super+滚轮 | 顶栏滚轮 / 胶囊点击 | —（硬编码） |

### 主题 / 外观 / 面板

| Omarchy | QuickTerm | 动作 id |
|---|---|---|
| Super+Ctrl+Shift+Space | `Cmd+Ctrl+Shift+Space` | `theme-picker` |
| Super+Ctrl+Space | `Cmd+Ctrl+Space`（首按开面板，面板开着再按 = 下一张） | `next-background` |
| Super+Shift+Space | `Cmd+Shift+Space` | `toggle-bar` |
| Super+Backspace | `Cmd+Backspace` | `toggle-opacity` |
| Super+Shift+Backspace | `Cmd+Shift+Backspace` | `toggle-gaps` |
| Super+Alt+Space | `Cmd+Alt+Space` | `main-menu` |
| Super+K | `Cmd+K` | `keybind-help` ※偏移 2 |
| — | `Cmd+,` | `open-settings` |

### 鼠标手势（硬编码）

悬停焦点；⌘+左拖（平铺 = 拖放，浮动 = 移动并置顶）；⌘+右拖调大小；顶栏滚轮切工作区；内容区双指横滑平移画布；顶栏双击 zoom；时钟点击换格式；音量点击静音；dwindle 分隔条拖拽 / 双击等分；面板遮罩点击关闭。

**偏移说明**：1) `Cmd+-/=` 是 mac 终端字号铁律，resize 改 `Cmd+Ctrl+方向`；2) `Cmd+K` 归 QuickTerm 速查表——**QuickTerm 不注入任何终端级 keybind**，需要清屏键请在 ghostty 配置自行 `keybind =`。

**退出语义**（2026-09-04）：`Cmd+Q`/菜单退出/引擎 quit 动作统一经 `applicationShouldTerminate`——还有打开的 pane（含浮动与 Scratchpad）时弹确认（退出/取消），一个都没有时直接退出；退出前保存状态。

**保留系统行为不占用**：`Cmd+C/V`、`Cmd++/-/0`、`Cmd+Q/M/H`。测试固化 `Cmd+C/V/-`、裸 `Esc`、`Cmd+Q`、未定义组合一律放行。

**未实现的后备键位**：`Cmd+G` pane 分组、`Cmd+O` 弹出独立窗口、`Cmd+Ctrl+V` 剪贴板历史、全局热键下拉终端。

---

## 6. 工程与构建

### 6.1 目录结构（实际）

```
quickterm/
├─ project.yml            # XcodeGen 源；QuickTerm.xcodeproj 为生成物（gitignore）
├─ Sources/
│  ├─ App/                # main、AppDelegate(+Ghostty)（测试隔离）、MainMenu、Info.plist
│  ├─ Windowing/          # HiddenTitlebarWindow、MainWindowController、RootView(WorkspaceModel)、
│  │                      # WorkspaceLayout、FloatingPane、HoverOcclusion
│  ├─ Splits/             # ScrollingStrip(+View)、PaneChrome、SplitTree+QuickTerm
│  ├─ GhosttyEmbed/       # 移植自 Ghostty macos/Sources/Ghostty（MIT）：SurfaceView、SplitTree、Config、Shims…
│  ├─ StatusBar/          # StatusBarView、SystemStatsService
│  ├─ Theming/            # ThemeManager、Theme、VisualEffectBlur、Palette（回退色）
│  ├─ Palette/            # OverlayPanel（四合一面板）
│  └─ Config/             # ConfigStore(+ConfigWatcher)、KeybindingMap、WMAction、EngineOverlay、ModifierState
├─ Tests/                 # 8 文件 59 用例（XCTest，TEST_HOST = app）
├─ Themes/                # 22 主题 colors.toml（进 git）+ backgrounds/（不进 git）
├─ Resources/AppIcon.icns
├─ vendor/ghostty         # submodule，pin v1.3.1
├─ scripts/               # build-ghosttykit.sh、fetch-zig-deps.sh、fetch-themes.sh、make-icon.sh/.swift
- 通用二进制：`GHOSTTYKIT_TARGET=universal scripts/build-ghosttykit.sh`（arm64 + x86_64，发布 DMG 必需；归档修复按架构分别处理后 lipo；详见 porting-notes「通用二进制构建」）；开发默认 `native`。
└─ docs/                  # 本方案、porting-notes.md、acceptance/、superpowers/plans/
```

### 6.2 GhosttyKit 构建管线

1. submodule pin `v1.3.1`；按 `build.zig.zon` 的 `minimum_zig_version` 自动安装精确版 Zig 到 `.tools/`
2. `zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native` → `vendor/ghostty/macos/GhosttyKit.xcframework`（不进 git）
3. `xcodegen generate` → `xcodebuild`；Ghostty 资源（terminfo、shell-integration）postBuild 拷入 bundle
4. **已固化的环境修补**（详见 `docs/porting-notes.md`）：Zig 自带网络客户端不走代理 → `fetch-zig-deps.sh` 离线预取；Xcode 26 SDK `libSystem.tbd` 缺 arm64 → 脚本内 SDK overlay + xcrun shim；libtool 丢 Zig 归档成员 → Python 逐档案名取最新重打 fat 归档；macOS 26 CVDisplayLink 会话配额 → overlay 注入 `window-vsync = false`
5. 无产物缓存判断：脚本每次都跑 `zig build`（增量靠 Zig 自身缓存）；只有 Zig 工具链下载与 SDK overlay 按已存在跳过。代理环境：先让脚本装好 Zig，再跑 `fetch-zig-deps.sh`，然后重跑脚本

部署目标 macOS 15+；开发验证于 macOS 26 / Xcode 26.6。

### 6.3 测试策略（实际覆盖）

8 个文件 59 用例：`ScrollingStripTests`（几何：填充/溢出/最小滚动/签名）、`WorkspaceTests`（工作区、浮动 clamp/默认 rect、遮挡几何、flipped 换算回归、状态 v3 往返）、`ConfigStoreTests`（全部键解析与 clamp、overlay 内容）、`SplitTreeQuickTermTests`、`ThemeTests`（发现、背景目录扫描）、`KeybindingMapTests`（默认表全绑定、Shift 微调、放行、键名规范化；覆盖/解绑合成在 `ConfigStoreTests`）、`MainWindowControllerTests`、`EngineSmokeTests`。手动验收清单见 `docs/acceptance/`。

### 6.4 风险与对策

| 风险 | 对策 |
|---|---|
| libghostty 内部 API 无稳定承诺 | pin tag + Zig 版本对应；升级视为独立移植任务；QuickTerm 改动以 `// QuickTerm：` 注释标记便于 rebase |
| 构建链复杂 | 一条脚本全自动 + porting-notes 记录全部环境坑 |
| IME/中文输入 | 移植 Ghostty `NSTextInputClient` 实现而非自写 |
| 键位与用户习惯冲突 | 全部可改键 + `Cmd+K` 速查 |
| 背景图版权 | 上游 Omarchy 仓库 MIT；图片构建期拉取、不进本仓库 git |

---

## 7. 交付时间线

| 版本 / tag | 内容 |
|---|---|
| m0 | 引擎跑通：脚手架、GhosttyKit 构建、单 surface、四层配置链、IME |
| m1 | dwindle 平铺核心、⌘拖拽、焦点跟随、隐藏标题栏、WM 按键框架 |
| m2 | 5 工作区、waybar 顶栏、滚轮切换 |
| m3 | 22 主题热切换、壁纸层、面板、透明度/gaps 开关 |
| m4 / v1.0 | 主菜单、速查、Scratchpad、config 热重载、状态恢复、全屏、DisplayLink 配额修复 |
| v1.1 | scrolling 无限画布默认（v5） |
| v1.2 | `pane-padding` 配置项 + Omarchy 同款 scrolling 几何 |
| v1.3 | Hyprland 间隙语义（10pt）、填充模式、padding 14（v6） |
| main（v1.3 之后未打 tag） | visible-columns、Cmd+Esc、图标、磨砂/透明度体系、浮动 pane（v7）、pane-opacity 0.92 / bar-opacity 0.75、遮挡判定（悬停/点击/⌘拖动）、换位视口跟随、背景系统 2.0、Apple 风格图标、双击分隔条等分修复（v8） |

---

## 8. 决策点（已确认，附落地结果）

1. **终端引擎**：方案 A，pin v1.3.1 ✅（未做协议抽象，直接移植层）
2. **`Cmd+Return`**：新建 pane ✅
3. **键位偏移**：resize→`Cmd+Ctrl+方向` ✅；`Cmd+K` 归速查 ✅（**不再**注入 `Cmd+Shift+K` 清屏——QuickTerm 不注入终端级 keybind）
4. **背景图来源**：改为构建期从上游全量拉取（每主题 2–9 张）+ 用户自选目录 ✅
5. **应用形态**：常规主窗口 + 窗口内 Scratchpad ✅（下拉式全局热键终端未做）
6. **最低系统**：macOS 15+ ✅
7. **配置格式**：TOML（极简自解析）✅
