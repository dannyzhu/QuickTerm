import AppKit

/// `app get|set`: absolute value assignment for process-level settings.
///
/// This group exists because the 5 modal-panel actions that `action` refuses (`theme-picker`,
/// `background-menu`, `main-menu`, `keybind-help`, `open-settings`) need an alternative path that
/// **can go over the socket**. Once one of those panels is open it takes arrow keys and Return to
/// finish using it - driving that over the socket just leaves the UI stuck half way through. So
/// what this offers is "set it to this value directly", not "open that panel".
///
/// There is deliberately **no** `app set control ...`: letting an agent change the control plane's
/// own switches would hand it a way to "close the gate first, then act". Those switches belong to
/// the user (config.toml + the menu).
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
            // Theme / background / gaps and friends are process-level visual switches: a layout
            // snapshot cannot undo them. Rather than register an undo entry that only half works,
            // be honest and keep this step off the undo stack.
            undoCommand: setting == .visibleColumns ? ctx.spec.cli : nil,
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

    // MARK: Read / write / validate (all three share one table; never let them drift apart)

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

    /// Normalize whatever spelling the user gave into "what it will look like when read back" -
    /// **both the diff and the idempotency check rest on this**. Without normalization `--gaps ON`
    /// and the `on` that comes back on a read count as two different values, so every single call
    /// reports that it "changed something"
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
            // Going through toggle **is** right: `toggleGaps` carries other side effects that have
            // to run too (the opacity one also writes the engine overlay). The absolute semantics
            // are guaranteed by the diff above - when the value is already equal, this is never
            // reached.
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
