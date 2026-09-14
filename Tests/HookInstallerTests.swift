import AppKit
import XCTest
@testable import QuickTerm

/// **Editing somebody else's configuration file** (plan §2.6).
///
/// Every case here is one sentence from that section, and they are all the same kind of claim:
/// what we write is exactly what the tier says, and *everything we did not write is still there
/// afterwards*. A hook installer that loses a user's own `PreToolUse` entry is worse than one that
/// never worked.
///
/// **No case touches the real `~`.** `HookInstaller.homeOverride` is pointed at a temporary
/// directory in `setUp` and `assertUnderRoot` proves every path the installer computed lives
/// inside it, so a regression that resolves the real home fails here rather than on somebody's
/// machine.
@MainActor
final class HookInstallerTests: XCTestCase {
    private var root: URL!
    private var savedSettings = AgentSettings()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quickterm-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        HookInstaller.homeOverride = root

        // The shared registry is where the rules and the tier come from. Under the test host it is
        // already attached with the three bundled files; a registry that somehow is not gets them
        // here, so this case never depends on the order the suite happens to run in.
        if AgentRegistry.shared.rules.isEmpty {
            AgentRegistry.shared.reloadRulesForTesting(AgentRulesLoader.load(userDirectory: nil).rules)
        }
        savedSettings = AgentRegistry.shared.settings
        AgentRegistry.shared.settings.hookDetail = "lifecycle"
    }

    override func tearDownWithError() throws {
        AgentRegistry.shared.settings = savedSettings
        HookInstaller.homeOverride = nil
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: What install writes

    /// Exactly the tier's events, in exactly the shape that agent documents — for all three, and
    /// for both tiers. The comparison is against a document built here from the plan's table, so a
    /// change to the entry shape has to be made in two places on purpose.
    func testInstallWritesExactlyTheEventsOfTheTierForEveryShape() throws {
        for id in ["claude-code", "codex", "gemini"] {
            for tier in ["lifecycle", "tools"] {
                let directory = try scratch("\(id)-\(tier)")
                AgentRegistry.shared.settings.hookDetail = tier
                let change = try HookInstaller.install(id: id, configDir: directory)
                XCTAssertEqual(change.from, "absent")
                XCTAssertEqual(change.to, tier)
                XCTAssertTrue(change.changed)

                let rules = try XCTUnwrap(AgentRegistry.shared.rules[id])
                let install = try XCTUnwrap(rules.install)
                let url = try XCTUnwrap(HookInstaller.configURL(for: rules, configDir: directory))
                assertUnderRoot(url.path)
                XCTAssertEqual(url.lastPathComponent, (install.config as NSString).lastPathComponent)

                let written = try XCTUnwrap(FileManager.default.contents(atPath: url.path))
                let wanted = try document(events: install.events(detail: tier), shape: .of(install.shape),
                                          command: HookInstaller.commandString(agent: id))
                XCTAssertEqual(written, wanted, "\(id) @ \(tier) is not the documented shape")
                // `withoutEscapingSlashes`: a path full of `\/` is a path nobody can read.
                XCTAssertFalse(String(decoding: written, as: UTF8.self).contains("\\/"))
            }
        }
    }

    /// The one entry an agent sees is a single-quoted path plus the agent id — the marker and the
    /// whole reason a home directory with a space in it works.
    func testTheCommandStringIsTheSingleQuotedScriptPathAndTheAgentID() throws {
        let directory = try scratch("quoting")
        _ = try HookInstaller.install(id: "claude-code", configDir: directory)
        let text = try String(contentsOfFile: configPath("claude-code", in: directory), encoding: .utf8)
        XCTAssertTrue(text.contains("'\(HookInstaller.scriptPath())' claude-code"), text)
        assertUnderRoot(HookInstaller.scriptPath())
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: HookInstaller.scriptPath()))
    }

    func testInstallingTwiceChangesNothingTheSecondTime() throws {
        let directory = try scratch("idempotent")
        _ = try HookInstaller.install(id: "claude-code", configDir: directory)
        let first = try Data(contentsOf: URL(fileURLWithPath: configPath("claude-code", in: directory)))

        let again = try HookInstaller.install(id: "claude-code", configDir: directory)
        XCTAssertFalse(again.changed, "from \(again.from) -> to \(again.to)")
        XCTAssertEqual(again.from, "lifecycle")
        let second = try Data(contentsOf: URL(fileURLWithPath: configPath("claude-code", in: directory)))
        XCTAssertEqual(first, second, "byte-identical, or the file's mtime churns on every launch")
    }

    /// Owner decision Q4: changing `hook-detail` rewrites what is installed, in place. The count
    /// matters — a second copy of our entry means two processes per event, for ever.
    func testChangingTheTierRewritesInPlaceRatherThanDuplicating() throws {
        let directory = try scratch("tier")
        _ = try HookInstaller.install(id: "claude-code", configDir: directory)
        AgentRegistry.shared.settings.hookDetail = "tools"
        let change = try HookInstaller.install(id: "claude-code", configDir: directory)
        XCTAssertEqual(change.from, "lifecycle")
        XCTAssertEqual(change.to, "tools")

        let status = HookInstaller.status(id: "claude-code", configDir: directory)
        XCTAssertEqual(status.detail, "tools")
        XCTAssertEqual(Set(status.entries),
                       Set(try XCTUnwrap(AgentRegistry.shared.rules["claude-code"]?.install)
                           .events(detail: "tools")))
        XCTAssertEqual(ourEntryCount(in: directory, id: "claude-code"), status.entries.count,
                       "one entry per event, never two")

        // And back down: the tool events lose ours again.
        AgentRegistry.shared.settings.hookDetail = "lifecycle"
        _ = try HookInstaller.install(id: "claude-code", configDir: directory)
        XCTAssertEqual(HookInstaller.status(id: "claude-code", configDir: directory).detail, "lifecycle")
        XCTAssertFalse(Set(HookInstaller.status(id: "claude-code", configDir: directory).entries).contains("PreToolUse"))
    }

    /// `hooks status` reads the file and nothing else: it is what the menu titles, the auto-install
    /// ask and the CLI all branch on.
    func testStatusReportsTheTierAndCallsAHalfInstalledFileMixed() throws {
        let directory = try scratch("status")
        var status = HookInstaller.status(id: "claude-code", configDir: directory)
        XCTAssertFalse(status.installed)
        XCTAssertFalse(status.configExists)
        XCTAssertNil(status.detail)

        _ = try HookInstaller.install(id: "claude-code", configDir: directory)
        status = HookInstaller.status(id: "claude-code", configDir: directory)
        XCTAssertTrue(status.installed)
        XCTAssertTrue(status.configExists)
        XCTAssertEqual(status.detail, "lifecycle")
        XCTAssertEqual(status.entries.first, "SessionStart", "rule-file order, not alphabetical")

        // Half of the lifecycle tier removed by hand is neither tier.
        var config = try XCTUnwrap(try editor(id: "claude-code", in: directory).read())
        var hooks = try XCTUnwrap(config["hooks"] as? [String: Any])
        hooks.removeValue(forKey: "Stop")
        config["hooks"] = hooks
        _ = try editor(id: "claude-code", in: directory).write(try HookConfigEditor.serialize(config))
        XCTAssertEqual(HookInstaller.status(id: "claude-code", configDir: directory).detail, "mixed")
    }

    // MARK: What install leaves alone

    /// The whole risk of this feature in one case: a file with the user's own settings, their own
    /// hook on the very same event, and a matcher we do not understand.
    func testEverythingTheUserWroteSurvivesInstallAndUninstall() throws {
        let directory = try scratch("survives")
        let path = configPath("claude-code", in: directory)
        let original: [String: Any] = [
            "model": "opus",
            "env": ["FOO": "bar"],
            "hooks": [
                "Stop": [["matcher": "Bash",
                          "hooks": [["type": "command", "command": "/usr/local/bin/mine.sh", "timeout": 9]]]],
                "PreCompact": [["hooks": [["type": "command", "command": "echo compacting"]]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: URL(fileURLWithPath: path))

        _ = try HookInstaller.install(id: "claude-code", configDir: directory)
        var now = try XCTUnwrap(try editor(id: "claude-code", in: directory).read())
        XCTAssertEqual(now["model"] as? String, "opus")
        XCTAssertEqual((now["env"] as? [String: Any])?["FOO"] as? String, "bar")
        XCTAssertTrue(commands(in: now, event: "Stop").contains("/usr/local/bin/mine.sh"))
        XCTAssertEqual(commands(in: now, event: "PreCompact"), ["echo compacting"])
        XCTAssertEqual(matchers(in: now, event: "Stop"), ["Bash"], "a matcher we do not understand is not ours to drop")

        let removal = try HookInstaller.uninstall(id: "claude-code", configDir: directory)
        XCTAssertEqual(removal.to, "absent")
        now = try XCTUnwrap(try editor(id: "claude-code", in: directory).read())
        XCTAssertEqual(now["model"] as? String, "opus")
        XCTAssertEqual(commands(in: now, event: "Stop"), ["/usr/local/bin/mine.sh"])
        XCTAssertEqual(commands(in: now, event: "PreCompact"), ["echo compacting"])
        XCTAssertEqual(ourEntryCount(in: directory, id: "claude-code"), 0)
    }

    /// Uninstall leaves no litter: no empty group, no empty event array, and no empty `hooks`
    /// object in a file that had none before.
    func testUninstallDropsEmptyGroupsAndAnEmptyHooksObject() throws {
        let directory = try scratch("empty")
        _ = try HookInstaller.install(id: "codex", configDir: directory)
        _ = try HookInstaller.uninstall(id: "codex", configDir: directory)
        let root = try XCTUnwrap(try editor(id: "codex", in: directory).read())
        XCTAssertNil(root["hooks"], "an empty hooks object is litter in somebody's settings file")
    }

    func testUninstallOfSomethingNotInstalledChangesNothing() throws {
        let directory = try scratch("noop")
        let change = try HookInstaller.uninstall(id: "codex", configDir: directory)
        XCTAssertFalse(change.changed)
        XCTAssertEqual(change.from, "absent")
    }

    // MARK: Refusals

    func testAConfigFileThatIsNotAnObjectIsRefusedAndLeftAlone() throws {
        let directory = try scratch("not-an-object")
        let path = configPath("claude-code", in: directory)
        try Data("[1, 2, 3]".utf8).write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try HookInstaller.install(id: "claude-code", configDir: directory)) { error in
            XCTAssertEqual((error as? ControlErrorBody)?.code, ControlErrorCode.badRequest.rawValue)
        }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "[1, 2, 3]")
        let status = HookInstaller.status(id: "claude-code", configDir: directory)
        XCTAssertFalse(status.installed)
        XCTAssertNotNil(status.issue)
    }

    /// A dotfiles repository symlinks `settings.json`. Writing through the link keeps the link;
    /// renaming over it would silently turn the user's symlink into a plain file and their repo
    /// would stop tracking it.
    func testASymlinkedConfigFileIsWrittenThroughAndTheLinkSurvives() throws {
        let directory = try scratch("linked")
        let real = root.appendingPathComponent("dotfiles-settings.json")
        try Data("{}".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(atPath: configPath("claude-code", in: directory),
                                                   withDestinationPath: real.path)
        _ = try HookInstaller.install(id: "claude-code", configDir: directory)

        XCTAssertTrue(HookScript.isSymlink(configPath("claude-code", in: directory)), "the link must survive")
        let throughTheLink = try String(contentsOf: real, encoding: .utf8)
        XCTAssertTrue(throughTheLink.contains("quickterm-agent-state.sh"), throughTheLink)
    }

    func testASymlinkedScriptPathRefusesToInstall() throws {
        let directory = try scratch("linked-script")
        let real = root.appendingPathComponent("somebody-elses.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: real)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: HookInstaller.scriptPath()).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: HookInstaller.scriptPath(),
                                                   withDestinationPath: real.path)

        XCTAssertThrowsError(try HookInstaller.install(id: "claude-code", configDir: directory)) { error in
            XCTAssertEqual((error as? ControlErrorBody)?.code, ControlErrorCode.badRequest.rawValue)
        }
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "#!/bin/sh\nexit 0\n")
        // The refusal comes before the config file is touched.
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath("claude-code", in: directory)))
    }

    func testAnUnknownAgentIsRefusedWithTheIDsThatExist() {
        XCTAssertThrowsError(try HookInstaller.install(id: "claude-cod", configDir: root.path)) { error in
            let body = error as? ControlErrorBody
            XCTAssertEqual(body?.code, ControlErrorCode.badRequest.rawValue)
            XCTAssertEqual(body?.candidates?.contains("claude-code"), true)
        }
    }

    // MARK: Where the script lands

    /// **The one case in this file that does not pin `~`** — and it is the only shape a live run
    /// ever has, because `homeOverride` is process-local: a test can set it, `quickterm hooks
    /// install --config-dir /tmp/x` cannot. The gap it was written for is exactly that: the entries
    /// followed `--config-dir` and the script did not, so a smoke promising to touch nothing of the
    /// user's wrote into their real `~/.config/quickterm/hooks` and left an entry in the scratch
    /// directory naming it.
    func testTheScriptFollowsTheSameOverrideTheEntriesDoAndNeverTheRealHome() throws {
        let directory = try scratch("no-home-override")
        let realHome = NSHomeDirectory()
        HookInstaller.homeOverride = nil          // tearDown clears it again

        let script = HookInstaller.scriptPath(configDir: directory)
        let underRealHome = script.hasPrefix(realHome + "/")
        XCTAssertFalse(underRealHome,
                       "--config-dir has to move the script as well as the entries: \(script)")
        XCTAssertTrue(script.hasPrefix(directory + "/"), script)
        // **Nothing is written until that holds.** Proving the bug must not be the thing that
        // writes an executable into the developer's own ~/.config/quickterm.
        guard !underRealHome else { return }

        XCTAssertEqual(try HookInstaller.install(id: "claude-code", configDir: directory).to, "lifecycle")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script))
        XCTAssertEqual(HookInstaller.scriptStatus(configDir: directory).path, script,
                       "status has to report the script install with the same flag would write")

        let text = try String(contentsOfFile: configPath("claude-code", in: directory), encoding: .utf8)
        XCTAssertTrue(text.contains("'\(script)' claude-code"),
                      "the entry names the script this install actually wrote: \(text)")
        XCTAssertFalse(text.contains(realHome), "not one path under the real home reached the file")
    }

    /// The second copy's half of the same rule: started with `QUICKTERM_CONFIG_FILE`, QuickTerm's
    /// own configuration directory moves, and the script is part of that configuration. A pure
    /// path computation — a second copy writing anything here is the thing being ruled out.
    func testASecondCopyKeepsTheScriptBesideItsOwnConfigFile() {
        let saved = ConfigStore.configURLOverride
        defer { ConfigStore.configURLOverride = saved }
        HookInstaller.homeOverride = nil
        ConfigStore.configURLOverride = root.appendingPathComponent("second-copy/config.toml")

        XCTAssertEqual(HookInstaller.scriptPath(),
                       root.appendingPathComponent("second-copy/hooks")
                           .appendingPathComponent(HookScript.fileName).path)
        XCTAssertFalse(HookInstaller.scriptPath().hasPrefix(NSHomeDirectory() + "/"))
        // `--config-dir` is the more specific instruction of the two and still wins.
        XCTAssertTrue(HookInstaller.scriptPath(configDir: root.appendingPathComponent("flag").path)
            .hasPrefix(root.appendingPathComponent("flag").path + "/"))
    }

    // MARK: The hook-detail rewrite (owner decision Q4)

    /// A changed `[agents] hook-detail` brings **installed** agents in line, and nobody else: an
    /// agent with no entries of ours does not acquire any because a config key moved.
    func testTheTierRewriteTouchesOnlyAgentsWhoseInstalledTierMoved() throws {
        _ = try HookInstaller.install(id: "claude-code")
        assertUnderRoot(try XCTUnwrap(HookInstaller.status(id: "claude-code").configPath))

        AgentRegistry.shared.settings.hookDetail = "tools"
        XCTAssertEqual(HookInstaller.rewriteInstalledEntries().map(\.agent), ["claude-code"])
        XCTAssertEqual(HookInstaller.status(id: "claude-code").detail, "tools")
        XCTAssertFalse(HookInstaller.status(id: "codex").installed,
                       "a config key moving must not install anything new")
        XCTAssertTrue(HookInstaller.rewriteInstalledEntries().isEmpty, "and it settles")
    }

    /// The rewrite is not a self-heal: it must not repoint the script at the running build, or a
    /// Debug build starting up would take over the hooks of the user's installed QuickTerm.
    func testTheTierRewriteLeavesTheScriptsBakedBinaryAlone() throws {
        _ = try HookInstaller.install(id: "claude-code")
        let other = root.appendingPathComponent("another-quickterm").path
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: other))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: other)
        try HookScript.write(to: HookInstaller.scriptPath(), binary: other)

        AgentRegistry.shared.settings.hookDetail = "tools"
        _ = HookInstaller.rewriteInstalledEntries()
        XCTAssertEqual(HookScript.status(path: HookInstaller.scriptPath()).bakedBinary, other)

        // An explicit install, on the other hand, is the user saying "use this copy".
        _ = try HookInstaller.install(id: "claude-code")
        XCTAssertEqual(HookScript.status(path: HookInstaller.scriptPath()).bakedBinary,
                       HookScript.bundledBinary)
    }

    /// **The hot-reload half of Q4**, and the gap this case was written for: the rewrite ran at
    /// launch only, so editing `[agents] hook-detail` and saving left the installed entries — and
    /// `hooks status` — on the old tier until the next launch, while the key's own help text says
    /// it "rewrites installed hooks to match".
    func testSavingAChangedHookDetailRewritesTheInstalledEntries() throws {
        _ = try HookInstaller.install(id: "claude-code")
        XCTAssertEqual(HookInstaller.status(id: "claude-code").detail, "lifecycle")
        ControlActivityLog.shared.clear()

        // A copy running on an overridden config file may only rewrite entries that live inside
        // that file's directory — the sandbox-home shape the smoke uses, and the only shape in
        // which a case can reach the rewrite at all: never through the developer's real home.
        let saved = ConfigStore.configURLOverride
        defer { ConfigStore.configURLOverride = saved }
        ConfigStore.configURLOverride = root.appendingPathComponent("config.toml")
        XCTAssertTrue(HookInstaller.entriesLive(under: root))

        var settings = ConfigStore.Settings()
        settings.agentsHookDetail = "tools"
        try withThrowawaySession { $0.applyGlobalConfig(settings) }

        XCTAssertEqual(HookInstaller.status(id: "claude-code").detail, "tools",
                       "a saved hook-detail has to reach the entries that are already installed")
        let logged = ControlActivityLog.shared.recent().first { $0.command == "hooks.install" }
        XCTAssertEqual(logged?.peer, "QuickTerm", "the file did not change behind anybody's back")
        XCTAssertEqual(logged?.outcome, ControlActivityLog.Entry.Outcome.applied)
        XCTAssertEqual(logged?.changes.first?.path, "hooks.claude-code")
        XCTAssertEqual(logged?.changes.first?.to, "tools")
    }

    /// A reload that leaves the tier alone rewrites nothing: `applyGlobalConfig` runs on every save
    /// of `config.toml`, and re-reading three other programs' configuration files on each one is
    /// work nobody asked for.
    func testAReloadThatDoesNotMoveTheTierRewritesNothing() throws {
        _ = try HookInstaller.install(id: "claude-code")
        ControlActivityLog.shared.clear()
        let saved = ConfigStore.configURLOverride
        defer { ConfigStore.configURLOverride = saved }
        ConfigStore.configURLOverride = root.appendingPathComponent("config.toml")

        var settings = ConfigStore.Settings()
        settings.agentsHookDetail = "lifecycle"
        try withThrowawaySession { $0.applyGlobalConfig(settings) }

        XCTAssertEqual(HookInstaller.status(id: "claude-code").detail, "lifecycle")
        XCTAssertTrue(ControlActivityLog.shared.recent().isEmpty)
    }

    /// And a **second copy** rewrites nothing at all: a Debug build reloading its own config file
    /// must not take over the hooks the user's installed QuickTerm is serving, which is the same
    /// takeover `HookScript.healIfStale` refuses.
    func testAHotReloadInASecondCopyLeavesEntriesOutsideItsDirectoryAlone() throws {
        _ = try HookInstaller.install(id: "claude-code")
        let saved = ConfigStore.configURLOverride
        defer { ConfigStore.configURLOverride = saved }
        // Somewhere else entirely: the entries live under the pinned home, not under this.
        ConfigStore.configURLOverride = root.appendingPathComponent("second-copy/config.toml")
        XCTAssertFalse(HookInstaller.entriesLive(under: root.appendingPathComponent("second-copy")))

        var settings = ConfigStore.Settings()
        settings.agentsHookDetail = "tools"
        try withThrowawaySession { $0.applyGlobalConfig(settings) }

        XCTAssertEqual(HookInstaller.status(id: "claude-code").detail, "lifecycle",
                       "a second copy owns its own directory and nothing else")
    }

    // MARK: The auto-install ask (plan §2.6 + §2.5)

    /// Under `ask` the registry asks once per agent per launch — the first time a pane runs an
    /// agent whose hooks are missing — and installs only on approval.
    func testTheAutoInstallAskFiresOncePerAgentPerLaunch() throws {
        let registry = try askRegistry(policy: "ask")
        let consent = ControlConsent(screens: nil)
        var prompts: [ControlConsent.Request] = []
        consent.decisionStub = { request, reply in
            prompts.append(request)
            reply(.allow)
        }
        registry.consent = consent
        let pane = UUID()

        registry.apply(.processes([4242]), pane: pane)
        registry.apply(.processes([4242, 4243]), pane: UUID())
        XCTAssertEqual(prompts.count, 1, "once per agent per launch, not once per pane")
        XCTAssertEqual(prompts.first?.scope, "hooks.install:claude-code",
                       "one grant per agent: approving Claude Code's file is not approving Codex's")
        XCTAssertTrue(HookInstaller.status(id: "claude-code").installed)
    }

    func testTheAutoInstallAskNeverFiresUnderNever() throws {
        let registry = try askRegistry(policy: "never")
        let consent = ControlConsent(screens: nil)
        var prompts = 0
        consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        registry.consent = consent
        registry.apply(.processes([4242]), pane: UUID())
        XCTAssertEqual(prompts, 0)
        XCTAssertFalse(HookInstaller.status(id: "claude-code").installed)
    }

    func testUnderAlwaysItInstallsWithoutAsking() throws {
        let registry = try askRegistry(policy: "always")
        let consent = ControlConsent(screens: nil)
        var prompts = 0
        consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        registry.consent = consent
        registry.apply(.processes([4242]), pane: UUID())
        XCTAssertEqual(prompts, 0, "always means the user has already answered this question")
        XCTAssertTrue(HookInstaller.status(id: "claude-code").installed)
    }

    /// The launch self-heal is **off under the test host**, and this is the case that says so: a
    /// suite run must never write a hook script or touch an agent's configuration file on the
    /// machine running it. (The rewriting itself is covered above and in `HookScriptTests`.)
    func testTheLaunchSelfHealDoesNothingUnderTheTestHost() {
        XCTAssertTrue(AppDelegate.isRunningTests)
        AppDelegate.ensureAgentHooksHealthy()
        XCTAssertFalse(FileManager.default.fileExists(atPath: HookInstaller.scriptPath()))
    }

    // MARK: Helpers

    /// A registry of its own, so the shared one's statuses are not disturbed, but pointed at the
    /// real `claude-code` rules — the ask is about a file, and the file is what it names.
    private func askRegistry(policy: String) throws -> AgentRegistry {
        let rules = try XCTUnwrap(AgentRegistry.shared.rules["claude-code"])
        let registry = AgentRegistry(rules: [rules], center: NoticeCenter(locator: NoticeLocator.unattached))
        registry.settings.enabled = ["claude-code"]
        registry.settings.autoInstallHooks = policy
        return registry
    }

    /// A process-level session of its own, because the hot-reload path under test is
    /// `AppSession.applyGlobalConfig` and running it on the test host's own session would
    /// reconfigure the screens every later case shares.
    ///
    /// It still reaches a handful of process-wide singletons on the way past (the same ones
    /// `WorkingDirectoryGateTests` restores): they are saved here and put back, or the next case
    /// in the suite inherits this one's settings. Its control server never binds — no socket path
    /// was injected, and under the test host that is what `AppSession.controlAllowed` refuses.
    private func withThrowawaySession(_ body: (AppSession) throws -> Void) throws {
        let registry = ScreenRegistry()
        let session = AppSession(screens: registry, themeManager: ThemeManager(),
                                 stateURL: root.appendingPathComponent("state.json"))
        let language = Localization.shared.language
        let browser = BrowserPaneView.settings
        let extensions = BrowserExtensionManager.shared.isEnabled
        let notices = NoticeCenter.shared.settings
        let consent = AgentRegistry.shared.consent
        defer {
            session.controlServer.stop()
            // The session pointed the process-wide event bus at its own registry, which is about
            // to be deallocated; the bus holds it weakly, so hand it back before the next case.
            if let app = NSApp.delegate as? AppDelegate {
                ControlEventBus.shared.attach(screens: app.screens)
            }
            _ = Localization.shared.setLanguage(language)
            BrowserPaneView.settings = browser
            BrowserExtensionManager.shared.isEnabled = extensions
            NoticeCenter.shared.settings = notices
            AgentRegistry.shared.consent = consent
        }
        try body(session)
    }

    private func scratch(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func configPath(_ id: String, in directory: String) -> String {
        let raw = AgentRegistry.shared.rules[id]?.install?.config ?? ""
        return (directory as NSString).appendingPathComponent((raw as NSString).lastPathComponent)
    }

    private func editor(id: String, in directory: String) throws -> HookConfigEditor {
        let rules = try XCTUnwrap(AgentRegistry.shared.rules[id])
        let install = try XCTUnwrap(rules.install)
        return HookConfigEditor(url: URL(fileURLWithPath: configPath(id, in: directory)),
                                shape: .of(install.shape),
                                command: try HookInstaller.commandString(agent: id))
    }

    /// The document the plan's table says each shape writes, built independently of the code that
    /// writes it.
    private func document(events: [String], shape: HookConfigShape, command: String) throws -> Data {
        var entry: [String: Any] = ["type": "command", "command": command,
                                    "timeout": shape.timeout]
        if shape.isAsync { entry["async"] = true }
        if let name = shape.entryName { entry["name"] = name }
        var hooks: [String: Any] = [:]
        for event in events { hooks[event] = [["hooks": [entry]] as [String: Any]] }
        return try HookConfigEditor.serialize(["hooks": hooks])
    }

    private func commands(in root: [String: Any], event: String) -> [String] {
        let groups = (root["hooks"] as? [String: Any])?[event] as? [Any] ?? []
        return groups.flatMap { group in
            ((group as? [String: Any])?["hooks"] as? [Any] ?? [])
                .compactMap { ($0 as? [String: Any])?["command"] as? String }
        }
    }

    private func matchers(in root: [String: Any], event: String) -> [String] {
        let groups = (root["hooks"] as? [String: Any])?[event] as? [Any] ?? []
        return groups.compactMap { ($0 as? [String: Any])?["matcher"] as? String }
    }

    private func ourEntryCount(in directory: String, id: String) -> Int {
        guard let root = try? editor(id: id, in: directory).read() ?? [:] else { return 0 }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return hooks.keys.reduce(0) { total, event in
            total + commands(in: root, event: event).filter { HookScript.isOurs(command: $0) }.count
        }
    }

    /// The invariant behind every case in this file: nothing the installer computed is outside the
    /// temporary root, so no test can reach the developer's own `~/.claude/settings.json`.
    private func assertUnderRoot(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(path.hasPrefix(root.path + "/"),
                      "\(path) is outside the test's root \(root.path)", file: file, line: line)
    }
}

/// **`hooks install | uninstall | status` over the control plane** — the gates core owns and this
/// package must not edit, tested from the outside exactly as an agent would hit them.
///
/// The confirmation is the point of most of these: `hooks install` is class `mutate` (it changes
/// nothing of the user's layout) and is still the one mutation that writes into another program's
/// configuration file, so it is confirmed like a destructive one, with a grant scope of its own per
/// agent.
@MainActor
final class ControlHooksCommandTests: XCTestCase {
    private var harness: ControlHarness!
    private var root: URL!
    private var savedSettings = AgentSettings()

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ControlHarness()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quickterm-hooks-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        HookInstaller.homeOverride = root
        if AgentRegistry.shared.rules.isEmpty {
            AgentRegistry.shared.reloadRulesForTesting(AgentRulesLoader.load(userDirectory: nil).rules)
        }
        savedSettings = AgentRegistry.shared.settings
        AgentRegistry.shared.settings.hookDetail = "lifecycle"
    }

    override func tearDownWithError() throws {
        AgentRegistry.shared.settings = savedSettings
        HookInstaller.homeOverride = nil
        harness.cleanup()
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var scratch: String { root.appendingPathComponent("agent").path }

    private func install(_ agent: String, args extra: [String: JSONValue] = [:]) throws -> ControlReply {
        var args: [String: JSONValue] = ["agent": .string(agent), "config-dir": .string(scratch)]
        for (key, value) in extra { args[key] = value }
        return try harness.run("hooks.install", args: args)
    }

    private func settingsPath(_ id: String) -> String {
        let raw = AgentRegistry.shared.rules[id]?.install?.config ?? ""
        return (scratch as NSString).appendingPathComponent((raw as NSString).lastPathComponent)
    }

    // MARK: The confirmation

    func testInstallAsksOncePerAgentAndNamesTheFile() throws {
        var prompts: [ControlConsent.Request] = []
        harness.consent.decisionStub = { request, reply in
            prompts.append(request)
            reply(.allow)
        }
        try install("claude-code").assertOK()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts.first?.cls, .mutate)
        XCTAssertEqual(prompts.first?.scope, "hooks.install:claude-code",
                       "one grant per agent: approving Claude Code's file is not approving Codex's")
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsPath("claude-code")))

        // Codex is a different file and therefore a different question.
        try install("codex").assertOK()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(prompts.last?.scope, "hooks.install:codex")

        // The same agent again in the same launch is already granted.
        AgentRegistry.shared.settings.hookDetail = "tools"
        try install("claude-code").assertOK()
        XCTAssertEqual(prompts.count, 2, "the grant is cached per (pid, agent)")
    }

    func testDenyingWritesNothing() throws {
        harness.consent.decisionStub = { _, reply in reply(.deny) }
        let reply = try install("claude-code")
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.denied.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsPath("claude-code")))
    }

    /// `all` is **one** prompt, because the grant scope core computes is the argument as written
    /// (`hooks.install:all`). Everything it then installs happens under that one approval — which
    /// is why the alert has to be the sentence the user reads, not a per-file one.
    func testAllInstallsEveryAgentThatHasAnInstaller() throws {
        var prompts: [ControlConsent.Request] = []
        harness.consent.decisionStub = { request, reply in
            prompts.append(request)
            reply(.allow)
        }
        let reply = try install("all")
        reply.assertOK()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts.first?.scope, "hooks.install:all")
        for id in HookInstaller.installableIDs {
            XCTAssertTrue(HookInstaller.status(id: id, configDir: scratch).installed, id)
        }
        // And the diff names every one of them.
        let changes = try harness.mutation(reply)["changes"]?.arrayValue ?? []
        XCTAssertEqual(changes.count, HookInstaller.installableIDs.count)
    }

    // MARK: The mutation envelope

    func testASecondInstallIsASilentNoopAndExitsSevenWhenAsked() throws {
        try install("claude-code").assertOK()
        let again = try install("claude-code")
        let payload = try harness.mutation(again)
        XCTAssertEqual(payload["changed"]?.boolValue, false)
        XCTAssertEqual(payload["applied"]?.boolValue, false)

        let strict = try install("claude-code", args: ["fail-if-noop": .bool(true)])
        XCTAssertFalse(strict.ok)
        XCTAssertEqual(strict.error?.code, ControlErrorCode.noop.rawValue)
    }

    func testDryRunReportsTheDiffAndWritesNothing() throws {
        let reply = try install("claude-code", args: ["dry-run": .bool(true)])
        let payload = try harness.mutation(reply)
        XCTAssertEqual(payload["dryRun"]?.boolValue, true)
        XCTAssertEqual(payload["changed"]?.boolValue, true)
        XCTAssertEqual(payload["applied"]?.boolValue, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsPath("claude-code")),
                       "a dry run must not create the agent's file")
    }

    func testUninstallNeedsNoConfirmation() throws {
        try install("claude-code").assertOK()
        var prompts = 0
        harness.consent.decisionStub = { _, reply in
            prompts += 1
            reply(.allow)
        }
        try harness.run("hooks.uninstall",
                        args: ["agent": .string("claude-code"), "config-dir": .string(scratch)]).assertOK()
        XCTAssertEqual(prompts, 0, "removing only our own entries is not a question")
        XCTAssertFalse(HookInstaller.status(id: "claude-code", configDir: scratch).installed)
    }

    // MARK: status

    func testStatusIsAReadAndReportsTheScriptAndEveryAgent() throws {
        try install("claude-code").assertOK()
        let reply = try harness.run("hooks.status", args: ["config-dir": .string(scratch)])
        reply.assertOK()
        let data = try XCTUnwrap(reply.data?.objectValue)
        XCTAssertEqual(data["schema"]?.stringValue, "quickterm.hooks/1")
        let script = try XCTUnwrap(data["script"]?.objectValue)
        XCTAssertEqual(script["path"]?.stringValue, HookInstaller.scriptPath())
        XCTAssertEqual(script["exists"]?.boolValue, true)

        let agents = try XCTUnwrap(data["agents"]?.arrayValue)
        XCTAssertEqual(agents.count, HookInstaller.installableIDs.count)
        let claude = try XCTUnwrap(agents.first { $0.objectValue?["id"]?.stringValue == "claude-code" }?.objectValue)
        XCTAssertEqual(claude["installed"]?.boolValue, true)
        XCTAssertEqual(claude["detail"]?.stringValue, "lifecycle")
        XCTAssertEqual(claude["configPath"]?.stringValue, settingsPath("claude-code"))

        // One agent by name.
        let one = try harness.run("hooks.status", args: ["agent": .string("codex"),
                                                         "config-dir": .string(scratch)])
        one.assertOK()
        XCTAssertEqual(try XCTUnwrap(one.data?.objectValue?["agents"]?.arrayValue).count, 1)
    }

    func testAnUnknownAgentIsRefusedWithCandidates() throws {
        let reply = try install("claude")
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertEqual(reply.error?.candidates?.contains("claude-code"), true)
        XCTAssertEqual(reply.error?.candidates?.contains("all"), true)
    }
}
