import XCTest
@testable import QuickTerm

/// Where the notes come from and how Markdown is flattened for the house text area.
final class ReleaseNotesTests: XCTestCase {
    func testAssetURLsFollowTheReleaseLayout() {
        XCTAssertEqual(ReleaseNotes.assetURL(version: "1.6.8", language: .en)?.absoluteString,
                       "https://github.com/dannyzhu/QuickTerm/releases/download/v1.6.8/QuickTerm-1.6.8-notes.md")
        XCTAssertEqual(ReleaseNotes.assetURL(version: "1.6.8", language: .zh)?.absoluteString,
                       "https://github.com/dannyzhu/QuickTerm/releases/download/v1.6.8/QuickTerm-1.6.8-notes.zh-CN.md")
        XCTAssertEqual(ReleaseNotes.releasePageURL(version: "1.6.8")?.absoluteString,
                       "https://github.com/dannyzhu/QuickTerm/releases/tag/v1.6.8")
    }

    func testAVersionThatIsNotThreeNumbersGetsNoURL() {
        for bad in ["1.6", "v1.6.8", "1.6.8/../x", "", "abc", "1.6.8 "] {
            XCTAssertFalse(ReleaseNotes.isValidVersion(bad), bad)
            XCTAssertNil(ReleaseNotes.assetURL(version: bad, language: .en), bad)
        }
        XCTAssertTrue(ReleaseNotes.isValidVersion("1.6.8"))
    }

    func testTheUILanguageComesFirstThenTheOther() {
        let zh = ReleaseNotes.candidateURLs(version: "1.6.8", language: .zh)
        XCTAssertEqual(zh.map(\.lastPathComponent), ["QuickTerm-1.6.8-notes.zh-CN.md", "QuickTerm-1.6.8-notes.md"])
        let en = ReleaseNotes.candidateURLs(version: "1.6.8", language: .en)
        XCTAssertEqual(en.map(\.lastPathComponent), ["QuickTerm-1.6.8-notes.md", "QuickTerm-1.6.8-notes.zh-CN.md"])
    }

    func testMarkdownIsFlattened() {
        let markdown = """
        ## QuickTerm 1.6.8

        Universal binary. **Signed** and `notarized`.

        ### Fixes
        - Cmd-clicking a [link](https://example.com/x) works.
        - Second item
          - nested

        ```bash
        # keep me
        make-release.sh --notarize
        ```
        """
        let plain = ReleaseNotes.plainText(fromMarkdown: markdown)
        XCTAssertEqual(plain, """
        QuickTerm 1.6.8

        Universal binary. Signed and notarized.

        Fixes
        • Cmd-clicking a link (https://example.com/x) works.
        • Second item
          • nested

        # keep me
        make-release.sh --notarize
        """)
    }

    @MainActor
    func testTheLoaderFallsBackWithoutTouchingTheNetworkForABadVersion() async {
        let loader = ReleaseNotes.Loader()
        let text = await loader.notes(version: "not-a-version", language: .en, fallback: "## Fallback\n- ok")
        XCTAssertEqual(text, "Fallback\n• ok")
        let none = await loader.notes(version: "not-a-version", language: .en, fallback: nil)
        XCTAssertNil(none)
    }
}
