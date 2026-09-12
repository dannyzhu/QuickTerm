import AppKit

/// Tab bar for a browser pane: trapezoid tabs, laid out by hand.
///
/// No Auto Layout. The pane is hosted by SwiftUI and has no external width constraint, so any
/// **required** width constraint inside the pane feeds back and solves the pane's own width as the
/// sum of its tabs (see porting-notes). This view computes frames from the available width inside
/// layout() and exposes zero constraints.
///
/// Layering: the current tab shares the color of the toolbar below it and leaves its bottom edge open
/// (it "sits on" the toolbar, topmost); inactive tabs sit one layer back (dimmer, lighter type), rise
/// on hover and reveal a close button on the right; the current tab's close button is always shown.
/// Neighbouring trapezoids overlap each other's slanted edges by `overlap`.
/// Width: the available width is split evenly, clamped to [minWidth, maxWidth]; once even the minimum
/// no longer fits, the bar scrolls horizontally (scroll wheel; the selected tab scrolls itself into
/// view). A permanent "+" new-tab button lives on the right: it follows the last tab, and pins to the
/// right end once the tabs fill the bar (its slot is already subtracted from the tabs' available
/// width, so scrolling never slides a tab underneath it).
final class BrowserTabBarView: NSView {
    struct Item: Equatable {
        var title: String
        var active: Bool
    }

    struct Metrics: Equatable {
        /// Maximum tab width (config browser-tab-width).
        var maxWidth: CGFloat = 200
        /// Minimum tab width (config browser-tab-min-width); once space runs out the tabs stop
        /// shrinking and the bar scrolls instead.
        var minWidth: CGFloat = 80
        static let barHeight: CGFloat = 30
        static let tabHeight: CGFloat = 26
        static let slant: CGFloat = 9
        static let overlap: CGFloat = 8
        static let insetX: CGFloat = 8
        static let cornerRadius: CGFloat = 4
        /// Side length of the "+" button on the right, and the gap between it and the tabs.
        static let newTabSize: CGFloat = 22
        static let newTabGap: CGFloat = 4
        /// Width the tab area has to leave free on the right for the "+" button.
        static let newTabReserve: CGFloat = newTabSize + newTabGap

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
    var onNewTab: (() -> Void)?

    private(set) var itemViews: [BrowserTabItemView] = []
    /// Horizontal scroll offset used when the content is wider than the bar (>= 0).
    private(set) var scrollOffset: CGFloat = 0
    private var pendingRevealActive = false
    private var lastLayoutWidth: CGFloat = -1
    private var hoverArea: NSTrackingArea?
    private var background: NSColor = .black
    private var foreground: NSColor = .white
    private let newTabButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        clipsToBounds = true
        newTabButton.bezelStyle = .accessoryBarAction
        newTabButton.isBordered = false
        newTabButton.imagePosition = .imageOnly
        newTabButton.image = NSImage(systemSymbolName: "plus",
                                     accessibilityDescription: L("browser.tab.new"))?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        newTabButton.toolTip = L("browser.tab.new-tooltip")
        newTabButton.target = self
        newTabButton.action = #selector(newTabTapped)
        addSubview(newTabButton)
    }

    @objc private func newTabTapped() { onNewTab?() }

    /// The "+" button, exposed for tests.
    var newTabButtonForTesting: NSButton { newTabButton }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Data

    /// Sync the tab list: existing item views are reused (hover state and tracking areas are not
    /// rebuilt), only the title and the active flag change; when the active item moves, scroll it
    /// into view.
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
        newTabButton.contentTintColor = foreground.withAlphaComponent(0.7)
        needsDisplay = true
    }

    // MARK: - Layout

    /// Width of each tab in the current layout (all tabs are equally wide).
    var tabWidth: CGFloat {
        let n = CGFloat(itemViews.count)
        guard n > 0 else { return 0 }
        let fill = (visibleWidth + (n - 1) * Metrics.overlap) / n
        return min(metrics.maxWidth, max(metrics.clampedMin, fill))
    }

    /// Width needed to lay out every tab (not counting the insets on either side).
    var contentWidth: CGFloat {
        let n = CGFloat(itemViews.count)
        guard n > 0 else { return 0 }
        return n * tabWidth - (n - 1) * Metrics.overlap
    }

    /// Horizontal space available to the tabs (everything but the insets and the "+" on the right).
    var visibleWidth: CGFloat { max(0, bounds.width - 2 * Metrics.insetX - Metrics.newTabReserve) }

    var maxScrollOffset: CGFloat { max(0, contentWidth - visibleWidth) }
    var isOverflowing: Bool { maxScrollOffset > 0.5 }

    var itemFrames: [CGRect] { itemViews.map(\.frame) }

    override func layout() {
        super.layout()
        let w = tabWidth
        // Getting narrower (splitting or resizing the pane) grows the overflow: the old offset is
        // still legal, but the current tab may now be clipped, so re-reveal it on every width change.
        if bounds.width != lastLayoutWidth {
            lastLayoutWidth = bounds.width
            pendingRevealActive = true
        }
        if pendingRevealActive {
            pendingRevealActive = false
            revealActive(width: w)
        }
        scrollOffset = min(max(0, scrollOffset), maxScrollOffset)
        // Snap frames to physical pixels: an evenly split width is usually fractional, and a layer-
        // backed tab resamples the 1pt stroke and the 11pt text into a blur at fractional positions.
        let scale = window?.backingScaleFactor ?? 2
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        for (i, v) in itemViews.enumerated() {
            let left = Metrics.insetX - scrollOffset + CGFloat(i) * (w - Metrics.overlap)
            v.frame = CGRect(x: snap(left), y: 0, width: snap(left + w) - snap(left), height: Metrics.tabHeight)
        }
        // The "+" follows the slanted edge of the last tab; once the tabs fill the available width it
        // pins to the right end.
        let size = Metrics.newTabSize
        let pinned = bounds.maxX - Metrics.insetX - size
        let afterLast = itemViews.isEmpty
            ? Metrics.insetX
            : Metrics.insetX - scrollOffset + contentWidth - Metrics.slant + Metrics.newTabGap
        newTabButton.frame = NSRect(x: snap(min(afterLast, pinned)), y: (Metrics.tabHeight - size) / 2,
                                    width: size, height: size)
        restack()
        needsDisplay = true
    }

    /// Stacking order: inactive tabs left to right, each one lapping over its left neighbour's
    /// slanted edge; the current tab is always topmost.
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
        let visible = visibleWidth
        if start < scrollOffset {
            scrollOffset = start
        } else if end > scrollOffset + visible {
            scrollOffset = end - visible
        }
    }

    /// Scroll horizontally when the content overflows (a mouse with only a vertical wheel has its
    /// vertical delta used instead); otherwise pass the event up.
    override func scrollWheel(with event: NSEvent) {
        guard isOverflowing else { super.scrollWheel(with: event); return }
        let dx = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        // A trackpad's delta is in points, a plain wheel's is in lines (one notch is about 1): without
        // the conversion, one notch would scroll a single point.
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : max(20, metrics.clampedMin / 2)
        scroll(by: -dx * unit)
    }

    func scroll(by delta: CGFloat) {
        let next = min(max(0, scrollOffset + delta), maxScrollOffset)
        guard next != scrollOffset else { return }
        scrollOffset = next
        needsLayout = true
    }

    // MARK: - Hover (decided centrally by the bar)

    /// NSTrackingArea is a plain rectangle and knows nothing about sibling occlusion: neighbouring
    /// trapezoids overlap by 8pt, so a per-tab tracking area leaves both tabs "hovered" inside the
    /// overlap band and pops up two close buttons. Instead the bar owns one tracking area and settles
    /// hover with a trapezoid hit test.
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
        if newWindow == nil { updateHover(atBarPoint: nil) }   // no mouseExited arrives once detached
    }

    /// Hit the topmost trapezoid tab (walking z-order from the top; outside the slanted edge does not
    /// count).
    func item(atBarPoint point: NSPoint) -> BrowserTabItemView? {
        for case let v as BrowserTabItemView in subviews.reversed() {
            let path = BrowserTabItemView.shape(in: v.bounds)
            path.close()
            if path.contains(v.convert(point, from: self)) { return v }
        }
        return nil
    }

    /// Hover state: only the tab that was hit is hovering (nil = the mouse is on no tab at all).
    func updateHover(atBarPoint point: NSPoint?) {
        let hit = point.flatMap { item(atBarPoint: $0) }
        for v in itemViews { v.hovering = v === hit }
    }

    // MARK: - Drawing: bar fill plus the baseline, which opens up under the current tab

    override func draw(_ dirtyRect: NSRect) {
        Self.barColor(background: background, foreground: foreground).setFill()
        bounds.fill()
        let line = NSBezierPath()
        line.lineWidth = 1
        let y: CGFloat = 0.5
        var x0 = bounds.minX
        if let active = itemViews.first(where: { $0.active }), active.frame.width > 0 {
            // The baseline breaks at the feet of the current tab (each slant foot gives up 0.5pt so
            // the line meets the tab's stroke cleanly).
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

    /// Bar fill: the background blended 12% toward the foreground (dark theme = dark grey, light theme
    /// = light grey); the current tab uses the pure background color so it joins the toolbar.
    static func barColor(background: NSColor, foreground: NSColor) -> NSColor {
        background.blended(withFraction: 0.12, of: foreground) ?? background
    }
}

/// One trapezoid tab: a title plus a close button. A click outside the slanted edge falls through to
/// the neighbour underneath (hit testing follows the path, not the frame).
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
    /// Set by BrowserTabBarView.updateHover.
    var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            needsLayout = true
            needsDisplay = true
        }
    }
    /// Too narrow means no close button at all, or the title would be down to a few pixels. Once the
    /// tab is wide enough its slot is reserved whether or not the button is shown, so revealing the
    /// button on hover does not re-truncate the title and make the text jump.
    var fitsClose: Bool { bounds.width >= 2 * BrowserTabBarView.Metrics.slant + Self.textInset + Self.closeSize + 20 }
    /// Close button: always visible on the current tab, appearing on the right of an inactive tab
    /// while it is hovered.
    var showsClose: Bool { fitsClose && (active || hovering) }
    var closeButtonVisible: Bool { !closeButton.isHidden }
    /// Width available to the title, exposed for tests.
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
        closeButton.image = NSImage(systemSymbolName: "xmark",
                                    accessibilityDescription: L("browser.tab.close"))?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        closeButton.toolTip = L("browser.tab.close")
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

    // MARK: - Geometry

    static let closeSize: CGFloat = 16
    static let textInset: CGFloat = 6

    /// The trapezoid: the bottom edge spans the full width, both slanted edges come in by `slant`,
    /// and the top corners are rounded.
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

    /// Only the inside of the trapezoid counts as a hit: the corners outside the slanted edges fall
    /// through to the neighbour stacked below.
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
        let textRight = fitsClose ? closeX - 4 : right - 2   // the reserved slot does not follow hover
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: textLeft, y: (bounds.height - h) / 2, width: max(0, textRight - textLeft), height: h)
    }

    // MARK: - Drawing

    static func outlineColor(foreground: NSColor) -> NSColor { foreground.withAlphaComponent(0.22) }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        // An inactive tab's fill starts at y=1 so the bar's baseline runs under its feet, putting it a
        // layer back; the current tab covers the baseline instead and joins the toolbar.
        let fill = Self.shape(in: NSRect(x: 0, y: active ? 0 : 1, width: bounds.width, height: bounds.height - 0.5))
        fill.close()
        if active {
            background.setFill()
        } else {
            let bar = BrowserTabBarView.barColor(background: background, foreground: foreground)
            (bar.blended(withFraction: hovering ? 0.10 : 0.04, of: foreground) ?? bar).setFill()
        }
        fill.fill()
        // Stroke only the slanted edges and the top; the bottom edge is the bar's baseline, which
        // breaks under the current tab so that tab reads as one piece with the toolbar.
        let outline = Self.shape(in: NSRect(x: inset.minX, y: 0, width: inset.width, height: inset.maxY))
        outline.lineWidth = 1
        Self.outlineColor(foreground: foreground).setStroke()
        outline.stroke()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) { onSelect?() }

    /// Middle-click closes the tab, as browsers do.
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() } else { super.otherMouseDown(with: event) }
    }

    @objc private func closeTapped() { onClose?() }
}
