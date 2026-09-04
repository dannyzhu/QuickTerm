import SwiftUI

/// Omarchy 视觉（spec §1.1/§4.2）：2px 边框（焦点 = accent #7aa2f7 / 非焦点 = 灰 0x59@67%）、
/// gaps_in 语义（每 pane 每边 pane-gap，默认 5：相邻合成 10；边缘与外圈同值合成 10——左中右等宽，
/// scrolling / dwindle / 浮动一致）、直角、popin 87% 弹入动画。焦点态随悬停即时切换。
struct PaneChrome: ViewModifier {
    @ObservedObject var surfaceView: PaneView
    /// 浮动层 pane：非激活不垫磨砂 backdrop——它身后是下层平铺 pane 内容
    /// 而非壁纸，HUD 材质糊上去近乎实心；跳过后与平铺 pane 同为 0.92 透明
    var floating: Bool = false
    @EnvironmentObject var theme: ThemeManager
    @State private var appeared: Bool

    /// 已播过弹入的 surface：视图因布局变化重挂载时不再重播（否则整屏一起"闪"）
    private static var popped = Set<UUID>()

    init(surfaceView: PaneView, floating: Bool = false) {
        self.surfaceView = surfaceView
        self.floating = floating
        _appeared = State(initialValue: Self.popped.contains(surfaceView.id))
    }

    func body(content: Content) -> some View {
        content
            // 非激活 pane：背面垫窗口内 backdrop 模糊——磨砂的是透出的壁纸，文字锐利。
            // 激活 pane 无 backdrop = 清玻璃（透出清晰壁纸）。
            .background {
                if surfaceView.focused {
                    // 激活 = 清玻璃但更实（合成到 active-opacity，默认 0.98）
                    theme.background.opacity(theme.activeUnderlayAlpha)
                } else if theme.frostedInactive, !floating {
                    // 非激活 = 磨砂玻璃（backdrop 模糊壁纸，文字锐利）
                    VisualEffectBlur()
                }
            }
            .border(surfaceView.focused ? theme.accent : Palette.inactiveBorder, width: 2)
            .padding(theme.gapsEnabled ? theme.paneGap : 0)   // 每边留白 pane-gap（两种布局一致）
            .scaleEffect(appeared ? 1 : 0.87)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                guard !appeared else { return }
                Self.popped.insert(surfaceView.id)
                withAnimation(.easeOut(duration: 0.2)) { appeared = true }
            }
    }
}
