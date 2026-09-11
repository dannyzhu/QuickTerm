import SwiftUI

/// M3 前的固定调色板（Tokyo Night，spec §1.3 默认主题）。
/// M3 的 ThemeManager 会把这里换成 colors.toml 驱动的动态值。
enum Palette {
    static let background = Color(red: 0x1a / 255.0, green: 0x1b / 255.0, blue: 0x26 / 255.0)
    static let foreground = Color(red: 0xa9 / 255.0, green: 0xb1 / 255.0, blue: 0xd6 / 255.0)
    static let accent = Color(red: 0x7a / 255.0, green: 0xa2 / 255.0, blue: 0xf7 / 255.0)
    static let alert = Color(red: 0xa5 / 255.0, green: 0x55 / 255.0, blue: 0x55 / 255.0)
    static let inactiveBorder = Color(white: 0x59 / 255.0).opacity(0.67)
    /// 非焦点 pane 边框上那行标题的颜色。**比边框亮**，而且不带透明：
    /// 那行字有一半压在边框外面，身后是壁纸——照边框那个 0x59@67% 画，
    /// 遇上浅色壁纸就糊成一团。线可以淡（它只是根线），字得读得出来
    static let inactiveTitle = Color(white: 0xb4 / 255.0)
}
