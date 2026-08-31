import SwiftUI

/// M3 前的固定调色板（Tokyo Night，spec §1.3 默认主题）。
/// M3 的 ThemeManager 会把这里换成 colors.toml 驱动的动态值。
enum Palette {
    static let background = Color(red: 0x1a / 255.0, green: 0x1b / 255.0, blue: 0x26 / 255.0)
    static let foreground = Color(red: 0xa9 / 255.0, green: 0xb1 / 255.0, blue: 0xd6 / 255.0)
    static let accent = Color(red: 0x7a / 255.0, green: 0xa2 / 255.0, blue: 0xf7 / 255.0)
    static let alert = Color(red: 0xa5 / 255.0, green: 0x55 / 255.0, blue: 0x55 / 255.0)
    static let inactiveBorder = Color(white: 0x59 / 255.0).opacity(0.67)
}
