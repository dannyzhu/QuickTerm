import AppKit
import OSLog

/// What installing or uninstalling one agent's hooks changed — the diff `hooks install` reports
/// and the activity log records.
struct HookChange: Equatable {
    var agent: String
    /// `absent` | `lifecycle` | `tools` | `mixed`.
    var from: String
    var to: String
    /// The file that was (or would be) written, `~` already expanded.
    var configPath: String?

    var changed: Bool { from != to }

    init(agent: String, from: String, to: String, configPath: String? = nil) {
        self.agent = agent
        self.from = from
        self.to = to
        self.configPath = configPath
    }
}

/// **The one installer** (plan §2.6, owner decision Q2): the CLI's `hooks install`, the menu item
/// and the registry's auto-install ask all end here, so there is a single code path that edits
/// another program's config file and a single confirmation in front of it.
///
/// Three rules run through the whole type:
///
/// - **`~` is injectable.** `homeOverride` and `configDir` exist so that no test — and no smoke —
///   ever computes a path under the real home directory. A test that leaves `homeOverride` nil and
///   installs is a bug, not a strict test policy: it would rewrite the developer's own
///   `~/.claude/settings.json` on every run.
/// - **install is a statement of the whole state**, not an increment: after it, our entries are on
///   exactly the events of the current `hook-detail` tier and nowhere else, so the second run
///   writes nothing and a tier change rewrites in place.
/// - **it refuses rather than guesses.** A config file that is not a JSON object, an app path with
///   an apostrophe in it, a script path somebody has turned into a symlink: each is a
///   `bad_request` with nothing written.
@MainActor
enum HookInstaller {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "AgentHooks")

    /// **The injectable home** (see the type comment). nil in the app: the real home directory.
    static var homeOverride: URL?

    private static var home: URL { homeOverride ?? FileManager.default.homeDirectoryForCurrentUser }

    // MARK: Paths

    /// Where the script lives. `~/.config/quickterm/hooks/quickterm-agent-state.sh`, beside the
    /// rest of QuickTerm's own configuration — never *inside* an agent's own config file's
    /// directory tree by name, because one script serves all of them.
    ///
    /// **It follows every override the entries follow**, and for one reason: the entry we write
    /// into another program's config file *names this path*, so redirecting the entries and not
    /// the script writes a hook pointing at a file the caller never asked for. `homeOverride` is
    /// process-local — a test can set it, a CLI caller cannot — so without this a live
    /// `hooks install <agent> --config-dir /tmp/x` puts the entry in the scratch directory and the
    /// script it names in the user's real `~/.config/quickterm/hooks`, and a smoke that promises to
    /// touch nothing of the user's cannot keep that promise.
    ///
    /// In order:
    /// - **`homeOverride`** — a case has pinned `~` at a temporary directory, and everything,
    ///   this script included, belongs inside it;
    /// - **`--config-dir`** — the caller redirected this install wholesale, script and all;
    /// - **`QUICKTERM_CONFIG_FILE`** (`ConfigStore.configURLOverride`) — a second copy keeps its
    ///   own configuration directory, and the script is part of that configuration;
    /// - the real home.
    static func scriptPath(configDir: String? = nil) -> String {
        scriptDirectory(configDir: configDir).appendingPathComponent(HookScript.fileName).path
    }

    /// The directory half of `scriptPath` (see it for the order of the overrides).
    static func scriptDirectory(configDir: String? = nil) -> URL {
        if let homeOverride { return homeOverride.appendingPathComponent(".config/quickterm/hooks") }
        if let configDir, !configDir.isEmpty {
            return URL(fileURLWithPath: (configDir as NSString).expandingTildeInPath)
                .appendingPathComponent("hooks")
        }
        if let override = ConfigStore.configURLOverride {
            return override.deletingLastPathComponent().appendingPathComponent("hooks")
        }
        return home.appendingPathComponent(".config/quickterm/hooks")
    }

    /// The agent's own config file. `--config-dir` replaces the *directory* the rule file names
    /// and keeps its file name (`CLAUDE_CONFIG_DIR=/tmp/x` really does mean `/tmp/x/settings.json`),
    /// which is what makes the smoke in the plan a one-flag change rather than a second code path.
    static func configURL(for rules: AgentRules, configDir: String?) -> URL? {
        guard let raw = rules.install?.config else { return nil }
        let name = (raw as NSString).lastPathComponent
        if let configDir, !configDir.isEmpty {
            return URL(fileURLWithPath: (configDir as NSString).expandingTildeInPath)
                .appendingPathComponent(name)
        }
        if raw.hasPrefix("~/") { return home.appendingPathComponent(String(raw.dropFirst(2))) }
        return URL(fileURLWithPath: raw)
    }

    // MARK: Reading

    /// What is in that agent's config file right now. A pure read: `hooks status`, the menu's
    /// item titles and the auto-install ask all come through here.
    static func status(id: String, configDir: String? = nil) -> HookAgentStatus {
        let name = AgentRegistry.shared.rules[id]?.name ?? id
        guard let rules = AgentRegistry.shared.rules[id] else {
            return HookAgentStatus(id: id, name: name, issue: "no such rule file")
        }
        guard let install = rules.install, let url = configURL(for: rules, configDir: configDir) else {
            return HookAgentStatus(id: id, name: rules.name, issue: "this rule file declares no installer")
        }
        let editor = HookConfigEditor(url: url, shape: .of(install.shape), command: "")
        let exists = FileManager.default.fileExists(atPath: HookConfigEditor.resolvingLink(url).path)
        do {
            let root = try editor.read() ?? [:]
            let owned = editor.ownedEvents(in: root)
            return HookAgentStatus(id: rules.id, name: rules.name, configPath: url.path,
                                   configExists: exists, installed: !owned.isEmpty,
                                   entries: ordered(owned, by: install), detail: detail(of: owned, install: install))
        } catch let error as ControlErrorBody {
            return HookAgentStatus(id: rules.id, name: rules.name, configPath: url.path,
                                   configExists: exists, issue: error.message)
        } catch {
            return HookAgentStatus(id: rules.id, name: rules.name, configPath: url.path,
                                   configExists: exists, issue: "\(error)")
        }
    }

    /// The hook script on disk — at the path the *same* overrides resolve (see `scriptPath`), so
    /// `hooks status --config-dir <dir>` reports the script that `hooks install --config-dir <dir>`
    /// wrote rather than one in a directory it never touched.
    static func scriptStatus(configDir: String? = nil) -> HookScriptStatus {
        HookScript.status(path: scriptPath(configDir: configDir))
    }

    /// The rule ids that can be installed at all, in load order — what `all` means and what the
    /// menu lists.
    static var installableIDs: [String] {
        AgentRegistry.shared.activeRulesForInstall.filter { $0.install != nil }.map(\.id)
    }

    // MARK: Planning (a read; `install` does exactly this and then writes)

    /// What `install` would change, computed without touching a single byte. `commit()` needs the
    /// diff *before* it decides whether to act at all, and `--dry-run` needs it to be free.
    static func plan(id: String, configDir: String? = nil) throws -> HookChange {
        let (rules, install) = try installable(id)
        let url = try required(configURL(for: rules, configDir: configDir), id: id)
        let detailTier = AgentRegistry.shared.settings.hookDetail
        let command = try commandString(agent: rules.id, configDir: configDir)
        let editor = HookConfigEditor(url: url, shape: .of(install.shape), command: command)

        let root = try editor.read() ?? [:]
        let owned = editor.ownedEvents(in: root)
        var from = detail(of: owned, install: install) ?? "absent"
        let wanted = install.events(detail: detailTier)
        let next = try HookConfigEditor.serialize(editor.installing(events: wanted, into: root))
        let current = FileManager.default.contents(atPath: HookConfigEditor.resolvingLink(url).path)

        // The tier can be right while the file is still wrong: the app moved and the command
        // string now names a path that is gone, or the script itself was never written. Saying
        // "lifecycle -> lifecycle" there would report `changed: false` for a run that has work to
        // do, so the reason is spelled into `from` and the diff stays honest.
        let scriptStale = HookScript.status(path: scriptPath(configDir: configDir)).bakedBinary
            != HookScript.bundledBinary
        if from == detailTier, next != current || scriptStale {
            from = scriptStale ? "\(detailTier), script stale" : "\(detailTier), entries stale"
        }
        return HookChange(agent: rules.id, from: from, to: detailTier, configPath: url.path)
    }

    /// What `uninstall` would change.
    static func uninstallPlan(id: String, configDir: String? = nil) throws -> HookChange {
        let (rules, install) = try installable(id)
        let url = try required(configURL(for: rules, configDir: configDir), id: id)
        let editor = HookConfigEditor(url: url, shape: .of(install.shape), command: "")
        let owned = editor.ownedEvents(in: try editor.read() ?? [:])
        return HookChange(agent: rules.id, from: detail(of: owned, install: install) ?? "absent",
                          to: "absent", configPath: url.path)
    }

    // MARK: Writing

    /// Write our hook entries into the agent's own config file, at the tier `[agents] hook-detail`
    /// names, and write the script they run.
    @discardableResult
    static func install(id: String, configDir: String? = nil) throws -> HookChange {
        try perform(id: id, configDir: configDir, repointScript: true)
    }

    /// `repointScript` is the difference between *the user asked for this* and *we are keeping an
    /// existing installation in step*. An explicit install bakes the running app's own binary into
    /// the script, which is what somebody running `quickterm hooks install` from a fresh copy
    /// means. A tier rewrite must not: it happens at launch, and a Debug build starting up would
    /// otherwise quietly repoint the hooks that the user's installed QuickTerm is still serving.
    private static func perform(id: String, configDir: String?, repointScript: Bool) throws -> HookChange {
        let (rules, install) = try installable(id)
        let url = try required(configURL(for: rules, configDir: configDir), id: id)
        let change = try plan(id: id, configDir: configDir)
        let command = try commandString(agent: rules.id, configDir: configDir)

        // The script first: an entry pointing at a file that is not there would be a hook that
        // fails on the agent's very next prompt.
        let path = scriptPath(configDir: configDir)
        let script = HookScript.status(path: path)
        if repointScript || !script.ok {
            try HookScript.write(to: path, binary: HookScript.bundledBinary)
        }

        let editor = HookConfigEditor(url: url, shape: .of(install.shape), command: command)
        let root = try editor.read() ?? [:]
        let events = install.events(detail: AgentRegistry.shared.settings.hookDetail)
        try editor.write(try HookConfigEditor.serialize(editor.installing(events: events, into: root)))
        logger.notice("hooks installed for \(rules.id, privacy: .public): \(change.from, privacy: .public) -> \(change.to, privacy: .public)")
        return change
    }

    /// Remove **only** entries carrying our marker; the user's own hook entries stay.
    ///
    /// The script is deliberately left on disk: it belongs to QuickTerm, not to the agent, another
    /// agent may still be pointing at it, and an executable file in `~/.config/quickterm` is not
    /// something `hooks uninstall claude-code` promised to remove.
    @discardableResult
    static func uninstall(id: String, configDir: String? = nil) throws -> HookChange {
        let (rules, install) = try installable(id)
        let url = try required(configURL(for: rules, configDir: configDir), id: id)
        let change = try uninstallPlan(id: id, configDir: configDir)
        let editor = HookConfigEditor(url: url, shape: .of(install.shape), command: "")
        guard let root = try editor.read() else { return change }
        try editor.write(try HookConfigEditor.serialize(editor.uninstalling(from: root)))
        logger.notice("hooks removed for \(rules.id, privacy: .public)")
        return change
    }

    /// **A `hook-detail` change rewrites what is already installed** (owner decision Q4), for every
    /// agent that has our entries, without asking: the user consented to that agent's hooks and
    /// has just edited the key whose help says exactly this. Each rewrite is recorded in the
    /// activity log as a `hooks.install` by QuickTerm, so the file did not change behind anyone's
    /// back.
    ///
    /// Called at launch (the self-heal) and on every hot reload that really moves the tier, both
    /// through `AppDelegate.rewriteAgentHooksForChangedTier` — which owns the two guards that keep
    /// a test host and a second copy out of the user's files.
    @discardableResult
    static func rewriteInstalledEntries(configDir: String? = nil) -> [HookChange] {
        var out: [HookChange] = []
        let tier = AgentRegistry.shared.settings.hookDetail
        for id in installableIDs {
            // **Only a tier that no longer matches.** Not "anything `plan` would change": that
            // would also cover a script baked with another build's path, and rewriting *that*
            // without being asked is precisely what the self-heal rule forbids.
            let current = status(id: id, configDir: configDir)
            guard current.installed, let detail = current.detail, detail != tier else { continue }
            guard let applied = try? perform(id: id, configDir: configDir, repointScript: false)
            else { continue }
            out.append(applied)
            ControlActivityLog.shared.record(.init(
                at: Date(), command: "hooks.install", peer: "QuickTerm", originPane: nil,
                target: applied.configPath, outcome: ControlActivityLog.Entry.Outcome.applied,
                changes: [ControlChange("hooks.\(applied.agent)", from: applied.from, to: applied.to)]))
        }
        return out
    }

    /// Does every config file `rewriteInstalledEntries()` could touch live inside `directory`?
    ///
    /// The question a **second copy** has to answer before it rewrites anything (owner decision Q4
    /// on hot reload): a build started with `QUICKTERM_CONFIG_FILE` owns the directory that file
    /// sits in and nothing else, while the real `~/.claude/settings.json` belongs to the QuickTerm
    /// the user is actually running — and its hooks are the ones their agents are talking to.
    static func entriesLive(under directory: URL) -> Bool {
        let root = directory.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        for id in installableIDs {
            guard let rules = AgentRegistry.shared.rules[id],
                  let url = configURL(for: rules, configDir: nil) else { continue }
            guard url.standardizedFileURL.path.hasPrefix(prefix) else { return false }
        }
        return true
    }

    // MARK: The confirmation

    /// Ask the user, then install. The **same** prompt the CLI gets: one grant scope per agent,
    /// so approving Claude Code's file is not approving Codex's.
    static func requestInstall(id: String, via consent: ControlConsent?, peerName: String,
                               completion: @escaping (ControlConsent.Decision) -> Void) {
        guard let rules = AgentRegistry.shared.rules[id], let install = rules.install else {
            completion(.deny)
            return
        }
        guard let consent else {
            // No consent gate at all means the control plane is switched off. The menu item is a
            // direct instruction from the user in front of the machine, and refusing it because a
            // *socket* is disabled would make no sense to them.
            completion(.allow)
            return
        }
        let path = configURL(for: rules, configDir: nil)?.path ?? install.config
        consent.evaluate(.init(peerName: peerName, peerPID: getpid(), cls: .mutate,
                               summary: L("consent.summary.hooks-install", rules.name, path),
                               originPane: nil, originVerified: false, tokenPresent: true,
                               cacheable: true, scope: "hooks.install:\(id)")) { decision in
            completion(decision)
        }
    }

    // MARK: Small shared pieces

    /// The command string, or the refusal that a path we cannot quote earns. It names the script
    /// **this** install writes (`configDir` and the rest of the overrides, see `scriptPath`), never
    /// a path in a directory the caller redirected away from.
    static func commandString(agent: String, configDir: String? = nil) throws -> String {
        guard HookScript.quoted(HookScript.bundledBinary) != nil else {
            throw ControlErrorBody(
                .badRequest, "The app path contains a quote (\(HookScript.bundledBinary)), which cannot be written into a shell script",
                hint: "Move QuickTerm.app to a path without an apostrophe and install the hooks again.")
        }
        let path = scriptPath(configDir: configDir)
        guard let command = HookScript.command(scriptPath: path, agent: agent) else {
            throw ControlErrorBody(
                .badRequest, "The hook script path contains a quote (\(path)) and cannot be written into a config file",
                hint: "Move the home directory's quickterm config out of a path with an apostrophe.")
        }
        return command
    }

    private static func installable(_ id: String) throws -> (AgentRules, AgentRules.Install) {
        guard let rules = AgentRegistry.shared.rules[id] else {
            throw ControlErrorBody(.badRequest, "No agent rule file with id \(id)",
                                   candidates: AgentRegistry.shared.activeRulesForInstall.map(\.id))
        }
        guard let install = rules.install else {
            throw ControlErrorBody(.badRequest, "\(rules.name) declares no [install] table, so QuickTerm cannot write its hooks",
                                   hint: "Add an [install] table to the rule file, or install this agent's hooks by hand.")
        }
        return (rules, install)
    }

    private static func required(_ url: URL?, id: String) throws -> URL {
        guard let url else {
            throw ControlErrorBody(.badRequest, "\(id) has no config file to write")
        }
        return url
    }

    /// Which tier a set of installed events adds up to. `mixed` is the honest answer for anything
    /// in between — a half-installed file, or one a previous version wrote — and `hooks install`
    /// is what tidies it.
    private static func detail(of owned: Set<String>, install: AgentRules.Install) -> String? {
        if owned.isEmpty { return nil }
        if owned == Set(install.events(detail: "lifecycle")) { return "lifecycle" }
        if owned == Set(install.events(detail: "tools")) { return "tools" }
        return "mixed"
    }

    /// Rule-file order (lifecycle, then tools), so the list reads the way the rule file reads;
    /// anything else we own but no longer write is appended, sorted, rather than dropped.
    private static func ordered(_ owned: Set<String>, by install: AgentRules.Install) -> [String] {
        let known = install.events(detail: "tools")
        return known.filter(owned.contains) + owned.subtracting(known).sorted()
    }
}

extension AgentRegistry {
    /// Every **loaded** rule in id order — not `activeRules`, which is filtered by
    /// `[agents] enabled`. Installing hooks for an agent the user has switched off is still a
    /// perfectly sensible thing to ask for (they are switching it on next), and `hooks status`
    /// must report the file it can see either way.
    ///
    /// Id order rather than load order because load order is the registry's own private business;
    /// id order is stable, and for the three bundled files it is the same list.
    var activeRulesForInstall: [AgentRules] {
        rules.values.sorted { $0.id < $1.id }
    }
}
