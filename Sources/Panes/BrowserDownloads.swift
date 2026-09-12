import AppKit
import UniformTypeIdentifiers
import WebKit

/// Downloads for a browser pane: one download = one `BrowserDownloadItem`, the pane owns one
/// `BrowserDownloadList`, the `BrowserDownloadButton` to the right of the address bar draws the
/// aggregate progress ring, and clicking it opens the `BrowserDownloadPopover` list (cancel / reveal
/// in Finder / remove / clear completed).
///
/// Progress comes from `WKDownload.progress` (WKDownload conforms to `NSProgressReporting`): KVO on
/// `fractionCompleted`, throttled to <= 10 Hz before `onChange` fires, so a large download does not
/// repaint the UI once per received packet.

/// One download. Tests can build one without a WKDownload by passing a fake Progress and a fake
/// cancel closure.
@MainActor
final class BrowserDownloadItem: NSObject {
    enum State: Equatable {
        case downloading
        case completed
        case failed(String)
        case cancelled
    }

    let id = UUID()
    /// The associated WKDownload (nil for a fake item). Held strongly: WebKit only guarantees it stays
    /// alive while the download is in flight, and we still need it afterwards as the fallback for
    /// retry and cancel.
    let download: WKDownload?
    /// File name: guessed from the request URL until the destination path is settled.
    private(set) var filename: String
    /// Destination path. nil until `decideDestinationUsing`: a download that fails at connect time
    /// (connection refused, say) never gets that far, yet it still has to show up in the list as
    /// "failed".
    private(set) var destination: URL?
    let progress: Progress
    var state: State = .downloading
    private let cancelHandler: () -> Void

    /// A real download: progress is WKDownload's own Progress, used directly.
    init(download: WKDownload, filename: String) {
        self.download = download
        self.filename = filename
        self.progress = download.progress
        self.cancelHandler = { download.cancel() }
        super.init()
    }

    /// A test or otherwise fake item.
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

    /// Completed, failed or cancelled: the ones that can be cleared out of the list.
    var isFinished: Bool { !isActive }

    func setDestination(_ url: URL) {
        destination = url
        filename = url.lastPathComponent
    }

    func requestCancel() { cancelHandler() }

    // MARK: - Display

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()

    static func formatBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: max(bytes, 0))
    }

    /// The one-line status text: `1.2 MB / 5 MB · 45%` / `Completed · 5 MB` / `Canceled` /
    /// `Failed: ...`
    var statusText: String {
        switch state {
        case .downloading:
            let done = Self.formatBytes(progress.completedUnitCount)
            if progress.totalUnitCount > 0 {
                let total = Self.formatBytes(progress.totalUnitCount)
                let percent = Int((progress.fractionCompleted * 100).rounded())
                return L("browser.download.status.progress", done, total, percent)
            }
            return L("browser.download.status.downloading", done)
        case .completed:
            let size = progress.totalUnitCount > 0 ? progress.totalUnitCount : progress.completedUnitCount
            return L("browser.download.status.completed", Self.formatBytes(size))
        case .cancelled:
            return L("browser.download.status.cancelled")
        case .failed(let message):
            return L("browser.download.status.failed", message)
        }
    }

    /// Row icon: the system icon for the file extension.
    var icon: NSImage {
        let ext = (filename as NSString).pathExtension
        let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        return NSWorkspace.shared.icon(for: type ?? .data)
    }
}

/// One pane's download list: add and remove, state transitions, aggregate progress, and the throttled
/// `onChange`.
@MainActor
final class BrowserDownloadList: NSObject {
    /// Minimum interval between progress callbacks (<= 10 Hz).
    static let notifyInterval: TimeInterval = 0.1

    private(set) var items: [BrowserDownloadItem] = []
    /// UI refresh callback. Add/remove and state changes fire it immediately; progress changes are
    /// throttled.
    var onChange: (() -> Void)?

    private var observations: [UUID: NSKeyValueObservation] = [:]
    private var lastNotified = Date.distantPast
    private var notifyScheduled = false

    // MARK: - Add and remove

    func add(_ item: BrowserDownloadItem) {
        items.append(item)
        // Progress.fractionCompleted is KVO-observable; the callback can arrive on any thread, so
        // bounce every one of them back to the main thread.
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

    /// Drop every completed, failed or cancelled row; the in-flight ones stay.
    func clearFinished() {
        for item in items where item.isFinished { observations[item.id] = nil }
        items.removeAll { $0.isFinished }
        notifyNow()
    }

    /// Cancel: call the download's own cancel and move the state to cancelled right away. WebKit still
    /// calls didFail afterwards, which is why the transitions are idempotent.
    func cancel(_ item: BrowserDownloadItem) {
        guard item.isActive else { return }
        item.requestCancel()
        item.state = .cancelled
        notifyNow()
    }

    // MARK: - State transitions

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

    // MARK: - Aggregation

    var activeCount: Int { items.reduce(0) { $0 + ($1.isActive ? 1 : 0) } }

    /// Combined progress over every in-flight download; nil (indeterminate) when nothing is in flight,
    /// or when any one of them does not know its total size.
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

    // MARK: - Throttling

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

/// The download button to the right of the address bar: a hand-drawn progress ring plus a center
/// glyph (in flight = a down arrow, all completed = a checkmark, anything failed or cancelled = an
/// exclamation mark). 22x22, hidden while the list is empty (BrowserPaneView collapses its width and
/// its trailing gap to 0 at the same time).
@MainActor
final class BrowserDownloadButton: NSButton {
    static let size: CGFloat = 22

    /// Center glyph: in flight = a down arrow; all completed = a checkmark; nothing left but failed or
    /// cancelled = an exclamation mark.
    enum Glyph: Equatable { case arrow, check, warning }

    weak var list: BrowserDownloadList?
    var tint: NSColor = .white { didSet { needsDisplay = true } }

    /// NSButton defaults to `isFlipped == true` (y grows downward). This class draws everything itself
    /// and never calls super.draw, and the arcs, arrow and checkmark in draw(_:) are all written in
    /// y-up geometry, so switch back to the unflipped coordinate system here.
    /// Drop this line and you get an arrow pointing up, an upside-down checkmark, and a progress ring
    /// that starts at 6 o'clock and runs counterclockwise.
    override var isFlipped: Bool { false }

    /// Which center glyph to draw right now. The drawing code and the tooltip share it, and tests
    /// assert on it directly.
    var glyph: Glyph {
        let items = list?.items ?? []
        if (list?.activeCount ?? 0) > 0 || items.isEmpty { return .arrow }
        return items.allSatisfy { $0.state == .completed } ? .check : .warning
    }

    /// The arc that spins while progress is indeterminate.
    private var spinnerAngle: CGFloat = 0
    private var spinner: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .accessoryBarAction
        title = ""
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        toolTip = L("browser.download.button")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { spinner?.invalidate() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }

    /// Refresh visibility, tooltip and drawing from the list's current state; called from the list's
    /// onChange.
    func update() {
        let items = list?.items ?? []
        isHidden = items.isEmpty
        let active = list?.activeCount ?? 0
        let stopped = items.filter { $0.state != .completed && !$0.isActive }.count
        if active > 0 {
            toolTip = Lp("browser.download.button.active", count: active, active)
        } else if stopped > 0 {
            toolTip = Lp("browser.download.button.stopped", count: items.count, items.count, stopped)
        } else {
            toolTip = Lp("browser.download.button.count", count: items.count, items.count)
        }
        // Only an in-flight download whose total size is unknown needs the spinner.
        let indeterminate = active > 0 && list?.aggregateFraction == nil
        if indeterminate && !isHidden {
            if spinner == nil {
                spinner = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] timer in
                    MainActor.assumeIsolated {
                        // If the button went away first, kill the timer too: the runloop would hold
                        // it forever otherwise.
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

        // The track.
        tint.withAlphaComponent(0.25).setStroke()
        let track = NSBezierPath(ovalIn: box)
        track.lineWidth = 1.5
        track.stroke()

        // Progress arc: clockwise from 12 o'clock.
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
            // Everything has finished (completed, failed and cancelled all count): a full solid ring,
            // with the center glyph telling success from failure.
            let full = NSBezierPath(ovalIn: box)
            full.lineWidth = 1.5
            full.stroke()
        }

        // Center glyph (y-up, see isFlipped): in flight = a down arrow, all completed = a checkmark,
        // anything failed or cancelled = an exclamation mark (a checkmark there would report a failed
        // download as a successful one).
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

/// The download list popover: one row per download (icon + file name + status + a thin progress bar +
/// cancel / reveal in Finder / remove), with "Clear Completed" at the bottom. Row views are reused; a
/// change to the list only rewrites their contents instead of rebuilding them, which avoids flicker.
///
/// **The pane owns the NSPopover and this controller does not hold it back**:
/// `NSPopover.contentViewController` is a strong reference, so storing the NSPopover in the controller
/// as well makes a cycle between two objects that lock each other in place, and closing the pane would
/// never release the list, the items or the WKDownloads.
@MainActor
final class BrowserDownloadPopover: NSViewController {
    static let width: CGFloat = 320

    private let list: BrowserDownloadList
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
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
        emptyLabel.stringValue = L("browser.download.empty")
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .secondaryLabelColor
        clearButton.title = L("browser.download.clear-finished")
        clearButton.bezelStyle = .inline
        clearButton.controlSize = .small
        clearButton.font = .systemFont(ofSize: 11)
        clearButton.target = self
        clearButton.action = #selector(clearFinished)
        view = root
        rebuild()
    }

    /// Rebuild the rows from the list, reusing the row views that already exist.
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
        // The empty state and the "Clear Completed" button always sit after the rows.
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

    /// For tests.
    var rowsForTesting: [NSView] { rows }
    var clearButtonForTesting: NSButton { clearButton }
}

/// One row inside the popover.
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
            (primaryButton, "xmark.circle", L("browser.download.cancel"), #selector(primaryTapped)),
            (removeButton, "xmark", L("browser.download.remove"), #selector(removeTapped)),
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
            let cancel = L("browser.download.cancel")
            primaryButton.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: cancel)
            primaryButton.toolTip = cancel
            primaryButton.isHidden = false
        } else if item.state == .completed, item.destination != nil {
            let reveal = L("browser.download.reveal")
            primaryButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: reveal)
            primaryButton.toolTip = reveal
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

    /// For tests.
    var nameForTesting: String { nameLabel.stringValue }
    var statusForTesting: String { statusLabel.stringValue }
    var primaryButtonForTesting: NSButton { primaryButton }
}
