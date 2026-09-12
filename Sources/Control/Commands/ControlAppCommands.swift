import AppKit

/// `app get|set`：进程级设置的绝对设值。
///
/// 这一组存在的理由，是那 5 个被 `action` 拒掉的模态面板动作（`theme-picker`、
/// `background-menu`、`main-menu`、`keybind-help`、`open-settings`）需要一条**能经 socket 走**的
/// 替代路径。面板打开之后要靠方向键与回车才能用完——经 socket 执行等于把 UI 卡在半路。
/// 所以这里给的是"直接设成这个值"，不是"打开那个面板"。
///
/// 刻意**不给** `app set control …`：让 agent 能改控制面自己的开关，
/// 就等于给了它一条"先把闸门关掉再动手"的路。开关归用户（config.toml + 菜单）。
@MainActor
extension ControlCommandRunner {
    func runApp(_ ctx: ControlContext) throws -> (echo: ResolvedTarget?, data: any Encodable) {
        switch ctx.spec.verb {
        case "get": return try appGet(ctx)
        case "set": return try appSet(ctx)
        default: throw ControlErrorBody(.unknownCommand, "app has no verb \(ctx.spec.verb)")
        }
    }

    private var themeManager: ThemeManager? {
        (NSApp.delegate as? AppDelegate)?.themeManager
    }

    private func appGet(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        var wanted = ControlAppSetting.allCases
        if let key = ctx.string("key") {
            guard let only = ControlAppSetting(rawValue: key) else {
                throw ControlErrorBody(.badRequest, "There is no setting named \(key)",
                                       candidates: ControlAppSetting.allCases.map(\.rawValue))
            }
            wanted = [only]
        }
        let settings = try wanted.map { setting in
            ControlAppPayload.Setting(
                key: setting.rawValue,
                value: try value(of: setting, controller: scope.controller),
                choices: choices(of: setting),
                scope: setting.isPerScreen ? "screen" : "app",
                help: setting.help)
        }
        return (ResolvedTarget(screen: scope.controller.screenIndex + 1,
                               screenID: scope.controller.windowID.uuidString,
                               workspace: scope.controller.model.activeIndex + 1,
                               pane: nil, paneID: nil),
                ControlAppPayload(settings: settings))
    }

    private func appSet(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let scope = try requireScope(ctx, ctx.target)
        let controller = scope.controller
        guard let rawKey = ctx.string("key"), let setting = ControlAppSetting(rawValue: rawKey) else {
            throw ControlErrorBody(.badRequest, "app set needs a setting key",
                                   candidates: ControlAppSetting.allCases.map(\.rawValue))
        }
        guard let raw = ctx.string("value") else {
            throw ControlErrorBody(.badRequest, "app set \(setting.rawValue) needs a value",
                                   candidates: choices(of: setting))
        }
        let current = try value(of: setting, controller: controller)
        let normalized = try normalize(raw, for: setting)
        let changes = current == normalized
            ? []
            : [ControlChange(setting.isPerScreen ? "\(path(controller)).\(setting.rawValue)"
                                                 : "app.\(setting.rawValue)",
                             from: current, to: normalized)]
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: setting.isPerScreen ? [controller] : screens.controllers,
            // 主题 / 背景 / 间隙这类是进程级视觉开关：布局快照撤不回它们，
            // 与其登记一个撤不干净的撤销项，不如老实说这一步不进撤销栈
            undoName: setting == .visibleColumns ? "控制面：\(ctx.spec.cli)" : nil,
            target: setting.isPerScreen ? path(controller) : "app")
        var payload = try commit(mutation) {
            try apply(setting, value: normalized, controller: controller)
        }
        let settings = [ControlAppPayload.Setting(
            key: setting.rawValue,
            value: try value(of: setting, controller: controller),
            choices: choices(of: setting),
            scope: setting.isPerScreen ? "screen" : "app",
            help: setting.help)]
        payload.note = (payload.note.map { $0 + "; " } ?? "")
            + "current value: " + (settings.first?.value ?? "?")
        if setting.isPerScreen {
            payload.screen = ctx.encoder.screenInfo(controller, isKey: controller === screens.controlCurrent)
        }
        return (ResolvedTarget(screen: controller.screenIndex + 1,
                               screenID: controller.windowID.uuidString,
                               workspace: controller.model.activeIndex + 1,
                               pane: nil, paneID: nil), payload)
    }

    // MARK: 读 / 写 / 校验（三者共用同一张表，绝不各写各的）

    private func value(of setting: ControlAppSetting, controller: MainWindowController) throws -> String {
        guard let theme = themeManager else { throw ControlErrorBody(.internalError, "No ThemeManager") }
        switch setting {
        case .theme: return theme.current.name
        case .background:
            guard let url = theme.currentBackgroundURL else { return "none" }
            return url.deletingPathExtension().lastPathComponent
        case .gaps: return theme.gapsEnabled ? "on" : "off"
        case .opacity: return theme.opacityEnabled ? "on" : "off"
        case .bar: return controller.model.barVisible ? "on" : "off"
        case .visibleColumns: return String(controller.visibleColumns)
        }
    }

    private func choices(of setting: ControlAppSetting) -> [String]? {
        switch setting {
        case .theme: return themeManager?.themes.map(\.name)
        case .background:
            return themeManager?.backgroundChoices.map { $0.deletingPathExtension().lastPathComponent }
        case .gaps, .opacity, .bar: return ["on", "off"]
        case .visibleColumns: return (1...6).map(String.init)
        }
    }

    /// 把用户给的写法归一成"读回来会是什么样"——**diff 与幂等判定都靠它**。
    /// 不归一的话 `--gaps ON` 与读回来的 `on` 会被当成两个不同的值，于是每次调用都"改了一下"
    private func normalize(_ raw: String, for setting: ControlAppSetting) throws -> String {
        switch setting {
        case .gaps, .opacity, .bar:
            switch raw.lowercased() {
            case "on", "true", "yes", "1": return "on"
            case "off", "false", "no", "0": return "off"
            default: throw ControlErrorBody(.badRequest,
                                            "\(setting.rawValue) only accepts on / off, got \(raw)",
                                            candidates: ["on", "off"])
            }
        case .visibleColumns:
            guard let n = Int(raw), (1...6).contains(n) else {
                throw ControlErrorBody(.badRequest, "visible-columns must be 1–6, got \(raw)")
            }
            return String(n)
        case .theme:
            guard let theme = themeManager?.themes.first(where: { $0.name == raw }) else {
                throw ControlErrorBody(.notFound, "There is no theme named \(raw)",
                                       hint: "quickterm app get theme lists every valid value.",
                                       candidates: themeManager?.themes.map(\.name))
            }
            return theme.name
        case .background:
            let names = themeManager?.backgroundChoices.map { $0.deletingPathExtension().lastPathComponent } ?? []
            if let index = Int(raw) {
                guard index >= 1, index <= names.count else {
                    throw ControlErrorBody(.notFound, "Background index \(index) is out of "
                                               + "range (1–\(names.count))",
                                           candidates: names)
                }
                return names[index - 1]
            }
            guard names.contains(raw) else {
                throw ControlErrorBody(.notFound, "There is no background named \(raw)",
                                       hint: "quickterm app get background lists every valid value.",
                                       candidates: names)
            }
            return raw
        }
    }

    private func apply(_ setting: ControlAppSetting, value: String,
                       controller: MainWindowController) throws {
        guard let theme = themeManager else { throw ControlErrorBody(.internalError, "No ThemeManager") }
        switch setting {
        case .theme:
            guard let picked = theme.themes.first(where: { $0.name == value }) else {
                throw ControlErrorBody(.notFound, "There is no theme named \(value)")
            }
            theme.apply(picked)
        case .background:
            let names = theme.backgroundChoices.map { $0.deletingPathExtension().lastPathComponent }
            guard let index = names.firstIndex(of: value) else {
                throw ControlErrorBody(.notFound, "There is no background named \(value)")
            }
            theme.selectBackground(index)
        case .gaps:
            // 走 toggle**是**对的：`toggleGaps` 之外还有别的副作用要跑（透明那条还要写引擎覆盖层）。
            // 绝对语义由上面的 diff 保证——值相同时这段根本不会被调用
            if theme.gapsEnabled != (value == "on") { theme.toggleGaps() }
        case .opacity:
            if theme.opacityEnabled != (value == "on") { theme.toggleOpacity() }
        case .bar:
            controller.model.barVisible = (value == "on")
        case .visibleColumns:
            controller.setVisibleColumns(Int(value) ?? controller.visibleColumns)
        }
    }
}
