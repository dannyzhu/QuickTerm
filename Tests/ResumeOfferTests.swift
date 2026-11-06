import AppKit
import GhosttyKit
import XCTest
@testable import QuickTerm

/// The resume offer in a restored pane's agent band (session restore, spec decisions 13, 16, 19,
/// 20): when it is offered, when it types its line, and what takes it away.
///
/// All timing goes through `FakeScheduler`, so no case here waits for real time, except the one
/// engine case at the end, which proves the line actually runs in a real shell.
@MainActor
final class ResumeOfferTests: XCTestCase {
    private var language: AppLanguage!

    override func setUpWithError() throws {
        try super.setUpWithError()
        language = Localization.shared.language
        Localization.shared.setLanguage(.en)
    }

    override func tearDown() {
        Localization.shared.setLanguage(language)
        super.tearDown()
    }

    private static let claudeText = """
    id = "claude-code"
    name = "Claude Code"
    process = ["claude"]

    [resume]
    session = ["claude", "--resume", "{session}"]
    latest  = ["claude", "--continue"]
    """

    private var claude: AgentRules { get throws { try AgentRules.parse(Self.claudeText) } }
    private let withSession = AgentResumeRecord(agent: "claude-code", session: "a1b2c3d4")

    /// A clock and a timer queue the test moves by hand.
    @MainActor
    final class FakeScheduler {
        private(set) var now: TimeInterval = 0
        private var tasks: [(at: TimeInterval, seq: Int, work: () -> Void)] = []
        private var seq = 0

        var scheduler: ResumeOffer.Scheduler {
            ResumeOffer.Scheduler(now: { [unowned self] in now },
                                  after: { [unowned self] delay, work in
                                      seq += 1
                                      tasks.append((now + delay, seq, work))
                                  })
        }

        /// Run every task due up to `time`, in time order, with the clock at each task's time.
        func advance(to time: TimeInterval) {
            while let next = tasks.filter({ $0.at <= time + 1e-9 })
                .min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) {
                tasks.removeAll { $0.seq == next.seq }
                now = max(now, next.at)
                next.work()
            }
            now = max(now, time)
        }

        var pending: Int { tasks.count }
    }

    /// An offer over a screen that is a function of the fake clock, recording every line it sends.
    private func offer(_ fake: FakeScheduler, record: AgentResumeRecord? = nil,
                       screen: @escaping (TimeInterval) -> String,
                       sent: @escaping (String) -> Void) throws -> ResumeOffer {
        try XCTUnwrap(ResumeOffer(record: record ?? withSession, rules: try claude,
                                  snapshot: { screen(fake.now) }, send: sent,
                                  scheduler: fake.scheduler))
    }

    // MARK: Readiness and sending

    func testAcceptWhenReadySendsOnce() throws {
        let fake = FakeScheduler()
        var sent: [String] = []
        let offer = try offer(fake, screen: { $0 < 1 ? "restored" : "restored\n$ " }, sent: { sent.append($0) })
        XCTAssertFalse(offer.isReady, "nothing has changed since the restore")
        fake.advance(to: 1)
        offer.observe()
        XCTAssertFalse(offer.isReady, "the prompt just appeared: not quiet yet")
        fake.advance(to: 1.3)
        offer.observe()
        XCTAssertTrue(offer.isReady, "changed, then quiet for 0.3 s")

        offer.accept()
        XCTAssertEqual(sent, ["'claude' '--resume' 'a1b2c3d4'\r"], "ready: the line goes at once")
        offer.accept()
        fake.advance(to: 10)
        XCTAssertEqual(sent.count, 1, "a second accept sends nothing")
        XCTAssertEqual(fake.pending, 0, "nothing is left polling after the send")
    }

    func testAcceptBeforeReadyWaitsForIt() throws {
        let fake = FakeScheduler()
        var sent: [String] = []
        let offer = try offer(fake, screen: { $0 < 0.95 ? "restored" : "restored\n$ " }, sent: { sent.append($0) })
        offer.accept()
        XCTAssertTrue(sent.isEmpty, "the shell has not printed anything yet")
        fake.advance(to: 1.2)
        XCTAssertTrue(sent.isEmpty, "the prompt is up but not quiet for 0.3 s yet")
        fake.advance(to: 1.5)
        XCTAssertEqual(sent, ["'claude' '--resume' 'a1b2c3d4'\r"])
        fake.advance(to: 10)
        XCTAssertEqual(sent.count, 1)
    }

    /// Output at t = 0, 0.2 and 0.4 after the click: the last change is at 0.4, so it is ready at
    /// 0.7, not before. (The click is at fake time 1, so the restore-time baseline comes first.)
    func testReadyNeedsQuietOutput() throws {
        let fake = FakeScheduler()
        var sent: [String] = []
        // In tenths of a second, rounded: the poll times are sums of 0.1 and do not land exactly.
        let offer = try offer(fake, screen: { t in
            let tick = Int((t * 10).rounded()) - 10
            return tick < 0 ? "base" : tick < 2 ? "a" : tick < 4 ? "ab" : "abc"
        }, sent: { sent.append($0) })
        fake.advance(to: 1)
        offer.accept()
        fake.advance(to: 1.65)
        XCTAssertTrue(sent.isEmpty, "0.25 s after the last change is not quiet")
        fake.advance(to: 1.75)
        XCTAssertEqual(sent.count, 1, "0.3 s after the last change it is")
    }

    func testAcceptSendsAfterMaxWaitWithNoOutput() throws {
        let fake = FakeScheduler()
        var sent: [String] = []
        let offer = try offer(fake, screen: { _ in "restored" }, sent: { sent.append($0) })
        offer.accept()
        fake.advance(to: ResumeOffer.maxWait - 0.05)
        XCTAssertTrue(sent.isEmpty, "the screen never changed")
        fake.advance(to: ResumeOffer.maxWait)
        XCTAssertEqual(sent.count, 1, "5 s after the click it is sent anyway")
        fake.advance(to: 20)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(fake.pending, 0)
    }

    // MARK: Dismissal

    func testTypingDismissesTheOffer() throws {
        // The offer itself: dismissed before or after the click, it never sends.
        let fake = FakeScheduler()
        var sent: [String] = []
        let early = try offer(fake, screen: { _ in "restored" }, sent: { sent.append($0) })
        early.dismiss()
        early.accept()
        let late = try offer(fake, screen: { _ in "restored" }, sent: { sent.append($0) })
        late.accept()
        late.dismiss()
        fake.advance(to: 20)
        XCTAssertTrue(sent.isEmpty, "a dismissed offer never sends")

        // The pane: the first keystroke clears the button and the record.
        let pane = try terminal()
        let shown = try offer(fake, screen: { _ in "restored" }, sent: { sent.append($0) })
        pane.restoredAgentResume = withSession
        pane.resumeOffer = shown
        pane.keyDown(with: try escape())
        XCTAssertNil(pane.resumeOffer, "typing takes the button away")
        XCTAssertNil(pane.restoredAgentResume)
        shown.accept()

        // Clicked, then typed before the shell was ready: the line is not typed after the user's keys.
        let waiting = try offer(fake, screen: { _ in "restored" }, sent: { sent.append($0) })
        pane.resumeOffer = waiting
        pane.acceptResumeOffer()
        XCTAssertNil(pane.resumeOffer, "the button goes away on the click")
        pane.keyDown(with: try escape())
        fake.advance(to: 40)
        XCTAssertTrue(sent.isEmpty, "\(sent)")
    }

    /// A Command shortcut is not typing into the pane (copying from the restored screen is a likely
    /// first action), except a paste, which puts text on the command line the line would join.
    func testCommandShortcutsKeepTheOfferButPasteDismissesIt() throws {
        let fake = FakeScheduler()
        let pane = try terminal()
        pane.restoredAgentResume = withSession
        pane.resumeOffer = try offer(fake, screen: { _ in "restored" }, sent: { _ in })
        let copy = try key("c", keyCode: 8, flags: .command)
        pane.keyDown(with: copy)
        XCTAssertNotNil(pane.resumeOffer, "Cmd+C copies; it types nothing into the shell")
        XCTAssertNotNil(pane.restoredAgentResume)

        // Paste is decided before the event reaches the engine; the decision is tested on its own
        // so the test never pastes the developer's real clipboard into a shell.
        let paste = try key("v", keyCode: 9, flags: .command)
        XCTAssertTrue(pane.keyAnswersResumeOffer(paste), "Cmd+V pastes into the shell")
        XCTAssertFalse(pane.keyAnswersResumeOffer(copy))
        XCTAssertTrue(pane.keyAnswersResumeOffer(try key("c", keyCode: 8, flags: .control)),
                      "Ctrl+C goes to the shell")
        XCTAssertTrue(pane.keyAnswersResumeOffer(try escape()))

        // The menu's Paste (and any other path that pastes) dismisses too.
        pane.noteResumeOfferPaste()
        XCTAssertNil(pane.resumeOffer)
        XCTAssertNil(pane.restoredAgentResume)
    }

    /// Ruling: closing the pane calls off a clicked offer that is still waiting for the shell, so
    /// the pending wait never depends on the weak reference alone.
    func testClosingThePaneCallsOffAWaitingOffer() throws {
        let fake = FakeScheduler()
        var sent: [String] = []
        let controller = try XCTUnwrap(try XCTUnwrap(NSApp.delegate as? AppDelegate).controller)
        let pane = controller.newSurface(workingDirectory: NSTemporaryDirectory())
        XCTAssertTrue(controller.insertNewPane(pane))
        pane.resumeOffer = try offer(fake, screen: { _ in "restored" }, sent: { sent.append($0) })
        pane.acceptResumeOffer()
        controller.removeFromAnyWorkspace(pane)
        fake.advance(to: 20)
        XCTAssertTrue(sent.isEmpty, "a closed pane is never typed into: \(sent)")

        // The ordinary close (Cmd+W, the shell exiting) goes through closePane.
        let other = controller.newSurface(workingDirectory: NSTemporaryDirectory())
        XCTAssertTrue(controller.insertNewPane(other))
        other.resumeOffer = try offer(fake, screen: { _ in "restored" }, sent: { sent.append($0) })
        other.acceptResumeOffer()
        controller.closePane(other, confirmIfNeeded: false, animated: false)
        controller.flushPendingCloses()
        fake.advance(to: 40)
        XCTAssertTrue(sent.isEmpty, "\(sent)")
        controller.removeFromAnyWorkspace(other)
    }

    func testANewAgentDismissesTheOffer() throws {
        let fake = FakeScheduler()
        var sent: [String] = []
        let pane = try terminal()
        pane.restoredAgentResume = withSession
        pane.resumeOffer = try offer(fake, screen: { _ in "restored" }, sent: { sent.append($0) })
        pane.setAgentStatus(nil)
        XCTAssertNotNil(pane.resumeOffer, "no status is not a new agent")
        pane.setAgentStatus(AgentStatus(agent: "codex", name: "Codex", state: .working,
                                        since: Date(), evidence: .hook))
        XCTAssertNil(pane.resumeOffer, "an agent started in the pane: the button goes away")
        XCTAssertNil(pane.restoredAgentResume)
        fake.advance(to: 20)
        XCTAssertTrue(sent.isEmpty)
    }

    func testAcceptClearsTheButtonAndTheRecord() throws {
        let fake = FakeScheduler()
        var sent: [String] = []
        let pane = try terminal()
        pane.restoredAgentResume = withSession
        pane.resumeOffer = try offer(fake, screen: { _ in "restored" }, sent: { sent.append($0) })
        pane.acceptResumeOffer()
        XCTAssertNil(pane.resumeOffer)
        XCTAssertNil(pane.restoredAgentResume)
        fake.advance(to: ResumeOffer.maxWait)
        XCTAssertEqual(sent, ["'claude' '--resume' 'a1b2c3d4'\r"], "the clicked offer still sends")
    }

    // MARK: The band

    func testBandShowsTheButtonOnlyWithoutALiveAgent() {
        let live = AgentStatus(agent: "claude-code", name: "Claude Code", state: .idle,
                               since: Date(), evidence: .hook)
        let label = "Claude Code · Resume last session"
        XCTAssertEqual(PaneAgentStrip.resumeLabel(offer: label, status: nil, isTerminal: true), label)
        XCTAssertNil(PaneAgentStrip.resumeLabel(offer: label, status: live, isTerminal: true),
                     "a live agent owns the band")
        XCTAssertNil(PaneAgentStrip.resumeLabel(offer: label, status: nil, isTerminal: false),
                     "never on a browser pane")
        XCTAssertNil(PaneAgentStrip.resumeLabel(offer: nil, status: nil, isTerminal: true))

        XCTAssertTrue(PaneAgentStrip.draws(status: nil, title: nil, infoStrip: true, stripHeight: 16,
                                           isTerminal: true, resume: true),
                      "no status and no title: the band still draws for the button")
        XCTAssertFalse(PaneAgentStrip.draws(status: nil, title: nil, infoStrip: false, stripHeight: 16,
                                            isTerminal: true, resume: true),
                       "with the band switched off there is nowhere to draw it")

        let bare = PaneAgentStrip.Model.resumeOnly(title: nil, resume: label)
        XCTAssertEqual(bare.resume, label)
        XCTAssertEqual(bare.text, "")
        XCTAssertEqual(bare.glyph, "")
        XCTAssertEqual(bare.elapsed, "")
        XCTAssertEqual(bare.tone, .neutral)
        XCTAssertEqual(PaneAgentStrip.Model.resumeOnly(title: "build", resume: label).text, "build",
                       "a named pane keeps its name next to the button")
        XCTAssertNil(PaneAgentStrip.Model.make(status: live, now: Date(), language: .en).resume)
        XCTAssertNil(PaneAgentStrip.Model.titleOnly(title: "build").resume)
    }

    // MARK: When there is an offer

    func testOfferLabels() throws {
        let fake = FakeScheduler()
        let named = try offer(fake, screen: { _ in "" }, sent: { _ in })
        XCTAssertEqual(named.label, RestoreText.resumeButton(agent: "Claude Code"))
        XCTAssertEqual(named.label, "Claude Code · Resume last session")
        let latest = try offer(fake, record: AgentResumeRecord(agent: "claude-code", session: nil),
                               screen: { _ in "" }, sent: { _ in })
        XCTAssertEqual(latest.label, RestoreText.resumeLatest(agent: "Claude Code"))
        XCTAssertEqual(latest.line, "'claude' '--continue'\r")
        XCTAssertEqual(named.help, RestoreText.resumeHelp)
    }

    func testNoOfferWhenTheDirectoryIsGone() throws {
        let rules = ["claude-code": try claude]
        let settings = ConfigStore.Settings()
        XCTAssertNotNil(restoredOffer(withSession, settings: settings, directoryGone: false, rules: rules))
        XCTAssertNil(restoredOffer(withSession, settings: settings, directoryGone: true, rules: rules),
                     "spec decision 20: the conversation cannot be resumed there")
    }

    func testOfferWithContentOff() throws {
        let rules = ["claude-code": try claude]
        var settings = ConfigStore.Settings()
        settings.restoreContent = false
        settings.restoreAgentResume = true
        XCTAssertNotNil(restoredOffer(withSession, settings: settings, directoryGone: false, rules: rules),
                        "content and agent-resume are independent")
        settings.restoreAgentResume = false
        XCTAssertNil(restoredOffer(withSession, settings: settings, directoryGone: false, rules: rules))
    }

    func testNoOfferWithoutARuleOrACommand() throws {
        let settings = ConfigStore.Settings()
        let rules = ["claude-code": try claude]
        XCTAssertNil(restoredOffer(nil, settings: settings, directoryGone: false, rules: rules))
        XCTAssertNil(restoredOffer(AgentResumeRecord(agent: "gone-agent", session: "a1b2c3d4"),
                                   settings: settings, directoryGone: false, rules: rules),
                     "no rule file for the agent")
        XCTAssertNil(restoredOffer(AgentResumeRecord(agent: "claude-code", session: "x'; rm -rf ~"),
                                   settings: settings, directoryGone: false, rules: rules),
                     "the session id is checked again before anything is offered")
        let noResume = try AgentRules.parse("""
        id = "gemini"
        name = "Gemini"
        process = ["gemini"]
        """)
        XCTAssertNil(restoredOffer(AgentResumeRecord(agent: "gemini", session: nil), settings: settings,
                                   directoryGone: false, rules: ["gemini": noResume]),
                     "an agent with no resume form")
    }

    /// The launch path: a pane decoded from the archive gets its offer from the archived record.
    func testDecodedPaneOffersItsAgent() throws {
        try XCTSkipIf(AgentRegistry.shared.rules["claude-code"] == nil, "bundled rules not loaded")
        let decoded = try decodedPane(pwd: NSTemporaryDirectory())
        XCTAssertEqual(decoded.resumeOffer?.label, "Claude Code · Resume last session")
        XCTAssertEqual(decoded.resumeOffer?.line, "'claude' '--resume' 'a1b2c3d4'\r")

        let gone = try decodedPane(pwd: NSTemporaryDirectory() + "quickterm-no-such-\(UUID().uuidString)")
        XCTAssertNil(gone.resumeOffer, "the saved directory is gone: no button")
    }

    // MARK: Engine

    /// The line typed into a real shell runs: a bracketed paste keeps a CR inside the paste as
    /// text, so the Return has to arrive as a keystroke of its own.
    func testTheResumeLineRunsInTheShell() throws {
        let pane = try terminal()
        let echo = try AgentRules.parse("""
        id = "echo"
        name = "Echo"
        process = ["echo"]

        [resume]
        session = ["echo", "{session}"]
        """)
        let token = "QTRESUME\(Int.random(in: 100_000...999_999))ok"
        pane.resumeOffer = try XCTUnwrap(ResumeOffer(
            record: AgentResumeRecord(agent: "echo", session: token), rules: echo,
            snapshot: { [weak pane] in pane?.viewportSnapshot() ?? "" }, send: { [weak pane] in pane?.typeResumeLine($0) }))
        pane.acceptResumeOffer()
        let deadline = Date().addingTimeInterval(20)
        var ran = false
        while !ran, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let lines = (pane.controlReadText(tag: GHOSTTY_POINT_VIEWPORT) ?? "").components(separatedBy: "\n")
            ran = lines.contains { $0.trimmingCharacters(in: .whitespaces) == token }
        }
        XCTAssertTrue(ran, pane.controlReadText(tag: GHOSTTY_POINT_VIEWPORT) ?? "<no text>")
    }

    // MARK: Helpers

    private func restoredOffer(_ record: AgentResumeRecord?, settings: ConfigStore.Settings,
                               directoryGone: Bool, rules: [String: AgentRules]) -> ResumeOffer? {
        let fake = FakeScheduler()
        return ResumeOffer.forRestoredPane(record: record, settings: settings, directoryGone: directoryGone,
                                           rules: rules, snapshot: { "" }, send: { _ in },
                                           scheduler: fake.scheduler)
    }

    private func terminal() throws -> Ghostty.SurfaceView {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = NSTemporaryDirectory()
        return Ghostty.SurfaceView(try XCTUnwrap(appDelegate.ghostty.app), baseConfig: config)
    }

    private func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false, keyCode: keyCode))
    }

    private func escape() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53))
    }

    /// One pane through the archive and back, the way a launch decodes it.
    private func decodedPane(pwd: String) throws -> Ghostty.SurfaceView {
        let source = try terminal()
        source.pwd = pwd
        source.agentResumeRecord = withSession
        let window = WindowState(layouts: [.scrolling(ScrollingStrip(pane: source, widthFactor: 0.5))],
                                 floatings: [[]], activeIndex: 0)
        let previous = AgentResume.quitSaveStarted
        AgentResume.quitSaveStarted = true
        defer { AgentResume.quitSaveStarted = previous }
        let data = try JSONEncoder().encode(PersistedState(windows: [window]))
        let state = try XCTUnwrap(SessionStore.decode(data))
        return try XCTUnwrap(state.windows[0].layouts[0].paneList.first as? Ghostty.SurfaceView)
    }
}
