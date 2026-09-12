import AppKit
import SwiftUI
import XCTest
@testable import QuickTerm

/// What `LocalizationProbe` rendered, in order. A class so the probe can record from inside a
/// SwiftUI body without capturing a mutating local.
@MainActor
final class RenderedStrings {
    private(set) var values: [String] = []
    var last: String? { values.last }
    func record(_ value: String) { values.append(value) }
}

/// A SwiftUI view written the way the extraction passes should write one: the catalog is read
/// through `@EnvironmentObject`, which is what ties the view's identity to the language.
private struct LocalizationProbe: View {
    @EnvironmentObject private var i18n: Localization
    let seen: RenderedStrings

    var body: some View {
        let title = i18n("menu.shell.new-terminal")
        seen.record(title)
        return Text(title)
    }
}

/// Pin the UI language for the rest of one test case.
///
/// Anything that asserts user-visible text has to say which language it is reading. The app
/// follows the system language by default, so a bare assertion on a Chinese sentence is really
/// an assertion about the machine the suite happens to run on — green here, red on an English
/// Mac. The previous language is put back at teardown.
extension XCTestCase {
    func pinUILanguage(_ language: AppLanguage) {
        let previous = Localization.shared.language
        addTeardownBlock { Localization.shared.setLanguage(previous) }
        Localization.shared.setLanguage(language)
    }
}

/// The localization foundation (`Sources/Localization/Localization.swift` + `Resources/*.lproj`).
///
/// These tests are the mechanical half of the rule "the UI is bilingual": a key that exists in
/// code but in no table, or in English but not in Chinese, is a user-visible bug that nobody
/// notices until a Chinese user reads `menu.shell.new-terminal` off their own menu bar.
final class LocalizationTests: XCTestCase {
    /// The repo (tests run from the build products; the source tree is only reachable via #filePath)
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private var sourcesRoot: URL { repoRoot.appendingPathComponent("Sources") }

    /// Every `L(…)` / `Lp(…)` key that appears in Sources, with the file it appears in.
    private lazy var keysUsedInCode: [(key: String, file: String)] = Self.scanCallSites(sourcesRoot)

    /// The source tree lives under ~/Documents, which macOS gates behind a privacy prompt, and
    /// QuickTerm is ad-hoc signed — so the grant is rebound to the cdhash on **every rebuild**
    /// and the test host can be left staring at an unanswered "QuickTerm.app would like to
    /// access Documents". Probe one known file first: a failure there is the environment, not
    /// the catalog, and a red test would send the next reader hunting for a bug that is not there.
    private func requireReadableSources() throws {
        let probe = sourcesRoot.appendingPathComponent("App/MainMenu.swift")
        guard (try? String(contentsOf: probe, encoding: .utf8)) != nil else {
            throw XCTSkip("cannot read \(probe.path) — answer the macOS Documents-access prompt "
                + "for QuickTerm.app (ad-hoc signing rebinds it on every rebuild)")
        }
    }

    override func tearDown() {
        Localization.shared.apply(configValue: "auto")
        super.tearDown()
    }

    // MARK: The catalogs

    /// Both tables carry exactly the same keys. English is the base language, so a key only in
    /// Chinese is dead weight and a key only in English silently falls back — neither is intended.
    func testBothTablesHaveTheSameKeys() {
        let en = Set(Localization.shared.catalog(.en).strings.keys)
        let zh = Set(Localization.shared.catalog(.zh).strings.keys)
        XCTAssertFalse(en.isEmpty, "en.lproj did not load from the built bundle — check that the "
            + ".lproj directories are declared as resources in project.yml")
        XCTAssertEqual(en.subtracting(zh), [], "keys missing from zh-Hans")
        XCTAssertEqual(zh.subtracting(en), [], "keys in zh-Hans that English (the base) does not have")
    }

    /// Every key the code asks for exists in **both** tables.
    func testEveryKeyUsedInCodeExists() throws {
        try requireReadableSources()
        XCTAssertFalse(keysUsedInCode.isEmpty, "the call-site scanner found nothing — it is broken")
        let en = Localization.shared.catalog(.en).strings
        let zh = Localization.shared.catalog(.zh).strings
        for (key, file) in keysUsedInCode {
            XCTAssertNotNil(en[key], "\(file) uses \(key), which en.lproj does not declare")
            XCTAssertNotNil(zh[key], "\(file) uses \(key), which zh-Hans.lproj does not declare")
        }
    }

    /// A `.one` variant always has an `.other` and vice versa: `Lp` picks between them by count,
    /// and a missing half would fall back to English in the middle of a Chinese sentence.
    func testPluralVariantsComeInPairs() {
        for language in AppLanguage.allCases {
            let keys = Set(Localization.shared.catalog(language).strings.keys)
            for key in keys where key.hasSuffix(".one") {
                let other = key.replacingOccurrences(of: ".one", with: ".other")
                XCTAssertTrue(keys.contains(other), "\(language.rawValue): \(key) has no \(other)")
            }
            for key in keys where key.hasSuffix(".other") {
                let one = key.replacingOccurrences(of: ".other", with: ".one")
                XCTAssertTrue(keys.contains(one), "\(language.rawValue): \(key) has no \(one)")
            }
        }
    }

    /// **Only positional `%n$@`.** Word order differs between the two languages, so a translator
    /// has to be able to reorder the values; and because nothing but `%n$@` ever reaches
    /// `String(format:)`, a mistranslated format cannot crash the app the way `%d` with a String
    /// argument would. A literal percent is `%%`.
    func testEveryFormatUsesPositionalSpecifiersOnly() {
        for language in AppLanguage.allCases {
            for (key, value) in Localization.shared.catalog(language).strings {
                for bad in Self.nonPositionalSpecifiers(in: value) {
                    XCTFail("\(language.rawValue) \(key) uses \(bad); only %1$@, %2$@ … (or %% ) are allowed: \(value)")
                }
            }
        }
    }

    /// The two languages fill in the same set of arguments. A Chinese sentence that drops `%2$@`
    /// silently loses a pane handle out of a consent prompt.
    func testArgumentsMatchAcrossLanguages() {
        let en = Localization.shared.catalog(.en).strings
        let zh = Localization.shared.catalog(.zh).strings
        for (key, value) in en {
            guard let translated = zh[key] else { continue }
            XCTAssertEqual(Self.positionalIndices(in: value), Self.positionalIndices(in: translated),
                           "\(key): the two languages do not use the same arguments")
        }
    }

    /// One key, one owner. Areas may keep their own `<Area>.strings` table inside a `.lproj`
    /// (that is how several translation passes edit the catalog at once without colliding), so
    /// the same key claimed by two tables has to fail loudly rather than resolve by file order.
    func testNoKeyIsClaimedByTwoTables() {
        for language in AppLanguage.allCases {
            var owner: [String: String] = [:]
            for (table, keys) in Localization.shared.catalog(language).tables.sorted(by: { $0.key < $1.key }) {
                for key in keys {
                    if let first = owner[key] {
                        XCTFail("\(language.rawValue): \(key) is declared in both \(first).strings and \(table).strings")
                    }
                    owner[key] = table
                }
            }
        }
    }

    /// **Every declared key is asked for somewhere.** A key nobody reads still costs a
    /// translation and still has to be kept in step with its twin; and a key that *became*
    /// unused is the trace of UI that was deleted, or of a call site that quietly went back to
    /// a hard-coded literal — which is a string that stopped being bilingual.
    func testEveryDeclaredKeyIsUsed() throws {
        try requireReadableSources()
        // The scanner resolves a plural call site into its two halves, so both spellings count.
        let used = Set(keysUsedInCode.map(\.key))
        for key in Localization.shared.catalog(.en).strings.keys.sorted() where !used.contains(key) {
            XCTFail("\(key) is declared in en.lproj but no call site asks for it — delete it, or use it")
        }
    }

    /// **The two halves are really two languages.** English with CJK in it, or a Chinese value
    /// left as a copy of the English one, is what a half-finished translation pass leaves
    /// behind — and neither shows up as a missing key, so nothing else here would catch it.
    ///
    /// Some values *are* the same in both (`Shell`, a date skeleton, a pure format string). That
    /// is declared next to the value, with a `same-as-english:` comment above it in the Chinese
    /// table, rather than in a list inside this test — a list here would rot the moment somebody
    /// retranslated the entry.
    func testChineseValuesAreTranslatedAndEnglishOnesAreEnglish() throws {
        let en = Localization.shared.catalog(.en).strings
        let zh = Localization.shared.catalog(.zh).strings
        let exempt = try Self.sameAsEnglishKeys()
        XCTAssertFalse(exempt.isEmpty, "no `same-as-english:` marker was found in the bundled "
            + "catalog — either the markers are gone, or the copy phase has started compiling "
            + "the .strings files into binary plists and this test can no longer read them")
        for (key, value) in en.sorted(by: { $0.key < $1.key }) {
            XCTAssertNil(value.rangeOfCharacter(from: Self.cjk),
                         "\(key): the English value contains Chinese — en.lproj is the base language: \(value)")
            guard let translated = zh[key], translated == value, !exempt.contains(key) else { continue }
            XCTFail("\(key): the Chinese value is the English one, word for word (\(value)). Translate "
                + "it, or put a `same-as-english: <why>` comment above it in zh-Hans.lproj.")
        }
    }

    // MARK: Lookup and fallback

    /// A key missing from Chinese falls back to the English sentence — never to the raw key,
    /// which is what the user would otherwise read on screen.
    func testMissingChineseEntryFallsBackToEnglish() throws {
        let fixture = try makeFixtureBundle(
            en: ["fixture.both": "English both", "fixture.en-only": "English only"],
            zh: ["fixture.both": "中文"])
        let localization = Localization(resourceURL: fixture, preferred: ["zh-Hans"])
        XCTAssertEqual(localization.language, .zh)
        XCTAssertEqual(localization.string("fixture.both"), "中文")
        XCTAssertEqual(localization.string("fixture.en-only"), "English only",
                       "a key missing from zh must fall back to English, not to the raw key")
        XCTAssertNil(localization.format("fixture.nowhere"),
                     "a key in no table has no format (the caller renders the key and asserts in debug)")
    }

    /// Whole sentences with positional arguments: the same key, reordered by the translation.
    func testPositionalArgumentsAreReorderedByTheTranslation() throws {
        let fixture = try makeFixtureBundle(
            en: ["fixture.order": "Close %1$@ in %2$@."],
            zh: ["fixture.order": "在 %2$@ 里关掉 %1$@。"])
        let english = Localization(resourceURL: fixture, preferred: ["en-US"])
        let chinese = Localization(resourceURL: fixture, preferred: ["zh-Hans"])
        XCTAssertEqual(english.string("fixture.order", ["t7", "workspace 2"]), "Close t7 in workspace 2.")
        XCTAssertEqual(chinese.string("fixture.order", ["t7", "workspace 2"]), "在 workspace 2 里关掉 t7。")
    }

    /// Numbers go in as arguments too — `String(describing:)` renders them, so a table can never
    /// crash the app by writing `%1$@` where the call site passes an `Int`.
    func testNumbersAreFormattedThroughTheSameArgumentPath() {
        XCTAssertEqual(Lp("consent.subject.screen", count: 1, 2, "work", 1),
                       Localization.shared.string("consent.subject.screen.one", [2, "work", 1]))
        XCTAssertTrue(Lp("consent.subject.screen", count: 3, 2, "work", 3).contains("3"))
    }

    // MARK: auto / explicit

    /// `auto` follows the system's preferred languages; anything QuickTerm does not ship
    /// (French here) falls through to the next one, and to English when there is none.
    func testAutoFollowsTheSystem() {
        XCTAssertEqual(AppLanguage.resolve(configValue: "auto", preferred: ["zh-Hans-CN", "en-US"]), .zh)
        XCTAssertEqual(AppLanguage.resolve(configValue: "auto", preferred: ["en-GB", "zh-Hans"]), .en)
        XCTAssertEqual(AppLanguage.resolve(configValue: "auto", preferred: ["fr-FR", "zh-Hant-TW"]), .zh)
        XCTAssertEqual(AppLanguage.resolve(configValue: "auto", preferred: ["fr-FR"]), .en,
                       "a language we do not ship falls back to the base language")
        XCTAssertEqual(AppLanguage.resolve(configValue: "", preferred: ["zh-CN"]), .zh,
                       "an empty value behaves like auto")
    }

    /// An explicit value beats the system, in every spelling the config accepts.
    func testExplicitLanguageOverridesTheSystem() {
        for spelling in ["en", "en-US", "EN"] {
            XCTAssertEqual(AppLanguage.resolve(configValue: spelling, preferred: ["zh-Hans"]), .en, spelling)
        }
        for spelling in ["zh", "zh-Hans", "zh-CN", "ZH"] {
            XCTAssertEqual(AppLanguage.resolve(configValue: spelling, preferred: ["en-US"]), .zh, spelling)
        }
    }

    /// `[general] language` reaches the runtime through the same path every other key uses:
    /// ConfigSchema -> ConfigStore.Settings -> Localization. Hot reload switches it live.
    func testConfigKeyDrivesTheRuntime() {
        XCTAssertEqual(ConfigStore.Settings().language, "auto", "the default is auto")
        XCTAssertEqual(ConfigStore.parse("[general]\nlanguage = \"zh-Hans\"\n").language, "zh",
                       "the schema normalises the spelling")
        XCTAssertEqual(ConfigStore.parse("[general]\nlanguage = \"klingon\"\n").language, "auto",
                       "an unknown value is rejected and the default stands")

        let localization = Localization(preferred: ["en-US"])
        XCTAssertEqual(localization.language, .en)
        XCTAssertTrue(localization.apply(configValue: "zh", preferred: ["en-US"]),
                      "a changed language reports that it changed (so menus rebuild)")
        XCTAssertEqual(localization.language, .zh)
        XCTAssertFalse(localization.apply(configValue: "zh", preferred: ["en-US"]),
                       "an unchanged value must not churn every menu in the app")
        XCTAssertTrue(localization.apply(configValue: "auto", preferred: ["en-US"]))
        XCTAssertEqual(localization.language, .en)
    }

    /// A language change is announced to AppKit code that cannot observe an ObservableObject.
    func testLanguageChangeIsAnnounced() {
        let shared = Localization.shared
        let start = shared.language
        let expectation = expectation(forNotification: Localization.didChangeNotification,
                                      object: shared, handler: nil)
        shared.setLanguage(start == .en ? .zh : .en)
        wait(for: [expectation], timeout: 1)
        shared.setLanguage(start)
    }

    /// The config-file template writes its comments in the active language, and `[general]
    /// language` is itself documented in the template. (`AppSession.loadInitialConfig` resolves
    /// the language *before* it writes the template — a fresh install that pins `en` must not
    /// get a file full of Chinese comments.)
    func testTemplateCommentsFollowTheActiveLanguage() {
        let saved = ConfigSchema.templateLanguage
        defer { ConfigSchema.templateLanguage = saved }

        ConfigSchema.templateLanguage = .en
        let english = ConfigStore.template
        XCTAssertTrue(english.contains("# QuickTerm configuration"), english.prefix(200).description)
        XCTAssertTrue(english.contains("auto (follow the system)"), "[general] language help, in English")
        XCTAssertTrue(english.contains("[general]  # General"))
        XCTAssertFalse(ConfigStore.autofillBanner.contains("新增"))

        ConfigSchema.templateLanguage = .zh
        let chinese = ConfigStore.template
        XCTAssertTrue(chinese.contains("auto = 跟随系统"), "[general] language help, in Chinese")
        XCTAssertTrue(chinese.contains("[general]  # 通用"))
        XCTAssertTrue(ConfigStore.autofillBanner.contains("新增"))

        // Same assignment line in both languages: the README/template check keys off it
        for language in AppLanguage.allCases {
            ConfigSchema.templateLanguage = language
            XCTAssertTrue(ConfigStore.template.contains("# language = \"auto\""))
        }
    }

    // MARK: The pilot files really speak both languages

    /// The AppKit half: the main menu is built out of the catalog, and rebuilt on a change.
    func testMenuTitlesComeFromTheCatalog() {
        let shared = Localization.shared
        let start = shared.language
        defer { shared.setLanguage(start) }
        shared.setLanguage(.en)
        XCTAssertEqual(L("menu.shell.new-terminal"), "New Terminal")
        shared.setLanguage(.zh)
        XCTAssertEqual(L("menu.shell.new-terminal"), "新建终端")
        XCTAssertEqual(L("menu.window.close-screen"), "关闭屏幕")
    }

    /// The AppKit half, live: an NSMenuItem title is a **value**, not a binding, so a language
    /// change has to rebuild the menu. `MainMenu` listens for the change itself.
    @MainActor
    func testMainMenuRebuildsWhenTheLanguageChanges() throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let start = Localization.shared.language
        defer {
            Localization.shared.setLanguage(start)
            MainMenu.install(delegate: delegate)
        }
        Localization.shared.setLanguage(.en)
        MainMenu.install(delegate: delegate)
        XCTAssertEqual(menuTitle(of: .newTerminal), "New Terminal")

        // Nothing but the language changes here — no second install(). The menu has to follow.
        Localization.shared.setLanguage(.zh)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(menuTitle(of: .newTerminal), "新建终端",
                       "the main menu did not rebuild on a language change")
    }

    /// The title the main menu currently shows for a WM action.
    @MainActor
    private func menuTitle(of action: WMAction) -> String? {
        for top in NSApp.mainMenu?.items ?? [] {
            for item in top.submenu?.items ?? []
            where (item.representedObject as? String) == action.rawValue {
                return item.title
            }
        }
        return nil
    }

    /// The SwiftUI half: a view reads the catalog through `@EnvironmentObject`, and re-renders
    /// on a language change because that read goes through the `@Published` property.
    /// `MainWindowController` installs the same environment object on the real root view, so a
    /// view that does this in the app behaves the way it does here.
    @MainActor
    func testSwiftUIViewReadsTheCatalogAndFollowsTheLanguage() {
        let shared = Localization.shared
        let start = shared.language
        defer { shared.setLanguage(start) }
        shared.setLanguage(.en)

        let seen = RenderedStrings()
        let host = NSHostingView(rootView: LocalizationProbe(seen: seen)
            .environmentObject(shared))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(seen.last, "New Terminal",
                       "the view did not read the catalog through the environment object")

        // Nothing but the language changes — the view has to re-render on its own.
        shared.setLanguage(.zh)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(seen.last, "新建终端", "the SwiftUI view did not follow the language change")
    }

    /// The hard shape: an NSAlert body with interpolated values, in both languages, with the
    /// arguments landing in the place each language puts them.
    @MainActor
    func testConsentAlertIsWholeSentencesInBothLanguages() {
        let shared = Localization.shared
        let start = shared.language
        defer { shared.setLanguage(start) }
        let request = ControlConsent.Request(peerName: "node", peerPID: 4821, cls: .destructive,
                                             summary: "Close pane t7", originPane: "t3",
                                             tokenPresent: true)
        shared.setLanguage(.en)
        let english = ControlConsent.makeAlert(request)
        XCTAssertEqual(english.buttons.first?.title, "Deny")
        XCTAssertTrue(english.informativeText.contains("node (pid 4821), claiming to come from pane t3"),
                      english.informativeText)
        shared.setLanguage(.zh)
        let chinese = ControlConsent.makeAlert(request)
        XCTAssertEqual(chinese.buttons.first?.title, "拒绝")
        XCTAssertTrue(chinese.informativeText.contains("node（pid 4821），自称来自 pane t3"),
                      chinese.informativeText)
        XCTAssertTrue(chinese.informativeText.contains("Close pane t7"),
                      "the summary is interpolated, not translated: \(chinese.informativeText)")
    }

    // MARK: Call-site hygiene

    /// **No call site glues two lookups together.** `L("a") + name + L("b")` is the one shape that
    /// cannot be translated — Chinese puts the pieces in a different order — so keys hold whole
    /// sentences and values arrive as positional arguments instead.
    func testNoCallSiteConcatenatesLookups() throws {
        try requireReadableSources()
        let lookup = #"(?<![A-Za-z0-9_.])(?:Lp|L|i18n\.plural|i18n)"#
        let pattern = try NSRegularExpression(
            pattern: lookup + #"\("[^"]+"[^\n]*\)\s*\+"#
                + #"|\+\s*"# + lookup + #"\("#
                + #"|\\\(\s*"# + lookup + #"\("#)
        for file in Self.swiftFiles(sourcesRoot) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let body = String(line)
                let range = NSRange(body.startIndex..., in: body)
                XCTAssertNil(pattern.firstMatch(in: body, range: range),
                             "\(file.lastPathComponent) glues a lookup onto something else — "
                                + "make the key a whole sentence with %1$@ arguments: \(body.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    // MARK: Helpers

    /// The four spellings of one lookup: `L(…)` / `Lp(…, count:)` in AppKit code, `i18n(…)` /
    /// `i18n.plural(…, count:)` inside a SwiftUI body. Leaving `i18n` out would leave every key
    /// a SwiftUI view reads unchecked — that is most of the status bar and the whole palette.
    private static let callForms: [(prefix: String, plural: Bool)] = [
        ("i18n.plural(", true), ("i18n(", false), ("Lp(", true), ("L(", false),
    ]

    /// Every localization key a call site names.
    ///
    /// Regex over the call line is not enough: the key can sit on its own line inside a ternary
    /// (`L(destructive ? "a" : "b")`) and one call can nest another. So this walks each call's
    /// balanced parentheses and keeps the key-shaped literals inside — all of them for a plain
    /// lookup, only the first for a plural one, whose later arguments may be a nested `L(…)`.
    private static func scanCallSites(_ root: URL) -> [(key: String, file: String)] {
        var out: [(String, String)] = []
        for file in swiftFiles(root) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let characters = Array(text)
            var i = 0
            while i < characters.count {
                // not the tail of a longer identifier (URL(, someL(, model.i18n()
                let attached = i > 0 && (characters[i - 1].isLetter || characters[i - 1].isNumber
                    || characters[i - 1] == "_" || characters[i - 1] == ".")
                guard !attached,
                      let form = callForms.first(where: { matches($0.prefix, characters, at: i) })
                else {
                    i += 1
                    continue
                }
                let open = i + form.prefix.count - 1
                let literals = stringLiterals(in: characters, openParenAt: open).filter(isKeyShaped)
                for key in form.plural ? Array(literals.prefix(1)) : literals {
                    if form.plural {
                        out.append(("\(key).one", file.lastPathComponent))
                        out.append(("\(key).other", file.lastPathComponent))
                    } else {
                        out.append((key, file.lastPathComponent))
                    }
                }
                // carry on from just after the "(": a nested call is scanned on its own
                i = open + 1
            }
        }
        return out
    }

    /// `needle` starts at `index`.
    private static func matches(_ needle: String, _ characters: [Character], at index: Int) -> Bool {
        let wanted = Array(needle)
        guard index + wanted.count <= characters.count else { return false }
        return Array(characters[index ..< index + wanted.count]) == wanted
    }

    /// The string literals inside one balanced `( … )`.
    private static func stringLiterals(in characters: [Character], openParenAt start: Int) -> [String] {
        var out: [String] = []
        var depth = 0
        var i = start
        while i < characters.count {
            switch characters[i] {
            case "(":
                depth += 1
                i += 1
            case ")":
                depth -= 1
                i += 1
                if depth == 0 { return out }
            case "\"":
                var literal = ""
                i += 1
                while i < characters.count, characters[i] != "\"" {
                    if characters[i] == "\\" { i += 1 }
                    if i < characters.count { literal.append(characters[i]) }
                    i += 1
                }
                i += 1
                out.append(literal)
            default:
                i += 1
            }
        }
        return out
    }

    /// `menu.shell.new-terminal` — lowercase, dot separated, at least two segments.
    private static func isKeyShaped(_ literal: String) -> Bool {
        guard literal.contains(".") else { return false }
        let segments = literal.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
        }
    }

    static let cjk = CharacterSet(charactersIn: "\u{3000}"..."\u{303F}")
        .union(CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}"))
        .union(CharacterSet(charactersIn: "\u{FF00}"..."\u{FFEF}"))

    /// Keys the Chinese table declares as deliberately identical to English: the entry that
    /// follows a `same-as-english` marker.
    ///
    /// Read out of the **bundle**, not the source tree — the copy phase keeps the comments, and
    /// the source tree is behind a macOS privacy prompt in this repo (see
    /// `requireReadableSources`), which would make this test skip on the machine it matters on.
    private static func sameAsEnglishKeys() throws -> Set<String> {
        guard let resources = Bundle.main.resourceURL else { return [] }
        let directory = resources.appendingPathComponent("zh-Hans.lproj")
        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: nil)
        let entry = try NSRegularExpression(pattern: #"^\s*"([^"]+)"\s*="#)
        var out: Set<String> = []
        for file in files where file.pathExtension == "strings" {
            // the copy phase rewrites the sources as UTF-16; let Foundation sniff which it is
            var encoding = String.Encoding.utf8
            let text = try String(contentsOf: file, usedEncoding: &encoding)
            var armed = false
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let body = String(line)
                if body.contains("same-as-english") { armed = true; continue }
                guard armed else { continue }
                let range = NSRange(body.startIndex..., in: body)
                guard let match = entry.firstMatch(in: body, range: range),
                      let key = Range(match.range(at: 1), in: body) else { continue }
                out.insert(String(body[key]))
                armed = false
            }
        }
        return out
    }

    private static func swiftFiles(_ root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted {
            $0.path < $1.path
        }
    }

    /// Format specifiers that are not `%n$@` (and not an escaped `%%`).
    static func nonPositionalSpecifiers(in value: String) -> [String] {
        var out: [String] = []
        let characters = Array(value)
        var i = 0
        while i < characters.count {
            guard characters[i] == "%" else { i += 1; continue }
            var j = i + 1
            guard j < characters.count else { out.append("a trailing %"); break }
            if characters[j] == "%" { i = j + 2; continue }          // %% is a literal percent
            var digits = ""
            while j < characters.count, characters[j].isNumber {
                digits.append(characters[j])
                j += 1
            }
            let isPositional = !digits.isEmpty && j + 1 < characters.count
                && characters[j] == "$" && characters[j + 1] == "@"
            if isPositional {
                i = j + 2
                continue
            }
            out.append("%\(digits)\(j < characters.count ? String(characters[j]) : "")")
            i = j + 1
        }
        return out
    }

    /// The set of argument positions a format string fills in.
    static func positionalIndices(in value: String) -> Set<Int> {
        guard let pattern = try? NSRegularExpression(pattern: #"%(\d+)\$@"#) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return Set(pattern.matches(in: value, range: range).compactMap { match in
            Range(match.range(at: 1), in: value).flatMap { Int(value[$0]) }
        })
    }

    /// A throwaway resource directory with its own `.lproj` tables, so fallback can be tested
    /// without mutilating the real catalog.
    private func makeFixtureBundle(en: [String: String], zh: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt-l10n-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (language, table) in [(AppLanguage.en, en), (AppLanguage.zh, zh)] {
            let lproj = root.appendingPathComponent("\(language.lprojName).lproj")
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            try (table as NSDictionary).write(to: lproj.appendingPathComponent("Localizable.strings"))
        }
        return root
    }
}
