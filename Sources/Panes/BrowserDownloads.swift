import AppKit
import UniformTypeIdentifiers
import WebKit

/// 浏览器 pane 的下载：一条下载 = 一个 `BrowserDownloadItem`，pane 持一个 `BrowserDownloadList`，
/// 地址栏右侧的 `BrowserDownloadButton` 画聚合进度环，点开是 `BrowserDownloadPopover` 的列表
/// （取消 / 在 Finder 中显示 / 移除 / 清除已完成）。
///
/// 进度来自 `WKDownload.progress`（WKDownload 遵守 `NSProgressReporting`）：KVO 观察
/// `fractionCompleted`，节流到 ≤ 10 Hz 再回调 `onChange`，免得大文件下载时每收一个包就重画一次界面。

/// 一条下载。测试里可以不带 WKDownload（给个假 Progress + 假取消闭包）。
@MainActor
final class BrowserDownloadItem: NSObject {
    enum State: Equatable {
        case downloading
        case completed
        case failed(String)
        case cancelled
    }

    let id = UUID()
    /// 关联的 WKDownload（假条目为 nil）。强引用：WebKit 只保证下载进行中活着，
    /// 完成后我们还要靠它做重试 / 取消的兜底
    let download: WKDownload?
    /// 文件名：落盘路径定下来前先用请求 URL 猜一个
    private(set) var filename: String
    /// 落盘路径。`decideDestinationUsing` 之前是 nil——连接就失败的下载（例如连接被拒）
    /// 根本走不到那一步，但它同样要在列表里显示成"失败"
    private(set) var destination: URL?
    let progress: Progress
    var state: State = .downloading
    private let cancelHandler: () -> Void

    /// 真实下载：进度直接用 WKDownload 自己的 Progress
    init(download: WKDownload, filename: String) {
        self.download = download
        self.filename = filename
        self.progress = download.progress
        self.cancelHandler = { download.cancel() }
        super.init()
    }

    /// 测试 / 假条目
    init(filename: String, progress: Progress, destination: URL? = nil,
         cancel: @escaping () -> Void = {}) {
        self.download = nil
        self.filename = filename
        self.progress = progress
        self.destination = destination
        self.cancelHandler = cancel
        super.init()
    }

    var isActive: Bool { state == .downloading }

    /// 已完成 / 失败 / 取消 —— 可以从列表里清掉的
    var isFinished: Bool { !isActive }

    func setDestination(_ url: URL) {
        destination = url
        filename = url.lastPathComponent
    }

    func requestCancel() { cancelHandler() }

    // MARK: - 显示

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()

    static func formatBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: max(bytes, 0))
    }

    /// 一行状态文字：「1.2 MB / 5 MB · 45%」/「已完成 · 5 MB」/「已取消」/「失败：…」
    var statusText: String {
        switch state {
        case .downloading:
            let done = Self.formatBytes(progress.completedUnitCount)
            if progress.totalUnitCount > 0 {
                let total = Self.formatBytes(progress.totalUnitCount)
                let percent = Int((progress.fractionCompleted * 100).rounded())
                return "\(done) / \(total) · \(percent)%"
            }
            return "\(done) · 下载中"
        case .completed:
            let size = progress.totalUnitCount > 0 ? progress.totalUnitCount : progress.completedUnitCount
            return "已完成 · \(Self.formatBytes(size))"
        case .cancelled:
            return "已取消"
        case .failed(let message):
            return "失败：\(message)"
        }
    }

    /// 行图标：按扩展名取系统图标
    var icon: NSImage {
        let ext = (filename as NSString).pathExtension
        let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        return NSWorkspace.shared.icon(for: type ?? .data)
    }
}

/// 一个 pane 的下载列表：增删、状态流转、聚合进度，以及节流后的 `onChange`
@MainActor
final class BrowserDownloadList: NSObject {
    /// 进度回调的最小间隔（≤ 10 Hz）
    static let notifyInterval: TimeInterval = 0.1

    private(set) var items: [BrowserDownloadItem] = []
    /// 界面刷新回调（增删与状态变化立即触发；进度变化节流）
    var onChange: (() -> Void)?

    private var observations: [UUID: NSKeyValueObservation] = [:]
    private var lastNotified = Date.distantPast
    private var notifyScheduled = false

    // MARK: - 增删

    func add(_ item: BrowserDownloadItem) {
        items.append(item)
        // Progress 的 fractionCompleted 是 KVO 可观察的；回调可能在任意线程，统一甩回主线程
        observations[item.id] = item.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.progressDidChange() }
            }
        }
        notifyNow()
    }

    func remove(_ item: BrowserDownloadItem) {
        observations[item.id] = nil
        items.removeAll { $0 === item }
        notifyNow()
    }

    /// 已完成 / 失败 / 取消的行全部清掉（进行中的留着）
    func clearFinished() {
        for item in items where item.isFinished { observations[item.id] = nil }
        items.removeAll { $0.isFinished }
        notifyNow()
    }

    /// 取消：调下载自己的 cancel，状态立刻置为已取消（WebKit 之后还会回调一次 didFail，幂等）
    func cancel(_ item: BrowserDownloadItem) {
        guard item.isActive else { return }
        item.requestCancel()
        item.state = .cancelled
        notifyNow()
    }

    // MARK: - 状态流转

    func markCompleted(_ item: BrowserDownloadItem) {
        guard item.isActive else { return }
        item.state = .completed
        notifyNow()
    }

    func markFailed(_ item: BrowserDownloadItem, message: String) {
        guard item.isActive else { return }
        item.state = .failed(message)
        notifyNow()
    }

    func markCancelled(_ item: BrowserDownloadItem) {
        guard item.isActive else { return }
        item.state = .cancelled
        notifyNow()
    }

    func item(for download: WKDownload) -> BrowserDownloadItem? {
        items.first { $0.download === download }
    }

    // MARK: - 聚合

    var activeCount: Int { items.reduce(0) { $0 + ($1.isActive ? 1 : 0) } }

    /// 所有进行中下载的合计进度；没有进行中的、或任一条不知道总大小 → nil（不确定）
    var aggregateFraction: Double? {
        let active = items.filter(\.isActive)
        guard !active.isEmpty else { return nil }
        var total: Int64 = 0, done: Int64 = 0
        for item in active {
            guard item.progress.totalUnitCount > 0 else { return nil }
            total += item.progress.totalUnitCount
            done += item.progress.completedUnitCount
        }
        guard total > 0 else { return nil }
        return min(max(Double(done) / Double(total), 0), 1)
    }

    // MARK: - 节流

    private func progressDidChange() {
        guard !notifyScheduled else { return }
        let elapsed = Date().timeIntervalSince(lastNotified)
        if elapsed >= Self.notifyInterval {
            notifyNow()
            return
        }
        notifyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.notifyInterval - elapsed)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.notifyScheduled = false
                self.notifyNow()
            }
        }
    }

    private func notifyNow() {
        lastNotified = Date()
        onChange?()
    }
}

/// 地址栏右侧的下载按钮：自绘圆环进度 + 中心符号（进行中 = 向下箭头，全部完成 = 勾，
/// 有失败 / 取消 = 感叹号）。22×22，列表为空时隐藏（宽度与右侧间距由 BrowserPaneView 一起收成 0）。
@MainActor
final class BrowserDownloadButton: NSButton {
    static let size: CGFloat = 22

    /// 中心符号：进行中 = 向下箭头；全部完成 = 勾；只剩失败 / 取消 = 感叹号
    enum Glyph: Equatable { case arrow, check, warning }

    weak var list: BrowserDownloadList?
    var tint: NSColor = .white { didSet { needsDisplay = true } }

    /// NSButton 默认 `isFlipped == true`（y 向下）；本类完全自绘（不调 super.draw），
    /// draw(_:) 里的圆弧 / 箭头 / 勾都按 y 向上的几何写，这里统一回非翻转坐标系。
    /// 去掉这行会得到：向上的箭头、倒过来的勾、从 6 点开始逆时针的进度环。
    override var isFlipped: Bool { false }

    /// 当前该画哪个中心符号（画法与提示文字共用，测试也直接断言它）
    var glyph: Glyph {
        let items = list?.items ?? []
        if (list?.activeCount ?? 0) > 0 || items.isEmpty { return .arrow }
        return items.allSatisfy { $0.state == .completed } ? .check : .warning
    }

    /// 不确定进度时转动的那段弧
    private var spinnerAngle: CGFloat = 0
    private var spinner: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .accessoryBarAction
        title = ""
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        toolTip = "下载"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { spinner?.invalidate() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }

    /// 按列表现状刷新可见性 / 提示 / 重绘（列表的 onChange 里调）
    func update() {
        let items = list?.items ?? []
        isHidden = items.isEmpty
        let active = list?.activeCount ?? 0
        let stopped = items.filter { $0.state != .completed && !$0.isActive }.count
        if active > 0 {
            toolTip = "下载（\(active) 个进行中）"
        } else if stopped > 0 {
            toolTip = "下载（\(items.count) 项，\(stopped) 项失败或已取消）"
        } else {
            toolTip = "下载（\(items.count) 项）"
        }
        // 只有"不知道总大小的进行中下载"才需要转圈
        let indeterminate = active > 0 && list?.aggregateFraction == nil
        if indeterminate && !isHidden {
            if spinner == nil {
                spinner = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] timer in
                    MainActor.assumeIsolated {
                        // 按钮先没了的话把定时器也停掉（runloop 会一直持有它）
                        guard let self else { return timer.invalidate() }
                        self.spinnerAngle -= 30
                        self.needsDisplay = true
                    }
                }
            }
        } else {
            spinner?.invalidate()
            spinner = nil
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 3.5, dy: 3.5)
        let center = NSPoint(x: box.midX, y: box.midY)
        let radius = min(box.width, box.height) / 2
        let active = list?.activeCount ?? 0
        let fraction = list?.aggregateFraction

        // 轨道
        tint.withAlphaComponent(0.25).setStroke()
        let track = NSBezierPath(ovalIn: box)
        track.lineWidth = 1.5
        track.stroke()

        // 进度弧：12 点方向顺时针
        tint.setStroke()
        if active > 0 {
            let arc = NSBezierPath()
            if let fraction {
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(fraction), clockwise: true)
            } else {
                arc.appendArc(withCenter: center, radius: radius, startAngle: spinnerAngle,
                              endAngle: spinnerAngle - 90, clockwise: true)
            }
            arc.lineWidth = 1.5
            arc.lineCapStyle = .round
            arc.stroke()
        } else if !(list?.items.isEmpty ?? true) {
            // 全部结束（完成 / 失败 / 取消都算）：整圈实线，中心符号区分成败
            let full = NSBezierPath(ovalIn: box)
            full.lineWidth = 1.5
            full.stroke()
        }

        // 中心符号（y 向上，见 isFlipped）：进行中 = 向下箭头，全部完成 = 勾，
        // 有失败 / 取消 = 感叹号（画勾会把"下载失败了"说成"成功了"）
        let path = NSBezierPath()
        switch glyph {
        case .arrow:
            let h: CGFloat = 4.5, w: CGFloat = 3
            path.move(to: NSPoint(x: center.x, y: center.y + h))
            path.line(to: NSPoint(x: center.x, y: center.y - h))
            path.move(to: NSPoint(x: center.x - w, y: center.y - h + w))
            path.line(to: NSPoint(x: center.x, y: center.y - h))
            path.line(to: NSPoint(x: center.x + w, y: center.y - h + w))
        case .check:
            path.move(to: NSPoint(x: center.x - 3.5, y: center.y + 0.5))
            path.line(to: NSPoint(x: center.x - 1, y: center.y - 2.5))
            path.line(to: NSPoint(x: center.x + 3.5, y: center.y + 3))
        case .warning:
            path.move(to: NSPoint(x: center.x, y: center.y + 4))
            path.line(to: NSPoint(x: center.x, y: center.y - 0.5))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
        if glyph == .warning {
            tint.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 1, y: center.y - 4.5, width: 2, height: 2)).fill()
        }
    }
}

/// 下载列表弹出层：每条一行（图标 + 文件名 + 状态 + 细进度条 + 取消 / 在 Finder 中显示 / 移除），
/// 底部「清除已完成」。行视图复用，列表变动时只改内容不重建，避免闪烁。
///
/// **NSPopover 由 pane 持有，本控制器不反向持有它**：`NSPopover.contentViewController` 是强引用，
/// 控制器再存一个 NSPopover 就成了两个对象互锁的环——pane 关掉后列表、条目、WKDownload 全都释放不掉。
@MainActor
final class BrowserDownloadPopover: NSViewController {
    static let width: CGFloat = 320

    private let list: BrowserDownloadList
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "没有下载")
    private let clearButton = NSButton()
    private var rows: [BrowserDownloadRow] = []

    init(list: BrowserDownloadList) {
        self.list = list
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 80))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .secondaryLabelColor
        clearButton.title = "清除已完成"
        clearButton.bezelStyle = .inline
        clearButton.controlSize = .small
        clearButton.font = .systemFont(ofSize: 11)
        clearButton.target = self
        clearButton.action = #selector(clearFinished)
        view = root
        rebuild()
    }

    /// 按列表重建行（复用已有行视图）
    func rebuild() {
        guard isViewLoaded else { return }
        let items = list.items
        while rows.count > items.count {
            let row = rows.removeLast()
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        while rows.count < items.count {
            let row = BrowserDownloadRow()
            row.onCancel = { [weak self] item in self?.list.cancel(item); self?.rebuild() }
            row.onRemove = { [weak self] item in self?.list.remove(item); self?.rebuild() }
            rows.append(row)
            stack.insertArrangedSubview(row, at: rows.count - 1)
            row.widthAnchor.constraint(equalToConstant: Self.width - 20).isActive = true
        }
        for (row, item) in zip(rows, items) { row.configure(item) }
        // 空态与「清除已完成」的位置永远在行的后面
        for extra in [emptyLabel, clearButton] where extra.superview != nil {
            stack.removeArrangedSubview(extra)
            extra.removeFromSuperview()
        }
        if items.isEmpty {
            stack.addArrangedSubview(emptyLabel)
        } else if items.contains(where: \.isFinished) {
            stack.addArrangedSubview(clearButton)
        }
        stack.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.width, height: max(stack.fittingSize.height, 40))
    }

    @objc private func clearFinished() {
        list.clearFinished()
        rebuild()
    }

    /// 测试用
    var rowsForTesting: [NSView] { rows }
    var clearButtonForTesting: NSButton { clearButton }
}

/// 弹出层里的一行
@MainActor
final class BrowserDownloadRow: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let primaryButton = NSButton()
    private let removeButton = NSButton()
    private weak var item: BrowserDownloadItem?

    var onCancel: ((BrowserDownloadItem) -> Void)?
    var onRemove: ((BrowserDownloadItem) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.cell?.truncatesLastVisibleLine = true
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        for (button, symbol, tip, action) in [
            (primaryButton, "xmark.circle", "取消", #selector(primaryTapped)),
            (removeButton, "xmark", "从列表移除", #selector(removeTapped)),
        ] {
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.toolTip = tip
            button.target = self
            button.action = action
        }
        for v in [iconView, nameLabel, statusLabel, bar, primaryButton, removeButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 18),
            primaryButton.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -2),
            primaryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            primaryButton.widthAnchor.constraint(equalToConstant: 18),
            nameLabel.topAnchor.constraint(equalTo: topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -6),
            bar.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            bar.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 4),
            statusLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 3),
            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ item: BrowserDownloadItem) {
        self.item = item
        iconView.image = item.icon
        nameLabel.stringValue = item.filename
        nameLabel.toolTip = item.destination?.path ?? item.filename
        statusLabel.stringValue = item.statusText
        bar.isHidden = !item.isActive
        bar.doubleValue = item.progress.totalUnitCount > 0 ? item.progress.fractionCompleted : 0
        bar.isIndeterminate = item.isActive && item.progress.totalUnitCount <= 0
        if bar.isIndeterminate { bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
        removeButton.isHidden = item.isActive
        if item.isActive {
            primaryButton.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "取消")
            primaryButton.toolTip = "取消"
            primaryButton.isHidden = false
        } else if item.state == .completed, item.destination != nil {
            primaryButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "在 Finder 中显示")
            primaryButton.toolTip = "在 Finder 中显示"
            primaryButton.isHidden = false
        } else {
            primaryButton.isHidden = true
        }
    }

    @objc private func primaryTapped() {
        guard let item else { return }
        if item.isActive {
            onCancel?(item)
        } else if let destination = item.destination {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    @objc private func removeTapped() {
        guard let item else { return }
        onRemove?(item)
    }

    /// 测试用
    var nameForTesting: String { nameLabel.stringValue }
    var statusForTesting: String { statusLabel.stringValue }
    var primaryButtonForTesting: NSButton { primaryButton }
}
