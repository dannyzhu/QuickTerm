import XCTest
@testable import QuickTerm

/// **The order of the two gates in front of `hooks install`** (plan §2.6, owner decision Q2).
///
/// `hooks install` is the one mutation that writes into another program's configuration file, so
/// it is confirmed like a destructive command. That confirmation costs the user something — they
/// have to switch to QuickTerm and read a sentence about a file — and it is worth spending only on
/// a request that could actually go through.
///
/// An agent id that can never install is therefore refused **before** the sheet goes up, the same
/// way a `send-text` payload that cannot be delivered is validated before anyone is asked: the
/// caller gets `bad_request` with the ids that do exist, and nobody is called over to approve
/// editing a file that no rule file names. Without that ordering the CLI answers
/// `confirmation_required` (exit 4) to a plain typo, and answers it *after* leaving a sheet on the
/// user's screen.
///
/// Like the rest of the hook cases, nothing here goes near the real `~`: `homeOverride` is a
/// temporary directory and every command carries `--config-dir` into it.
@MainActor
final class ControlHooksConsentTests: XCTestCase {
    private var root: URL!
    private var savedSettings = AgentSettings()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quickterm-hooks-consent-\(UUID().uuidString)")
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
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// A temporary directory for the agent's own file, so a regression that gets past the refusal
    /// writes there and not into anybody's `~/.claude`.
    private var scratch: String { root.appendingPathComponent("agent").path }

    /// The gap this case was written for: the id was validated **after** the consent gate, so a
    /// typo put a sheet in front of the user first.
    func testAnAgentIDThatCanNeverInstallIsRefusedBeforeTheUserIsAsked() throws {
        let harness = try ControlHarness(allowDestructive: false)
        defer { harness.cleanup() }
        var prompts: [ControlConsent.Request] = []
        harness.consent.decisionStub = { request, reply in
            prompts.append(request)
            reply(.allow)
        }

        let reply = try harness.run("hooks.install", args: ["agent": .string("claude"),
                                                            "config-dir": .string(scratch)])
        XCTAssertTrue(prompts.isEmpty,
                      "a confirmation for an id that can never install is a question with no useful answer")
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue)
        XCTAssertEqual(reply.error?.candidates?.contains("claude-code"), true)
        XCTAssertEqual(reply.error?.candidates?.contains("all"), true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch))
    }

    /// The same thing seen from the CLI's side. With nobody to answer the sheet the caller used to
    /// be told `denied` here (and, in the app, `confirmation_required` — exit 4 — once the sheet
    /// timed out): two different answers to what is always the same fact, that there is no such
    /// agent. The refusal must not depend on what the user does with a dialog.
    func testTheRefusalDoesNotDependOnAnybodyAnsweringTheSheet() throws {
        let harness = try ControlHarness(allowDestructive: false)
        defer { harness.cleanup() }

        let reply = try harness.run("hooks.install", args: ["agent": .string("claude"),
                                                            "config-dir": .string(scratch)])
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, ControlErrorCode.badRequest.rawValue,
                       "an unknown agent is a bad request, never a denial or a missing confirmation")
    }

    /// The valid ids still go through the gate exactly as before — the check added in front of the
    /// confirmation must not become a second, stricter rule about who may install.
    func testAKnownAgentStillAsksAndInstalls() throws {
        let harness = try ControlHarness(allowDestructive: false)
        defer { harness.cleanup() }
        var prompts: [ControlConsent.Request] = []
        harness.consent.decisionStub = { request, reply in
            prompts.append(request)
            reply(.allow)
        }

        try harness.run("hooks.install", args: ["agent": .string("claude-code"),
                                                "config-dir": .string(scratch)]).assertOK()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts.first?.scope, "hooks.install:claude-code")
        XCTAssertTrue(HookInstaller.status(id: "claude-code", configDir: scratch).installed)
    }
}
