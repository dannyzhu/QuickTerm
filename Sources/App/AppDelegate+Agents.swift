import AppKit

/// **The app-level half of the hook installer** (plan §2.6): what launch does about a script that
/// has gone stale, what the *Agent Hooks* submenu does when it opens, and what its items do when
/// they are clicked.
///
/// Everything here ends in `HookInstaller`, which is the whole point: the menu is a third front
/// door onto the installer the CLI and the auto-install ask already use, not a second
/// implementation of it. The menu's one privilege is that it asks with `peerName: "QuickTerm"` —
/// the user is standing in front of the machine, and the alert says so.
extension AppDelegate {
    /// Guard for `ensureAgentHooksHealthy`, which is reachable from every menu rebuild (the menu
    /// is rebuilt whenever the UI language changes) and must run exactly once per launch.
    @MainActor private static var agentHooksHealed = false

    /// **The launch self-heal** (plan §2.6) plus the `hook-detail` rewrite (owner decision Q4).
    ///
    /// Two deliberately narrow jobs:
    /// - repoint the script when the binary it names has *gone* — never merely because a different
    ///   build is running, since a Debug build starting up must not repoint the hooks that the
    ///   user's installed QuickTerm is still serving (`HookScript.healIfStale`);
    /// - bring already-installed entries in line with `[agents] hook-detail`, for agents that have
    ///   our entries and no other.
    ///
    /// Skipped entirely for a **second copy** (`QUICKTERM_CONFIG_FILE` set, which is how a Debug
    /// build and the smoke runs are started) and under the test host: both would otherwise write
    /// into the real `~/.claude/settings.json` of the developer running them.
    ///
    /// ⚠️ **Seam.** The natural call site is `applicationDidFinishLaunching`, right after
    /// `ensureNoticeInterfaceInstalled()`; that file belongs to another package, so this is called
    /// from the last line of the launch sequence this package does own — `MainMenu.install`. Moving
    /// the call is one line and changes nothing here.
    @MainActor
    static func ensureAgentHooksHealthy() {
        guard !agentHooksHealed else { return }
        agentHooksHealed = true
        guard !isRunningTests, ConfigStore.configURLOverride == nil else { return }
        HookScript.healIfStale(path: HookInstaller.scriptPath(), binary: HookScript.bundledBinary)
        HookInstaller.rewriteInstalledEntries()
    }

    /// **The other half of owner decision Q4**: `[agents] hook-detail` changed *while the app was
    /// running*. Launch catches a tier that moved between runs; this catches the user editing the
    /// key and saving, which is the case the key's own help text describes — every agent that
    /// already has our entries is rewritten to the new tier, without a prompt, each rewrite logged
    /// as a `hooks.install` by QuickTerm.
    ///
    /// Called from `AppSession.applyGlobalConfig`, and **only when the tier really moved** — that
    /// file runs on every save of `config.toml`.
    ///
    /// The two guards are the promise `ensureAgentHooksHealthy` makes at launch, for the same
    /// reason: this writes into another program's configuration file.
    /// - **A test host writes nothing into the developer's home.** A case reaches the rewrite only
    ///   by pinning `HookInstaller.homeOverride` at a temporary directory of its own — the same
    ///   "tests opt in with an explicit path" rule `AppSession.controlAllowed` uses for the socket.
    /// - **A second copy owns only its own directory.** Started with `QUICKTERM_CONFIG_FILE` (a
    ///   Debug build, a smoke run), it may rewrite entries that live under that directory and no
    ///   others: the hooks in the real `~/.claude/settings.json` are being served by the QuickTerm
    ///   the user is actually running, and a Debug build reloading its config must not take them
    ///   over — that is exactly the takeover `HookScript.healIfStale` refuses one line up.
    @MainActor
    static func rewriteAgentHooksForChangedTier() {
        guard !isRunningTests || HookInstaller.homeOverride != nil else { return }
        if let override = ConfigStore.configURLOverride,
           !HookInstaller.entriesLive(under: override.deletingLastPathComponent()) { return }
        HookInstaller.rewriteInstalledEntries()
    }

    // MARK: The menu items

    @MainActor
    @objc func agentHooksInstallAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // The same prompt, the same grant scope and the same installer the CLI reaches: clicking
        // the menu item is not a shortcut past the confirmation.
        HookInstaller.requestInstall(id: id, via: AgentRegistry.shared.consent, peerName: "QuickTerm") { decision in
            MainActor.assumeIsolated {
                guard decision == .allow else { return }
                do {
                    _ = try HookInstaller.install(id: id)
                } catch {
                    Self.reportHookFailure(id: id, error: error)
                }
            }
        }
    }

    @MainActor
    @objc func agentHooksUninstallAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // No confirmation: this removes only entries carrying our own marker, and refusing to
        // undo something without a second dialog would be the wrong way round.
        do {
            _ = try HookInstaller.uninstall(id: id)
        } catch {
            Self.reportHookFailure(id: id, error: error)
        }
    }

    /// `hooks status` as an alert — the same reading the CLI prints, for somebody who has never
    /// run the CLI.
    @MainActor
    @objc func agentHooksStatusAction(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = L("agents.hooks.status.title")
        alert.informativeText = Self.hookStatusText()
        alert.addButton(withTitle: L("window.button.ok"))
        alert.runModal()
    }

    /// The alert's body. Whole sentences, one per line: a line is never glued together from
    /// fragments, because word order differs between the two languages.
    @MainActor
    static func hookStatusText() -> String {
        var lines: [String] = []
        let script = HookInstaller.scriptStatus()
        if !script.exists {
            lines.append(L("agents.hooks.status.script-missing", script.path))
        } else if let baked = script.bakedBinary, !script.bakedBinaryExists {
            lines.append(L("agents.hooks.status.script-stale", script.path, baked))
        } else {
            lines.append(L("agents.hooks.status.script-ready", script.path, script.bakedBinary ?? script.path))
        }
        for id in HookInstaller.installableIDs {
            let status = HookInstaller.status(id: id)
            guard status.installed, let detail = status.detail else {
                lines.append(L("agents.hooks.status.absent", status.name, status.configPath ?? ""))
                continue
            }
            lines.append(L("agents.hooks.status.installed", status.name, tierText(detail),
                           status.configPath ?? ""))
        }
        return lines.joined(separator: "\n")
    }

    private static func tierText(_ detail: String) -> String {
        switch detail {
        case "lifecycle": return L("agents.hooks.detail.lifecycle")
        case "tools": return L("agents.hooks.detail.tools")
        default: return L("agents.hooks.detail.mixed")
        }
    }

    @MainActor
    private static func reportHookFailure(id: String, error: Error) {
        let message = (error as? ControlErrorBody)?.message ?? "\(error)"
        let alert = NSAlert()
        alert.messageText = L("agents.hooks.failed", AgentRegistry.shared.rules[id]?.name ?? id)
        alert.informativeText = message
        alert.addButton(withTitle: L("window.button.ok"))
        alert.runModal()
    }
}

/// The **QuickTerm ▸ Agent Hooks** submenu: one item per loaded rule that has an installer, titled
/// by what clicking it would do *right now*.
///
/// Rebuilt on every open rather than kept in step, because the answer changes under us: the CLI,
/// another QuickTerm window and the auto-install ask all edit the same files, and a menu item
/// still saying "Install" for something installed a minute ago is worse than no menu item at all.
final class AgentHooksMenuDelegate: NSObject, NSMenuDelegate {
    private weak var target: AppDelegate?

    /// Not `@MainActor`: `MainMenu.install` is an ordinary synchronous function that AppKit calls
    /// on the main thread, and the delegate has to be constructible from there. Everything that
    /// actually reads state is on the main actor below.
    init(target: AppDelegate) {
        self.target = target
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild(menu) }
    }

    @MainActor
    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let ids = HookInstaller.installableIDs
        guard !ids.isEmpty else {
            let item = menu.addItem(withTitle: L("agents.hooks.none"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            return
        }
        for id in ids {
            let status = HookInstaller.status(id: id)
            let item = menu.addItem(
                withTitle: status.installed ? L("agents.menu.uninstall", status.name)
                    : L("agents.menu.install", status.name),
                action: status.installed ? #selector(AppDelegate.agentHooksUninstallAction(_:))
                    : #selector(AppDelegate.agentHooksInstallAction(_:)),
                keyEquivalent: "")
            item.target = target
            item.representedObject = id
            item.state = status.installed ? .on : .off
        }
        menu.addItem(.separator())
        let status = menu.addItem(withTitle: L("agents.menu.status"),
                                  action: #selector(AppDelegate.agentHooksStatusAction(_:)),
                                  keyEquivalent: "")
        status.target = target
    }
}
