import XCTest
@testable import QuickTerm

/// **How an OSC 7501 report reads in the agent model** (spec decisions 9, 11 and 14).
///
/// Pure functions only: the mapping table, whose report it is, and which of a pane's statuses the
/// band shows. The registry's use of them is in `AgentRegistryTests`.
@MainActor
final class ProgramStatusMapperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func report(_ state: ProgramStatusReport.State, kind: ProgramStatusReport.Kind? = nil,
                        id: String = "", app: String? = nil) -> ProgramStatusReport {
        ProgramStatusReport(state: state, kind: kind, progress: nil,
                            id: id.split(separator: "/").map(String.init),
                            app: app, title: nil, message: nil)
    }

    private func record(_ state: ProgramStatusReport.State, id: String = "", at offset: TimeInterval,
                        kind: ProgramStatusReport.Kind? = nil) -> ProgramStatusStore.Record {
        ProgramStatusStore.Record(report: report(state, kind: kind, id: id), foregroundGroup: 100,
                                  updatedAt: now.addingTimeInterval(offset))
    }

    // MARK: Decision 9

    func testMappingTable() {
        let table: [(ProgramStatusReport.State, ProgramStatusReport.Kind?, AgentState, AgentDetail?)] = [
            (.idle, nil, .idle, nil),
            (.working, nil, .working, nil),
            (.done, nil, .done, nil),
            (.error, nil, .error, nil),
            (.blocked, .permission, .blocked, .approval),
            (.blocked, .question, .blocked, .input),
            (.blocked, .auth, .blocked, .auth),
            (.blocked, nil, .blocked, .input),
        ]
        for (state, kind, expectedState, expectedDetail) in table {
            let mapped = ProgramStatusMapper.state(of: report(state, kind: kind))
            XCTAssertEqual(mapped.0, expectedState, "\(state) \(String(describing: kind))")
            XCTAssertEqual(mapped.1, expectedDetail, "\(state) \(String(describing: kind))")
        }
        XCTAssertEqual(AgentDetail.auth.coarse, .blocked, "auth is a kind of waiting for the human")
    }

    // MARK: Decision 11

    func testOwnerByAppIdAndByProcessName() {
        let rules = Dictionary(uniqueKeysWithValues:
            AgentRulesLoader.load(userDirectory: nil).rules.map { ($0.id, $0) })
        XCTAssertEqual(ProgramStatusMapper.owner(of: report(.working, app: "codex"), rules: rules), "codex")
        XCTAssertEqual(ProgramStatusMapper.owner(of: report(.working, app: "claude-code"), rules: rules),
                       "claude-code")
        XCTAssertEqual(ProgramStatusMapper.owner(of: report(.working, app: "claude"), rules: rules),
                       "claude-code", "a process name names its rule")
        XCTAssertNil(ProgramStatusMapper.owner(of: report(.working, app: "cargo"), rules: rules))
        XCTAssertNil(ProgramStatusMapper.owner(of: report(.working), rules: rules),
                     "no app is a generic program")
    }

    // MARK: Decision 14

    func testWinnerOrdersByUrgencyThenByRecency() {
        let records = [
            record(.idle, id: "i", at: 5), record(.done, id: "d", at: 4),
            record(.working, id: "w", at: 3), record(.error, id: "e", at: 2),
            record(.blocked, id: "b", at: 1),
        ]
        var remaining = records
        for expected in ["b", "e", "w", "d", "i"] {
            guard case .program(let winner)? = ProgramStatusMapper.winner(agent: nil, records: remaining)
            else { return XCTFail("expected a record to win") }
            XCTAssertEqual(winner.report.id, [expected])
            remaining.removeAll { $0.report.id == [expected] }
        }
        XCTAssertNil(ProgramStatusMapper.winner(agent: nil, records: []))

        // A tie goes to the most recent.
        let tie = [record(.working, id: "old", at: 1), record(.working, id: "new", at: 2)]
        guard case .program(let newest)? = ProgramStatusMapper.winner(agent: nil, records: tie)
        else { return XCTFail("expected a record to win") }
        XCTAssertEqual(newest.report.id, ["new"])
    }

    /// A `cargo` waiting for input outranks a hook-tracked agent that is merely working; the
    /// agent outranks a record that is less urgent than it.
    func testBlockedRecordOutranksAHookAgentThatIsWorking() {
        let agent = AgentStatus(agent: "codex", name: "Codex", state: .working, detail: .tool,
                                since: now, evidence: .hook, lastHookAt: now.addingTimeInterval(10))
        let blocked = record(.blocked, id: "cargo", at: 0, kind: .question)
        guard case .program(let won)? = ProgramStatusMapper.winner(agent: agent, records: [blocked])
        else { return XCTFail("the blocked record should win") }
        XCTAssertEqual(won.report.id, ["cargo"])

        let done = record(.done, id: "cargo", at: 20)
        guard case .agent(let status)? = ProgramStatusMapper.winner(agent: agent, records: [done])
        else { return XCTFail("the working agent should win over a done record") }
        XCTAssertEqual(status, agent)
        guard case .agent? = ProgramStatusMapper.winner(agent: agent, records: [])
        else { return XCTFail("an agent alone wins") }
    }
}
