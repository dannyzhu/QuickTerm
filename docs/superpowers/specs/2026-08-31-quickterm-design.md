# QuickTerm 设计方案

**日期**：2026-08-31 · **状态**：✅ 已确认（2026-08-31，7 个决策点全部按推荐值通过）
**修订 v2**：字体改 Monaco（UI 图标用 SF Symbols）；工作区固定 `Cmd+数字`、默认 5 个、取消 Ctrl+Tab；确认 `Cmd+方向键` 切换终端；新增 `Cmd+鼠标拖拽` 移动/分裂/调整 pane
**修订 v3**：快捷键全部可经 config `[keybinds]` 自配置（定义格式与动作清单）；引擎配置优先复用 `~/.config/ghostty/config`（四层配置链）
**修订 v4**：焦点跟随鼠标（悬停即激活 pane、外框高亮、直接输入）；激活/非激活 pane 动态透明度 0.985/0.96；决策点全部确认
**修订 v6**（2026-09-01，两轮）：`pane-padding` 配置项（默认 **14pt** = Omarchy 官方终端 padding，0–32，注入引擎 window-padding）；间隙统一为 Hyprland 语义（每 pane 边 5 → 相邻 10，外圈 5+5=10，**左中右等宽 10**）；scrolling 几何补全：**填充模式**——不溢出时列宽按比例放大填满（单列满屏、两列等隙为其自然结果），仅溢出进入最小滚动+露边
**修订 v5**（2026-09-01，v1.0 交付后用户以真机截图确认）：工作区默认布局改为 **scrolling 无限横向画布**（Omarchy/Hyprland `scrolling` 布局：`column_width = 0.49`，新 pane 插入焦点列右侧、视口跟随焦点列滚动、相邻列在两缘自然露出）；dwindle 保留，`Cmd+L` 按工作区切换（对应 Omarchy `Super+L`）。详见 §4.2-bis

一句话定位：**把 Omarchy 的 Hyprland 平铺桌面装进一个 macOS 原生窗口，里面全是终端。** 纯 Swift（AppKit + SwiftUI 混合），终端引擎为 libghostty（GhosttyKit），界面与快捷键忠实效仿 Omarchy。

---

## 1. Omarchy 调研结论（设计依据）

以下全部对照 `omarchy` 仓库（basecamp/omarchy → omacom/omarchy）master 分支源码与官方手册核实。

### 1.1 视觉语言（QuickTerm 要复刻的"味道"）

| 元素 | Omarchy 的做法 |
|---|---|
| 圆角 | **0（全直角）**——窗口、顶栏、菜单、OSD 一律方角，这是签名式外观 |
| 边框 | 2px；活动窗口 = 主题 accent 色，非活动 = 灰色 `rgba(595959aa)` |
| 间隙 | `gaps_in = 5`，`gaps_out = 10` |
| 透明度 | 极微妙：活动 0.985 / 非活动 0.96 |
| 字体 | **JetBrainsMono Nerd Font**：顶栏 12px、终端 9pt、菜单 18px |
| 动画 | 开窗 popin 87% + easeOutQuint（弹性）；**切工作区无动画（瞬时）** |
| 顶栏 | 26px 高、主题背景色实心条、无边框无圆角、单色图标 |
| 布局 | dwindle（二分递归平铺，永远向右/下分裂），可切换 niri 式滚动布局 |

### 1.2 顶栏（Waybar）结构

- **左**：Omarchy logo（点击开主菜单）+ 工作区号 `1–5` 常驻（活动工作区显示实心方块字形，空工作区 50% 透明，可点击）
- **中**：时钟 `Sunday 14:32`（星期全称 + 24h，无秒）；备用格式显示完整日期；周边还有天气/更新/录屏/勿扰指示器
- **右**：托盘抽屉 + 蓝牙、网络、音量、CPU、电池——全部单色 Nerd Font 图标，点击打开对应 TUI
- `Super+Shift+Space` 整条隐藏/显示

### 1.3 主题系统

- 19 个内置主题（Tokyo Night 默认；4 个浅色主题以 `light.mode` 空文件标记）
- 每个主题一个 `colors.toml`（`accent`/`cursor`/`foreground`/`background`/`selection` + ANSI 16 色）驱动全系统 ~15 个应用的配色模板
- 每个主题带**多张背景图**（Tokyo Night 有 7 张），`0-`、`1-` 前缀排序；符号链接指向当前背景，循环切换带回绕
- 切换机制：构建 next-theme 目录 → **原子替换 `current/theme` 目录** → 重启各表面
- 主题选择器 = Walker 网格菜单带实时预览（`Super+Ctrl+Shift+Space`）；背景菜单（`Super+Ctrl+Space`）

### 1.4 菜单（omarchy-menu / Walker）

居中面板、等宽 18px、主题色 2px 实线边框、0.95 透明度背景、无圆角、Nerd Font 图标前缀的层级 dmenu。主菜单：Apps / Learn / Trigger / Style / Setup / Install / Remove / Update / About / System。菜单动作跑在"浮动演示终端"里（先显示 ASCII logo，再执行命令）。

### 1.5 完整键位目录

约 130 条桌面级绑定已全量核实（v3 stable 与 quattro 分支差异已标注），完整表见调研附件。与 QuickTerm 相关的核心类别：窗口管理、工作区、Scratchpad、主题外观、菜单/速查、剪贴板。**注意：Omarchy 的 `Super+C/V` 万能复制粘贴本来就是在模仿 macOS 的 `Cmd+C/V`**——这使 Super→Cmd 映射天然顺滑。

---

## 2. 技术选型（三个方案与推荐）

### 方案 A（推荐）：嵌入完整 libghostty（GhosttyKit）

Ghostty 自家 macOS 应用消费的内部 C API（`include/ghostty.h`，约 80+ 函数）：`ghostty_app_new/tick`、`ghostty_surface_new`（传入 NSView 指针，Metal 渲染在库内完成）、按键/鼠标/尺寸/缩放输入、剪贴板与动作回调、**`ghostty_surface_update_config` 逐 surface 热更新配置**（主题/背景热切换的关键）。

- ✅ 最高保真：GPU 渲染、连字、Kitty graphics、完整 VT——与 Ghostty 本体完全同级
- ✅ 商业先例：OrbStack 2.0 已内嵌发布（Mitchell 本人确认）；官方参考实现 `ghostty-org/ghostling`、开源范例 `terhechte/Cormac`、`Lakr233/libghostty-spm`
- ✅ MIT 许可，无闭源障碍
- ⚠️ 风险：**该 API 明确"内部、不稳定、无兼容承诺"**；无预编译产物，需 pin 一个 Ghostty tag + 对应 Zig 版本，自行 `zig build -Demit-xcframework=true -Demit-macos-app=false` 产出 `macos/GhosttyKit.xcframework`；每次升级 Ghostty 都是一次移植任务
- 本机条件：Xcode 26.6 ✅ / Homebrew ✅ / **Zig 未装**（M0 脚本化安装 pin 版本）

### 方案 B：SwiftTerm

MIT、成熟的 AppKit `TerminalView`，一天可跑通。但渲染质量/性能与 Ghostty 不同级，且不满足"基于 ghostty lib"的硬性要求。仅作为整体不可行时的退路。

### 方案 C：libghostty-vt（官方唯一受支持的嵌入 API）+ 自研渲染

官方发布了预编译 `ghostty-vt.xcframework`（仅 VT 解析与状态，无渲染/无 PTY UI）。需要自写 Metal 渲染器与输入层——工作量最大，v1 不取。

**推荐 A**，同时在架构上把引擎藏在 `TerminalEngine` 协议后面：Mitchell 已预告官方 "纯 Swift Metal 渲染器 + vt 绑定" Swift 包（尚未发布），一旦落地可平滑迁移。

---

## 3. 总体架构

复刻 Ghostty 经过两次返工验证的混合架构：**AppKit 掌管状态与生命周期，SwiftUI 只做纯渲染**。

```
AppDelegate (AppKit 生命周期)
└─ MainWindowController : NSWindowController        ← 状态的唯一拥有者
   ├─ HiddenTitlebarWindow : NSWindow               ← 隐藏标题栏配方
   ├─ WorkspaceStore                                ← [Workspace]，每个含一棵 SplitTree
   ├─ GhosttyEngine : TerminalEngine                ← 包装 ghostty_app/config/surface
   ├─ ThemeManager                                  ← 主题包 + 背景循环 + 配置热推
   └─ KeybindingController                          ← performKeyEquivalent + 菜单同步
      └─ contentView = NSHostingView(RootView)      ← SwiftUI 从这里开始
         ZStack {
           BackgroundLayer(image)                   ← 连续壁纸（在所有 pane 之后）
           VStack { StatusBarView                   ← 26pt 仿 waybar 顶栏
                    SplitTreeView(tree) }           ← 纯渲染，叶子 = SurfacePaneView
           Overlays: PaletteView / ThemePicker / Scratchpad / Toast
         }
```

### 3.1 组件清单（每个组件：做什么 / 接口 / 依赖）

| 组件 | 职责 | 关键接口 |
|---|---|---|
| `TerminalEngine`（协议）/ `GhosttyEngine` | 初始化 ghostty_app、创建/销毁 surface、事件泵、动作回调分发、配置热更新 | `createSurface(in:cwd:) -> Pane`、`update(config:for:)`、`actions: AsyncStream<EngineAction>` |
| `SurfacePaneView: NSView` | 承载一个 ghostty surface（Metal 层由库内建）、按键/IME/鼠标转发、焦点态 | 移植自 Ghostty `SurfaceView`（MIT） |
| `SplitTree<Pane>` | 不可变值类型二叉树：insert/remove/swap/resize/equalize/zoom/空间导航，`Codable` | 移植自 Ghostty `SplitTree.swift`（约 1400 行，自包含） |
| `WorkspaceStore` | `[Workspace]`（id、name、tree、zoomed）+ activeIndex + scratchpad 特殊工作区；持久化 | `switchTo(_:)`、`movePane(to:)`、`mutateActiveTree(_:)` |
| `StatusBarView` + `SystemStatsService` | 仿 waybar 顶栏；CPU（host_processor_info）、电池（IOKit）、网络（NWPathMonitor）、音量（CoreAudio）、时钟 | 2s 定时刷新；模块点击行为见 §6 |
| `ThemeManager` | 加载主题包（colors.toml + backgrounds/）、SwiftUI 调色板派生、生成 ghostty 配置串、原子切换、背景循环 | `apply(theme:)`、`nextBackground()`、`current: Theme`（Observable） |
| `KeybindingController` | WM 级组合键拦截（`performKeyEquivalent`）→ Action；菜单栏 keyEquivalent 同步；用户覆盖 | 默认映射表 §5；冲突检测 |
| `PaletteView` | Walker 风格通用居中面板（列表/网格两种形态），驱动：主菜单、主题选择器、背景选择器、快捷键速查 | 单组件复用 |
| `ConfigStore` | `~/.config/quickterm/config.toml` 解析、热重载（DispatchSource 监听）、四层引擎配置链合成（优先复用 `~/.config/ghostty/config`，见 §4.7） | 解析失败回退默认值 + 顶栏警告 |

### 3.2 关键机制

- **隐藏标题栏配方**（照抄 Ghostty `HiddenTitlebarTerminalWindow`）：styleMask 保留 `.titled + .fullSizeContentView + .resizable...`，`titleVisibility = .hidden`、`titlebarAppearsTransparent`、隐藏三个红绿灯按钮、禁用系统 tab；顶栏区域自绘。保留 `.titled` 才有正常阴影/圆角外框/恢复行为。
- **按键拦截三层**（照抄 Ghostty）：① `SurfacePaneView.performKeyEquivalent` 在菜单分发前拦截 Cmd 组合，先查 QuickTerm WM 级映射表，命中则消费，否则交给 surface；② 菜单栏作为快捷键注册表（可见、可被系统改键）；③ AppDelegate 局部监视器兜底无窗口时的按键。**分层原则：WM 级键（分屏/工作区/主题）由 QuickTerm 解析；终端级键（复制/粘贴/字号）交由 libghostty 自己的配置解析。**
- **工作区 = 多棵 SplitTree 换着渲染**：不用 NSWindowTabGroup；`[SplitTree]` + index 就是工作区切换器，值类型 + `Codable` 免费带来持久化与（未来的）undo。切换瞬时无动画（忠实 Omarchy）。
- **zoom = 只渲染该子树**：`tree.zoomed ?? tree.root`，零几何计算，退出即恢复原布局（Hyprland `fullscreen,1` 同款语义）。
- **连续壁纸**：window `backgroundColor = .clear` + ZStack 底层 Image + 所有 surface `background-opacity < 1`——得到一张横跨所有 pane 的完整壁纸（比 libghostty 内建的逐 surface background-image 更接近 Hyprland 观感）。
- **主题热切换**：ThemeManager 生成新配置 → 对每个活动 surface 调 `ghostty_surface_update_config` → UI 层从 colors.toml 派生的 SwiftUI 调色板同步刷新。libghostty 明确支持逐 surface 运行时配置更新。
- **引擎配置链**：surface 配置按「ghostty 内置默认 → `~/.config/ghostty/config` → QuickTerm 主题层 → `[ghostty]` 透传」四层合成（§4.7）——用户已有的 ghostty 配置开箱即用。
- **非原生全屏**：移植 Ghostty `Fullscreen.swift` 的 NonNativeFullscreen（隐藏 Dock/菜单栏、去 `.titled`、异步 setFrame），`Ctrl+Cmd+F` 触发。

### 3.3 错误处理

- 引擎初始化失败（xcframework 缺失/资源包损坏）→ 启动 Alert + 退出，附诊断路径
- surface 创建失败 → 该 pane 显示错误占位视图（可关闭），不拖垮整树
- 配置/主题解析失败 → 回退默认值，顶栏显示警告胶囊（点击查看详情）
- 状态恢复失败（Codable 版本不匹配）→ 丢弃存档开全新工作区，不崩溃

---

## 4. 功能规格

### 4.1 快速创建终端（核心诉求）

- `Cmd+Return`：在焦点 pane 处按 dwindle 规则分裂出新终端，**继承焦点 pane 的当前目录**（Omarchy `Super+Return` 同语义）
- 新 pane 带 popin 87% + easeOutQuint 开窗动画
- `Cmd+S`：Scratchpad——覆盖层浮动终端（特殊工作区），再按隐藏，跨工作区保持会话
- 主菜单 / 命令面板中也可新建

### 4.2 窗口布局（dwindle 平铺）

1 个 pane 全屏 → 第 2 个左右对半 → 后续在焦点槽位继续二分（永远向右/下），gaps 5/10、2px accent 活动边框、直角。支持：方向焦点移动（空间导航，按几何位置而非树序）、相邻交换、关闭时兄弟节点回收父槽、比例拖拽（分隔条 1pt 可见 + 6pt 热区，双击等分）、pane zoom、全树等分。

**焦点跟随鼠标（忠实 Hyprland focus_follows_mouse）**：鼠标移入某个 pane 即激活它——外框立即变 accent 高亮、键盘输入直达该 pane，无需点击；点击与键盘方向导航同样有效。实现：每个 pane 挂 NSTrackingArea（mouseEntered → 焦点切换）；Scratchpad/菜单等覆盖层打开时挂起悬停切换，防误切。

**动态透明度（忠实 Omarchy active/inactive opacity）**：激活 pane 背景更实（0.985）、非激活更透（0.96），透出壁纸层次；焦点变化即时过渡。实现候选：引擎原生 `unfocused-split-opacity` 机制，或按焦点对 surface 热更新 `background-opacity`——M1 依实测手感二选一。

#### 4.2-bis 双布局（v5）：scrolling 无限画布为默认

Omarchy 实为双布局体系（源码：`layout = "dwindle"` + `scrolling.column_width = 0.49`，`Super+L` 按工作区切换并持久化）。QuickTerm 对齐：

- **scrolling（新工作区默认）**：工作区 = 无限横向列条带。每列宽 = 49% 视口（可调 25%–90%）、列内可纵向栈叠；`Cmd+Return` 在焦点列**右侧插入新列**（继承 cwd）；视口以最小滚动量保证焦点列完全可见，相邻列在两缘自然露出（= Omarchy 截图行为，露边源于"列宽<半屏+视口跟随"，非特效）；滚动 ~0.15s easeOut。
- **scrolling 键位语义**：`Cmd+←/→` 跨列焦点、`Cmd+↑/↓` 列内焦点；`Cmd+Shift+方向` 列换位/列内换位；`Cmd+J` 焦点 pane 併入左列纵栈 ⇄ 拆出独立列；`Cmd+Ctrl+←/→` 调列宽 ±5%、`Cmd+Ctrl+=` 全列重置 0.49（`Cmd+Ctrl+↑/↓` 在此布局无操作）；`Cmd+W` 关 pane、空列删除焦点左移；zoom/循环/拖拽语义同表（拖拽：左右缘=插新列、上下缘=併栈、中心=交换）；触控板双指横滑平移画布、松手吸附列边界（附带项）。
- **dwindle（保留）**：行为与 v4 完全一致；`Cmd+L` 在两布局间切换，pane 全保留（树叶序 ⇄ 列序互转）。
- 持久化升级 v2（含每工作区布局类型）；旧存档不兼容自动全新开始。

**鼠标布局操作（忠实 Omarchy Super+拖动）**：`Cmd+左键拖动` pane——拖到目标 pane **中心 = 交换位置**，拖到目标 pane **上/下/左/右边缘 = 在该侧分裂插入**（把一块区域分隔成多块）；`Cmd+右键拖动` = 调整 pane 大小（换算到就近分隔条比例）。实现照抄 Ghostty 的 split 拖拽（自定义 UTType + 最近边缘三角判定 drop zone），仅把触发条件改为按住 Cmd。普通鼠标仍可拖分隔条调比例、双击等分。

### 4.3 背景切换

每主题多背景 + 用户背景目录（`~/.config/quickterm/backgrounds/<theme>/`）；`Cmd+Ctrl+Space` 打开背景选择器（网格缩略图）并支持循环下一张（带回绕）；无背景主题显示纯 `background` 色。切换即时生效，无需重启。

### 4.4 顶部状态栏（仿 waybar，26pt）

| 区域 | 内容 | 交互 |
|---|---|---|
| 左 | QuickTerm logo + 工作区胶囊 1–5（活动 = `■`，空 = 50% 透明，有内容显示数字） | logo 点击开主菜单；胶囊点击切换；区域内滚轮循环工作区 |
| 中 | 时钟 `Sunday 14:32`（星期全称 + 24h） | 点击切换完整日期格式 `31 August W36 2026` |
| 右 | CPU、Wi-Fi、音量、电池——SF Symbols 单色图标（充放电时仅图标，其余 `85%`+图标；20% 预警变 `#a55555` 红） | CPU 点击弹出浮动终端跑 `top`（装了 btop 则 btop）；音量点击静音；电池点击显示剩余量通知 |

`Cmd+Shift+Space` 隐藏/显示整条。文字 Monaco 12pt、图标 SF Symbols（渲染为主题 fg 色）、主题 bg/fg 两色、无圆角。

### 4.5 主题系统

- 主题包格式与 Omarchy 同构：`themes/<name>/{colors.toml, backgrounds/, preview.png, light.mode?}`
- **移植全部 19 个 Omarchy 主题的 colors.toml**（MIT，纯色值）；Tokyo Night 为默认
- `Cmd+Ctrl+Shift+Space`：主题选择器（PaletteView 网格 + 色板预览），选中即热切换（终端色 + 顶栏 + 边框 + 菜单 + 背景一起换）
- 浅色主题正确联动 macOS 外观（`ghostty_app_set_color_scheme`）
- 用户主题目录 `~/.config/quickterm/themes/` 优先于内置

### 4.6 QuickTerm 菜单与速查

- `Cmd+Alt+Space`：主菜单（Walker 风格居中面板、Monaco 18px、2px 主题色边框、直角、SF Symbols 图标前缀、层级导航 + 模糊过滤）。v1 条目：**New Terminal / Style（Theme·Background·Font）/ Toggle（Top Bar·Gaps·Transparency）/ Keybindings / Settings / About**
- `Cmd+K`：快捷键速查表（可搜索，数据来自映射表本身，永不过时）
- `Cmd+,`：设置（先打开 config.toml；图形化设置面板后置）

### 4.7 配置文件

`~/.config/quickterm/config.toml`，文件监听热重载。示例：

```toml
theme      = "tokyo-night"   # 或 "ghostty"：不覆盖配色，完全跟随 ghostty 配置
workspaces = 5               # 1–10
pane-padding = 14            # pane 内终端四边留白（pt，0–32；Omarchy 官方值）
# font 未设置时默认 Monaco；若 ~/.config/ghostty/config 指定了 font-family 则尊重之

[keybinds]                   # WM 级动作全部可改键；值格式 "modifier+key"，"none" = 解绑
new-terminal     = "cmd+return"
close-pane       = "cmd+w"
focus-left       = "cmd+left"          # focus-right / focus-up / focus-down 同理
swap-left        = "cmd+shift+left"    # swap-* 同理
toggle-split-dir = "cmd+j"
toggle-zoom      = "cmd+f"
resize-left      = "cmd+ctrl+left"     # resize-* 同理；+shift = 微调
goto-workspace-1 = "cmd+1"             # …goto-workspace-5；move-to-workspace-N 同理
scratchpad       = "cmd+s"
theme-picker     = "cmd+ctrl+shift+space"
next-background  = "cmd+ctrl+space"
toggle-bar       = "cmd+shift+space"
toggle-opacity   = "cmd+backspace"
toggle-gaps      = "cmd+shift+backspace"
main-menu        = "cmd+alt+space"
keybind-help     = "cmd+k"

[ghostty]                    # 原样透传给引擎，最高优先级
# cursor-style = "block"
```

**引擎配置优先级链（低 → 高）**：

1. libghostty 内置默认值
2. **`~/.config/ghostty/config`**（按 Ghostty 原生规则加载，含 `config-file` 递归包含）——**用户已调好的 ghostty 配置直接复用**：字体、光标、滚动、padding、shell-integration、终端级 keybind 等全部生效
3. QuickTerm 主题层——仅覆盖配色/背景/透明度相关键以保证主题一致；`theme = "ghostty"` 可关闭本层
4. `[ghostty]` 透传段——最终覆盖

**键位分层**：`[keybinds]` 只管 WM 级动作（上表全集即动作清单，速查表由它生成）；终端级键（复制/粘贴/字号/清屏等）由引擎解析，用 ghostty 自己的 `keybind =` 语法写在 `~/.config/ghostty/config` 或 `[ghostty]` 段。改键热重载即时生效；加载时做冲突检测（两动作同键 → 顶栏警告 + 速查表标红）。

### 4.8 状态恢复

退出时序列化 `[Workspace]`（树形结构 + 各 pane cwd + 活动工作区 + 主题/背景选择），启动时恢复布局并在各 pane 的 cwd 重新起 shell（不恢复进程内容）。

### 4.9 字体

全局默认 **Monaco**（macOS 自带，无需分发字体文件）：终端 12pt（可配置）、顶栏 12pt、菜单 18pt。Monaco 无连字、不含 Nerd Font 图标，因此 **UI 图标一律用 SF Symbols**（顶栏/菜单/状态指示）。Monaco 仅是"无任何配置时的默认"：若 `~/.config/ghostty/config` 指定了 `font-family`，终端尊重其设置（配置链第 2 层）；quickterm config 设置字体则最终覆盖。

---

## 5. 快捷键映射表（Omarchy → QuickTerm）

原则：**Super→Cmd 直译优先**；被 macOS 系统占用或与铁律惯例冲突的少数键位做有依据的偏移，并全部可在 config 中改键。

### 窗口 / 分屏

| Omarchy | QuickTerm | 功能 |
|---|---|---|
| Super+Return | `Cmd+Return` | 新建终端（dwindle 分裂，继承 cwd） |
| Super+W | `Cmd+W` | 关闭焦点 pane（最后一个时关窗口，二次确认有活动进程时） |
| Super+←→↑↓ | `Cmd+←→↑↓` | 方向焦点移动（空间导航） |
| Super+Shift+←→↑↓ | `Cmd+Shift+←→↑↓` | 与相邻 pane 交换 |
| Super+J | `Cmd+J` | 切换分裂方向 |
| Super+F（窗口全屏） | `Cmd+F` | **pane zoom**（焦点 pane 占满内容区——Omarchy 语义里"窗口"≈我们的 pane） |
| —（macOS 惯例） | `Ctrl+Cmd+F` | 整窗全屏（非原生，隐藏菜单栏/Dock） |
| Super+‑/= 调整大小 | `Cmd+Ctrl+←→↑↓` | 调整 pane 大小（100px 步进；`+Shift` = 10px 微调）※见偏移说明 1 |
| —（Ghostty 惯例） | `Cmd+Ctrl+=` | 全树等分 |
| Alt+Tab / +Shift | `Alt+Tab` / `+Shift` | 循环下/上一个 pane（也可 `Cmd+[` / `Cmd+]`） |
| Super+左键拖动 | `Cmd+左键拖动` | 移动 pane：拖到目标中心 = 交换，拖到目标边缘 = 在该侧分裂插入 |
| Super+右键拖动 | `Cmd+右键拖动` | 调整 pane 大小（就近分隔条） |
| —（鼠标） | 拖动分隔条 | 比例调整；双击分隔条 = 等分 |

### 工作区

| Omarchy | QuickTerm | 功能 |
|---|---|---|
| Super+1…5 | `Cmd+1…5` | 切换工作区（**默认 5 个**；config 可扩至 10 → `Cmd+1…9,0`） |
| Super+Shift+1…5 | `Cmd+Shift+1…5` | 移动焦点 pane 到工作区 N 并跟随 |
| Super+滚轮 | 顶栏滚轮 / 胶囊点击 | 循环 / 直达工作区（不设 Ctrl+Tab 之类轮换键，直达为主） |
| Super+S | `Cmd+S` | Scratchpad 浮动终端 |

### 主题 / 外观

| Omarchy | QuickTerm | 功能 |
|---|---|---|
| Super+Ctrl+Shift+Space | `Cmd+Ctrl+Shift+Space` | 主题选择器 |
| Super+Ctrl+Space | `Cmd+Ctrl+Space` | 背景选择器 / 下一张背景 |
| Super+Shift+Space | `Cmd+Shift+Space` | 顶栏显示/隐藏 |
| Super+Backspace | `Cmd+Backspace` | 透明度开关 |
| Super+Shift+Backspace | `Cmd+Shift+Backspace` | gaps 开关 |

### 菜单 / 工具 / 终端惯例

| Omarchy | QuickTerm | 功能 |
|---|---|---|
| Super+Alt+Space | `Cmd+Alt+Space` | QuickTerm 主菜单（Cmd+Space 被 Spotlight 占用，恰好 Omarchy v3 菜单本来就在这个键） |
| Super+K | `Cmd+K`（默认忠实 Omarchy） | 快捷键速查 ※偏移说明 2：传统"清屏"移至 `Cmd+Shift+K`，两者均可改键 |
| Super+C / V | `Cmd+C` / `Cmd+V` | 复制/粘贴（Omarchy 本来就在模仿 macOS，天然一致） |
| —（macOS） | `Cmd++` / `Cmd+‑` / `Cmd+0` | 字号增/减/重置（保留铁律惯例，引擎层处理） |
| —（macOS） | `Cmd+,` | 设置 |
| —（macOS） | `Cmd+Q` / `Cmd+M` / `Cmd+H` | 退出/最小化/隐藏——**保留系统行为不占用** |

**偏移说明**（仅 2 处，其余全部直译）：
1. Omarchy 的 `Super+-/=` 调整窗口大小，但 macOS 终端里 `Cmd+-/=` 是字号缩放的铁律，故 resize 改用 `Cmd+Ctrl+方向键`（Ghostty 默认位，步进调成 Omarchy 的 100px）。
2. `Cmd+K` 在 mac 终端传统上是清屏；默认忠实 Omarchy（= 速查表），清屏移 `Cmd+Shift+K`，介意可一行配置换回。

工作区轮换不设快捷键（`Cmd+Tab` 被系统占用）：以 `Cmd+数字` 直达为主，辅以顶栏滚轮/点击。

**明确不做的 Omarchy 键位**（属于 OS 职责或超出终端范畴）：截图/录屏/OCR、通知管理、媒体与亮度键、蓝牙/WiFi 面板、锁屏/电源菜单、应用与网页启动器——macOS 系统均已提供。

### v2 后备键位（本期不实现，预留不冲突）

`Cmd+T` 浮动 toggle、`Cmd+G` pane 分组（tabbed group）、`Cmd+L` 滚动布局切换、`Cmd+O` pane 弹出为独立 macOS 窗口、`Cmd+Ctrl+V` 剪贴板历史、全局热键呼出（dropdown quick terminal）。

---

## 6. 工程与构建

### 6.1 目录结构

```
quickterm/
├─ QuickTerm.xcodeproj
├─ Sources/
│  ├─ App/            # main、AppDelegate、主菜单
│  ├─ Windowing/      # HiddenTitlebarWindow、MainWindowController、Fullscreen
│  ├─ Splits/         # SplitTree、SplitTreeView、SplitView、Divider（移植 MIT）
│  ├─ Workspaces/     # Workspace、WorkspaceStore、持久化
│  ├─ Engine/         # TerminalEngine 协议、GhosttyEngine、SurfacePaneView
│  ├─ StatusBar/      # StatusBarView、SystemStatsService
│  ├─ Theming/        # ThemeManager、Theme、colors.toml 解析
│  ├─ Palette/        # PaletteView、主菜单/主题/背景/速查数据源
│  └─ Config/         # ConfigStore、KeybindingMap
├─ Themes/            # 内置 19 主题包
├─ vendor/ghostty     # git submodule，pin 到最新稳定 tag（v1.3.1）
├─ scripts/
│  └─ build-ghosttykit.sh   # 安装 pin 版 Zig → zig build xcframework → 拷贝产物
└─ docs/
```

### 6.2 GhosttyKit 构建管线（M0 首要任务）

1. `git submodule add` ghostty，checkout tag `v1.3.1`（当前最新稳定；main 是 1.3.2-dev）
2. 从该 tag 的 `build.zig.zon` 读取 `minimum_zig_version`，脚本用 `zigup`/直接下载安装**精确版本**（main 已要求 0.16.x，tag 版本以 M0 实测为准；Zig 版本随 Ghostty pin 走，不用 brew 全局装）
3. `zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native`（开发用 native，发布切 universal）→ 产物在 **`vendor/ghostty/macos/GhosttyKit.xcframework`**
4. Xcode 工程链接 xcframework + Metal/Carbon 等系统框架，打包 Ghostty 资源（terminfo、shell-integration、themes）进 app bundle
5. 产物缓存：xcframework 不进 git，脚本按 (tag, zig 版本) 哈希缓存

部署目标 macOS 15+，开发机 macOS 26.7 / Xcode 26.6 满足要求。

### 6.3 测试策略

- **单元测试**（XCTest）：SplitTree 全部操作（插入/删除/交换/空间导航/resize/equalize/zoom/Codable 往返）——值类型纯函数，最易测也最值得测；WorkspaceStore 状态迁移；colors.toml 解析；KeybindingMap 冲突检测与用户覆盖合并
- **集成冒烟**：引擎初始化、surface 创建/销毁、配置热更新不崩溃
- **手动验收清单**：每里程碑一份（键位逐条过、主题逐个切、IME 中文输入、状态恢复）

### 6.4 风险与对策

| 风险 | 对策 |
|---|---|
| libghostty 内部 API 无稳定承诺 | pin tag + Zig 版本对应；`TerminalEngine` 协议隔离；升级 Ghostty 当作独立任务排期；关注官方 Swift 包（已预告"coming soon"），落地即迁移 |
| 构建链复杂（Zig + xcframework） | 一条 `scripts/build-ghosttykit.sh` 全自动；README 写清；产物本地缓存 |
| IME/中文输入细节多 | 移植 Ghostty SurfaceView 的 NSTextInputClient 实现而非自写；手动验收单列 |
| Cmd 键位与用户习惯冲突 | 三处偏移都有依据 + 全部可配置 + `Cmd+K` 速查随时查 |
| Omarchy 背景图版权归属 | 见决策点 4 |

---

## 7. 里程碑（每个都可运行、可演示）

| 里程碑 | 内容 | 验收 |
|---|---|---|
| **M0 引擎跑通** | 仓库脚手架（git init、Xcode 工程、submodule、构建脚本）；单窗口单 surface；四层配置链（复用 `~/.config/ghostty/config`）；键盘输入/IME/复制粘贴可用 | 打开 app 能正常用 shell，ghostty 已有配置生效，中文输入正常 |
| **M1 平铺核心** | SplitTree + dwindle 分裂/关闭/焦点空间导航/交换/resize/等分/zoom；`Cmd+鼠标拖拽`移动/分裂/调整 pane；焦点跟随鼠标 + 动态透明度（0.985/0.96）；隐藏标题栏窗口 + gaps + 2px 活动边框；WM 级按键框架 + 菜单栏同步 | §5 窗口/分屏表逐条通过 + 悬停激活/透明度切换生效 |
| **M2 工作区 + 顶栏** | 工作区（默认 5 个、瞬时切换、移动 pane）；顶栏全模块（logo/胶囊/时钟/CPU/网络/音量/电池）+ 点击与滚轮交互 + 隐藏 toggle | §5 工作区表 + §4.4 全部行为通过 |
| **M3 主题 + 背景** | 19 主题移植、主题选择器、背景选择/循环、连续壁纸层、透明度/gaps toggle、popin 开窗动画、浅色主题联动 | 任意主题热切换 < 200ms，无重启 |
| **M4 打磨收尾** | 主菜单、快捷键速查、Scratchpad、config.toml 热重载 + 改键、状态恢复、非原生全屏、App 图标 | 全量验收单通过，打包可分发 .app |

---

## 8. 决策点（已全部确认）

以下 7 项已于 2026-08-31 全部按推荐值确认：

1. **终端引擎**：方案 A（完整 libghostty，pin v1.3.1）？——推荐 A
2. **`Cmd+Return` 语义**：新建 pane（推荐，Omarchy 神韵）而非新建 macOS 窗口？
3. **两处键位偏移**（resize→`Cmd+Ctrl+方向`、清屏→`Cmd+Shift+K`）接受否？
4. **背景图来源**：推荐移植 19 主题 colors + 每主题内置 1–2 张 Omarchy 官方背景（仓库 MIT，但图片单独来源未逐一考证；更稳妥可改为程序化渐变背景 + 用户自加图片目录）
5. **应用形态**：v1 = 常规主窗口 + 窗口内 Scratchpad（推荐）；全局热键下拉式 quick terminal 放 v2？
6. **最低系统版本**：macOS 15+（跟随 Ghostty 支持范围）？
7. **配置格式**：TOML（与 Omarchy colors.toml 同族）？
