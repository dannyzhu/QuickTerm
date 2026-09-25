import XCTest
@testable import QuickTerm

/// The scripted scenarios really walk the state machine (they are what the UI is checked against
/// without a server).
@MainActor
final class UpdateSimulatorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UpdateSimulator.delayScale = 0.01   // 2 s steps become 20 ms
    }

    override func tearDown() {
        UpdateSimulator.delayScale = 1
        super.tearDown()
    }

    private func wait(until predicate: @escaping () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    func testHappyPathReachesInstallingAfterAnInstall() {
        let model = UpdateViewModel()
        UpdateSimulator.happyPath.simulate(with: model)
        XCTAssertTrue(wait { if case .updateAvailable = model.state { return true }; return false })
        model.state.confirm()
        XCTAssertTrue(wait { if case .downloading = model.state { return true }; return false })
        XCTAssertTrue(wait { if case .extracting = model.state { return true }; return false })
        XCTAssertTrue(wait { if case .installing = model.state { return true }; return false })
    }

    func testNotFoundAndErrorScenarios() {
        let model = UpdateViewModel()
        UpdateSimulator.notFound.simulate(with: model)
        XCTAssertTrue(wait { if case .notFound = model.state { return true }; return false })
        let other = UpdateViewModel()
        UpdateSimulator.error.simulate(with: other)
        XCTAssertTrue(wait { if case .error = other.state { return true }; return false })
    }

    func testStagedAndAutoUpdateScenarios() {
        let staged = UpdateViewModel()
        UpdateSimulator.staged.simulate(with: staged)
        guard case .installing(let i) = staged.state else { return XCTFail("staged goes straight to installing") }
        XCTAssertTrue(i.isAutoUpdate)
        XCTAssertNotNil(i.skip, "a staged update offers Skip")
        let auto = UpdateViewModel()
        UpdateSimulator.autoUpdate.simulate(with: auto)
        guard case .installing(let a) = auto.state else { return XCTFail() }
        XCTAssertNil(a.skip, "Sparkle's willInstallUpdateOnQuit hands over no reply block")
    }

    func testEveryScenarioIsNamedForTheEnvironmentVariable() {
        XCTAssertEqual(UpdateSimulator(rawValue: "happyPath"), .happyPath)
        XCTAssertEqual(UpdateSimulator.allCases.count, 8)
    }
}
