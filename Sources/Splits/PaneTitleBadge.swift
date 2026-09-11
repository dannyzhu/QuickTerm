import AppKit

/// pane 顶边框上那块标题的**排版计算**（画在哪由 `PaneChrome` 负责）。
///
/// 单独拎出来做成纯函数，是因为几条规则是缠在一起的：20 字上限、不许越过右上角、
/// 右边还得给边框留下至少两个字符的线、还得真压在那条 2px 线上。视图里量不出"放不下"——
/// `Text` 自己会截断、会换行、会把 `…` 贴到最后一格，于是"边框断口"与"真正画出来的字"就对不上了；
/// 只有先把要画的那一串连同它的落位一起算死，断口才画得准，也才测得动。
enum PaneTitleBadge {
    /// 最多 20 个字。按**字素簇**算：一个汉字、一个 emoji（哪怕是 ZWJ 拼出来的）都是 1。
    /// 截断时那个省略号**算在这 20 个里**——所以 30 字的标题画出来是 19 字 + `…`
    static let maxCharacters = 20
    static let ellipsis = "…"

    /// 边框线宽（四条边同宽，标题纵向就压在这条线的中心上）
    static let lineWidth: CGFloat = 2

    struct Metrics: Equatable {
        let font: NSFont
        /// 文字左端距 pane 左边框外沿
        let leadingInset: CGFloat
        /// 断口比文字每侧宽出来的一点，免得字头字尾贴着线茬
        let sidePadding: CGFloat
        /// 右侧必须保住的边框长度，单位是"字符"
        let reservedCharacters: Int

        /// 「一个字符宽」的口径：比例字体里根本没有统一字宽，这里取数字 `0` 的步进宽度。
        /// 选它是因为 UI 字体的数字是等宽的（表格要对齐），而且比多数小写字母宽——
        /// 拿它当"一个字符"既确定，又偏保守（留出来的线只会比两个真字符长）
        var characterWidth: CGFloat { width(of: "0") }

        /// 徽标一行的高度（纵向居中要它）
        var lineHeight: CGFloat {
            ("0" as NSString).size(withAttributes: [.font: font]).height
        }

        /// 单行 `Text` 盒顶到基线的距离：盒高就是 `lineHeight`，基线落在
        /// 半行距 + 上伸部处（半行距 = (行高 − 字面高)/2）
        var baselineInset: CGFloat {
            (lineHeight - (font.ascender - font.descender)) / 2 + font.ascender
        }

        /// 盒顶到大写字母顶的距离。判断"这条线到底有没有从字身上穿过去"必须用它，
        /// 不能拿盒顶当墨迹顶：盒子上面那 3pt 多是空的（半行距 + 上伸部里没字的那截），
        /// 按盒顶算会把默认 `pane-gap = 5` 也判成"放不下"，整个功能就没了
        var capTopInset: CGFloat { baselineInset - font.capHeight }

        func width(of text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }

        /// 与状态条同门的小号 UI 字重；10pt 压在 2px 线上正好不喧宾夺主
        static let standard = Metrics(font: .systemFont(ofSize: 10, weight: .medium),
                                      leadingInset: 8, sidePadding: 4, reservedCharacters: 2)
    }

    /// 这一帧顶边框上的标题：画什么字、画在哪、边框从哪咬到哪。
    /// nil（`place` 不返回它）的意思是**整条边框照常连着画**
    struct Placement: Equatable {
        /// 截断之后真正要画的那一串
        let text: String
        /// `Text` 盒左上角相对 pane 左上角（边框外沿）的纵向偏移，向下为正
        let offsetY: CGFloat
        /// 上边框断口（相对 pane 左边框外沿）
        let gapStart: CGFloat
        let gapEnd: CGFloat
    }

    /// 顶边框上留给文字的最大宽度。
    /// 断口右沿 = 左内缩 + 文字宽 + 一点留白，它到右上角之间就是那段"保命的线"，
    /// 必须 ≥ 两个字符宽——于是文字能占的就只剩这么多
    static func availableTextWidth(topEdgeWidth: CGFloat, metrics: Metrics = .standard) -> CGFloat {
        topEdgeWidth - metrics.leadingInset - metrics.sidePadding
            - CGFloat(metrics.reservedCharacters) * metrics.characterWidth
    }

    /// 纯函数：这一帧顶边框上该画的字符串；一个字都放不下（或本来就没标题）时 nil。
    /// nil 的意思是**整条边框照常连着画**，而不是画个空口子或者孤零零一个省略号
    static func fit(title: String, topEdgeWidth: CGFloat, metrics: Metrics = .standard) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let available = availableTextWidth(topEdgeWidth: topEdgeWidth, metrics: metrics)
        guard available > 0 else { return nil }

        let chars = Array(trimmed)   // Character = 字素簇，CJK / emoji 各算一个
        if chars.count <= maxCharacters, metrics.width(of: trimmed) <= available { return trimmed }

        // 逐格往回缩。`content` 是省略号**之外**的字数，画出来一共 content + 1 个字，
        // 所以起点 19 正好压在 20 的上限上。缩到只剩省略号就收手——
        // 一个 `…` 占着边框却什么也没说，还不如把线画全
        for content in stride(from: min(chars.count - 1, maxCharacters - 1), through: 1, by: -1) {
            let candidate = String(chars.prefix(content)) + ellipsis
            if metrics.width(of: candidate) <= available { return candidate }
        }
        return nil
    }

    /// 纵向落位：`Text` 盒相对上边框外沿的偏移；**上方腾不出地方时 nil = 这一帧不画标题**。
    ///
    /// 陷阱：pane 槽位是按槽位裁的，边框以外能借的只有自己那一圈 pane-gap（`overhang`）。
    /// gaps 关掉（Cmd+Shift+Backspace / `app set --gaps off`）或 `pane-gap = 0` 时一点也借不到，
    /// 字就会整个掉到线下面压在终端第一行上，边框却还被咬开一个空口子——
    /// 那正是"文字不得越出顶部线框"要禁的样子。所以借不到就干脆不画，
    /// 判据是**线心得落在字身（大写高）里**：线从字上穿过去才叫"压在线上"
    static func verticalOffset(overhang: CGFloat, metrics: Metrics = .standard) -> CGFloat? {
        let centred = lineWidth / 2 - metrics.lineHeight / 2   // 盒心压线心 = 正经居中
        let offset = max(-overhang, centred)                   // 借不到那么多就往下让一让
        guard offset + metrics.capTopInset <= lineWidth / 2 else { return nil }
        return offset
    }

    /// 顶边框被咬开的那一段（相对 pane 左边框外沿）。传进来的必须是 `fit` 吐出来的串
    static func gapRange(for text: String,
                         metrics: Metrics = .standard) -> (start: CGFloat, end: CGFloat) {
        (max(0, metrics.leadingInset - metrics.sidePadding),
         metrics.leadingInset + metrics.width(of: text) + metrics.sidePadding)
    }

    /// 唯一的对外入口：字、落位、断口一次算完。
    /// 断口与文字必须出自同一个判断——分两处各判各的，就会出现"边框咬开了、字却没画/掉下去了"
    static func place(title: String?, topEdgeWidth: CGFloat, overhang: CGFloat,
                      metrics: Metrics = .standard) -> Placement? {
        guard let title,
              let offsetY = verticalOffset(overhang: overhang, metrics: metrics),
              let text = fit(title: title, topEdgeWidth: topEdgeWidth, metrics: metrics)
        else { return nil }
        let gap = gapRange(for: text, metrics: metrics)
        return Placement(text: text, offsetY: offsetY, gapStart: gap.start, gapEnd: gap.end)
    }
}
