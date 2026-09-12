import SwiftUI

/// The fixed pre-M3 palette (Tokyo Night, the default theme in spec §1.3).
/// The M3 `ThemeManager` replaces these with dynamic values driven by colors.toml.
enum Palette {
    static let background = Color(red: 0x1a / 255.0, green: 0x1b / 255.0, blue: 0x26 / 255.0)
    static let foreground = Color(red: 0xa9 / 255.0, green: 0xb1 / 255.0, blue: 0xd6 / 255.0)
    static let accent = Color(red: 0x7a / 255.0, green: 0xa2 / 255.0, blue: 0xf7 / 255.0)
    static let alert = Color(red: 0xa5 / 255.0, green: 0x55 / 255.0, blue: 0x55 / 255.0)
    static let inactiveBorder = Color(white: 0x59 / 255.0).opacity(0.67)
    /// Color of the title drawn on an unfocused pane's border. **Brighter than the border**,
    /// and with no transparency: half of that text sits outside the border with the wallpaper
    /// behind it, so drawing it in the border's own 0x59 at 67% smears it into the background on
    /// a light wallpaper. The line may be faint (it is only a line); the text has to stay
    /// readable.
    static let inactiveTitle = Color(white: 0xb4 / 255.0)
}
