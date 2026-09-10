import XCTest
@testable import QuickTerm

/// 命令表的完整性与安全分级。
/// 这一组用例的存在理由只有一个：**新加一个 WMAction 却没在 CLI 里露出来，必须让构建变红**。
/// （kitty 的 `kitten @ action` 与 yabai/skhd 的"只有一条路径"给的都是这个保证。）
final class ControlActionTests: XCTestCase {
    func testEveryWMActionIsExposedAndClassified() {
        let docs = ControlCommandTable.actionDocs
        XCTAssertEqual(docs.count, WMAction.allCases.count)
        XCTAssertEqual(Set(docs.map(\.name)), Set(WMAction.allCases.map(\.rawValue)),
                       "命令表里的动作必须与 WMAction.allCases 完全一致")
        for doc in docs {
            XCTAssertFalse(doc.helpZH.isEmpty, "\(doc.name) 缺中文说明")
            XCTAssertTrue([.read, .mutate, .destructive, .interactive, .sensitive].contains(doc.cls))
        }
    }

    func testActionCountIsStillSixtySeven() {
        // 设计稿写的是 67（多 case 一行的写法藏了 22 个）。数字变了要有人主动来改这一行，
        // 顺便复核新动作的分级——而不是悄悄多出一个未分级的动作
        XCTAssertEqual(WMAction.allCases.count, 67)
    }

    func testInteractiveActionsAreRefused() {
        // 打开覆盖面板 / 弹出菜单的这些，经 socket 执行会把 UI 卡在半路（NSMenu.popUp 还会直接占住主线程）
        let expected: Set<WMAction> = [.themePicker, .backgroundMenu, .keybindingHelp,
                                       .mainMenu, .openSettings, .webExtensions]
        XCTAssertEqual(ControlCommandTable.interactiveActions, expected)
        for action in expected {
            XCTAssertEqual(ControlCommandTable.actionClass(action), .interactive, "\(action.rawValue)")
            XCTAssertFalse(ControlCommandTable.interactiveHint(action).isEmpty,
                           "\(action.rawValue) 被拒绝时必须给出具体去处")
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
        // 分级用的是代码自己的 `browserOnly` 谓词（rawValue.hasPrefix("web-")），
        // 不是另抄一份清单——抄的那份必然漂移
        let browserOnly = ControlCommandTable.actionDocs.filter(\.browserOnly).map(\.name)
        XCTAssertEqual(Set(browserOnly), Set(WMAction.allCases.filter(\.browserOnly).map(\.rawValue)))
        XCTAssertFalse(browserOnly.isEmpty)
        XCTAssertTrue(browserOnly.allSatisfy { $0.hasPrefix("web-") })
    }

    func testWorkspaceActionsExposeOneBasedIndex() {
        for doc in ControlCommandTable.actionDocs {
            let action = WMAction(rawValue: doc.name)
            XCTAssertEqual(doc.workspace, action?.workspaceIndex.map { $0 + 1 },
                           "\(doc.name)：CLI 只见 1 起序号，0 起的内部下标绝不外泄")
        }
        XCTAssertEqual(ControlCommandTable.actionDocs.first { $0.name == "goto-workspace-3" }?.workspace, 3)
    }

    // MARK: 命令表本身

    func testCommandTableIsSelfConsistent() {
        XCTAssertEqual(Set(ControlCommandTable.commands.map(\.name)).count,
                       ControlCommandTable.commands.count, "命令重名")
        for spec in ControlCommandTable.commands {
            XCTAssertFalse(spec.summary.isEmpty, "\(spec.name) 缺 summary")
            XCTAssertFalse(spec.examples.isEmpty, "\(spec.name) 缺例子")
            XCTAssertTrue(spec.examples.allSatisfy { $0.hasPrefix("quickterm ") },
                          "\(spec.name) 的例子必须是可以直接复制粘贴的整行命令")
            let positional = spec.args.filter(\.positional)
            XCTAssertLessThanOrEqual(positional.count, 2, "\(spec.name) 位置参数过多，可读性会塌")
            for arg in spec.args where arg.kind == .enumeration {
                XCTAssertNotNil(arg.values, "\(spec.name) 的枚举参数 \(arg.name) 没写可选值")
            }
        }
    }

    func testQueryCommandsEmbedAnOutputSample() {
        // wezterm 的 --help 缺这一项，于是 agent 每个会话都要浪费一次调用去认输出形状
        for name in ["state", "list", "get"] {
            XCTAssertNotNil(ControlCommandTable.command(name)?.outputSample,
                            "\(name) 的帮助必须内嵌一段真实输出样例")
        }
    }

    func testHelpTextIsLearnableInOneRead() {
        let help = Help.root(cliVersion: "1.5.8")
        XCTAssertLessThan(help.split(separator: "\n").count, 120, "根帮助要能被模型一次读完")
        XCTAssertTrue(help.contains("EXAMPLES"))
        XCTAssertTrue(help.contains("describe --json"), "根帮助必须把 agent 指向 describe")
        for spec in ControlCommandTable.commands {
            XCTAssertTrue(help.contains(spec.name), "根帮助漏了命令 \(spec.name)")
            let sub = Help.command(spec)
            XCTAssertTrue(sub.hasSuffix(spec.examples.last!), "\(spec.name) 的帮助必须以 EXAMPLES 结尾")
        }
    }

    // MARK: 参数解析（由同一张表驱动）

    func testParsesPositionalAndFlags() throws {
        guard case .command(let parsed) = try Args.parse(["list", "panes", "--fields", "handle,cwd"]) else {
            return XCTFail("应解析成命令")
        }
        XCTAssertEqual(parsed.spec.name, "list")
        XCTAssertEqual(parsed.args["what"]?.stringValue, "panes")
        XCTAssertEqual(parsed.args["fields"]?.stringValue, "handle,cwd")
    }

    func testParsesTargetAndBooleans() throws {
        guard case .command(let parsed) = try Args.parse(["action", "toggle-zoom", "-t", "2:3.t7", "--precise"]) else {
            return XCTFail("应解析成命令")
        }
        XCTAssertEqual(parsed.target, "2:3.t7")
        XCTAssertEqual(parsed.args["name"]?.stringValue, "toggle-zoom")
        XCTAssertEqual(parsed.args["precise"]?.boolValue, true)
    }

    func testRejectsUnknownCommandAndFlagAndEnum() {
        XCTAssertThrowsError(try Args.parse(["frobnicate"]))
        XCTAssertThrowsError(try Args.parse(["state", "--nope"]))
        XCTAssertThrowsError(try Args.parse(["list", "tabs"]), "list 的枚举值要当场拒绝")
        XCTAssertThrowsError(try Args.parse(["list"]), "缺位置参数要报错，不能默认成什么")
    }

    func testActionListSkipsPositional() throws {
        guard case .command(let parsed) = try Args.parse(["action", "--list"]) else {
            return XCTFail("应解析成命令")
        }
        XCTAssertEqual(parsed.args["list"]?.boolValue, true)
        XCTAssertNil(parsed.args["name"])
    }

    @MainActor
    func testActionSuggestionsForHallucinatedNames() {
        let suggestions = ControlCommandRunner.suggestions(for: "close_pane")
        XCTAssertTrue(suggestions.contains("close-pane"), "打错的动作名要给出最接近的候选：\(suggestions)")
    }
}
