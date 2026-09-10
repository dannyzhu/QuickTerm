import AppKit

/// 把活着的注册表编码成 `quickterm.state/1`。
/// **全部经 JSONEncoder**（`ControlStatePayload` 是 Codable）——绝不手拼 JSON：
/// yabai 曾在一个版本里给 `query --windows` 拼出一个尾逗号，打断了所有下游 jq 管道。
@MainActor
struct ControlStateEncoder {
    let screens: ScreenRegistry
    /// 请求带了有效的来源 token（决定浏览器 pane 的 URL / 标题是否打码）
    let trusted: Bool
    /// `[control] expose-browser`：token | always | never
    let exposeBrowser: String
    let mode: String

    static let redacted = "<redacted>"

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// 浏览器 pane 的网址 / 标题是否可见。
    /// 一条规则，正面回答"浏览器 pane 里装着用户已登录的会话"：
    /// 没有 token 的调用方读不到——`quickterm state` 本身就是一个外泄面
    var exposesBrowser: Bool {
        switch exposeBrowser {
        case "always": true
        case "never": false
        default: trusted
        }
    }

    func payload(scope: MainWindowController? = nil) -> ControlStatePayload {
        let controllers = scope.map { [$0] } ?? screens.controllers
        // **不能用 `screens.key`**：那是 `NSApp.keyWindow`，应用不在前台时是 nil，
        // 于是每块屏幕都 `key: false`，而每块屏幕又各报一个 `focused: true` 的 pane——
        // describe 里"全局唯一的那个在 key: true 的屏幕上"这条消歧规则直接无解。
        // 而 agent 从 Terminal.app / 后台任务驱动时应用**正好**就不在前台，
        // 本地测的时候（QuickTerm 总在最前）永远复现不出来。
        // 用与目标解析同一条阶梯（controlCurrent），保证恒有且只有一块 key
        let keyController = screens.controlCurrent
        return ControlStatePayload(
            app: .init(version: appVersion,
                       protocolVersion: ControlProtocol.version,
                       workspaceCount: screens.primary?.model.layouts.count ?? 0,
                       mode: mode,
                       trusted: trusted),
            screens: controllers.map { screenInfo($0, isKey: $0 === keyController) },
            panes: controllers.flatMap { paneInfos(of: $0) })
    }

    func screenInfo(_ controller: MainWindowController, isKey: Bool) -> ControlStatePayload.ScreenInfo {
        let model = controller.model
        let display = DisplayRef(screen: controller.window?.screen)
        let frame = controller.savedFrame ?? controller.window?.frame
        return .init(
            index: controller.screenIndex + 1,
            id: controller.windowID.uuidString,
            title: controller.window?.title ?? ScreenRegistry.title(forIndex: controller.screenIndex),
            key: isKey,
            activeWorkspace: model.activeIndex + 1,
            visibleColumns: controller.visibleColumns,
            fullscreen: controller.isSimpleFullscreen,
            joinAllSpaces: controller.joinsAllSpaces,
            display: display.map { .init(uuid: $0.uuid, name: $0.name) },
            frame: frame.map { [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height] },
            workspaces: model.layouts.indices.map { workspaceInfo(controller, index: $0) })
    }

    func workspaceInfo(_ controller: MainWindowController, index: Int) -> ControlStatePayload.WorkspaceInfo {
        let model = controller.model
        let layout = model.layouts[index]
        let closing = model.closingPanes
        func live(_ panes: [PaneView]) -> [PaneView] { panes.filter { !closing.contains($0.id) } }
        let handles = live(layout.paneList).map { ControlHandleRegistry.shared.handle(for: $0) }
        let floating = live(model.floatings[index].map(\.pane))
            .map { ControlHandleRegistry.shared.handle(for: $0) }

        var columns: [ControlStatePayload.ColumnInfo]?
        var tree: [ControlStatePayload.TreeLeafInfo]?
        var zoom: String?
        switch layout {
        case .scrolling(let strip):
            columns = strip.columns.map { column in
                .init(width: column.widthFactor,
                      panes: live(column.panes).map { ControlHandleRegistry.shared.handle(for: $0) })
            }
            if let zoomed = strip.zoomedPane, !closing.contains(zoomed.id) {
                zoom = ControlHandleRegistry.shared.handle(for: zoomed)
            }
        case .dwindle(let splitTree):
            tree = live(splitTree.root?.leaves() ?? []).compactMap { pane in
                guard let node = splitTree.root?.node(view: pane),
                      let path = splitTree.root?.path(to: node) else { return nil }
                return .init(pane: ControlHandleRegistry.shared.handle(for: pane), path: Self.pathString(path))
            }
            if let zoomed = splitTree.zoomed, case .leaf(let view) = zoomed, !closing.contains(view.id) {
                zoom = ControlHandleRegistry.shared.handle(for: view)
            }
        }

        return .init(
            index: index + 1,
            layout: layout.name,
            empty: handles.isEmpty && floating.isEmpty,
            active: index == model.activeIndex,
            panes: handles,
            zoom: zoom,
            columns: columns,
            tree: tree,
            floating: floating)
    }

    /// dwindle 树里的位置：左 = `a`、右 = `b`，点号连接（根是空串）
    static func pathString(_ path: SplitTree<PaneView>.Path) -> String {
        path.path.map { component in
            switch component {
            case .left: "a"
            case .right: "b"
            }
        }.joined(separator: ".")
    }

    func paneInfos(of controller: MainWindowController) -> [ControlStatePayload.PaneInfo] {
        let model = controller.model
        var out: [ControlStatePayload.PaneInfo] = []
        for index in model.layouts.indices {
            let workspaceInfo = self.workspaceInfo(controller, index: index)
            let positions = Self.positions(in: model.layouts[index])
            for pane in model.layouts[index].paneList where !model.closingPanes.contains(pane.id) {
                out.append(paneInfo(pane, controller: controller, workspace: index,
                                    at: positions[pane.id], float: false,
                                    zoomed: workspaceInfo.zoom == ControlHandleRegistry.shared.handle(for: pane)))
            }
            for floating in model.floatings[index] where !model.closingPanes.contains(floating.pane.id) {
                out.append(paneInfo(floating.pane, controller: controller, workspace: index,
                                    at: nil, float: true, zoomed: false))
            }
        }
        return out
    }

    static func positions(in layout: WorkspaceLayout) -> [UUID: ControlStatePayload.PaneInfo.Position] {
        var out: [UUID: ControlStatePayload.PaneInfo.Position] = [:]
        switch layout {
        case .scrolling(let strip):
            for (c, column) in strip.columns.enumerated() {
                for (r, pane) in column.panes.enumerated() {
                    out[pane.id] = .init(column: c, row: r, path: nil)
                }
            }
        case .dwindle(let tree):
            for pane in tree.root?.leaves() ?? [] {
                guard let node = tree.root?.node(view: pane),
                      let path = tree.root?.path(to: node) else { continue }
                out[pane.id] = .init(column: nil, row: nil, path: pathString(path))
            }
        }
        return out
    }

    func paneInfo(_ pane: PaneView, controller: MainWindowController, workspace: Int,
                  at position: ControlStatePayload.PaneInfo.Position?,
                  float: Bool, zoomed: Bool) -> ControlStatePayload.PaneInfo {
        let browser = pane as? BrowserPaneView
        let hide = browser != nil && !exposesBrowser
        return .init(
            handle: ControlHandleRegistry.shared.handle(for: pane),
            id: pane.id.uuidString,
            kind: pane.kind.rawValue,
            role: controller.controlRole(of: pane),
            screen: controller.screenIndex + 1,
            workspace: workspace + 1,
            at: position,
            title: hide ? Self.redacted : pane.paneTitle,
            cwd: pane.workingDirectory,
            url: browser.map { hide ? Self.redacted : ($0.currentURL?.absoluteString ?? "") },
            tabs: browser?.tabs.count,
            focused: controller.focusedPane === pane && controller.model.activeIndex == workspace,
            busy: pane.wantsConfirmClose,
            float: float,
            zoom: zoomed,
            redacted: hide ? true : nil)
    }
}
