# QuickTerm

**Omarchy 风格的 macOS 原生平铺终端，引擎为 libghostty。**

QuickTerm 把 [Omarchy](https://omarchy.org) 的 Hyprland 平铺桌面装进一个 macOS 原生窗口，里面全是终端：无限横向滚动布局、工作区、浮动 pane、waybar 风格状态条、22 套 Omarchy 主题与全部壁纸，以及同一套 `Super` → `Cmd` 键位。终端引擎是 [Ghostty](https://ghostty.org) 自家的库（GhosttyKit，pin v1.3.1），渲染、连字与 VT 保真度与 Ghostty 本体完全一致。

[English](README.md)

![scrolling 画布：左侧整列 btop，右侧一列叠栈（htop 在上、CLI agent 在下），第三列在右缘露边](docs/images/screenshot-01.png)

![向右滚动一列后：激活 pane 带 accent 边框，非激活 pane 磨砂，前一列在左缘露边](docs/images/screenshot-02.png)

---

## 亮点

- **默认无限横向画布** —— 每个工作区是一条可以一直往右长的列条带（Hyprland `scrolling` 布局：默认每屏两列，两侧各露出相邻列的一条边）。新终端插在焦点列右侧；视口以最小滚动量跟随焦点。经典 **dwindle** 平铺一键 `Cmd+L` 切换。
- **悬停即焦点** —— 鼠标移到哪个 pane，哪个就激活：边框变主题 accent 色，键盘直接输入。
- **浮动 pane** —— `Cmd+T` 把 pane 从平铺里浮起；`⌘`+左键拖动移动，`⌘`+右键拖动调大小。
- **5 个工作区** —— `Cmd+1…5` 切换，`Cmd+Shift+1…5` 带着 pane 一起走；顶栏上滚滚轮循环。
- **waybar 风格顶栏** —— 工作区、时钟、CPU、网络、音量、电池。26pt、单色 SF Symbols、半透明。
- **22 套 Omarchy 主题** 连同全部壁纸，一帧内热切换；也可以选自己的图片当背景。
- **玻璃质感** —— pane 以 0.92 透明度压在连续壁纸之上，激活 pane 合成到 0.98，非激活的平铺 pane 垫磨砂（文字依然锐利）。一个键全部关掉。
- **直接复用你的 Ghostty 配置** —— 字体、光标、滚动、shell 集成、终端级键位全部从 `~/.config/ghostty/config` 读入，QuickTerm 只在其上叠加主题配色与 padding。
- **全部可改键** —— 每个窗口管理动作都是 `config.toml` 里的一个键；`Cmd+K` 随时查实时速查表。
- **状态恢复** —— 布局、浮动 pane、活动工作区、每个 pane 的工作目录，下次启动原样回来。

## 安装

预构建的 DMG 在 [Releases](https://github.com/dannyzhu/QuickTerm/releases) 页面（Apple Silicon，macOS 15+）。

1. 打开 DMG，把 **QuickTerm** 拖进 **应用程序**。
2. 应用是 ad-hoc 签名、未经 Apple 公证，首次打开会被 macOS 拦下。先双击一次，关掉"Apple 无法验证……"的对话框，然后二选一：
   - 打开 **系统设置 → 隐私与安全性**，拉到底部找到 QuickTerm 的条目，点 **仍要打开**；或
   - 在终端清除隔离标记（之后不再弹窗）：
     ```bash
     xattr -dr com.apple.quarantine /Applications/QuickTerm.app
     ```
3. 再次启动即可，首个窗口会在你的主目录打开一个 shell。

可选：把 DMG 和 Release 附带的 `.sha256` 文件放在同一目录，运行 `shasum -a 256 -c QuickTerm-<版本>.dmg.sha256` 校验下载。想自己从源码打 DMG，先按[构建](#构建)一节准备好环境，再运行 `scripts/make-release.sh`。

## 构建环境要求

仅从源码构建时需要。Releases 里的 DMG 在任何 Apple Silicon Mac（macOS 15+）上直接运行，不需要以下任何东西。

- macOS 15+（开发验证于 macOS 26 / Xcode 26.6，Apple Silicon）
- Xcode 26+，并已安装 Metal Toolchain：`xcodebuild -downloadComponent MetalToolchain`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
- Zig 无需手动安装，脚本按 Ghostty pin 的精确版本自动装到 `.tools/`

## 构建

```bash
git clone --recurse-submodules <本仓库>
cd quickterm
scripts/build-ghosttykit.sh      # 先把 pin 版 Zig 装到 .tools/，再构建 vendor/ghostty/macos/GhosttyKit.xcframework（首次 10–30 分钟）
scripts/fetch-themes.sh          # 拉取 Omarchy 主题壁纸（不进 git，约 50 MB）
xcodegen generate
xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug build
```

代理环境下 `build-ghosttykit.sh` 里的 Zig 依赖拉取可能报 HTTP 400——Zig 自带的拉取器不走系统代理。此时跑 `scripts/fetch-zig-deps.sh`（用构建脚本刚装好的 Zig，经 curl 预取并灌进 Zig 缓存），然后重新执行 `scripts/build-ghosttykit.sh`。

运行：

```bash
open "$(xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/QuickTerm.app"
```

测试（59 个用例，以 app 为测试宿主）：

```bash
xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug test
```

## 使用

### 布局

**scrolling**（每个工作区的默认）。列宽默认为视口的 49%，即"每屏 2 列"（`0.98 / N`）。装得下时列按比例放大填满（单列满屏、两列左中右间隙相等）；装不下时视口以最小滚动量保证焦点列完整可见。每屏列数可在主菜单循环 2 → 3 → 4，或在配置里写 `visible-columns`。触控板双指横滑平移画布，松手吸附到列边界。

`Cmd+J`：单 pane 的列併入左侧列（成为纵向栈）；多 pane 列里的焦点 pane 拆出为独立列。

**dwindle**（`Cmd+L` 按工作区切换）。Omarchy 式递归二分：焦点 pane 宽大于高就向右分裂，否则向下。`Cmd+J` 翻转最近一层分裂方向。拖分隔条调比例，双击分隔条等分。

两种布局互切时 pane 全部保留、顺序不变（列 → 右分裂链，列内栈 → 下分裂链）。

### 浮动 pane 与 Scratchpad

`Cmd+T` 把焦点 pane 浮起：宽 = 默认列宽 × 75%，高 = 内容区 45%，居中。按住 `⌘` 左键拖动移动（自动置顶），右键拖动调大小。再按 `Cmd+T` 塞回平铺。浮动 pane 可用 `Cmd+Shift+数字` 跨工作区搬家，并随布局一起保存。

`Cmd+S` 唤出 Scratchpad —— 一个跨工作区的全局终端，居中覆盖（70% × 60%），点击外部隐藏。

### 鼠标

| 手势 | 效果 |
|---|---|
| 悬停 | 焦点跟随鼠标 |
| `⌘` + 左键拖平铺 pane | 落到目标中心 = 交换。落到边缘：scrolling 下左右缘 = 在旁边插一列、上下缘 = 併进目标列的栈；dwindle 下 = 在该侧分裂插入 |
| `⌘` + 左键拖浮动 pane | 移动（并置顶） |
| `⌘` + 右键拖 | 调大小：scrolling 改列宽，dwindle 调就近分隔条，浮动 pane 改自身 |
| 顶栏上滚滚轮 | 循环工作区 |
| 双指横滑 | 平移 scrolling 画布 |
| 顶栏空白处双击 | 窗口 zoom 铺满可视区 |
| 点时钟 / 喇叭 / 工作区胶囊 | 切日期格式 / 静音 / 跳到该工作区 |

### 面板

所有面板居中、Walker 风格：`↑`/`↓` 移动、`Return` 确认、`Esc` 或点击外部关闭。

- **主题选择器**（`Cmd+Ctrl+Shift+Space`）—— 每行名称、浅色主题带 `light` 标记、8 色色板。
- **背景选择器**（`Cmd+Ctrl+Space`）—— 3 列缩略图网格；`←`/`→` 逐张，`↑`/`↓` 按行。面板打开时再按同一键直接跳下一张。末位「**选择图片…**」打开文件选择器，图片会拷入 `~/.config/quickterm/backgrounds/` 并立即生效；自己的图片在所有主题下都可选。
- **快捷键速查**（`Cmd+K`）—— 由当前生效的键位表实时生成，永远反映你的改键。
- **主菜单**（`Cmd+Alt+Space`）—— 新建终端 · 主题 · 背景 · 每屏列数 · 顶栏开关 · Gaps 开关 · 透明度开关 · 快捷键速查 · 设置 · 关于。

### 透明度

| 配置 | 默认 | 作用 |
|---|---|---|
| `pane-opacity` | 0.92 | 终端背景透明度（引擎 `background-opacity`） |
| `active-opacity` | 0.98 | 激活 pane 背后垫主题底色，合成到该值 |
| `bar-opacity` | 0.75 | 顶栏背景 |
| `divider-opacity` | 0.5 | dwindle 分隔细线（1pt）的不透明度（1 = 实线，0 = 隐藏） |
| `inactive-blur` | 2.5 | `> 0` 时非激活的平铺 pane 背后垫磨砂（模糊的是壁纸，文字不受影响；浮动 pane 不垫；目前数值只作开关） |

`Cmd+Backspace` 一键全部关掉（pane 与顶栏变不透明）；`Cmd+Shift+Backspace` 开关 gaps。

## 默认快捷键

下表每个动作都可在 `config.toml` 改键（见[配置](#配置)）。不在表内的组合一律放行给终端 —— `Cmd+C`/`Cmd+V`、字号键、`Cmd+Q` 等完全不受影响。

| 按键 | 动作 id | 功能 |
|---|---|---|
| `Cmd+Return` | `new-terminal` | 新建终端（焦点列右侧 / dwindle 分裂），继承当前目录 |
| `Cmd+W` | `close-pane` | 关闭焦点 pane（有进程运行时确认） |
| `Cmd+←↑↓→` | `focus-*` | 移动焦点 |
| `Cmd+Shift+←↑↓→` | `swap-*` | 换位（视口自动跟随） |
| `Cmd+J` | `toggle-split-dir` | 併列/拆列（scrolling）· 翻转分裂（dwindle） |
| `Cmd+F` | `toggle-zoom` | pane 占满内容区 |
| `Cmd+Ctrl+←↑↓→` | `resize-*` | 调整大小——scrolling 只调列宽（左右），dwindle 四向；`Shift` 微调仅 dwindle 生效 |
| `Cmd+Ctrl+=` | `equalize` | 全部等分 / 列宽重置 |
| `Alt+Tab` / `Alt+Shift+Tab`、`Cmd+]` / `Cmd+[` | `cycle-pane-next` / `-prev` | 循环 pane |
| `Cmd+L` | `toggle-layout` | scrolling ⇄ dwindle |
| `Cmd+T` | `toggle-float` | 浮动 ⇄ 平铺 |
| `Cmd+S` | `scratchpad` | Scratchpad 终端 |
| `Cmd+1…5` | `goto-workspace-N` | 切换工作区（`workspaces > 5` 时补 `Cmd+6…9,0`） |
| `Cmd+Shift+1…5` | `move-to-workspace-N` | 把 pane 移到工作区并跟随 |
| `Cmd+Shift+Space` | `toggle-bar` | 顶栏显示/隐藏 |
| `Cmd+Ctrl+Shift+Space` | `theme-picker` | 主题选择器 |
| `Cmd+Ctrl+Space` | `next-background` | 背景选择器 / 下一张 |
| `Cmd+Backspace` | `toggle-opacity` | 透明度开关 |
| `Cmd+Shift+Backspace` | `toggle-gaps` | Gaps 开关 |
| `Cmd+K` | `keybind-help` | 速查表 |
| `Cmd+Alt+Space` | `main-menu` | 主菜单 |
| `Cmd+,` | `open-settings` | 打开 `config.toml`（存在 ghostty 配置时一并打开） |
| `Ctrl+Cmd+F` / `Cmd+Esc` | `toggle-fullscreen` / `exit-fullscreen` | 非原生全屏（隐藏 Dock 与菜单栏） |

与 Omarchy 的两处有意偏移：调整大小用 `Cmd+Ctrl+方向`，因为 `Cmd+-`/`Cmd+=` 在所有 macOS 终端里都是字号键；`Cmd+K` 是速查表而不是"清屏"（需要清屏键请在 ghostty 配置里自行绑定）。

macOS 菜单栏的 Shell / Pane 菜单只列了少数动作的固定默认快捷键，不随改键变化；速查表（`Cmd+K`）永远是准的。

## 配置

`~/.config/quickterm/config.toml` —— 首次按 `Cmd+,` 会生成带注释的模板；保存即热重载。

```toml
# theme = "tokyo-night"     # 或 "ghostty"：不碰配色，完全跟随 ~/.config/ghostty/config
# workspaces = 5            # 1–10
# pane-padding = 14         # 终端内四边留白 pt，0–32（Omarchy 官方值）
# visible-columns = 2       # scrolling 每屏可见列数，1–6
# pane-opacity = 0.92       # 0.5–1.0
# active-opacity = 0.98     # 0.5–1.0
# bar-opacity = 0.75        # 0–1
# divider-opacity = 0.5     # 0–1，dwindle 分隔细线
# inactive-blur = 2.5       # > 0 开启非激活磨砂

[keybinds]                  # 动作 = "修饰键+键"；"none" 解绑。动作 id 见 Cmd+K
# new-terminal = "cmd+return"
# toggle-float = "cmd+shift+t"

[ghostty]                   # 任意 Ghostty 选项，原样透传，最高优先级
# cursor-style = block
# font-size = 13
```

修饰键写法：`cmd`/`command`/`super`、`shift`、`alt`/`option`/`opt`、`ctrl`/`control`。键名：单个字符，或 `left` `right` `up` `down` `return` `tab` `space` `backspace` `escape`。一个动作一个组合 —— 覆盖会替换掉该动作的全部默认键。

### 引擎配置是怎么合成的

Ghostty 的配置按五层合成，后者覆盖前者：

1. libghostty 内置默认值
2. QuickTerm 内置兜底（`ghostty-default.conf`：Monaco 15、Builtin Pastel Dark 主题、copy-on-select、1 亿行 scrollback、option-as-alt 等）—— **仅当你完全没有 Ghostty 配置文件时**加载；一旦有了自己的配置，这一层整体让位
3. **`~/.config/ghostty/config`** —— 按 Ghostty 原生规则加载，含 `config-file` 递归包含。字体、光标、滚动、shell 集成、终端级 `keybind =` 全部生效。
4. QuickTerm 覆盖层（`~/Library/Application Support/QuickTerm/engine-overlay.conf`，切主题时重写）：当前主题的配色与 palette、`window-padding-x/y`、`background-opacity`、`unfocused-split-opacity`，以及 `window-vsync = false`（见故障排查）。`theme = "ghostty"` 时只保留 padding。
5. `config.toml` 的 `[ghostty]` 段，追加在最后。

Ghostty 加载器有个特点：经 `config-file` 包含进来的文件是在第 4、5 层**之后**才应用的，所以写在包含文件里的配色会压过 QuickTerm 的主题。想让主题生效，配色请放在顶层 `~/.config/ghostty/config`，或干脆交给 QuickTerm。

### 文件与目录

| 路径 | 用途 |
|---|---|
| `~/.config/quickterm/config.toml` | QuickTerm 配置（热重载） |
| `~/.config/quickterm/themes/<name>/{colors.toml, backgrounds/}` | 自定义主题；与内置同名时覆盖内置 |
| `~/.config/quickterm/backgrounds/` | 自选壁纸，全主题共用 |
| `~/.config/ghostty/config` | 你的 Ghostty 配置，原样复用 |
| `~/Library/Application Support/QuickTerm/` | `engine-overlay.conf` 与 `state.json`（布局存档） |

## 故障排查

- **Zig 拉依赖报 400 / HttpConnectionClosing** —— Zig 的拉取器不走系统代理。先让 `scripts/build-ghosttykit.sh` 把 Zig 装好（会停在拉依赖那步），再跑 `scripts/fetch-zig-deps.sh`（用 curl 预取并灌进 Zig 缓存），然后重跑构建脚本。
- **链接报大量 undefined symbol（`_sigaction` 等）** —— Xcode 26 SDK 的 `libSystem.tbd` 缺 arm64。`scripts/build-ghosttykit.sh` 会自动打 SDK overlay；务必用脚本构建，不要手动 `zig build`。
- **`cannot execute tool 'metal'`** —— 安装 Metal Toolchain（见环境要求）。
- **`xcodebuild` 找不到 `GhosttyKit.xcframework`** —— 先跑 `scripts/build-ghosttykit.sh`，再 `xcodegen generate`。
- **背景选择器里只有「选择图片…」一格** —— 主题壁纸不进 git；跑 `scripts/fetch-themes.sh` 后重新构建。
- **开了几百个 pane 之后新终端全部失败** —— macOS 26 对已废弃的 `CVDisplayLink` 有登录会话级配额。QuickTerm 注入 `window-vsync = false` 绕开；若你手动改回 `true` 又撞上配额，注销重登即可恢复。

每一条的来龙去脉见 [`docs/porting-notes.md`](docs/porting-notes.md)。

## 架构一段话

AppKit 掌管状态与生命周期，SwiftUI 只做渲染。`MainWindowController` 是窗口管理状态的唯一拥有者，分派所有动作；布局是不可变值类型（scrolling 画布用 `ScrollingStrip`，dwindle 用 Ghostty 的 `SplitTree`），所以工作区就是一个值数组，持久化就是 `Codable`。Ghostty 嵌入层（`Sources/GhosttyEmbed/`）移植自 Ghostty 自家 macOS 应用（MIT），QuickTerm 的改动以 `// QuickTerm：` 注释标记。重叠 pane 上的悬停与点击焦点判定走模型几何（`HoverOcclusion`）而非 AppKit `hitTest`，所以按住 `⌘` 时浮出的拖拽源覆盖层抢不走焦点；`⌘` 拖拽的目标判定用 `hitTest`，命中非 surface 时按 z 序做几何回退。

- 设计方案：[`docs/superpowers/specs/2026-08-31-quickterm-design.md`](docs/superpowers/specs/2026-08-31-quickterm-design.md)
- 移植笔记与环境坑：[`docs/porting-notes.md`](docs/porting-notes.md)
- 验收清单：[`docs/acceptance/`](docs/acceptance/)

## 致谢

- [Ghostty](https://github.com/ghostty-org/ghostty)（Mitchell Hashimoto）—— 终端引擎与 `Sources/GhosttyEmbed/` 的嵌入代码（MIT）。
- [Omarchy](https://github.com/basecamp/omarchy)（DHH 与贡献者）—— 设计、键位以及 22 套主题与壁纸（MIT）。

## 许可

MIT，见 [`LICENSE`](LICENSE)。Ghostty 与 Omarchy 的资产保留各自的 MIT 许可与版权声明。
