import AppKit
import SwiftUI

/// 状态条上工作区胶囊的**排版计算**（画在哪由 `StatusBarView` 负责）。
///
/// 单独拎出来做成纯函数，理由与 `PaneTitleBadge` 是同一条：视图里量不出"放不下"。
/// 状态条是三段式的——左边 logo + 胶囊 + 控制面闪烁，中间时钟（ZStack 独立居中，
/// 与两侧宽度无关），右边 cpu / 网络 / 音量 / 电池。胶囊一旦开始显示名字，
/// 左边那一段就会变长；长到顶上时钟时 SwiftUI 不会报错，它会把 `Text` 压扁、截断，
/// 于是整条栏看上去像坏了。所以"放不放得下"必须在画之前算出来，
/// 而且是**整排一起**算：半排名字半排序号读起来就是个 bug。
enum WorkspacePill {
    /// 名字最多 12 个字素簇，截断的 `…` 算在这 12 个里面（与 pane 标题同一条数法，只是上限不同）
    static let maxCharacters = 12

    /// 状态条那支 Monaco 12。Monaco 是系统自带的；真取不到（字体被停用）就退回等宽系统字——
    /// 关键是量的与画的必须是同一支，否则量出来的宽度说明不了任何事，
    /// 所以 `pill` 里的字也直接套这支，而不是各写一遍 `.custom("Monaco", size: 12)`
    static let font: NSFont = NSFont(name: "Monaco", size: 12)
        ?? .monospacedSystemFont(ofSize: 12, weight: .regular)

    /// 数字 / `■` 胶囊的宽度（今天的样子，一个点也不动）
    static let plainWidth: CGFloat = 18
    /// 起了名的胶囊左右各留一点：胶囊间距只有 3pt，不留的话两个名字会糊成一片
    static let titlePadding: CGFloat = 4
    /// 胶囊之间
    static let spacing: CGFloat = 3
    /// logo / 胶囊组 / 控制面闪烁之间（= `leftSection` 那个 HStack 的 spacing）
    static let sectionSpacing: CGFloat = 8
    /// 控制面闪烁自己的左右内边距
    static let flashPadding: CGFloat = 6
    /// 左边这一段与时钟之间至少留出来的空气。它同时兜着测量误差：
    /// 这里量的是 `NSAttributedString` 的宽度，SwiftUI 排版会各自向上取整零点几个点
    static let clearance: CGFloat = 8

    static func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// 截断到 12 个字；没起过名（nil / 空串 / 全空白）→ nil
    static func clamped(_ title: String?) -> String? {
        title.flatMap { PaneTitleBadge.clamp($0, to: maxCharacters) }
    }

    /// 这个槽位上画什么字：起过名（且这一排在显示名字）就是名字，
    /// 否则还是老样子——活动的是 `■`，其余是序号
    static func label(title: String?, index: Int, active: Bool, showingTitles: Bool) -> String {
        if showingTitles, let name = clamped(title) { return name }
        return active ? "■" : "\(index + 1)"
    }

    /// 一个胶囊多宽：名字胶囊按字宽加两边留白，序号胶囊永远是那 18pt。
    ///
    /// **套娃的顺序得跟 `pill` 一模一样**：那边 `padding` 包在 `frame(minWidth:)` 外面，
    /// 于是 18pt 这个下限只兜住文字，两边的留白是加在它外头的。写成 `max(18, 字宽 + 8)`
    /// 就成了另一个形状：一个字母、一个汉字这类窄名字每个胶囊少算最多 8pt，
    /// 而整排统共只有 `clearance` 那 8pt 余量——五个这样的胶囊足够把名字压到时钟上
    static func pillWidth(title: String?, index: Int, active: Bool, showingTitles: Bool) -> CGFloat {
        let text = label(title: title, index: index, active: active, showingTitles: showingTitles)
        guard showingTitles, clamped(title) != nil else { return plainWidth }
        return max(plainWidth, width(of: text)) + 2 * titlePadding
    }

    /// 胶囊上那块字**本身**（颜色与点击交给 `StatusBarView`）。
    ///
    /// 排版这一层只写在这里：宽度是在这个文件里算的，多一处等价的修饰符链
    /// 就是多一次"量的与画的对不上"的机会——`pillWidth` 与它一一对应，
    /// 用例把两者真排一遍比对（`testPillWidthMatchesTheLaidOutPill`）
    static func pill(title: String?, index: Int, active: Bool, showingTitles: Bool) -> some View {
        let named = showingTitles && clamped(title) != nil
        return Text(label(title: title, index: index, active: active, showingTitles: showingTitles))
            // 名字里混进换行（粘贴、或手改存档）的话，`Text` 会老老实实排成两行：
            // 状态条高 26pt 是写死的，第二行直接把字顶到背景外面去
            .lineLimit(1)
            // 量宽度用的就是 `font` 这支。写 `.custom("Monaco", size: 12)` 的话，
            // Monaco 被停用时两边的退路不是同一支字，量出来的宽度就说明不了任何事
            .font(Font(font))
            .frame(minWidth: plainWidth, minHeight: 20)
            .padding(.horizontal, named ? titlePadding : 0)
    }

    /// 左边一整段（logo + 胶囊 + 控制面闪烁）要多宽
    static func leftSectionWidth(titles: [String?], activeIndex: Int, showingTitles: Bool,
                                 flash: String?) -> CGFloat {
        var out = width(of: "◆")
        for index in titles.indices {
            out += (index == 0 ? sectionSpacing : spacing)
                + pillWidth(title: titles[index], index: index,
                            active: index == activeIndex, showingTitles: showingTitles)
        }
        if let flash { out += sectionSpacing + width(of: flash) + 2 * flashPadding }
        return out
    }

    /// 这一排胶囊**能不能**显示名字（全有或全无）。
    ///
    /// 判据：左边那一段不许伸进时钟。时钟在内容区正中间，它的左沿就是
    /// `内容宽 / 2 − 时钟宽 / 2`——这是个能算出来的数，不是估的。
    /// 右边那组统计量在时钟的另一侧，左边这一段够不到它们：真能够到，说明右段自己就比
    /// 半条栏还宽，那是今天不带名字也一样会挤的另一回事。
    /// 内容宽还没量出来（第一帧 `GeometryReader` 给 0）时按"放不下"算：
    /// 宁可名字晚一帧出来，也不要先画坏一帧
    static func showsTitles(contentWidth: CGFloat, titles: [String?], activeIndex: Int,
                            clockWidth: CGFloat, flash: String?) -> Bool {
        guard contentWidth > 0, titles.contains(where: { clamped($0) != nil }) else { return false }
        let left = leftSectionWidth(titles: titles, activeIndex: activeIndex,
                                    showingTitles: true, flash: flash)
        return left <= contentWidth / 2 - clockWidth / 2 - clearance
    }
}
