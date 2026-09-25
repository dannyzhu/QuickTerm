import Sparkle
import SwiftUI
import XCTest
@testable import QuickTerm

/// The status-bar item: which glyph each state gets, and that it hides when idle and fits the bar.
@MainActor
final class UpdateIndicatorTests: XCTestCase {
    private func available(stage: UpdateState.UpdateAvailable.Stage = .notDownloaded) -> UpdateState {
        .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), stage: stage, userInitiated: false, reply: { _ in }))
    }

    func testIdleHasNoGlyph() {
        XCTAssertNil(UpdateIndicatorGlyph(state: .idle))
    }

    func testGlyphsPerState() throws {
        let checking = try XCTUnwrap(UpdateIndicatorGlyph(state: .checking(.init(cancel: {}))))
        XCTAssertEqual(checking.symbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(checking.tone, .foreground)
        XCTAssertEqual(checking.tooltipKey, "update.bar.checking")

        let found = try XCTUnwrap(UpdateIndicatorGlyph(state: available()))
        XCTAssertEqual(found.symbol, "arrow.down.circle")
        XCTAssertEqual(found.tone, .accent)
        XCTAssertEqual(found.tooltipKey, "update.bar.available")

        XCTAssertEqual(UpdateIndicatorGlyph(state: available(stage: .downloaded))?.tooltipKey, "update.bar.downloaded")

        let downloading = try XCTUnwrap(UpdateIndicatorGlyph(state: .downloading(.init(cancel: {}, version: "9.9.9", expectedLength: 200, progress: 50))))
        XCTAssertNil(downloading.symbol)
        XCTAssertEqual(downloading.ring!, 0.25, accuracy: 0.001)
        XCTAssertEqual(downloading.tooltipArguments, ["9.9.9", "25"])

        let staged = try XCTUnwrap(UpdateIndicatorGlyph(state: .installing(.init(isAutoUpdate: true, version: "9.9.9", restart: {}, later: {}, skip: nil))))
        XCTAssertEqual(staged.symbol, "power.circle")
        XCTAssertEqual(staged.tooltipKey, "update.bar.installing")

        XCTAssertEqual(UpdateIndicatorGlyph(state: .notFound(.init()))?.symbol, "checkmark.circle")

        let failed = try XCTUnwrap(UpdateIndicatorGlyph(state: .error(.init(error: NSError(domain: "x", code: 1), kind: .other, retry: {}, dismiss: {}))))
        XCTAssertEqual(failed.symbol, "exclamationmark.triangle")
        XCTAssertEqual(failed.tone, .alert)
    }

    func testEveryTooltipKeyExistsInBothCatalogs() {
        let states: [UpdateState] = [
            .checking(.init(cancel: {})), available(), available(stage: .downloaded),
            .downloading(.init(cancel: {}, version: nil, expectedLength: nil, progress: 0)),
            .extracting(.init(version: nil, progress: 0)),
            .installing(.init(isAutoUpdate: true, version: nil, restart: {}, later: {}, skip: nil)),
            .notFound(.init()),
            .error(.init(error: NSError(domain: "x", code: 1), kind: .other, retry: {}, dismiss: {})),
        ]
        for state in states {
            let key = UpdateIndicatorGlyph(state: state)!.tooltipKey
            XCTAssertNotNil(Localization.shared.catalog(.en).strings[key], key)
            XCTAssertNotNil(Localization.shared.catalog(.zh).strings[key], key)
        }
    }

    func testTheItemHidesWhenIdleAndFitsTheBarOtherwise() {
        let model = UpdateViewModel()
        func host() -> NSView {
            NSHostingView(rootView: UpdateIndicator(model: model, onClick: {})
                .environmentObject(ThemeManager())
                .environmentObject(Localization.shared))
        }
        XCTAssertEqual(host().fittingSize.width, 0, "idle draws nothing")
        model.state = available()
        let visible = host().fittingSize
        XCTAssertGreaterThan(visible.width, 0)
        XCTAssertLessThanOrEqual(visible.height, StatusBarView.height)
        model.state = .downloading(.init(cancel: {}, version: "9.9.9", expectedLength: 10, progress: 5))
        XCTAssertLessThanOrEqual(host().fittingSize.height, StatusBarView.height, "the ring fits too")
    }

    func testTheLaunchOverrideParsesTheFeedURL() {
        let fromArgument = AppDelegate.LaunchOverrides(
            arguments: ["QuickTerm", "--update-feed-url", "https://example.invalid/appcast.xml"], environment: [:])
        XCTAssertEqual(fromArgument.updateFeedURL?.absoluteString, "https://example.invalid/appcast.xml")
        let fromEnvironment = AppDelegate.LaunchOverrides(
            arguments: ["QuickTerm"], environment: ["QUICKTERM_UPDATE_FEED_URL": "https://example.invalid/env.xml"])
        XCTAssertEqual(fromEnvironment.updateFeedURL?.absoluteString, "https://example.invalid/env.xml")
        XCTAssertNil(AppDelegate.LaunchOverrides(arguments: ["QuickTerm"], environment: [:]).updateFeedURL)
        XCTAssertEqual(AppDelegate.LaunchOverrides.switches.count, 4)
    }

    func testTheSessionOwnsTheControllerAndAppliesTheConfig() throws {
        let session = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.session)
        XCTAssertNil(session.updates.updater, "the test host never has a Sparkle updater")
        let before = session.settings
        defer { session.apply(before) }
        session.apply(ConfigStore.parse("[updates]\ncheck = false\ninstall = true\n"))
        XCTAssertEqual(session.updates.settings, UpdateSettings(check: false, install: true))
    }
}
