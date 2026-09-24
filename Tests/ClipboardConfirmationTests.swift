import AppKit
import GhosttyKit
import XCTest
@testable import QuickTerm

/// **The engine's clipboard questions get an answer.**
///
/// libghostty hands three clipboard decisions to the app through one notification: a paste with
/// a line break into a program that is not framing pastes, an OSC 52 read while `clipboard-read
/// = ask`, and an OSC 52 write while `clipboard-write = ask`. Until `ClipboardConfirmation`
/// existed nothing observed that notification, so the paste vanished, the write was dropped and
/// the read was never completed — the program sat waiting for a reply that never came.
///
/// The claims made here are about the contract with the engine, so the sheet and the C call are
/// swapped for closures and everything runs on a private NotificationCenter: the app's own
/// observer on `.default` would put a real sheet up — or, for a pane without a window, hand the
/// made-up request pointer below to the engine.
@MainActor
final class ClipboardConfirmationTests: XCTestCase {
    private var center: NotificationCenter!
    private var confirmation: ClipboardConfirmation!
    /// What was handed back to the engine, in order.
    private var completions: [(data: String, state: UnsafeMutableRawPointer?)] = []
    /// A stand-in for the engine's request allocation; the fakes never dereference it.
    private let state = UnsafeMutableRawPointer(bitPattern: 0x10)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        center = NotificationCenter()
        confirmation = ClipboardConfirmation(center: center)
        completions = []
        confirmation.complete = { [unowned self] _, data, state in completions.append((data, state)) }
    }

    override func tearDown() {
        confirmation = nil
        center = nil
        super.tearDown()
    }

    private func makeView() throws -> Ghostty.SurfaceView {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        return Ghostty.SurfaceView(try XCTUnwrap(appDelegate.ghostty.app), baseConfig: nil)
    }

    /// Posts what `Ghostty.App.confirmReadClipboard` / `writeClipboard` post, in the same shape:
    /// the state is an `UnsafeMutableRawPointer?` boxed as `Any`, absent for a write.
    private func post(_ kind: Ghostty.ClipboardRequest, contents: String, view: Ghostty.SurfaceView,
                      state: UnsafeMutableRawPointer?, to center: NotificationCenter? = nil) {
        var info: [AnyHashable: Any] = [
            Ghostty.Notification.ConfirmClipboardStrKey: contents,
            Ghostty.Notification.ConfirmClipboardRequestKey: kind,
        ]
        if state != nil {
            let boxed: UnsafeMutableRawPointer? = state
            info[Ghostty.Notification.ConfirmClipboardStateKey] = boxed as Any
        }
        (center ?? self.center).post(name: Ghostty.Notification.confirmClipboard, object: view, userInfo: info)
    }

    private func answer(_ action: ClipboardConfirmation.Action) {
        confirmation.present = { _, reply in reply(action) }
    }

    // MARK: The engine is always told how a paste or read ended

    func testADeniedOSC52ReadIsStillAnsweredWithAnEmptyClipboard() throws {
        let view = try makeView()
        answer(.deny)
        post(.osc_52_read, contents: "secret", view: view, state: state)
        XCTAssertEqual(completions.count, 1, "a denied read is completed, not left hanging")
        XCTAssertEqual(completions.first?.data, "", "the program hears an empty clipboard")
        XCTAssertEqual(completions.first?.state, state, "with the engine's own request pointer")
        XCTAssertNil(confirmation.pending)
    }

    func testAnAllowedOSC52ReadHandsTheClipboardTextToTheEngine() throws {
        let view = try makeView()
        answer(.allow)
        post(.osc_52_read, contents: "secret", view: view, state: state)
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.data, "secret")
        XCTAssertEqual(completions.first?.state, state)
    }

    func testACancelledUnsafePasteIsCompletedSoTheEngineCanFreeTheRequest() throws {
        let view = try makeView()
        answer(.deny)
        post(.paste, contents: "rm -rf /\n", view: view, state: state)
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.data, "", "an empty paste: nothing reaches the program")
        XCTAssertEqual(completions.first?.state, state)
    }

    func testAConfirmedUnsafePasteGoesThroughUnchanged() throws {
        let view = try makeView()
        answer(.allow)
        post(.paste, contents: "echo one\necho two\n", view: view, state: state)
        XCTAssertEqual(completions.map(\.data), ["echo one\necho two\n"])
    }

    func testAPasteWithoutItsEngineRequestIsIgnoredRatherThanCompletedWithNothing() throws {
        let view = try makeView()
        var asked = 0
        confirmation.present = { _, reply in asked += 1; reply(.allow) }
        post(.paste, contents: "x\n", view: view, state: nil)
        XCTAssertEqual(asked, 0, "there is no request to answer, so there is nothing to ask")
        XCTAssertTrue(completions.isEmpty)
    }

    // MARK: A write never goes back to the engine

    func testAnOSC52WriteTouchesThePasteboardOnlyWhenAllowed() throws {
        let view = try makeView()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.danny.quickterm.tests.clipboard-confirmation"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        answer(.deny)
        post(.osc_52_write(pasteboard), contents: "written", view: view, state: nil)
        XCTAssertNil(pasteboard.string(forType: .string), "denied: the pasteboard is left alone")

        answer(.allow)
        post(.osc_52_write(pasteboard), contents: "written", view: view, state: nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "written")

        XCTAssertTrue(completions.isEmpty, "a write is completed on the app side, never through the engine")
    }

    // MARK: One question at a time

    func testASecondRequestWhileOneIsUpIsDeniedOnTheSpot() throws {
        let view = try makeView()
        let second = UnsafeMutableRawPointer(bitPattern: 0x20)!
        var replies: [(ClipboardConfirmation.Action) -> Void] = []
        confirmation.present = { _, reply in replies.append(reply) }

        post(.osc_52_read, contents: "first", view: view, state: state)
        XCTAssertEqual(replies.count, 1)
        XCTAssertNotNil(confirmation.pending)
        XCTAssertTrue(completions.isEmpty, "the first question is still open")

        post(.osc_52_read, contents: "second", view: view, state: second)
        XCTAssertEqual(replies.count, 1, "no second sheet")
        XCTAssertEqual(completions.count, 1, "but the second request is answered, so it does not hang either")
        XCTAssertEqual(completions.first?.data, "")
        XCTAssertEqual(completions.first?.state, second)

        replies[0](.allow)
        XCTAssertEqual(completions.count, 2)
        XCTAssertEqual(completions.last?.data, "first")
        XCTAssertEqual(completions.last?.state, state)
        XCTAssertNil(confirmation.pending, "answered, so the next request may ask again")

        replies[0](.allow)
        XCTAssertEqual(completions.count, 2, "a reply is taken once")
    }

    func testAPaneClosedWhileTheQuestionIsUpIsNotCompletedIntoAFreedSurface() throws {
        weak var weakView: Ghostty.SurfaceView?
        var reply: ((ClipboardConfirmation.Action) -> Void)?
        confirmation.present = { _, r in reply = r }
        try autoreleasepool {
            let view = try makeView()
            weakView = view
            post(.osc_52_read, contents: "secret", view: view, state: state)
            XCTAssertNotNil(reply)
        }
        // The notification autoreleases its object once, so turn the runloop before looking again.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, weakView != nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNil(weakView, "the open question must not keep the pane alive")

        reply?(.allow)
        XCTAssertTrue(completions.isEmpty, "the surface is gone, and the engine's request went with it")
        XCTAssertNil(confirmation.pending)
    }

    // MARK: The sheet

    func testTheOSC52SheetPutsDenyOnReturnAndAllowBehindAClick() {
        for kind in [Ghostty.ClipboardRequest.osc_52_read, .osc_52_write(nil)] {
            let alert = ClipboardConfirmation.makeAlert(kind, contents: "secret")
            XCTAssertEqual(alert.buttons.count, 2)
            XCTAssertEqual(alert.buttons[0].title, L("consent.alert.button.deny"))
            XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
            XCTAssertEqual(alert.buttons[1].title, L("consent.alert.button.allow"))
            XCTAssertEqual(alert.buttons[1].keyEquivalent, "", "no key lands on Allow")
            XCTAssertEqual(ClipboardConfirmation.allowResponse(for: kind), .alertSecondButtonReturn)
        }
    }

    func testTheUnsafePasteSheetKeepsPasteOnReturnAndCancelOnEscape() {
        let alert = ClipboardConfirmation.makeAlert(.paste, contents: "a\nb")
        XCTAssertEqual(alert.buttons[0].title, L("terminal.clipboard.button.paste"))
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons[1].title, L("window.button.cancel"))
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
        XCTAssertEqual(ClipboardConfirmation.allowResponse(for: .paste), .alertFirstButtonReturn)
    }

    func testTheSheetShowsTheExplanationAboveTheTextItIsAbout() throws {
        let alert = ClipboardConfirmation.makeAlert(.osc_52_read, contents: "the clipboard")
        XCTAssertEqual(alert.messageText, L("terminal.clipboard.read.title"))
        XCTAssertEqual(alert.informativeText, "", "the explanation is in the accessory, not stacked above it")
        let accessory = try XCTUnwrap(alert.accessoryView)
        let intro = try XCTUnwrap(accessory.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(intro.stringValue, L("terminal.clipboard.read.detail"))
        let scroll = try XCTUnwrap(accessory.subviews.compactMap { $0 as? NSScrollView }.first)
        XCTAssertEqual((scroll.documentView as? NSTextView)?.string, "the clipboard")
        XCTAssertGreaterThan(intro.frame.minY, scroll.frame.maxY - 1, "the intro sits above the text")
        XCTAssertGreaterThanOrEqual(accessory.frame.height, intro.frame.maxY)
    }

    // MARK: The app really listens

    func testTheAppAnswersARequestFromAPaneThatHasNoWindow() throws {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let live = try XCTUnwrap(appDelegate.clipboardConfirmation, "installed at launch")
        let original = live.complete
        defer { live.complete = original }
        var handed: [(data: String, state: UnsafeMutableRawPointer?)] = []
        live.complete = { _, data, state in handed.append((data, state)) }

        // The real presenter: a pane that is not in any window has nowhere to hang a sheet, so
        // its request is denied — and denied means answered, not dropped.
        let view = try makeView()
        XCTAssertNil(view.window)
        post(.osc_52_read, contents: "secret", view: view, state: state, to: .default)
        XCTAssertEqual(handed.count, 1)
        XCTAssertEqual(handed.first?.data, "")
        XCTAssertEqual(handed.first?.state, state)
        XCTAssertNil(live.pending)
    }
}
