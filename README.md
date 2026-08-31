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
