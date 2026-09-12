import Combine
import Foundation

/// The app's bilingual UI (English + Simplified Chinese).
///
/// English is the development/base language: every key exists in `en.lproj`, and a key that is
/// missing from another table falls back to the English value — never to the raw key, which is
/// what a user would otherwise read on screen.
///
/// Three deliberate choices:
/// 1. **The catalogs are read straight out of the `.lproj` directories**, not through
///    `Bundle.main.localizedString`. The active language is ours to decide (`[general] language`
///    can pin it), so letting `Bundle` pick from the system's preferred languages would mean two
///    different answers to "what language is the UI in" — and the one the user configured would
///    lose. Reading the files also lets `LocalizationTests` diff the key sets of the two tables.
/// 2. **One area owns one table.** Every `*.strings` file inside a `.lproj` is loaded and
///    merged (`Menus.strings`, `Control.strings`, …), so parallel translation passes each add
///    their own file instead of all appending to one shared table. A key defined in two tables
///    is a bug and `LocalizationTests` fails on it.
/// 3. **The only format specifiers are positional** (`%1$@`, `%2$@` …) and every argument is
///    rendered with `String(describing:)` before formatting. Word order differs between the two
///    languages, so a translator has to be able to reorder the values; and because nothing but
///    `%n$@` ever reaches `String(format:)`, a mistranslated format can never crash the app.
///
/// Not localized, by policy: the `quickterm` CLI, OSLog output, wire identifiers, config keys and
/// pane handles. Those are English in both languages.
final class Localization: ObservableObject {
    static let shared = Localization()

    /// Posted on the main queue after `language` changes. AppKit code that cannot observe an
    /// `ObservableObject` (the main menu, for one) rebuilds itself on this.
    static let didChangeNotification = Notification.Name("dev.danny.quickterm.localizationDidChange")

    /// The language the UI is drawn in right now. `@Published`, so SwiftUI re-renders on a change.
    @Published private(set) var language: AppLanguage

    /// The value of `[general] language` as written in the config file (`auto` | `en` | `zh`).
    private(set) var configValue = "auto"

    /// The directory the `.lproj` folders sit in. Injectable so tests can point at a fixture
    /// instead of mutilating the real catalog.
    private let resourceURL: URL?
    private var catalogs: [AppLanguage: Catalog] = [:]

    /// One language's merged catalog.
    struct Catalog {
        /// key -> format string, merged across every `*.strings` table in the `.lproj`
        var strings: [String: String] = [:]
        /// table name -> the keys it declares (so a test can spot a key claimed by two tables)
        var tables: [String: Set<String>] = [:]
    }

    init(resourceURL: URL? = Bundle.main.resourceURL,
         preferred: [String] = Locale.preferredLanguages) {
        self.resourceURL = resourceURL
        self.language = AppLanguage.resolve(configValue: "auto", preferred: preferred)
    }

    // MARK: Active language

    /// Apply `[general] language`. Idempotent: an unchanged value publishes nothing, so a config
    /// hot reload that touched some other key does not rebuild every menu in the app.
    @discardableResult
    func apply(configValue raw: String, preferred: [String] = Locale.preferredLanguages) -> Bool {
        configValue = raw
        return setLanguage(AppLanguage.resolve(configValue: raw, preferred: preferred))
    }

    /// Force a language regardless of the config. Only for tests and for the language picker a
    /// future settings window will have.
    @discardableResult
    func setLanguage(_ next: AppLanguage) -> Bool {
        guard next != language else { return false }
        language = next
        // Process-wide effects belong to the process-wide instance only: a fixture built by a
        // test must not repaint the real menu bar or flip the language the config template is
        // written in.
        guard self === Self.shared else { return true }
        ConfigSchema.templateLanguage = next
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return true
    }

    // MARK: Lookup

    /// A whole sentence or label, with its positional arguments filled in.
    ///
    /// Prefer the global `L(_:_:)` in AppKit code and `i18n(...)` inside a SwiftUI body.
    func string(_ key: String, _ arguments: [any CustomStringConvertible] = []) -> String {
        guard let format = format(key) else {
            // A key that exists in no table would otherwise be drawn on screen as
            // "menu.shell.new-terminal". Loud in debug, harmless in release.
            assertionFailure("Missing localization key: \(key)")
            return key
        }
        guard !arguments.isEmpty else { return format }
        let values = arguments.map { String(describing: $0) as CVarArg }
        return String(format: format, arguments: values)
    }

    /// The format string for a key: active language first, English second.
    func format(_ key: String, in language: AppLanguage? = nil) -> String? {
        let active = language ?? self.language
        if let hit = catalog(active).strings[key] { return hit }
        guard active != .en else { return nil }
        return catalog(.en).strings[key]
    }

    /// A language's catalog, loaded once.
    func catalog(_ language: AppLanguage) -> Catalog {
        if let cached = catalogs[language] { return cached }
        let loaded = Self.loadCatalog(language, resourceURL: resourceURL)
        catalogs[language] = loaded
        return loaded
    }

    /// Read every `*.strings` file in `<language>.lproj` and merge them.
    ///
    /// `NSDictionary(contentsOf:)` reads both the UTF-8 source form and the UTF-16 form Xcode's
    /// copy phase produces, so this is the same code path in the repo and in the built bundle.
    static func loadCatalog(_ language: AppLanguage, resourceURL: URL?) -> Catalog {
        var out = Catalog()
        guard let resourceURL else { return out }
        let lproj = resourceURL.appendingPathComponent("\(language.lprojName).lproj")
        let files = (try? FileManager.default.contentsOfDirectory(at: lproj,
                                                                  includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "strings" }
            // InfoPlist.strings belongs to the system (Info.plist keys, read by launchd/TCC
            // long before this class exists); it is not part of the app's own catalog
            .filter { $0.deletingPathExtension().lastPathComponent != "InfoPlist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        for file in files {
            guard let table = NSDictionary(contentsOf: file) as? [String: String] else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            out.tables[name] = Set(table.keys)
            out.strings.merge(table) { current, _ in current }
        }
        return out
    }
}

// MARK: - SwiftUI call form

extension Localization {
    /// `i18n("menu.pane")` / `i18n("consent.subject.pane", handle, title)` inside a SwiftUI body.
    /// Reading through the observed object is what makes the view re-render on a language change.
    func callAsFunction(_ key: String, _ arguments: any CustomStringConvertible...) -> String {
        string(key, arguments)
    }

    /// Count-dependent form: picks `<base>.one` or `<base>.other`.
    func plural(_ base: String, count: Int, _ arguments: any CustomStringConvertible...) -> String {
        string(Self.pluralKey(base, count: count), arguments)
    }

    static func pluralKey(_ base: String, count: Int) -> String {
        "\(base).\(count == 1 ? "one" : "other")"
    }
}

// MARK: - AppKit call form

/// One whole localized sentence or label. The single lookup used by AppKit code (menus, NSAlert).
///
/// The key holds the WHOLE sentence; values are passed as positional arguments so the translation
/// can put them wherever that language needs them:
///
///     L("consent.summary.applies-to", subject)
///
/// Never glue two lookups together with `+` or string interpolation — that is exactly the shape
/// that cannot be translated, and `LocalizationTests.testNoCallSiteConcatenatesLookups` fails on it.
func L(_ key: String, _ arguments: any CustomStringConvertible...) -> String {
    Localization.shared.string(key, arguments)
}

/// Count-dependent form: `Lp("consent.subject.screen", count: n, index, title, n)` reads
/// `consent.subject.screen.one` when `n == 1` and `…other` otherwise. The count is NOT inserted
/// for you — pass it among the arguments wherever the sentence needs it.
func Lp(_ base: String, count: Int, _ arguments: any CustomStringConvertible...) -> String {
    Localization.shared.string(Localization.pluralKey(base, count: count), arguments)
}
