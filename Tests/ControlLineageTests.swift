import Darwin
import XCTest
@testable import QuickTerm

/// **The one factual claim the lineage rule rests on** (plan §2.2): a process started inside a
/// pane reaches QuickTerm through that pane's own shell, and that shell is what
/// `NoticeOrigin.lineageRoot` names. A process in another pane answers with a different root, and
/// a process outside QuickTerm's tree answers with none — which is what makes "a forger may add a
/// notice and never remove one" enforceable rather than aspirational.
///
/// These cases use real processes, because the whole point of the lineage is that it is a fact
/// about the kernel's process table and not about anything we write down ourselves.
final class ControlLineageTests: XCTestCase {
    // MARK: parent(of:)

    func testTheParentOfThisProcessIsItsRealParent() {
        XCTAssertEqual(ControlLineage.parent(of: getpid()), getppid())
    }

    func testAnImpossiblePidHasNoParent() {
        XCTAssertNil(ControlLineage.parent(of: 0))
        XCTAssertNil(ControlLineage.parent(of: -1))
        // Above the default `kern.maxproc` ceiling: nothing can be there to read.
        XCTAssertNil(ControlLineage.parent(of: 9_999_999))
    }

    // MARK: root(of:under:)

    func testTheRootIsTheDirectChildThePidDescendsFrom() throws {
        let (shell, grandchild, cleanup) = try spawnShellWithBackgroundChild()
        defer { cleanup() }

        XCTAssertEqual(ControlLineage.root(of: grandchild, under: getpid()),
                       shell.processIdentifier,
                       "the root of a grandchild is the child of ours it descends from — the "
                       + "pane's shell, in the app")
        XCTAssertEqual(ControlLineage.root(of: shell.processIdentifier, under: getpid()),
                       shell.processIdentifier,
                       "a direct child is its own root")
    }

    func testAProcessOutsideOurSubtreeHasNoRoot() {
        // Our own parent is emphatically not our descendant, and neither are we.
        XCTAssertNil(ControlLineage.root(of: getppid(), under: getpid()))
        XCTAssertNil(ControlLineage.root(of: getpid(), under: getpid()))
        XCTAssertNil(ControlLineage.root(of: 1, under: getpid()), "launchd descends from nobody")
    }

    func testTheWalkStopsAtMaxDepth() throws {
        let (shell, grandchild, cleanup) = try spawnShellWithBackgroundChild()
        defer { cleanup() }

        // The chain is two steps long (grandchild → shell → us), so a budget of one cannot reach
        // the top. Asserted on a two-deep chain rather than on the 33 processes it would take to
        // exhaust the real default: what is being pinned is that the budget is spent per step and
        // that running out answers nil rather than walking on to launchd.
        XCTAssertNil(ControlLineage.root(of: grandchild, under: getpid(), maxDepth: 1))
        XCTAssertEqual(ControlLineage.root(of: grandchild, under: getpid(), maxDepth: 2),
                       shell.processIdentifier)
    }

    // MARK: Ownership — a root-owned ancestor is a hop, not a wall

    /// The live defect this case exists for. Ghostty spawns each pane's shell through
    /// `/usr/bin/login`, which runs as uid 0, and `proc_pidinfo(PROC_PIDTBSDINFO)` answers EPERM
    /// for a process owned by another user — so a walk built on it stopped at that `login`, one
    /// hop short of QuickTerm's own child. `NoticeOrigin.lineageRoot` was then nil for *every*
    /// hook that ran inside a pane, and a `Stop` from a process that is no descendant of
    /// QuickTerm at all resolved a hook-posted alarm instead of answering `origin_mismatch`.
    ///
    /// Walking this process's own ancestry catches that on any host: whatever else is in the
    /// chain, launchd is pid 1 and it runs as root.
    func testEveryAncestorResolvesEvenWhenItIsOwnedByRoot() {
        var current = getpid()
        var chain: [pid_t] = [current]
        var rootOwned: [pid_t] = []
        var reachedLaunchd = false

        for _ in 0..<64 {
            let owner = uid(of: current)
            if owner == 0 { rootOwned.append(current) }
            guard let parent = ControlLineage.parent(of: current) else {
                XCTFail("the walk stopped at pid \(current), owned by uid "
                        + "\(owner.map { String($0) } ?? "unknown") — chain so far \(chain). A "
                        + "process owned by another user has to be one more hop, not a wall.")
                return
            }
            chain.append(parent)
            if current == 1 {
                XCTAssertEqual(parent, 0, "the parent of launchd is the kernel, pid 0")
                reachedLaunchd = true
                break
            }
            current = parent
        }

        XCTAssertTrue(reachedLaunchd,
                      "the walk should climb from this process all the way to launchd: \(chain)")
        XCTAssertFalse(rootOwned.isEmpty,
                       "pid 1 alone makes this true on every host — if it is empty the case is no "
                       + "longer exercising ownership at all")
    }

    /// The same fact in one assertion, for when the walk above fails and it helps to know where.
    func testLaunchdAnswersAlthoughItRunsAsRoot() {
        XCTAssertEqual(uid(of: 1), 0, "launchd runs as root on every macOS host")
        XCTAssertEqual(ControlLineage.parent(of: 1), 0,
                       "pid 1 is owned by root and still has to answer; that it did not is exactly "
                       + "why a hook inside a pane came back with no lineage")
    }

    // MARK: Fixture

    /// The owner of `pid`, read here rather than through the code under test: ownership is not
    /// what these cases assert, it is what explains a failure ("stopped at pid 1, uid 0").
    private func uid(of pid: pid_t) -> uid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        return info.kp_eproc.e_ucred.cr_uid
    }

    /// `/bin/sh` with a background `sleep`, which gives us a two-deep chain under this process.
    /// The pid comes back through a file rather than a pipe so that nothing here can block on a
    /// read that never arrives.
    private func spawnShellWithBackgroundChild() throws -> (shell: Process, grandchild: pid_t,
                                                            cleanup: () -> Void) {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qt-lineage-\(UUID().uuidString.prefix(8))")
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 30 & echo $! > '\(file.path)'; wait"]
        shell.standardOutput = Pipe()
        shell.standardError = Pipe()
        try shell.run()

        var grandchild: pid_t = 0
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                grandchild = pid
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let cleanup = {
            if grandchild > 0 { kill(grandchild, SIGKILL) }
            if shell.isRunning { shell.terminate() }
            shell.waitUntilExit()
            try? FileManager.default.removeItem(at: file)
        }
        guard grandchild > 0 else {
            cleanup()
            throw XCTSkip("the shell never reported its background child")
        }
        return (shell, grandchild, cleanup)
    }
}
