# QuickTerm

Omarchy 风格的 macOS 原生终端：Hyprland 式平铺 + 工作区 + 主题/背景切换，
终端引擎为 libghostty（GhosttyKit）。设计方案见
`docs/superpowers/specs/2026-08-31-quickterm-design.md`。

## 构建

    scripts/build-ghosttykit.sh   # 首次约 10–30 分钟（含下载 Zig 与全量编译）
    xcodegen generate
    xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug build

要求：macOS 15+、Xcode 26+。Zig 由脚本按 pin 版本自动安装到 .tools/。
