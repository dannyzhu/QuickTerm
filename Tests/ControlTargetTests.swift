import XCTest
@testable import QuickTerm

/// Addressing syntax (Phase 1 §1). **Pure value types, no window needed** — the same layer as
/// ScrollingStripTests.
final class ControlTargetTests: XCTestCase {
    private func parse(_ text: String) throws -> ControlTarget {
        try ControlTarget.parse(text)
    }

    // MARK: Each of the three segments on its own

    func testBareIntegerIsScreenNotPane() throws {
        // Pane handles always carry a type prefix (t7/b3), so a bare integer is always a screen.
        // This has to be nailed down: otherwise `-t 2` is a screen one moment and a pane the next,
        // and an agent's scripts would randomly hit the wrong thing
        XCTAssertEqual(try parse("2"), ControlTarget(screen: .index(2), workspace: nil, pane: nil))
        XCTAssertEqual(try parse("@current"), ControlTarget(screen: .current, workspace: nil, pane: nil))
        XCTAssertEqual(try parse("@primary"), ControlTarget(screen: .primary, workspace: nil, pane: nil))
    }

    func testScreenWorkspacePane() throws {
        XCTAssertEqual(try parse("2:3.t7"),
                       ControlTarget(screen: .index(2), workspace: .index(3), pane: .handle("t7")))
        XCTAssertEqual(try parse("2:3"),
                       ControlTarget(screen: .index(2), workspace: .index(3), pane: nil))
        XCTAssertEqual(try parse("2:"), ControlTarget(screen: .index(2), workspace: nil, pane: nil))
        XCTAssertEqual(try parse("2:.t7"),
                       ControlTarget(screen: .index(2), workspace: nil, pane: .handle("t7")))
        XCTAssertEqual(try parse(":3.t7"),
                       ControlTarget(screen: nil, workspace: .index(3), pane: .handle("t7")))
        XCTAssertEqual(try parse(":3"), ControlTarget(screen: nil, workspace: .index(3), pane: nil),
                       "once the screen is explicitly omitted, the right of the colon must start "
                       + "at the workspace (it must not be read as screen 3 again)")
    }

    func testWorkspaceIsOneBasedOnTheWire() throws {
        // The internal activeIndex is 0-based; the CLI only ever sees 1-based (matching Cmd+1..0)
        guard case .index(let n)? = try parse(":1").workspace else {
            return XCTFail("expected a workspace to parse out")
        }
        XCTAssertEqual(n, 1)
        XCTAssertThrowsError(try parse(":0"), "0 is not a valid workspace index") { error in
            XCTAssertEqual(error as? ControlTarget.ParseError, .badPane("0"))
        }
    }

    func testPaneForms() throws {
        XCTAssertEqual(try parse("t7").pane, .handle("t7"))
        XCTAssertEqual(try parse("b12").pane, .handle("b12"))
        XCTAssertEqual(try parse("@focused").pane, .focused)
        XCTAssertEqual(try parse("@self").pane, .selfPane)
        XCTAssertEqual(try parse("@left").pane, .direction(.left))
        XCTAssertEqual(try parse("@next").pane, .cycle(next: true))
        XCTAssertEqual(try parse("#9c1b4e2f").pane, .id("9c1b4e2f"))
        XCTAssertEqual(try parse("#9C1B4E2F").pane, .id("9c1b4e2f"), "uuid matching is case-insensitive")
    }

    func testBareUUIDIsPaneAndScreenNeedsColon() throws {
        let uuid = "3f2a9c1b-0000-0000-0000-000000000000"
        XCTAssertEqual(try parse("#\(uuid)").pane, .id(uuid))
        XCTAssertNil(try parse("#\(uuid)").screen)
        XCTAssertEqual(try parse("#\(uuid):").screen, .id(uuid))
        XCTAssertNil(try parse("#\(uuid):").pane)
    }

    // MARK: A separator inside a predicate must not be split off (a trap we actually hit)

    func testPredicateColonIsNotAScreenSeparator() throws {
        XCTAssertEqual(try parse("title:~nvim").pane, .title("nvim"))
        XCTAssertNil(try parse("title:~nvim").screen)
        XCTAssertEqual(try parse("kind:browser").pane, .kind("browser"))
        XCTAssertEqual(try parse("role:file-manager").pane, .role("file-manager"))
    }

    func testPredicateDotIsNotAWorkspaceSeparator() throws {
        XCTAssertEqual(try parse("cwd:/Users/danny/a.b").pane, .cwd("/Users/danny/a.b"))
        XCTAssertEqual(try parse("title:~foo.bar").pane, .title("foo.bar"),
                       "a dot inside the regex must not be taken for the workspace.pane separator")
    }

    func testPredicateWithExplicitScreen() throws {
        let target = try parse("2:3.title:~dev")
        XCTAssertEqual(target.screen, .index(2))
        XCTAssertEqual(target.workspace, .index(3))
        XCTAssertEqual(target.pane, .title("dev"))
    }

    // MARK: Round-trip

    func testRoundTrip() throws {
        for text in ["2", "@current", "@primary", "2:3", "2:3.t7", "2:.t7", ":3", ":3.t7",
                     "t7", "b3", "@focused", "@self", "@left", "@next",
                     "#9c1b4e2f", "#9c1b4e2f:", "title:~nvim", "cwd:/a/b.c",
                     "kind:terminal", "role:file-manager", "2:3.title:~dev"] {
            let parsed = try parse(text)
            XCTAssertEqual(parsed.text, text, "`\(text)` does not round-trip")
            XCTAssertEqual(try parse(parsed.text), parsed, "`\(text)` does not re-parse to the same value")
        }
    }

    // MARK: Adversarial input (agents hallucinate arguments)

    func testRejectsControlCharacters() {
        XCTAssertThrowsError(try parse("t7\u{0}"), "NUL has to be rejected")
        XCTAssertThrowsError(try parse("title:~a\nb"), "a bare newline would break NDJSON framing")
    }

    func testRejectsGarbage() {
        for bad in ["", "   ", "@nope", "#zz", "#abc", "unknown:foo", "title:nvim", "kind:tty"] {
            XCTAssertThrowsError(try parse(bad), "`\(bad)` should error out instead of guessing")
        }
    }

    func testUUIDPrefixNeedsFourHexDigits() {
        XCTAssertThrowsError(try parse("#abc"), "a uuid prefix shorter than 4 hex digits matches too much by accident")
        XCTAssertNoThrow(try parse("#abcd"))
    }

    func testEmptyTargetIsNotEmptyStruct() throws {
        XCTAssertTrue(ControlTarget().isEmpty)
        XCTAssertFalse(try parse("t7").isEmpty)
    }
}
