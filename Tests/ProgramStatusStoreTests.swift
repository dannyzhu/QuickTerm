import XCTest
@testable import QuickTerm

/// **The per-pane OSC 7501 records** (spec decisions 3, 5 and 20).
///
/// Every case but the last builds a store of its own with a hand-driven clock, so nothing here
/// depends on the shared store the test host's real surfaces can reach. The heartbeat is not
/// running in a test host; `checkForeground` is driven directly with a closure that answers from
/// a dictionary.
@MainActor
final class ProgramStatusStoreTests: XCTestCase {
    // MARK: Helpers

    private var now = Date(timeIntervalSinceReferenceDate: 0)

    private func makeStore() -> ProgramStatusStore {
        ProgramStatusStore(clock: { [unowned self] in self.now })
    }

    private func report(_ state: ProgramStatusReport.State, _ id: String = "",
                        kind: ProgramStatusReport.Kind? = nil, progress: Int? = nil,
                        app: String? = nil, title: String? = nil,
                        message: String? = nil) -> ProgramStatusReport {
        ProgramStatusReport(
            state: state, kind: kind, progress: progress,
            id: id.split(separator: "/").map(String.init),
            app: app, title: title, message: message)
    }

    /// The pane's record ids as slash paths, in the store's order.
    private func ids(_ store: ProgramStatusStore, _ pane: UUID) -> [String] {
        store.records(pane: pane).map { $0.report.id.joined(separator: "/") }
    }

    /// Count `onChange` calls per pane.
    private func countChanges(_ store: ProgramStatusStore) -> () -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        store.onChange = { counts[$0, default: 0] += 1 }
        return { counts }
    }

    // MARK: Records (decision 3)

    func testReportReplacesItsRecord() {
        let store = makeStore()
        let pane = UUID()
        store.receive(report(.working, "build", progress: 10, app: "cargo", title: "Build"),
                      pane: pane, foregroundGroup: 100)
        now += 1
        store.receive(report(.working, "build", progress: 40), pane: pane, foregroundGroup: 100)

        let records = store.records(pane: pane)
        XCTAssertEqual(records.count, 1)
        // Replaced completely: `app` and `title` were not repeated, so they are gone.
        XCTAssertEqual(records.first?.report, report(.working, "build", progress: 40))
        XCTAssertEqual(records.first?.foregroundGroup, 100)
        XCTAssertEqual(records.first?.updatedAt, now)
    }

    func testRootAndNamedRecordsAreSeparate() {
        let store = makeStore()
        let pane = UUID()
        store.receive(report(.working), pane: pane, foregroundGroup: 100)
        store.receive(report(.working, "a"), pane: pane, foregroundGroup: 100)
        XCTAssertEqual(ids(store, pane), ["", "a"])
    }

    func testClearRemovesTheSubtreeOnly() {
        let store = makeStore()
        let pane = UUID()
        for id in ["a", "a/b", "a/b/c", "a/c", "ab", "x"] {
            store.receive(report(.working, id), pane: pane, foregroundGroup: 100)
        }
        store.receive(report(.clear, "a/b"), pane: pane, foregroundGroup: 100)
        XCTAssertEqual(ids(store, pane), ["a", "a/c", "ab", "x"])

        // Segment-wise: clearing `a` takes `a/c` with it and leaves `ab`.
        store.receive(report(.clear, "a"), pane: pane, foregroundGroup: 100)
        XCTAssertEqual(ids(store, pane), ["ab", "x"])
    }

    func testClearWithoutIdRemovesAll() {
        let store = makeStore()
        let pane = UUID()
        let other = UUID()
        store.receive(report(.working), pane: pane, foregroundGroup: 100)
        store.receive(report(.done, "a"), pane: pane, foregroundGroup: 100)
        store.receive(report(.working, "a"), pane: other, foregroundGroup: 200)
        store.receive(report(.clear), pane: pane, foregroundGroup: 100)
        XCTAssertTrue(store.records(pane: pane).isEmpty)
        XCTAssertEqual(ids(store, other), ["a"], "another pane's records are not touched")
    }

    func testClearNeverBecomesARecord() {
        let store = makeStore()
        let pane = UUID()
        store.receive(report(.clear, "nothing/here"), pane: pane, foregroundGroup: 100)
        XCTAssertTrue(store.records(pane: pane).isEmpty)
    }

    func testCapDropsTheLeastRecentlyUpdated() {
        let store = makeStore()
        let pane = UUID()
        for i in 0..<ProgramStatusStore.cap {
            store.receive(report(.working, "r\(i)"), pane: pane, foregroundGroup: 100)
            now += 1
        }
        // Touch r0, so r1 is now the least recently updated.
        store.receive(report(.working, "r0", progress: 5), pane: pane, foregroundGroup: 100)
        now += 1
        XCTAssertEqual(store.records(pane: pane).count, 64)

        store.receive(report(.working, "r64"), pane: pane, foregroundGroup: 100)
        let kept = Set(ids(store, pane))
        XCTAssertEqual(kept.count, 64)
        XCTAssertFalse(kept.contains("r1"))
        XCTAssertTrue(kept.contains("r0"))
        XCTAssertTrue(kept.contains("r64"))

        // Replacing an existing id at the cap evicts nothing.
        store.receive(report(.done, "r2"), pane: pane, foregroundGroup: 100)
        XCTAssertEqual(Set(ids(store, pane)), kept)
    }

    // MARK: Clearing on exit (decision 5)

    func testRecordDropsWhenTheForegroundGroupChanges() {
        let store = makeStore()
        let pane = UUID()
        for state: ProgramStatusReport.State in [.working, .blocked, .idle, .done, .error] {
            store.receive(report(state, state.rawValue), pane: pane, foregroundGroup: 100)
        }
        // A record whose group was never known cannot be judged, so it stays.
        store.receive(report(.working, "unknown"), pane: pane, foregroundGroup: nil)

        store.checkForeground { $0 == pane ? 100 : nil }
        XCTAssertEqual(store.records(pane: pane).count, 6, "same group: nothing drops")

        store.checkForeground { _ in nil }
        XCTAssertEqual(store.records(pane: pane).count, 6, "current group unknown: nothing drops")

        store.checkForeground { $0 == pane ? 200 : nil }
        XCTAssertEqual(ids(store, pane), ["done", "error", "unknown"])
    }

    func testReportTypedAtThePromptSurvivesTheHeartbeat() {
        let store = makeStore()
        let pane = UUID()
        let shell: Int32 = 100
        // `printf` is a builtin, so the foreground group is the shell's own.
        store.receive(report(.working, app: "cargo"), pane: pane, foregroundGroup: shell)
        store.checkForeground { _ in shell }
        store.checkForeground { _ in shell }
        XCTAssertEqual(store.records(pane: pane).count, 1)

        // The next command takes the foreground: the record's job is over.
        store.checkForeground { _ in 300 }
        XCTAssertTrue(store.records(pane: pane).isEmpty)
    }

    func testAReportFromANewForegroundGroupDropsTheOldJobsRecords() {
        let store = makeStore()
        let pane = UUID()
        store.receive(report(.working, "old"), pane: pane, foregroundGroup: 100)
        store.receive(report(.done, "finished"), pane: pane, foregroundGroup: 100)
        // The check also runs on every report (decision 5).
        store.receive(report(.working, "new"), pane: pane, foregroundGroup: 200)
        XCTAssertEqual(ids(store, pane), ["finished", "new"])
    }

    func testPromptStartDropsWorkingBlockedIdle() {
        let store = makeStore()
        let pane = UUID()
        for state: ProgramStatusReport.State in [.working, .blocked, .idle, .done, .error] {
            store.receive(report(state, state.rawValue), pane: pane, foregroundGroup: 100)
        }
        let changes = countChanges(store)
        store.promptStarted(pane: pane)
        XCTAssertEqual(ids(store, pane), ["done", "error"])
        XCTAssertEqual(changes()[pane], 1)

        // bash can send two prompt starts per prompt: the second finds nothing to drop.
        store.promptStarted(pane: pane)
        XCTAssertEqual(ids(store, pane), ["done", "error"])
        XCTAssertEqual(changes()[pane], 1)
    }

    func testChildExitDropsWorkingBlockedIdle() {
        let store = makeStore()
        let pane = UUID()
        for state: ProgramStatusReport.State in [.working, .blocked, .idle, .done, .error] {
            store.receive(report(state, state.rawValue), pane: pane, foregroundGroup: 100)
        }
        let changes = countChanges(store)
        store.childExited(pane: pane)
        XCTAssertEqual(ids(store, pane), ["done", "error"])
        XCTAssertEqual(changes()[pane], 1)

        // The notification and the heartbeat backstop can both report the same exit.
        store.childExited(pane: pane)
        XCTAssertEqual(ids(store, pane), ["done", "error"])
        XCTAssertEqual(changes()[pane], 1)
    }

    // MARK: Pane life cycle

    func testResetClearsAll() {
        let store = makeStore()
        let pane = UUID()
        store.receive(report(.done, "a"), pane: pane, foregroundGroup: 100)
        store.receive(report(.error, "b"), pane: pane, foregroundGroup: 100)
        let changes = countChanges(store)
        store.reset(pane: pane)
        XCTAssertTrue(store.records(pane: pane).isEmpty)
        XCTAssertEqual(changes()[pane], 1)
        store.reset(pane: pane)
        XCTAssertEqual(changes()[pane], 1, "a reset with nothing to drop is not a change")
    }

    func testPaneClosedForgetsThePane() {
        let store = makeStore()
        let pane = UUID()
        let other = UUID()
        store.receive(report(.done), pane: pane, foregroundGroup: 100)
        store.receive(report(.done), pane: other, foregroundGroup: 200)
        XCTAssertEqual(store.panes, [pane, other] as Set)
        store.paneClosed(pane)
        XCTAssertTrue(store.records(pane: pane).isEmpty)
        XCTAssertEqual(store.panes, [other] as Set)
    }

    func testRemoveAllDropsEveryPane() {
        let store = makeStore()
        let a = UUID()
        let b = UUID()
        store.receive(report(.working), pane: a, foregroundGroup: 100)
        store.receive(report(.working, "x"), pane: a, foregroundGroup: 100)
        store.receive(report(.done), pane: b, foregroundGroup: 200)
        let changes = countChanges(store)
        store.removeAll()
        XCTAssertTrue(store.panes.isEmpty)
        XCTAssertEqual(changes(), [a: 1, b: 1])
    }

    // MARK: Change notification

    func testOnChangeFiresOncePerChange() {
        let store = makeStore()
        let pane = UUID()
        let changes = countChanges(store)

        store.receive(report(.working, "a", progress: 1), pane: pane, foregroundGroup: 100)
        XCTAssertEqual(changes()[pane], 1, "a new record")

        now += 5
        store.receive(report(.working, "a", progress: 1), pane: pane, foregroundGroup: 100)
        XCTAssertEqual(changes()[pane], 1, "an identical repeat is not a change")
        XCTAssertEqual(store.records(pane: pane).first?.updatedAt, now,
                       "but it still counts as an update")

        store.receive(report(.working, "a", progress: 2), pane: pane, foregroundGroup: 100)
        XCTAssertEqual(changes()[pane], 2, "a replaced record")

        store.receive(report(.working, "b"), pane: pane, foregroundGroup: 100)
        store.receive(report(.working, "c"), pane: pane, foregroundGroup: 100)
        XCTAssertEqual(changes()[pane], 4)

        // A new group drops a and b and adds d: one report, one change.
        store.receive(report(.working, "d"), pane: pane, foregroundGroup: 200)
        XCTAssertEqual(ids(store, pane), ["d"])
        XCTAssertEqual(changes()[pane], 5)

        store.receive(report(.clear, "nothing"), pane: pane, foregroundGroup: 200)
        XCTAssertEqual(changes()[pane], 5, "a clear that removes nothing")
        store.receive(report(.clear, "d"), pane: pane, foregroundGroup: 200)
        XCTAssertEqual(changes()[pane], 6)

        store.receive(report(.working, "e"), pane: pane, foregroundGroup: 200)
        store.checkForeground { _ in 200 }
        XCTAssertEqual(changes()[pane], 7, "a heartbeat that drops nothing")
        store.checkForeground { _ in 300 }
        XCTAssertEqual(changes()[pane], 8)
        store.checkForeground { _ in 300 }
        XCTAssertEqual(changes()[pane], 8)
    }

    // MARK: The switch (decision 20)

    func testTurningTheFeatureOffClearsEveryRecord() {
        let previous = ProgramStatusRouter.isEnabled
        let store = ProgramStatusStore.shared
        let pane = UUID()
        addTeardownBlock { @MainActor in
            ProgramStatusRouter.isEnabled = previous
            store.paneClosed(pane)
        }
        ProgramStatusRouter.isEnabled = true
        ProgramStatusRouter.report(report(.working), pane: pane, foregroundGroup: 100)
        XCTAssertEqual(store.records(pane: pane).count, 1)

        ProgramStatusRouter.isEnabled = false
        XCTAssertTrue(store.records(pane: pane).isEmpty)
        ProgramStatusRouter.report(report(.working), pane: pane, foregroundGroup: 100)
        XCTAssertTrue(store.records(pane: pane).isEmpty, "off: reports are ignored")
    }
}
