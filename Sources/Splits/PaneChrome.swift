import SwiftUI

/// Omarchy 视觉（spec §1.1/§4.2）：2px 边框（焦点 = accent #7aa2f7 / 非焦点 = 灰 0x59@67%）、
/// gaps_in=5（每叶 2.5，相邻合成 5）、直角、popin 87% 弹入动画。焦点态随悬停即时切换。
struct PaneChrome: ViewModifier {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    @EnvironmentObject var theme: ThemeManager
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .border(surfaceView.focused ? theme.accent : Palette.inactiveBorder, width: 2)
            .padding(theme.gapsEnabled ? 2.5 : 0)
            .scaleEffect(appeared ? 1 : 0.87)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: 0.2)) { appeared = true }
            }
    }
}
