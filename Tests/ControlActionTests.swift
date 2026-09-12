import XCTest
@testable import QuickTerm

/// Completeness and safety classification of the command table.
/// This group of cases exists for exactly one reason: **adding a WMAction without exposing it in
/// the CLI has to turn the build red**. (kitty's `kitten @ action` and the "there is only one
/// path" rule in yabai/skhd both buy you the same guarantee.)
final class ControlActionTests: XCTestCase {
    func testEveryWMActionIsExposedAndClassified() {
        let docs = ControlCommandTable.actionDocs
        XCTAssertEqual(docs.count, WMAction.allCases.count)
        XCTAssertEqual(Set(docs.map(\.name)), Set(WMAction.allCases.map(\.rawValue)),
                       "the actions in the command table must match WMAction.allCases exactly")
        for doc in docs {
            XCTAssertFalse(doc.helpZH.isEmpty, "\(doc.name) is missing its Chinese help text")
            XCTAssertTrue([.read, .mutate, .destructive, .interactive, .sensitive].contains(doc.cls))
        }
    }

    func testActionCountIsStillSixtySeven() {
        // The spec says 67 (22 of them hide inside multi-case-per-line declarations). If the
        // number moves, somebody has to come and change this line on purpose and review the new
        // action's classification while they are at it — rather than an unclassified action
        // quietly slipping in
        XCTAssertEqual(WMAction.allCases.count, 67)
    }

    func testInteractiveActionsAreRefused() {
        // The ones that open an overlay panel or pop up a menu leave the UI stuck halfway when
        // they are driven over the socket (NSMenu.popUp goes further and blocks the main thread)
        let expected: Set<WMAction> = [.themePicker, .backgroundMenu, .keybindingHelp,
                                       .mainMenu, .openSettings, .webExtensions]
        XCTAssertEqual(ControlCommandTable.interactiveActions, expected)
        for action in expected {
            XCTAssertEqual(ControlCommandTable.actionClass(action), .interactive, "\(action.rawValue)")
            XCTAssertFalse(ControlCommandTable.interactiveHint(action).isEmpty,
                           "\(action.rawValue) must name a concrete place to go when it is refused")
        }
    }

    func testDestructiveActionsPromptOnce() {
        XCTAssertEqual(ControlCommandTable.destructiveActions, [.closePane])
        XCTAssertEqual(ControlCommandTable.actionClass(.closePane), .destructive)
        XCTAssertTrue(ControlCommandClass.destructive.requiresConsent)
        XCTAssertFalse(ControlCommandClass.read.requiresConsent)
    }

    func testEverythingElseIsPlainMutation() {
        for action in WMAction.allCases
        where !ControlCommandTable.interactiveActions.contains(action)
            && !ControlCommandTable.destructiveActions.contains(action) {
            XCTAssertEqual(ControlCommandTable.actionClass(action), .mutate, "\(action.rawValue)")
        }
    }

    func testBrowserOnlyActionsAreFlagged() {
        // The classification uses the code's own `browserOnly` predicate
        // (rawValue.hasPrefix("web-")), not a second hand-copied list — a copied list is
        // guaranteed to drift
        let browserOnly = ControlCommandTable.actionDocs.filter(\.browserOnly).map(\.name)
        XCTAssertEqual(Set(browserOnly), Set(WMAction.allCases.filter(\.browserOnly).map(\.rawValue)))
        XCTAssertFalse(browserOnly.isEmpty)
        XCTAssertTrue(browserOnly.allSatisfy { $0.hasPrefix("web-") })
    }

    func testWorkspaceActionsExposeOneBasedIndex() {
        for doc in ControlCommandTable.actionDocs {
            let action = WMAction(rawValue: doc.name)
            XCTAssertEqual(doc.workspace, action?.workspaceIndex.map { $0 + 1 },
                           "\(doc.name): the CLI only ever sees 1-based indices; the 0-based internal index never leaks")
        }
        XCTAssertEqual(ControlCommandTable.actionDocs.first { $0.name == "goto-workspace-3" }?.workspace, 3)
    }

    // MARK: The command table itself

    func testCommandTableIsSelfConsistent() {
        XCTAssertEqual(Set(ControlCommandTable.commands.map(\.name)).count,
                       ControlCommandTable.commands.count, "duplicate command name")
        for spec in ControlCommandTable.commands {
            XCTAssertFalse(spec.summary.isEmpty, "\(spec.name) has no summary")
            XCTAssertFalse(spec.examples.isEmpty, "\(spec.name) has no examples")
            XCTAssertTrue(spec.examples.allSatisfy { $0.hasPrefix("quickterm ") },
                          "\(spec.name) examples must be whole command lines you can copy-paste as-is")
            let positional = spec.args.filter(\.positional)
            XCTAssertLessThanOrEqual(positional.count, 2,
                                     "\(spec.name) has too many positional arguments; readability collapses")
            for arg in spec.args where arg.kind == .enumeration {
                XCTAssertNotNil(arg.values, "\(spec.name): enum argument \(arg.name) does not list its allowed values")
            }
        }
    }

    func testQueryCommandsEmbedAnOutputSample() {
        // wezterm's --help leaves this out, so an agent burns one call per session just to learn
        // the shape of the output
        for name in ["state", "list", "get"] {
            XCTAssertNotNil(ControlCommandTable.command(name)?.outputSample,
                            "the help for \(name) must embed a real sample of its output")
        }
    }

    func testHelpTextIsLearnableInOneRead() {
        let help = Help.root(cliVersion: "1.5.8")
        XCTAssertLessThan(help.split(separator: "\n").count, 120, "the root help has to be readable by a model in one pass")
        XCTAssertTrue(help.contains("EXAMPLES"))
        XCTAssertTrue(help.contains("describe --json"), "the root help must point an agent at describe")
        for spec in ControlCommandTable.commands where spec.group == nil {
            XCTAssertTrue(help.contains(spec.name), "the root help is missing command \(spec.name)")
        }
        // The noun-verb layer is listed by group in the root help (one line per group): the whole
        // verb string for a group has to appear verbatim. A missing verb means "not in the help,
        // but in the implementation" — an agent would never discover it
        for group in ControlCommandTable.groups {
            let verbs = ControlCommandTable.commands(inGroup: group).map(\.verb).joined(separator: " | ")
            XCTAssertTrue(help.contains("\(group)"), "the root help is missing command group \(group)")
            XCTAssertTrue(help.contains(verbs),
                          "the \(group) line in the root help is missing verbs: it should contain \(verbs)")
            XCTAssertTrue(Help.group(group).contains(verbs.split(separator: "|").first!.trimmingCharacters(in: .whitespaces)),
                          "quickterm \(group) --help must list its verbs")
        }
        for spec in ControlCommandTable.commands {
            let sub = Help.command(spec)
            XCTAssertTrue(sub.hasSuffix(spec.examples.last!), "the help for \(spec.name) must end with EXAMPLES")
            XCTAssertTrue(sub.contains(spec.cli),
                          "the help for \(spec.name) must spell out the command-line form \(spec.cli)")
        }
    }

    // MARK: Argument parsing (driven off that same table)

    /// A global flag that takes a value has to work **before** the command name too
    /// (`quickterm --socket /p state`): if the value is not consumed along with the flag, the next
    /// round takes `/p` for the command name and answers with "unknown command /p"
    func testGlobalFlagWithAValueBeforeTheCommandName() throws {
        guard case .command(let parsed) = try Args.parse(["--socket", "/tmp/x.sock", "state"]) else {
            return XCTFail("should parse as a command")
        }
        XCTAssertEqual(parsed.spec.name, "state")
        XCTAssertEqual(parsed.socketOverride, "/tmp/x.sock")

        guard case .command(let targeted) = try Args.parse(["-t", "t7", "pane", "set", "--zoom", "on"]) else {
            return XCTFail("should parse as a command")
        }
        XCTAssertEqual(targeted.spec.name, "pane.set")
        XCTAssertEqual(targeted.target, "t7")
        XCTAssertEqual(targeted.args["zoom"]?.stringValue, "on")
    }

    /// Noun-verb: `pane new` and the wire name `pane.new` are one and the same command
    func testParsesNounVerbCommands() throws {
        guard case .command(let parsed) = try Args.parse(
            ["pane", "new", "--kind", "browser", "--url", "http://x", "--env", "A=1", "--env", "B=2",
             "--dry-run", "--fail-if-noop"]) else {
            return XCTFail("should parse as a command")
        }
        XCTAssertEqual(parsed.spec.name, "pane.new")
        XCTAssertEqual(parsed.spec.cli, "pane new")
        XCTAssertEqual(parsed.args["kind"]?.stringValue, "browser")
        XCTAssertEqual(parsed.args["env"]?.arrayValue?.compactMap { $0.stringValue }, ["A=1", "B=2"],
                       "--env is repeatable: comma separation would cut a value that contains a comma of its own")
        XCTAssertEqual(parsed.args[ControlCommandTable.Flag.dryRun]?.boolValue, true)
        XCTAssertEqual(parsed.args[ControlCommandTable.Flag.failIfNoop]?.boolValue, true)

        guard case .groupHelp(let group) = try Args.parse(["pane", "--help"]) else {
            return XCTFail("`quickterm pane --help` should print the listing for that group")
        }
        XCTAssertEqual(group, "pane")

        XCTAssertThrowsError(try Args.parse(["pane"]), "the noun on its own must error out and list the verbs")
        XCTAssertThrowsError(try Args.parse(["pane", "frobnicate"]))
    }

    func testParsesPositionalAndFlags() throws {
        guard case .command(let parsed) = try Args.parse(["list", "panes", "--fields", "handle,cwd"]) else {
            return XCTFail("should parse as a command")
        }
        XCTAssertEqual(parsed.spec.name, "list")
        XCTAssertEqual(parsed.args["what"]?.stringValue, "panes")
        XCTAssertEqual(parsed.args["fields"]?.stringValue, "handle,cwd")
    }

    func testParsesTargetAndBooleans() throws {
        guard case .command(let parsed) = try Args.parse(["action", "toggle-zoom", "-t", "2:3.t7", "--precise"]) else {
            return XCTFail("should parse as a command")
        }
        XCTAssertEqual(parsed.target, "2:3.t7")
        XCTAssertEqual(parsed.args["name"]?.stringValue, "toggle-zoom")
        XCTAssertEqual(parsed.args["precise"]?.boolValue, true)
    }

    func testRejectsUnknownCommandAndFlagAndEnum() {
        XCTAssertThrowsError(try Args.parse(["frobnicate"]))
        XCTAssertThrowsError(try Args.parse(["state", "--nope"]))
        XCTAssertThrowsError(try Args.parse(["list", "tabs"]),
                             "an out-of-range enum value for list must be rejected on the spot")
        XCTAssertThrowsError(try Args.parse(["list"]),
                             "a missing positional argument must error out, never quietly default to something")
    }

    func testActionListSkipsPositional() throws {
        guard case .command(let parsed) = try Args.parse(["action", "--list"]) else {
            return XCTFail("should parse as a command")
        }
        XCTAssertEqual(parsed.args["list"]?.boolValue, true)
        XCTAssertNil(parsed.args["name"])
    }

    @MainActor
    func testActionSuggestionsForHallucinatedNames() {
        let suggestions = ControlCommandRunner.suggestions(for: "close_pane")
        XCTAssertTrue(suggestions.contains("close-pane"),
                      "a mistyped action name must come back with the closest candidates: \(suggestions)")
    }
}
