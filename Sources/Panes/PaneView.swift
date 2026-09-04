import AppKit
import Combine

/// pane 种类：存档判别与内容视图分发用
enum PaneKind: String, Codable {
    case terminal
    case browser
}

/// 布局容器（SplitTree / ScrollingStrip / FloatingPane）编解码叶子用的多态工厂。
/// 基类的 init(from:) 无法构造子类，所以由基类按存档里的 `kind` 分发到具体类型；
/// 旧存档（v3 及以前）没有 kind，视为终端。
protocol PaneCodable {
    static func decodePane(from decoder: Decoder) throws -> Self
    func encodePane(to encoder: Encoder) throws
}

/// 所有 pane 的基类：终端（Ghostty.SurfaceView）、浏览器（BrowserPaneView）……
/// 布局树 / 滚动条带 / 浮动层、焦点模型、拖放、存档只认这个类型；终端语义只留在子类
/// （关闭确认、目录继承、引擎回调、主题热切换）。
///
/// 焦点真相 = 窗口 first responder 是本 pane **或其后代**（浏览器 pane 的 FR 是内部的 WKWebView）。
/// `focused` 标志只由 focusDidChange 驱动（become/resign、托管视图的回调、控制器对账）。
class PaneView: NSView, ObservableObject, Identifiable, PaneCodable {
    let id: UUID

    /// 子类必须覆写
    class var kind: PaneKind { fatalError("PaneView subclass must override kind") }
    var kind: PaneKind { type(of: self).kind }

    init(id: UUID = UUID(), frame: NSRect) {
        self.id = id
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - 子类接口

    /// 状态条 / 速查表用的标题
    var paneTitle: String { "" }
    /// 新建终端要继承的目录（终端 = OSC 7 的 pwd；浏览器 = nil）
    var workingDirectory: String? { nil }
    /// 关闭前是否要确认（终端：仍有子进程在跑）
    var wantsConfirmClose: Bool { false }
    /// 键盘焦点实际落到的视图（终端 = 自己；浏览器 = WKWebView）
    var focusTarget: NSView { self }

    // MARK: - 焦点

    /// 是否持有键盘焦点（PaneChrome 边框等观察）。非 @Published：变化时手动发 objectWillChange
    private(set) var focused = false

    /// 焦点变化。子类覆写时先调 super，再做引擎同步等
    func focusDidChange(_ focused: Bool) {
        guard self.focused != focused else { return }
        objectWillChange.send()
        self.focused = focused
    }

    /// 窗口 first responder 是本 pane 或其后代
    func holdsFirstResponder(of window: NSWindow) -> Bool {
        guard let fr = window.firstResponder else { return false }
        if fr === self { return true }
        if let view = fr as? NSView { return view.isDescendant(of: self) }
        return false
    }

    var controller: BaseTerminalController? {
        window?.windowController as? BaseTerminalController
    }

    /// 本 pane（或其托管视图）成为 first responder：更新标志 + 通知控制器维持单焦点不变量
    func paneDidBecomeFirstResponder() {
        focusDidChange(true)
        controller?.paneDidBecomeFirstResponder(self)
    }

    func paneDidResignFirstResponder() {
        focusDidChange(false)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { paneDidBecomeFirstResponder() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        // 有时会手动调用（SplitView / moveFocus）以强制让出焦点
        if result { paneDidResignFirstResponder() }
        return result
    }

    /// first responder 视图被移出窗口时，AppKit 静默重置 FR 而**不调用** resignFirstResponder
    /// （已用独立探针验证），`focused` 会残留为 true。SwiftUI 重建层级（Cmd+L / Cmd+T / 切工作区）
    /// 时必然发生。记下"脱离时正是 FR"，重新挂载后夺回，让标志与真相重新一致。
    private var reclaimFocusOnAttach = false

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, holdsFirstResponder(of: window) {
            reclaimFocusOnAttach = true
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard reclaimFocusOnAttach, let window else { return }
        reclaimFocusOnAttach = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window, !self.holdsFirstResponder(of: window) else { return }
            // 只在"FR 因脱离被静默重置为窗口/nil"时夺回；期间若别的 responder（如刚新建并被
            // 控制器聚焦的 pane）已取得焦点，绝不抢——否则新建 pane 的焦点会被原 pane 夺走
            if let fr = window.firstResponder, fr !== window { return }
            if let controller = self.controller, !controller.paneMayReclaimFocus(self) { return }
            window.makeFirstResponder(self.focusTarget)
        }
    }

    /// 悬停即焦点（spec §4.2）：子类在 mouseMoved 里（过了遮挡判定后）调用
    func hoverFocusIfNeeded() {
        guard let window, let controller,
              !controller.commandPaletteIsShowing,
              window.isKeyWindow,
              controller.focusFollowsMouse,
              !holdsFirstResponder(of: window),          // 以真 FR 为准，不信残留的 focused
              controller.paneMayReclaimFocus(self) else { return }
        // 最后一条：新 pane 插入会让邻居的 tracking area 重建，AppKit 会合成一次 mouseMoved——
        // 鼠标恰好停在旧 pane 上时，悬停会把刚交给新 pane 的焦点抢回来；控制器有待聚焦意图时不抢
        PaneView.moveFocus(to: self)
    }

    /// 移交键盘焦点（移植自 Ghostty.moveFocus）：目标尚未挂进窗口时指数退避重试，最多 0.5s；
    /// `from` 显式让出（引擎侧的 resign 回调有时不来）。
    static func moveFocus(to: PaneView, from: PaneView? = nil, delay: TimeInterval? = nil) {
        let maxDelay: TimeInterval = 0.5
        guard (delay ?? 0) < maxDelay else { return }
        let nextDelay: TimeInterval = delay.map { $0 * 2 } ?? 0.05
        let work = DispatchWorkItem {
            guard let window = to.window else {
                moveFocus(to: to, from: from, delay: nextDelay)
                return
            }
            // 有意与 Ghostty.moveFocus 不同：from === to（cycle 回绕到自己）时不 resign——否则
            // makeFirstResponder 被 AppKit 短路不再回调 become，pane 仍是 FR 却 focused=false
            // 只对"自己就是 FR"的 pane（终端）手动 resign；托管视图（WKWebView）不能在
            // makeFirstResponder 流程之外调 resignFirstResponder（WebKit 内部断言），交给下面的
            // makeFirstResponder 正常流程让出
            if let from, from !== to, from.focusTarget === from {
                _ = from.resignFirstResponder()
            }
            window.makeFirstResponder(to.focusTarget)
        }
        if let delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - 存档（PaneCodable）

    private enum KindKey: String, CodingKey { case kind }

    static func decodePane(from decoder: Decoder) throws -> Self {
        let kind = try decoder.container(keyedBy: KindKey.self)
            .decodeIfPresent(PaneKind.self, forKey: .kind) ?? .terminal   // v3 存档无 kind = 终端
        let pane: PaneView
        switch kind {
        case .terminal: pane = try Ghostty.SurfaceView(from: decoder)
        case .browser: pane = try BrowserPaneView.decode(from: decoder)
        }
        guard let typed = pane as? Self else {
            throw DecodingError.typeMismatch(Self.self, .init(
                codingPath: decoder.codingPath, debugDescription: "pane kind \(kind) is not \(Self.self)"))
        }
        return typed
    }

    func encodePane(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: KindKey.self)
        try container.encode(kind, forKey: .kind)
        try encodePayload(to: encoder)
    }

    /// 子类把自己的字段编进同一个 encoder（与 kind 同级）
    func encodePayload(to encoder: Encoder) throws {}
}

extension PaneView {
    /// pane 的快照图（拖拽预览）
    var asImage: NSImage? {
        guard let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: bitmapRep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmapRep)
        return image
    }
}
