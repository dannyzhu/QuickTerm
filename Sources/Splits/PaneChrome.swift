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

    private var borderColor: Color { surfaceView.focused ? theme.accent : Palette.inactiveBorder }
    /// 标题与边框**不是同一个颜色**：焦点态两者都用 accent（够亮），非焦点态线照旧淡，
    /// 字则单独提亮——字有一半落在边框外的壁纸上，跟着线一起淡就读不出来了
    private var titleColor: Color { surfaceView.focused ? theme.accent : Palette.inactiveTitle }

    /// 上边框那块标题：**只认被显式设过的**（右键「Change Terminal Title」/ 控制面
    /// `pane set --title`）。shell 用 OSC 报上来的不算——那玩意每敲一条命令就换一次，
    /// 边框会跟着抖。总开关是 config `pane-title`
    private var titleOnFrame: String? {
        theme.paneTitleEnabled ? surfaceView.customTitle : nil
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
            // 不再用 `.border`：标题要像 fieldset 的 legend 一样把上边框咬开一个口，
            // 四条边只能自己画（长相与原来那圈 2px 直角边框逐像素一致）
            .overlay { PaneFrame(color: borderColor, titleColor: titleColor,
                                 title: titleOnFrame, overhang: overhang) }
            .padding(theme.gapsEnabled ? theme.paneGap : 0)   // 每边留白 pane-gap（两种布局一致）
            .scaleEffect(appeared ? 1 : 0.87)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                guard !appeared else { return }
                Self.popped.insert(surfaceView.id)
                withAnimation(.easeOut(duration: 0.2)) { appeared = true }
            }
    }

    /// 标题往上能越出边框多少：外层槽位是 `.clipped()` 的，边框以外只剩这一圈 pane-gap
    private var overhang: CGFloat { theme.gapsEnabled ? theme.paneGap : 0 }
}

/// pane 的四条边 + 压在上边框上的标题。标题所在的那一段边框是断开的（fieldset legend）。
/// 焦点一变，线与字一起换色，看上去仍是一个框；但非焦点态字比线亮一档
/// （见 `PaneChrome.titleColor`：字有一半落在边框外的壁纸上）。
private struct PaneFrame: View {
    let color: Color
    /// 标题的颜色（见 `PaneChrome.titleColor`：非焦点态比边框亮一档）
    let titleColor: Color
    /// 要显示的标题原文（截多长、画在哪、边框断哪一段都在 `PaneTitleBadge` 里算）；
    /// nil 或算下来放不下 = 画整圈不断的边框
    let title: String?
    /// 上边框之上还能借用多少空间（= pane-gap）：借不到就连标题带断口一起不画
    let overhang: CGFloat

    var body: some View {
        GeometryReader { geo in
            let metrics = PaneTitleBadge.Metrics.standard
            // 断口与文字同出一处：分开算就会出现"边框咬开了、字却掉到线下面"
            let badge = PaneTitleBadge.place(title: title, topEdgeWidth: geo.size.width,
                                             overhang: overhang, metrics: metrics)
            ZStack(alignment: .topLeading) {
                Path { path in
                    frame(&path, size: geo.size, gap: badge.map { (start: $0.gapStart, end: $0.gapEnd) })
                }
                .fill(color)
                if let badge {
                    Text(badge.text)
                        .font(Font(metrics.font))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: metrics.leadingInset, y: badge.offsetY)
                }
            }
        }
        // 边框与标题都不能吃鼠标：终端的选中、⌘+点击链接都要穿过去
        .allowsHitTesting(false)
    }

    /// 四条边各画成一个实心矩形（而不是 stroke）：直角、线宽精确、断口好开
    private func frame(_ path: inout Path, size: CGSize, gap: (start: CGFloat, end: CGFloat)?) {
        let line = PaneTitleBadge.lineWidth
        let (w, h) = (size.width, size.height)
        guard w > 0, h > 0 else { return }
        // 左右两条画满高，四个直角就由它们补齐
        path.addRect(CGRect(x: 0, y: 0, width: line, height: h))
        path.addRect(CGRect(x: w - line, y: 0, width: line, height: h))
        path.addRect(CGRect(x: 0, y: h - line, width: w, height: line))
        guard let gap, gap.start < w else {
            path.addRect(CGRect(x: 0, y: 0, width: w, height: line))
            return
        }
        path.addRect(CGRect(x: 0, y: 0, width: gap.start, height: line))
        let right = min(gap.end, w)
        path.addRect(CGRect(x: right, y: 0, width: w - right, height: line))
    }
}
