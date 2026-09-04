import AppKit

/// 浏览器 pane 的标签条：梯形标签、手工布局。
///
/// 不用 Auto Layout：pane 由 SwiftUI 托管、没有外部宽度约束，pane 内部任何**必需**的宽度约束都会反过来把
/// pane 自身解成标签之和（见 porting-notes）。这里只在 layout() 里按可用宽度算帧，对外零约束。
///
/// 层次：当前标签与下方工具条同色、底边开口（"贴"在工具条上，最上层）；非激活标签退后一层（更暗、更细的字），
/// 悬停浮起并在右侧露出关闭钮；当前标签的关闭钮常显。相邻梯形斜边互相叠进 `overlap`。
/// 宽度：在 [minWidth, maxWidth] 内等分可用宽度；到最小宽度仍放不下时横向滚动（滚轮；选中的标签自动滚入视野）。
final class BrowserTabBarView: NSView {
    struct Item: Equatable {
        var title: String
        var active: Bool
    }

    struct Metrics: Equatable {
        /// 标签最大宽度（config browser-tab-width）
        var maxWidth: CGFloat = 200
        /// 标签最小宽度（config browser-tab-min-width）；空间不够时不再缩窄，改为滚动
        var minWidth: CGFloat = 80
        static let barHeight: CGFloat = 30
        static let tabHeight: CGFloat = 26
        static let slant: CGFloat = 9
        static let overlap: CGFloat = 8
        static let insetX: CGFloat = 8
        static let cornerRadius: CGFloat = 4

        var clampedMin: CGFloat { min(minWidth, maxWidth) }
    }

    var metrics = Metrics() {
        didSet {
            guard metrics != oldValue else { return }
            pendingRevealActive = true
            needsLayout = true
        }
    }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private(set) var itemViews: [BrowserTabItemView] = []
    /// 内容超宽时的横向滚动偏移（≥ 0）
    private(set) var scrollOffset: CGFloat = 0
    private var pendingRevealActive = false
    private var lastLayoutWidth: CGFloat = -1
    private var hoverArea: NSTrackingArea?
    private var background: NSColor = .black
    private var foreground: NSColor = .white

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - 数据

    /// 同步标签列表：复用已有的项视图（悬停状态、tracking area 不重建），只改标题 / 激活态；
    /// 激活项变化时把它滚进视野
    func update(items: [Item]) {
        let previousActive = itemViews.firstIndex { $0.active }
        while itemViews.count > items.count {
            let v = itemViews.removeLast()
            v.removeFromSuperview()
        }
        while itemViews.count < items.count {
            let v = BrowserTabItemView()
            v.applyTheme(background: background, foreground: foreground)
            addSubview(v)
            itemViews.append(v)
        }
        for (i, item) in items.enumerated() {
            let v = itemViews[i]
            v.title = item.title
            v.active = item.active
            v.onSelect = { [weak self] in self?.onSelect?(i) }
            v.onClose = { [weak self] in self?.onClose?(i) }
        }
        let activeNow = items.firstIndex { $0.active }
        if activeNow != previousActive { pendingRevealActive = true }
        needsLayout = true
        needsDisplay = true
    }

    func applyTheme(background: NSColor, foreground: NSColor) {
        self.background = background
        self.foreground = foreground
        for v in itemViews { v.applyTheme(background: background, foreground: foreground) }
        needsDisplay = true
    }

    // MARK: - 布局

    /// 当前布局下每个标签的宽度（等宽）
    var tabWidth: CGFloat {
        let n = CGFloat(itemViews.count)
        guard n > 0 else { return 0 }
        let available = bounds.width - 2 * Metrics.insetX
        let fill = (available + (n - 1) * Metrics.overlap) / n
        return min(metrics.maxWidth, max(metrics.clampedMin, fill))
    }

    /// 全部标签摆开需要的宽度（不含两侧留白）
    var contentWidth: CGFloat {
        let n = CGFloat(itemViews.count)
        guard n > 0 else { return 0 }
        return n * tabWidth - (n - 1) * Metrics.overlap
    }

    var maxScrollOffset: CGFloat { max(0, contentWidth - (bounds.width - 2 * Metrics.insetX)) }
    var isOverflowing: Bool { maxScrollOffset > 0.5 }

    var itemFrames: [CGRect] { itemViews.map(\.frame) }

    override func layout() {
        super.layout()
        let w = tabWidth
        // 变窄（split / 缩放 pane）会让溢出变大，旧偏移仍合法但当前标签可能被裁掉：宽度一变就重新露出它
        if bounds.width != lastLayoutWidth {
            lastLayoutWidth = bounds.width
            pendingRevealActive = true
        }
        if pendingRevealActive {
            pendingRevealActive = false
            revealActive(width: w)
        }
        scrollOffset = min(max(0, scrollOffset), maxScrollOffset)
        // 帧对齐到物理像素：等分宽度多是小数，图层化的标签会把 1pt 描边和 11pt 文字重采样成糊的
        let scale = window?.backingScaleFactor ?? 2
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        for (i, v) in itemViews.enumerated() {
            let left = Metrics.insetX - scrollOffset + CGFloat(i) * (w - Metrics.overlap)
            v.frame = CGRect(x: snap(left), y: 0, width: snap(left + w) - snap(left), height: Metrics.tabHeight)
        }
        restack()
        needsDisplay = true
    }

    /// 叠放次序：非激活标签从左到右、右边的压左边的斜边；当前标签永远最上层
    private func restack() {
        let ordered = itemViews.filter { !$0.active } + itemViews.filter { $0.active }
        let current = subviews.compactMap { $0 as? BrowserTabItemView }
        guard current != ordered else { return }
        for v in ordered { addSubview(v, positioned: .above, relativeTo: nil) }
    }

    private func revealActive(width w: CGFloat) {
        guard let i = itemViews.firstIndex(where: { $0.active }) else { return }
        let start = CGFloat(i) * (w - Metrics.overlap)
        let end = start + w
        let visible = bounds.width - 2 * Metrics.insetX
        if start < scrollOffset {
            scrollOffset = start
        } else if end > scrollOffset + visible {
            scrollOffset = end - visible
        }
    }

    /// 内容超宽时横向滚轮（只有纵向滚轮的鼠标用纵向增量代替）；否则交给上层
    override func scrollWheel(with event: NSEvent) {
        guard isOverflowing else { super.scrollWheel(with: event); return }
        let dx = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        // 触控板的增量是 pt，普通滚轮的是"行"（一格 ≈ 1）：不换算的话一格只滚 1pt
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : max(20, metrics.clampedMin / 2)
        scroll(by: -dx * unit)
    }

    func scroll(by delta: CGFloat) {
        let next = min(max(0, scrollOffset + delta), maxScrollOffset)
        guard next != scrollOffset else { return }
        scrollOffset = next
        needsLayout = true
    }

    // MARK: - 悬停（标签条统一判定）

    /// NSTrackingArea 是纯矩形、不感知兄弟遮挡：相邻梯形叠 8pt，每个标签自带 tracking area 会让
    /// 重叠带里两个标签同时"悬停"、冒出两个关闭钮。改由标签条一个 tracking area + 梯形命中裁决。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(atBarPoint: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateHover(atBarPoint: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { updateHover(atBarPoint: nil) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { updateHover(atBarPoint: nil) }   // 脱离窗口收不到 mouseExited
    }

    /// 命中最上层的梯形标签（z 序自顶向下；斜边外不算）
    func item(atBarPoint point: NSPoint) -> BrowserTabItemView? {
        for case let v as BrowserTabItemView in subviews.reversed() {
            let path = BrowserTabItemView.shape(in: v.bounds)
            path.close()
            if path.contains(v.convert(point, from: self)) { return v }
        }
        return nil
    }

    /// 悬停态：只有命中的那个标签是 hovering（nil = 鼠标不在任何标签上）
    func updateHover(atBarPoint point: NSPoint?) {
        let hit = point.flatMap { item(atBarPoint: $0) }
        for v in itemViews { v.hovering = v === hit }
    }

    // MARK: - 绘制：条底 + 基线（当前标签下方留口）

    override func draw(_ dirtyRect: NSRect) {
        Self.barColor(background: background, foreground: foreground).setFill()
        bounds.fill()
        let line = NSBezierPath()
        line.lineWidth = 1
        let y: CGFloat = 0.5
        var x0 = bounds.minX
        if let active = itemViews.first(where: { $0.active }), active.frame.width > 0 {
            // 基线在当前标签两侧脚下断开（斜边落点各让 0.5pt 与描边接合）
            let f = active.frame
            line.move(to: NSPoint(x: x0, y: y))
            line.line(to: NSPoint(x: max(x0, f.minX + 0.5), y: y))
            x0 = f.maxX - 0.5
        }
        line.move(to: NSPoint(x: x0, y: y))
        line.line(to: NSPoint(x: bounds.maxX, y: y))
        BrowserTabItemView.outlineColor(foreground: foreground).setStroke()
        line.stroke()
    }

    /// 条底色：背景向前景靠 12%（深色主题 = 深灰，浅色主题 = 浅灰），当前标签用纯背景色贴到工具条上
    static func barColor(background: NSColor, foreground: NSColor) -> NSColor {
        background.blended(withFraction: 0.12, of: foreground) ?? background
    }
}

/// 一个梯形标签：标题 + 关闭钮。斜边外的点击穿透给底下的邻居（按路径命中）。
final class BrowserTabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    var title: String = "" {
        didSet {
            guard title != oldValue else { return }
            label.stringValue = title
            toolTip = title
        }
    }
    var active = false {
        didSet {
            guard active != oldValue else { return }
            applyTextStyle()
            needsLayout = true
            needsDisplay = true
        }
    }
    /// 由 BrowserTabBarView.updateHover 设置
    var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            needsLayout = true
            needsDisplay = true
        }
    }
    /// 太窄就不显示关闭钮（否则标题只剩几个像素）；够宽时无论显不显示都给它留位，
    /// 这样悬停出现关闭钮不会把标题重新截断（文字跳动）
    var fitsClose: Bool { bounds.width >= 2 * BrowserTabBarView.Metrics.slant + Self.textInset + Self.closeSize + 20 }
    /// 关闭钮：当前标签常显，非激活标签悬停时出现在右侧
    var showsClose: Bool { fitsClose && (active || hovering) }
    var closeButtonVisible: Bool { !closeButton.isHidden }
    /// 测试用：标题可用宽度
    var titleWidthForTesting: CGFloat { label.frame.width }

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var background: NSColor = .black
    private var foreground: NSColor = .white

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭标签")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        closeButton.toolTip = "关闭标签"
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = true
        addSubview(closeButton)
        applyTextStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme(background: NSColor, foreground: NSColor) {
        self.background = background
        self.foreground = foreground
        applyTextStyle()
        needsDisplay = true
    }

    private func applyTextStyle() {
        label.font = .systemFont(ofSize: 11, weight: active ? .semibold : .regular)
        label.textColor = active ? foreground : foreground.withAlphaComponent(0.62)
        closeButton.contentTintColor = foreground.withAlphaComponent(active ? 0.8 : 0.65)
    }

    // MARK: - 几何

    static let closeSize: CGFloat = 16
    static let textInset: CGFloat = 6

    /// 梯形：底边全宽，两条斜边各收进 slant，顶角圆角
    static func shape(in bounds: NSRect) -> NSBezierPath {
        let s = BrowserTabBarView.Metrics.slant
        let r = BrowserTabBarView.Metrics.cornerRadius
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX, y: bounds.minY))
        path.appendArc(from: NSPoint(x: bounds.minX + s, y: bounds.maxY),
                       to: NSPoint(x: bounds.maxX - s, y: bounds.maxY), radius: r)
        path.appendArc(from: NSPoint(x: bounds.maxX - s, y: bounds.maxY),
                       to: NSPoint(x: bounds.maxX, y: bounds.minY), radius: r)
        path.line(to: NSPoint(x: bounds.maxX, y: bounds.minY))
        return path
    }

    /// 命中只认梯形内部：斜边外的角落穿透给压在下面的邻居
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        let probe = Self.shape(in: bounds)
        probe.close()
        guard probe.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        let s = BrowserTabBarView.Metrics.slant
        closeButton.isHidden = !showsClose
        let closeW = Self.closeSize
        let right = bounds.maxX - s - 4
        let closeX = right - closeW
        closeButton.frame = NSRect(x: closeX, y: (bounds.height - closeW) / 2, width: closeW, height: closeW)
        let textLeft = bounds.minX + s + Self.textInset
        let textRight = fitsClose ? closeX - 4 : right - 2   // 留位不随悬停变化
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: textLeft, y: (bounds.height - h) / 2, width: max(0, textRight - textLeft), height: h)
    }

    // MARK: - 绘制

    static func outlineColor(foreground: NSColor) -> NSColor { foreground.withAlphaComponent(0.22) }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        // 非激活标签的填充从 y=1 起，让标签条的基线从脚下穿过（退后一层）；当前标签盖住基线（贴上工具条）
        let fill = Self.shape(in: NSRect(x: 0, y: active ? 0 : 1, width: bounds.width, height: bounds.height - 0.5))
        fill.close()
        if active {
            background.setFill()
        } else {
            let bar = BrowserTabBarView.barColor(background: background, foreground: foreground)
            (bar.blended(withFraction: hovering ? 0.10 : 0.04, of: foreground) ?? bar).setFill()
        }
        fill.fill()
        // 描边：只描斜边 + 顶边；底边由标签条的基线负责（当前标签处基线断开 = 与工具条连成一体）
        let outline = Self.shape(in: NSRect(x: inset.minX, y: 0, width: inset.width, height: inset.maxY))
        outline.lineWidth = 1
        Self.outlineColor(foreground: foreground).setStroke()
        outline.stroke()
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) { onSelect?() }

    /// 中键点击关闭（浏览器习惯）
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() } else { super.otherMouseDown(with: event) }
    }

    @objc private func closeTapped() { onClose?() }
}
