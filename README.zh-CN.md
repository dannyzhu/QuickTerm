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
- **浏览器 pane 带扩展** —— `Cmd+B` 开一个多标签的 WebKit 浏览器 pane；Chrome / Firefox 的 WebExtensions 可以直接从 Chrome Web Store 装，或从本机 Chrome 导入（macOS 15.4+）。
- **状态恢复** —— 布局、浮动 pane、活动工作区、每个 pane 的工作目录，下次启动原样回来。
- **可脚本化、给 agent 用的** —— 一个 Unix socket 控制面加一个 `quickterm` 命令行：读状态、用一份 JSON spec 摆好整个工作区、长轮询事件，也可以当 MCP 服务挂上去。读是免确认的，改是可见可撤销的，破坏性的会先问你（见[控制面](#控制面命令行与-ai-agent)）。

## 安装

预构建的 DMG 在 [Releases](https://github.com/dannyzhu/QuickTerm/releases) 页面（通用二进制，Apple Silicon 与 Intel 均可，macOS 15.4+）。

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

仅从源码构建时需要。Releases 里的 DMG 在任何 Mac（Apple Silicon 或 Intel，macOS 15.4+）上直接运行，不需要以下任何东西。

- macOS 15.4+（开发验证于 macOS 26 / Xcode 26.6，Apple Silicon）
- Xcode 26+，并已安装 Metal Toolchain：`xcodebuild -downloadComponent MetalToolchain`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
- Zig 无需手动安装，脚本按 Ghostty pin 的精确版本自动装到 `.tools/`

## 构建

```bash
git clone --recurse-submodules <本仓库>
cd quickterm
scripts/build-ghosttykit.sh      # 先把 pin 版 Zig 装到 .tools/，再构建 vendor/ghostty/macos/GhosttyKit.xcframework（首次 10–30 分钟）
# GHOSTTYKIT_TARGET=universal scripts/build-ghosttykit.sh   # arm64 + x86_64 通用库（发布 DMG 必需；耗时约 2 倍）
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

### 屏幕（多窗口）

一个「屏幕」就是一个 QuickTerm 窗口，有自己的工作区、状态栏、浮动层和 Scratchpad——每台显示器摆一个，互不干扰。入口全在 **Window 菜单**（不占快捷键，这类操作本来就少）：

| 菜单项 | 作用 |
|---|---|
| 新建屏幕 | 在当前显示器上开一个，继承焦点 pane 的目录 |
| 在显示器上新建屏幕 ▸ | 同上，但由你选显示器（子菜单每次打开时重建，热插拔与虚拟显示器都能跟上） |
| 将此屏幕移到显示器 ▸ | 把当前屏幕搬到另一台显示器（窗口没有标题栏可拖，所以靠这个） |
| 在所有桌面显示 | 让这个屏幕出现在所有桌面 |
| 关闭屏幕 | 关掉它（还有进程在跑会先确认）；关掉最后一个 = 退出 |

**一键复原**：下次启动会还原每个屏幕、它原来所在的显示器，以及各自的工作区、布局、浮动 pane、每个终端 pane 的目录、每个浏览器 pane 打开的标签页。存档是持续写的（防抖），不再只在退出时写一次；格式为 `state.json` v5——老版本 QuickTerm 读不了它，所以本版首次启动会在旁边留一份 `state.pre-v5.json` 备份。

两条来自 macOS 本身的限制：**窗口无法被程序放到指定的虚拟桌面（Space）**——公开 API 没有这个能力，新屏幕只会开在你当前所在的桌面，你用 Mission Control 拖过去之后 macOS 会记住，但重启后我们无法复原；另外只要有任一屏幕处于非原生全屏，Dock 与菜单栏会在**所有显示器**上隐藏，因为 `presentationOptions` 是进程级的。

### 鼠标

| 手势 | 效果 |
|---|---|
| 悬停 | 焦点跟随鼠标 |
| `⌘` + 左键拖平铺 pane | 落到目标中心 = 交换。落到边缘：scrolling 下左右缘 = 在旁边插一列、上下缘 = 併进目标列的栈；dwindle 下 = 在该侧分裂插入 |
| `⌘` + 左键拖浮动 pane | 移动（并置顶） |
| `⌘` + 右键拖 | 调大小：scrolling 改列宽，dwindle 调就近分隔条，浮动 pane 改自身 |
| `⌘` + 点击终端里的链接 | 在浏览器 pane 里打开——当前工作区最近激活的浏览器 pane 开新标签，没有就在终端旁新开一个（`link-opener = "system"` 恢复系统浏览器） |
| 顶栏上滚滚轮 | 循环工作区 |
| 双指横滑 | 平移 scrolling 画布。鼠标在**激活的**浏览器 pane 上时交给网页（横向滚动 / 前进后退手势） |
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
| `divider-opacity` | 0.2 | dwindle 分隔细线（1pt）的不透明度（1 = 实线，0 = 隐藏） |
| `pane-gap` | 5 | 每 pane 每边留白 pt，scrolling / dwindle 一致（相邻间距 = 2×gap；dwindle 分隔线不占空间）。旧键 `dwindle-gap` 仍可读作别名 |
| `file-manager-command` | yazi | `file-manager` 动作运行的程序（名字按 PATH 与常见 Homebrew/cargo 目录查找，或绝对路径；`lf`、`ranger` 亦可）。安装：`brew install yazi` |
| `browser-home` | https://www.google.com | 新浏览器 pane 打开的页面 |
| `browser-search` | https://www.google.com/search?q=%s | 地址栏输入非网址时的搜索模板（`%s` = 关键词） |
| `browser-user-agent` | safari | `safari` 伪装成 Safari（Google 登录页拒绝嵌入式浏览器）、`webkit` 用原生 WebKit UA、或任意自定义字符串 |
| `browser-inspectable` | false | 浏览器 pane 开启 Web Inspector |
| `browser-tab-bar` | always | `always` 始终显示标签条；`auto` 单标签时隐藏。标签条右端有 `+` 按钮,点击新建标签 |
| `browser-tab-width` | 200 | 标签最大宽度 pt（40–600）；不足时各标签等分标签条 |
| `link-opener` | browser-pane | 终端里 `⌘`+点击的 http(s) 链接开在哪：`browser-pane` = 在当前工作区最近激活的浏览器 pane 里开新标签（没有就在终端旁新开一个浏览器 pane）；`system` = 系统默认浏览器。其它 scheme（mailto、ssh、文件路径）始终交给系统 |
| `browser-tab-min-width` | 80 | 标签最小宽度 pt（40–600）；全部到最小仍放不下时标签条横向滚动（滚轮；当前标签自动滚入视野） |
| `browser-extensions` | true | 浏览器 pane 加载 WebExtensions（见 [浏览器扩展](#浏览器扩展)）。`false` = 全部卸载，新标签也不再挂扩展 controller |
| `browser-download-dir` | ~/Downloads | 浏览器 pane 的下载落盘目录（支持 `~`；不是个已存在的目录时回退 `~/Downloads`）。下载进度显示在地址栏右侧，点开可取消 / 在 Finder 中显示 / 清除已完成 |

下载落在 `browser-download-dir`（默认 `~/Downloads`）：下载期间地址栏右侧出现进度环，点开是下载列表——取消、在 Finder 中显示、移除单行、清除已完成。
列表属于 pane：关掉这个 pane 会取消它里面还没下完的下载。

浏览器 pane 的边界：没有 Widevine DRM（Netflix/Spotify 网页版不可用）、没有系统密码自动填充和通行密钥（这类流程请用 `Cmd+Shift+O` 到系统浏览器完成）。

| `inactive-blur` | 2.5 | `> 0` 时非激活的平铺 pane 背后垫磨砂（模糊的是壁纸，文字不受影响；浮动 pane 不垫；目前数值只作开关） |

`Cmd+Backspace` 一键全部关掉（pane 与顶栏变不透明）；`Cmd+Shift+Backspace` 开关 gaps。

### 浏览器扩展

浏览器 pane 用 WebKit 的 `WKWebExtension` 跑 Chrome / Firefox 格式的 WebExtensions（macOS 15.4+）。`browser-extensions = false` 整体关闭。

- **从 Chrome Web Store 安装** —— 在浏览器 pane 里打开扩展的商店页，点右下角注入的 **添加到 QuickTerm** 按钮：QuickTerm 下载 CRX、列出它要的权限，确认后安装。
- **从 Chrome 导入** —— 工具条右端的拼图菜单（`Cmd+Shift+E`）里有「从 Chrome 导入已安装扩展…」：把 `~/Library/Application Support/Google/Chrome/Default/Extensions` 里每个扩展的最高版本复制过来（主题、打包应用、已装过的跳过）。
- **管理** —— 同一个菜单里列出全部已安装扩展（停用的带「（已停用）」后缀），子菜单可以打开、固定到工具条、启用 / 停用、打开选项页、移除。
- **固定到工具条** —— 与 Chrome 一样：只有**固定**的扩展才在拼图左边有按钮（带 badge），其余都待在拼图菜单里（菜单里的「打开」等同于点那颗按钮）。从商店装的默认固定，从 Chrome 导入的沿用它在 Chrome 里的固定状态；地址栏最少保留 200pt，固定了但放不下的按钮会从工具条上藏起来，仍可从拼图菜单点开；pane 窄到连 200pt 都放不下时改由地址栏继续让步——拼图按钮始终看得见、点得到。
- **popup 与右键菜单** —— 点扩展按钮弹出它的 popup；页面右键菜单末尾会追加扩展自己的菜单项。
- **文件位置** —— `~/Library/Application Support/QuickTerm/Extensions/<id>/`，启用与固定状态在同目录的 `state.json`。扩展与你的标签共享 cookie 与登录态。
- **兼容垫片** —— 安装时（旧版本装的扩展则在下次启动时补一次）QuickTerm 会改写扩展的 `background` 入口，让 `__quickterm-compat.js` 先跑：补上 WebKit 没有的 `webNavigation.onHistoryStateUpdated` / `onReferenceFragmentUpdated`（空事件；Stylish 的后台在顶层直接 addListener，缺了整个扩展起不来），并让 `importScripts()` 跳过空文件（WebKit 在每个被导入脚本求值后会清空 microtask 队列，Tampermonkey 的启动标记因此翻转、popup 永远转圈）；同时把脚本里写死的 `chrome-extension:` 改成 `webkit-extension:`——WebKit 下扩展页面的地址是 `webkit-extension://`，写死 scheme 的 Chrome 构建会把自己的 popup 当成外来页面（Tampermonkey 的后台因此拒掉 popup 的每个请求，popup 一片空白）。嵌在普通网页里的扩展页面（Stylish 的侧栏是个 `webkit-extension://` iframe）跑在网页进程里，直接调 `tabs` / `windows` / `action` / `scripting` / `alarms` / `contextMenus` / `cookies` 会被 WebKit 杀掉整个页面进程，因此除 `runtime` / `storage` / `i18n` / `permissions` 外的命名空间在那里都换成经扩展后台转发的代理（没有后台脚本的扩展，这些调用会失败而不是崩溃）。网站把数据交给扩展走的是 Chrome 的 `externally_connectable` 通道（userstyles.org 就是这样把登录状态交给 Stylish 的），页面侧写的是 `chrome.runtime.sendMessage(<扩展 id>, …)`；WebKit 实现了这条通道，但只把入口挂在 `browser.runtime` 上，因此地址命中某个已装扩展 `externally_connectable.matches` 的网页会另外拿到一层最小的 `chrome.runtime` 别名（只有 `sendMessage` / `connect`）——其它站点不注入，页面自己已有 `chrome` 时也一概不动。原始入口记在 manifest 的 `__quickterm` 下，扩展更新会重新生成。
- **支持范围** —— WebKit 实现了约 25 个 WebExtension API 命名空间。不支持：阻断式 `webRequest`（用 `declarativeNetRequest`）、`identity`、`history`、`downloads`、`management`、`proxy`、`debugger` 与原生消息；`storage.sync` 只存本地、不跨设备。manifest 里声明的权限在安装时一次性授予，扩展运行中再要的权限会弹窗确认。

## 默认快捷键

下表每个动作都可在 `config.toml` 改键（见[配置](#配置)）。不在表内的组合一律放行给终端 —— `Cmd+C`/`Cmd+V`、字号键、`Cmd+Q` 等完全不受影响。`Cmd+Q` 在还有 pane 打开时会先确认，一个 pane 都没有时直接退出。

| 按键 | 动作 id | 功能 |
|---|---|---|
| `Cmd+Return` | `new-terminal` | 新建终端（焦点列右侧 / dwindle 分裂），继承当前目录 |
| `Cmd+W` | `close-pane` | 关闭焦点 pane（有进程运行时确认）。关掉最后一个 pane 后窗口保留并提示新建，程序不退出 |
| `Cmd+←↑↓→` | `focus-*` | 移动焦点 |
| `Cmd+Shift+←↑↓→` | `swap-*` | 换位（视口自动跟随） |
| `Cmd+J` | `toggle-split-dir` | 併列/拆列（scrolling）· 翻转分裂（dwindle） |
| `Cmd+F` | `toggle-zoom` | pane 占满内容区 |
| `Cmd+Ctrl+←↑↓→` | `resize-*` | 调整大小——scrolling 只调列宽（左右），dwindle 四向；`Shift` 微调仅 dwindle 生效 |
| `Cmd+Ctrl+=` | `equalize` | 全部等分 / 列宽重置 |
| `Alt+Tab` / `Alt+Shift+Tab`、`Cmd+]` / `Cmd+[` | `cycle-pane-next` / `-prev` | 循环 pane |
| `Cmd+L` | `toggle-layout` | scrolling ⇄ dwindle |
| `Cmd+T` | `toggle-float` | 浮动 ⇄ 平铺。按住 ⌘：拖中间移动，拖四边沿该轴缩放，拖四角双轴缩放（对边不动），光标会提示；⌘+右键拖动从右下角缩放 |
| `Cmd+S` | `scratchpad` | Scratchpad 终端 |
| `Cmd+Shift+B` | `file-manager` | 文件管理器（[yazi](https://github.com/sxyazi/yazi)）在新 pane 里以焦点 pane 的目录启动；在别的目录退出则原位开终端 |
| `Cmd+B` | `new-browser` | 浏览器 pane（WebKit），打开 `browser-home` |
| `Cmd+Shift+K` | `clear-terminal` | 仅终端 pane：清屏并清回滚（ghostty 的 `clear_screen`；`Cmd+K` 被速查表占用） |
| `Cmd+Shift+L` / `Cmd+R` | `web-focus-address` / `web-reload` | 仅焦点在浏览器 pane 时：地址栏 / 重新加载（其它 pane 放行这些键） |
| `Cmd+Shift+[` / `Cmd+Shift+]` | `web-back` / `web-forward` | 仅浏览器 pane：后退 / 前进 |
| `Cmd+=` / `Cmd+-` / `Cmd+0` | `web-zoom-in` / `web-zoom-out` / `web-zoom-reset` | 仅浏览器 pane：页面缩放（终端字号键不受影响） |
| `Cmd+Shift+O` | `web-open-external` | 仅浏览器 pane：用系统默认浏览器打开当前页 |
| `Cmd+N` / `Ctrl+Tab` / `Ctrl+Shift+Tab` | `web-new-tab` / `web-next-tab` / `web-prev-tab` | 仅浏览器 pane：标签页。`Cmd+W` 关当前标签（最后一个标签关 pane）；⌘+点击链接后台新标签；`window.open` 开新标签 |
| `Cmd+Shift+E` | `web-extensions` | 仅浏览器 pane：扩展菜单（安装 / 启停 / 从 Chrome 导入） |
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

与 Omarchy 的两处有意偏移：调整大小用 `Cmd+Ctrl+方向`，因为 `Cmd+-`/`Cmd+=` 在所有 macOS 终端里都是字号键；`Cmd+K` 是速查表而不是"清屏"——清屏用 `Cmd+Shift+K`（`clear-terminal`，同样可改键）。

macOS 菜单栏的 Shell / Pane 菜单只列了少数动作的默认快捷键；标签不随改键变化，但快捷键本身遵守 `[keybinds]`（解绑或改键后的组合不再从菜单触发）。速查表（`Cmd+K`）永远反映当前键位表。

## 控制面（命令行与 AI agent）

QuickTerm 在 `~/Library/Application Support/QuickTerm/` 下监听一个 Unix domain socket，并随包提供 `quickterm` 命令行。快捷键能做的，命令行都能做；在这之上还有一层名词-动词层，它的定规是**只给绝对设值，绝不 toggle**——agent 看不到状态，重试一次 toggle 会把自己撤销。

```sh
quickterm install-cli --alias qt     # 软链到 /usr/local/bin，不可写则 ~/.local/bin —— 永远不弹管理员密码
quickterm describe --json            # 整个控制面的机器可读 schema；agent 每个会话读一次即可
```

CLI 解析、`--help`、`describe --json`、安全分级与 MCP 工具表**全部从同一张命令表生成**，所以这层表面不可能漂移。

```
quickterm state | list | get | action <wm-action> | describe | version
quickterm pane      new | close | focus | move | swap | set | resize
quickterm workspace goto | set-layout | equalize | clear | count
quickterm screen    new | close | move | focus | set
quickterm app       get | set
quickterm spec      dump | validate | apply
quickterm events    poll | follow
quickterm input     send-text
quickterm mcp
```

每个 pane 的环境里都已经有 `QUICKTERM_SOCKET` / `QUICKTERM_PANE` / `QUICKTERM_SCREEN` / `QUICKTERM_WORKSPACE` / `QUICKTERM_TOKEN` / `QUICKTERM_PANE_TOKEN`，所以 `-t @self` 零配置就能用。

### 一次摆好一整个工作区

要摆好一整个工作区，用 `spec apply`，别发 N 条 `pane new`：N 条命令 = N 次重排、N 次动画、N 个失败点，中途失败还会留下一个谁也说不清的半成品。spec 是一次算完、一次落地。

```sh
cat > dev.json <<'JSON'
{ "schema": "quickterm.workspace/1", "layout": "scrolling", "visibleColumns": 3,
  "columns": [
    {"panes": [{"cwd": "~/proj", "cmd": "nvim ."}]},
    {"panes": [{"cwd": "~/proj", "cmd": "npm run dev", "hold": true}, {"cwd": "~/proj"}]},
    {"panes": [{"kind": "browser", "url": "http://localhost:3000"}]}],
  "focus": {"column": 0, "row": 0} }
JSON

quickterm spec apply -f dev.json -t :4 --dry-run   # 只打印 diff，一个字节都不改
quickterm spec apply -f dev.json -t :4            # 默认 --into-empty：非空工作区一律拒绝
```

`spec dump` 打印的就是那份 spec 本身（不套响应信封），所以 `dump → 改字段 → apply --reuse` 是个闭环：对得上的 pane 原地留着，跑着的 dev server 不会被重启。

### `[control]` 配置

```toml
[control]
# socket = true             # false 彻底不监听（quickterm 命令行与 MCP 都连不上）
# mcp = true                # false 时 `quickterm mcp` 直接拒绝服务（socket 仍可给你自己的命令行用）
# mode = "ask"              # off = 不监听 | readonly = 只读 | ask = 默认（"on" 是 ask 的别名）
# expose-browser = "token"  # token | always | never：谁能读到浏览器 pane 的网址与标题
# send-text = false         # quickterm input send-text：把文本当键盘输入送进一个终端 pane。
```

`socket`、旧名 `enabled`、`mode` 是同一个监听器上的三个开关，**取最严的那个**：`socket = false`、`enabled = false`、`mode = "off"`，任何一个都等于彻底不监听。`mcp` 是单独一档，因为两者的攻击面不同：你完全可能自己要用命令行，却不想让任何 MCP 宿主（以及它读到的每一段网页 / CI 日志）连进来。`mcp = false` 时 `quickterm mcp` 直接拒绝服务，并在错误里点名是哪个配置键拒绝的；socket 仍然照常给你自己的 shell 用。

**刻意没有"免确认"这一档**：确认闸门只能靠 `off` / `readonly` 绕开，写错一个值也只会回落到 `ask`。

配置里**所有布尔键**（这一段以及别处）都认 `true` / `1` / `yes` / `on` 与 `false` / `0` / `no` / `off`（大小写无所谓）。表外的写法一律**不猜**：那一行不生效，保留声明的默认值，并在日志里写一条点名键与值的告警——所以 `socket = off` 是真的关掉监听，而不是悄悄留在"开"上。

### 安全姿态

- 读是静默的——但**没有继承 `QUICKTERM_TOKEN` 的调用方读不到浏览器 pane 的网址与标题**（`<redacted>`）。浏览器 pane 里装着用户已登录的会话，`quickterm state` 本身就是一个外泄面。
- 改是静默但**可见**的：状态栏闪一下（写明命令与自称来源 pane），完整记录在应用内的控制面活动日志里，布局类变更登记到 UndoManager（`Cmd+Z` 可回滚）。变更命令按来源限流；用户面前挂着模态对话框时，**所有**变更命令一律拒绝。
- 破坏性命令（`pane close`、`workspace clear`、`screen close`、`spec apply --replace`）按 (调用进程 pid, 命令类) **在 QuickTerm 里确认一次**。确认框里的进程名与 pid 来自内核（`LOCAL_PEERPID`），抄走 token 也伪装不了。
- `input send-text` 默认关闭，**等于在那个 shell 里打字**（可能是 root，也可能是一条活着的 ssh 会话）。打开之后：写调用方自己那个 pane 免确认（那个 tty 本来就是它自己的），但这一点要用继承来的、每 pane 一枚的 `QUICKTERM_PANE_TOKEN` **证明**——自报的 `QUICKTERM_PANE` 换不来豁免，服务端验不了它。写**任何**别的 pane 每次都要确认，**确认框里会列出要打进去的正文以及后面跟不跟回车**；控制字符一律拒绝，换行只能靠显式的 `--enter`。
- 连接必须与 QuickTerm 同 uid（`LOCAL_PEERCRED`）；socket 0600，目录 0700。**绝不监听 TCP，也绝不做转义序列通道。**
- **`QUICKTERM_TOKEN` 是来源证明，不是权限边界。** 每次启动只有一枚、注入每一个 pane，所以它只能回答"这条命令来自**某个** QuickTerm pane"，绝不跳过任何确认。`QUICKTERM_PANE_TOKEN` 每 pane 一枚（`HMAC(每次启动的密钥, paneID)`），能回答前者答不了的"来自**哪一个** pane"——但它同样不是权限边界，全控制面只用在一处：`send-text` 的自写豁免。

真正的威胁不是这台机器上的别的用户，而是**被利用的代理**：pane 里的 agent 读到一个被投毒的网页 / README / CI 日志，然后被指使去跑 `quickterm` 命令。所以确认闸门从第一版就在，而不是留给"v2"。

### MCP

`quickterm mcp` 是一个 stdio MCP 服务，11 个粗粒度工具**由同一张命令表生成**（手写的那份两个版本之内必然漂移）。

```sh
claude mcp add quickterm -- /usr/local/bin/quickterm mcp
codex mcp add quickterm -- /usr/local/bin/quickterm mcp
quickterm mcp --list-tools | jq -r '.tools[].name'
```

工具注解（`readOnlyHint` / `destructiveHint` / `idempotentHint`）是从每条命令的安全分级**机械映射**出来的，宿主因此能自动放行读、对破坏性调用弹确认——这是在 QuickTerm 自己的闸门之外、独立的第二道闸。MCP 这一层没有任何自己的特权：每次调用走的都是同一条 socket、同一套确认与限流。

### 老实说的限制

- 短句柄（`t7`/`b3`）只在 QuickTerm 这一次运行期间稳定；跨重启唯一稳定的身份是 pane 的 `id`（UUID）。
- 事件只携带结构、标题与 cwd，**绝不携带 pane 的输出内容**。"读一读那条命令打印了什么"不是控制面做的事。
- 有些变更会推进 `seq` 却没有类型化事件（`app set theme`、`screen set --fullscreen`）：你只知道快照过期了，得重新读一次 `state`。
- `events follow` 是给人和 shell 脚本的流；agent 应该用 `events poll --since` 长轮询。
- MCP 工具表约 64 KB 的 schema —— 那是每次会话都要付的上下文税，而 CLI 不调用就不占一个 token。所以：交互式的一次性控制用 MCP，批量组合用 CLI。
- `spec apply` 不搬窗口（要搬用 `screen move`）；落刀之后才失败会如实报 `partial_apply`，绝不假装什么都没发生。

完整的 agent 文档（寻址语法、退出码表、经验法则）：[`docs/agents/quickterm-cli.md`](docs/agents/quickterm-cli.md)。

## 配置

`~/.config/quickterm/config.toml` —— 首次按 `Cmd+,` 会生成带注释的模板；保存即热重载。

```toml
# 每个配置项只在 Sources/Config/ConfigSchema.swift 那张注册表里声明一次，这一段就是它。
# 配置项按功能分组 —— 一个分组 = 设置界面的一个 tab。

[appearance]
# theme = "tokyo-night"  # 或 "ghostty"：不覆盖配色，完全跟随 ghostty 配置
# pane-opacity = 0.92    # pane 背景透明度（0.5–1.0；非激活基准，文字不受影响）
# active-opacity = 0.98  # 激活 pane 背景等效透明度（0.5–1.0）
# bar-opacity = 0.75     # 顶部状态条背景透明度（0–1）
# divider-opacity = 0.2  # dwindle 分隔细线不透明度（0–1；0 隐藏，1 实线）
# inactive-blur = 2.5    # 非激活 pane 磨砂背景（> 0 开启；0 关闭）
# pane-padding = 14      # pane 内终端四边留白（pt，0–32；Omarchy 官方值 14）
# pane-gap = 5           # 每 pane 每边留白 pt（0–20；相邻间距 = 2×gap；scrolling / dwindle 一致）

[workspace]
# workspaces = 5       # 1–10
# visible-columns = 2  # scrolling 每屏可见列数（1–6；未设置走主菜单选择）

[terminal]
# file-manager-command = "yazi"  # 文件管理器程序（Cmd+Shift+B 在新 pane 里运行；名字或绝对路径，lf/ranger 亦可）

[browser]
# home = "https://www.google.com"                # 浏览器 pane（Cmd+B）打开的首页
# search = "https://www.google.com/search?q=%s"  # 地址栏输入非网址时的搜索模板（%s = 关键词）
# user-agent = "safari"                          # 伪装成 Safari（Google 登录页拒绝嵌入式浏览器）；"webkit" = 不伪装；或填自定义 UA
# inspectable = false                            # 浏览器 pane 的 Web Inspector（右键"检查元素"）
# tab-bar = "always"                             # 标签条：always = 始终显示（默认）；auto = 只有一个标签时隐藏
# tab-width = 200                                # 标签最大宽度 pt（40–600）
# tab-min-width = 80                             # 标签最小宽度 pt（40–600）；放不下时标签条横向滚动
# extensions = true                              # 浏览器 pane 加载 WebExtensions（Chrome Web Store 安装 / 从 Chrome 导入；macOS 15.4+）
# download-dir = "~/Downloads"                   # 浏览器 pane 下载落盘目录（支持 ~；目录不存在时回退 ~/Downloads）
# link-opener = "browser-pane"                   # 终端 ⌘+点击链接：browser-pane = 在浏览器 pane 打开（有则用最近激活的，无则新开）；system = 系统浏览器

[keybinds]                  # 动作 = "修饰键+键"；"none" 解绑。动作 id 见 Cmd+K
# new-terminal = "cmd+return"
# toggle-float = "cmd+shift+t"
# file-manager = "cmd+shift+b"
# new-browser = "cmd+b"

[ghostty]                   # 任意 Ghostty 选项，原样透传，最高优先级
# cursor-style = block
# font-size = 13
```

**旧写法永远有效。** 这些键原先都摊在文件顶层（`theme = …`、`browser-home = …`），`[control]` 里叫 `enabled`；每一种旧写法都照收不误，不警告、不啰嗦 —— 你现有的 `config.toml` 一个字都不用改。上面这份是全新安装会生成的样子：`[browser]` 段里去掉了 `browser-` 前缀（段名已经说了），`[control] enabled` 改叫 `socket`（被开关的本来就是那个 socket 监听）。新旧同时写了的话新名赢，只有 `socket`/`enabled` 例外 —— 那一对取**更严**的那个（见上面的 `[control]`）。

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
| `~/Library/Application Support/QuickTerm/` | `engine-overlay.conf` 与 `state.json`（v5：屏幕、布局、终端目录、浏览器标签；`state.pre-v5.json` 是升级前的备份） |

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
