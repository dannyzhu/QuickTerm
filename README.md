# QuickTerm

Omarchy 风格的 macOS 原生终端：Hyprland 式平铺 + 工作区 + 主题/背景切换，
终端引擎为 libghostty（GhosttyKit，pin Ghostty v1.3.1）。设计方案见
`docs/superpowers/specs/2026-08-31-quickterm-design.md`，移植与构建细节见
`docs/porting-notes.md`。

## 环境要求

- macOS 15+（开发验证于 macOS 26.7 / Xcode 26.6）
- Xcode 26+，且已安装 Metal Toolchain：`xcodebuild -downloadComponent MetalToolchain`
- Homebrew（用于安装 xcodegen：`brew install xcodegen`）
- Zig 无需手动安装——构建脚本按 Ghostty pin 的版本自动装到 `.tools/`

## 构建

```bash
git submodule update --init                # 拉取 vendor/ghostty (v1.3.1)
scripts/fetch-zig-deps.sh                  # 代理环境下预取 Zig 依赖（可跳过，构建失败再跑）
scripts/build-ghosttykit.sh                # 构建 GhosttyKit.xcframework（首次 10–30 分钟）
xcodegen generate
xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug build
```

运行：`open build/.../QuickTerm.app`，或

```bash
open "$(xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/QuickTerm.app"
```

测试：

```bash
xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug test
```

## 故障排查

- **Zig 拉依赖报 400/HttpConnectionClosing**：Zig 自带网络客户端不走系统代理，先跑 `scripts/fetch-zig-deps.sh`
- **链接报大量 undefined symbol（_sigaction 等）**：Xcode 26 SDK 的 arm64 tbd 问题，`scripts/build-ghosttykit.sh` 内置 overlay 修复，确保用脚本构建而非手动 `zig build`
- **报 cannot execute tool 'metal'**：安装 Metal Toolchain（见环境要求）
- **xcodebuild 找不到 GhosttyKit.xcframework**：先跑 `scripts/build-ghosttykit.sh` 再 `xcodegen generate`

## 配置

QuickTerm 优先复用你已有的 `~/.config/ghostty/config`（字体、光标、滚动、终端级键位等）。
QuickTerm 自身配置 `~/.config/quickterm/config.toml`（M4 起支持，格式见设计方案 §4.7）。

## 快捷键（M1）

默认 **scrolling 无限横向画布**（v1.1，忠实 Omarchy：新列插在当前列右侧、列宽 0.49、
视口跟随焦点、相邻列两缘露出）；`Cmd+L` 按工作区切换 dwindle 平铺。
Cmd+Return 新建（scrolling=右插新列 / dwindle=分裂）· Cmd+W 关闭 · Cmd+方向 焦点 ·
Cmd+Shift+方向 换位 · Cmd+J（scrolling=併栈⇄拆列 / dwindle=切分裂方向）· Cmd+F 缩放 ·
Cmd+Ctrl+←→ 调列宽/大小 · Cmd+Ctrl+= 等分 · Alt+Tab / Cmd+[ ] 循环 ·
⌘+左键拖 移动/插列/併栈 · ⌘+右键拖 调大小 · 双指横滑 平移画布

## 配置（M4）

`~/.config/quickterm/config.toml`（主菜单 → 设置 可自动创建模板；保存即热重载）：
`theme`（主题名或 "ghostty" 完全跟随 ghostty 配置）· `workspaces`（1–10）·
`[keybinds]` 改键（动作清单见 Cmd+K）· `[ghostty]` 任意 ghostty 选项透传（最高优先级）。

已知环境注意：macOS 26 对已废弃的 CVDisplayLink 存在会话级配额，QuickTerm 默认
`window-vsync = false` 绕开（可在 `[ghostty]` 覆盖，配额耗尽时注销重登恢复）。
