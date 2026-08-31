import SwiftUI

/// Omarchy 视觉（spec §1.1/§4.2）：2px 边框（焦点 = accent #7aa2f7 / 非焦点 = 灰 0x59@67%）、
/// gaps_in=5（每叶 2.5，相邻合成 5）、直角、popin 87% 弹入动画。焦点态随悬停即时切换。
struct PaneChrome: ViewModifier {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    @State private var appeared = false

    static let accent = Color(red: 0x7a / 255.0, green: 0xa2 / 255.0, blue: 0xf7 / 255.0)
    static let inactive = Color(white: 0x59 / 255.0).opacity(0.67)

    func body(content: Content) -> some View {
        content
            .border(surfaceView.focused ? Self.accent : Self.inactive, width: 2)
            .padding(2.5)
            .scaleEffect(appeared ? 1 : 0.87)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: 0.2)) { appeared = true }
            }
    }
}
