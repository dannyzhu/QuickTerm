import AppKit
import OSLog
import WebKit

/// Host interface for the extension manager: reach every browser pane, the focused one, and open a
/// new browser pane. In the WebExtensions world a browser pane is a "window" and the tabs inside the
/// pane are its "tabs". Implemented by MainWindowController.
@MainActor
protocol BrowserExtensionHost: AnyObject {
    /// Browser panes across every workspace, the floating layer included.
    var browserPanes: [BrowserPaneView] { get }
    /// The browser pane holding keyboard focus, falling back to the most recently active one.
    var focusedBrowserPane: BrowserPaneView? { get }
    /// Open a new browser pane (an extension's windows.create).
    @discardableResult func openBrowserWindow(url: URL?) -> BrowserPaneView?
}

extension Notification.Name {
    /// Posted after an install, a removal, or an enable/disable; the toolbar rebuilds its buttons.
    static let browserExtensionsDidChange = Notification.Name("QuickTerm.browserExtensionsDidChange")
    /// An extension action's icon, badge or enabled state changed (object = WKWebExtensionContext).
    static let browserExtensionActionDidUpdate = Notification.Name("QuickTerm.browserExtensionActionDidUpdate")
}

enum BrowserExtensionError: LocalizedError {
    case invalidID
    case download(String)
    case notCRX
    case unpackFailed(String)
    case noManifest

    var errorDescription: String? {
        switch self {
        case .invalidID: L("browser.install.error.invalid-id")
        case .download(let why): L("browser.install.error.download", why)
        case .notCRX: L("browser.install.error.not-crx")
        case .unpackFailed(let why): L("browser.install.error.unpack", why)
        case .noManifest: L("browser.install.error.no-manifest")
        }
    }
}

/// Installation and runtime management of WebExtensions in Chrome / Firefox format, on top of
/// WKWebExtension (macOS 15.4+).
///
/// Unpacked extensions live in `~/Library/Application Support/QuickTerm/Extensions/<id>/`, with the
/// metadata in `state.json` in the same directory. WKWebExtensionController runs on a persistent
/// configuration keyed by a fixed UUID, so an extension's own storage survives on disk, and it shares
/// the default WKWebsiteDataStore with the browser tabs, so logins and cookies are shared.
///
/// Permissions: at install time everything the manifest asks for in `requestedPermissions` /
/// `requestedPermissionMatchPatterns` is granted outright, because the user already saw that list in
/// the install prompt. Anything an extension asks for later at runtime goes through the promptFor...
/// delegate prompts.
@MainActor
final class BrowserExtensionManager: NSObject, WKWebExtensionControllerDelegate {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "BrowserExtensions")

    enum Source: String, Codable {
        case webStore = "webstore"
        case chrome
        case local
    }

    /// The on-disk install record (`<store>/state.json`).
    struct Record: Codable, Equatable {
        var id: String
        var source: Source
        var version: String?
        var installedAt: Date
        var enabled: Bool
        /// Pinned to the toolbar, with Chrome's semantics: only pinned extensions get a button to the
        /// right of the address bar, everything else lives in the puzzle menu.
        var pinned: Bool

        init(id: String, source: Source, version: String?, installedAt: Date,
             enabled: Bool, pinned: Bool = false) {
            self.id = id
            self.source = source
            self.version = version
            self.installedAt = installedAt
            self.enabled = enabled
            self.pinned = pinned
        }

        /// state.json from 1.5.2 and earlier has no `pinned` key: a missing key means not pinned. Use
        /// decodeIfPresent, since a missing key must not make the whole record fail to decode.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            source = try container.decode(Source.self, forKey: .source)
            version = try container.decodeIfPresent(String.self, forKey: .version)
            installedAt = try container.decode(Date.self, forKey: .installedAt)
            enabled = try container.decode(Bool.self, forKey: .enabled)
            pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        }
    }

    /// The runtime triple for one installed extension.
    @MainActor
    final class Installed {
        var record: Record
        let webExtension: WKWebExtension
        let context: WKWebExtensionContext

        init(record: Record, webExtension: WKWebExtension, context: WKWebExtensionContext) {
            self.record = record
            self.webExtension = webExtension
            self.context = context
        }

        var id: String { record.id }
        var enabled: Bool { record.enabled }
        var pinned: Bool { record.pinned }
        var displayName: String { webExtension.displayName ?? record.id }
        var hasOptionsPage: Bool { webExtension.hasOptionsPage }
    }

    static let shared = BrowserExtensionManager()

    /// Tests only: point the panes and toolbars at a throwaway manager; reset to nil when done.
    static var overrideForTesting: BrowserExtensionManager?
    /// The manager actually used at runtime; panes, toolbars and menus all go through this.
    static var current: BrowserExtensionManager { overrideForTesting ?? shared }

    let storeDirectory: URL
    let controller: WKWebExtensionController
    weak var host: BrowserExtensionHost?
    private(set) var installed: [Installed] = []

    /// The `browser-extensions` config key: turning it off unloads every extension and stops the
    /// controller from being attached to newly created WebView configurations.
    var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            syncLoadedContexts()
            notifyExtensionsChanged()
        }
    }

    override convenience init() {
        // In the test host (TEST_HOST is the real app) never touch the user's real extension
        // directory: do not load the extensions they installed, and do not rewrite their state.json
        // or controller-id.
        if AppDelegate.isRunningTests {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("QuickTermTests/Extensions-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            self.init(configuration: .nonPersistent(), storeDirectory: temp)
            return
        }
        let store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { $0.appendingPathComponent("QuickTerm/Extensions", isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/QuickTerm/Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        self.init(configuration: .init(identifier: Self.persistentIdentifier(in: store)), storeDirectory: store)
    }

    /// For tests: a `.nonPersistent()` configuration plus a temporary store directory.
    init(configuration: WKWebExtensionController.Configuration, storeDirectory: URL) {
        // Extensions share the default data store with the tabs, so the cookies and logins an
        // extension sees are the very ones the user is browsing with.
        if configuration.isPersistent { configuration.defaultWebsiteDataStore = .default() }
        self.storeDirectory = storeDirectory
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        // A failure to load an extension's background (MV3's service worker) used to be completely
        // silent: WebKit only records the error into context.errors, which we never read, so all the
        // user sees is "clicking the extension icon does nothing". Subscribe and log them.
        NotificationCenter.default.addObserver(
            self, selector: #selector(contextErrorsDidUpdate(_:)),
            name: WKWebExtensionContext.errorsDidUpdateNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Errors already reported. WebKit hands you the entire history every time, so deduplicate or the
    /// log floods.
    private var reportedErrorKeys: Set<String> = []

    /// Test hook: records newly seen extension errors. Always nil in production.
    nonisolated(unsafe) static var errorRecorderForTesting: ((String, NSError) -> Void)?

    /// Test hook: records that an icon click really was dispatched through here. Always nil in
    /// production. The step that wakes the background lives in this method, and the UI calling
    /// `context.performAction(for:)` directly, bypassing it, is exactly the shape of that bug.
    nonisolated(unsafe) static var actionDispatchRecorderForTesting: ((String, BrowserPaneView.Tab?) -> Void)?

    @objc private func contextErrorsDidUpdate(_ note: Foundation.Notification) {
        guard let context = note.object as? WKWebExtensionContext,
              let item = installed.first(where: { $0.context === context }) else { return }
        reportNewErrors(of: item)
    }

    /// Log the errors that are newly present on the context, feeding the test hook too. Returns how
    /// many were new.
    @discardableResult
    func reportNewErrors(of item: Installed) -> Int {
        var count = 0
        for error in item.context.errors {
            let ns = error as NSError
            let key = "\(item.id)|\(ns.domain)|\(ns.code)|\(ns.localizedDescription)"
            guard !reportedErrorKeys.contains(key) else { continue }
            reportedErrorKeys.insert(key)
            count += 1
            let detail = "\(ns.domain)#\(ns.code) \(ns.localizedDescription)"
            Self.logger.warning("extension runtime error id=\(item.id, privacy: .public) \(detail, privacy: .public)")
            Self.errorRecorderForTesting?(item.id, ns)
        }
        return count
    }

    /// Clicking an extension icon (the toolbar button, or "Open" in the puzzle menu): wake the
    /// background content first, then run the action.
    ///
    /// An MV3 background service worker is reclaimed by WebKit after roughly 30 seconds idle, and
    /// `performAction(for:)` does not promise to bring it back. When it does not come back,
    /// `action.onClicked` never runs at all and the icon is simply mute (the user report: "Stylish's
    /// icon stops responding to clicks after a while"). So load it explicitly here: if it comes up,
    /// dispatch as usual; if it does not, at least the error reaches the log, where previously these
    /// failures left no trace whatsoever.
    /// An extension with no background content (a pure popup) is dispatched directly, without the
    /// detour.
    func performAction(of item: Installed, tab: BrowserPaneView.Tab?) {
        Self.actionDispatchRecorderForTesting?(item.id, tab)
        guard item.context.isLoaded else { return }
        guard item.webExtension.hasBackgroundContent else {
            item.context.performAction(for: tab)
            return
        }
        item.context.loadBackgroundContent { [weak self] error in
            MainActor.assumeIsolated {
                if let error {
                    let why = error.localizedDescription
                    Self.logger.warning("failed to wake extension background id=\(item.id, privacy: .public) error=\(why, privacy: .public)")
                    self?.reportNewErrors(of: item)
                }
                // Dispatch even after a failure: an extension with a popup should still show it.
                guard item.context.isLoaded else { return }
                item.context.performAction(for: tab)
            }
        }
    }

    /// The persistent controller identifier, kept in `<store>/controller-id`. Without it an
    /// extension's storage is not recognized again after a restart.
    private static func persistentIdentifier(in store: URL) -> UUID {
        let file = store.appendingPathComponent("controller-id")
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let uuid = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return uuid
        }
        let uuid = UUID()
        try? uuid.uuidString.write(to: file, atomically: true, encoding: .utf8)
        return uuid
    }

    // MARK: - Installed list

    private var stateURL: URL { storeDirectory.appendingPathComponent("state.json") }

    private func loadRecords() -> [Record] {
        guard let data = try? Data(contentsOf: stateURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Record].self, from: data)) ?? []
    }

    private func saveRecords() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(installed.map(\.record)) else { return }
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }

    /// Load every extension under `<store>/<id>/` at startup. A broken extension is logged and
    /// skipped; it takes down neither the other extensions nor the browser.
    func loadInstalled() async {
        let fm = FileManager.default
        let records = loadRecords()
        let dirs = (try? fm.contentsOfDirectory(at: storeDirectory,
                                                includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        var result: [Installed] = []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) else { continue }
            let id = dir.lastPathComponent
            let record = records.first { $0.id == id }
                ?? Record(id: id, source: .local, version: nil, installedAt: Date(), enabled: true)
            do {
                // A newer shim version, or an extension installed by an older build: patch it here.
                // Idempotent - already at the current version means this does nothing.
                applyCompatShim(to: dir, id: id)
                result.append(try await makeInstalled(record: record, directory: dir))
            } catch {
                Self.logger.warning("extension failed to load id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        installed = Self.sorted(result)
        saveRecords()
        notifyExtensionsChanged()
    }

    /// Apply the WebKit compatibility shim (see BrowserExtensionCompat). A failure is only logged: the
    /// extension still loads, just without the shim.
    private func applyCompatShim(to directory: URL, id: String) {
        do {
            try BrowserExtensionCompat.apply(to: directory)
        } catch {
            Self.logger.warning("failed to write extension compat shim id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func sorted(_ items: [Installed]) -> [Installed] {
        items.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Build the context: the id becomes the uniqueIdentifier so extension pages get a stable origin,
    /// permissions are granted, and only an enabled extension is attached to the controller.
    private func makeInstalled(record: Record, directory: URL) async throws -> Installed {
        let webExtension = try await WKWebExtension(resourceBaseURL: directory)
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = record.id
        // Setting uniqueIdentifier does not also change baseURL, which defaults to a random host that
        // differs on every construction. An extension page's origin (runtime.getURL, and the page-side
        // localStorage/IndexedDB that hang off it) has to be stable across restarts, so pin it
        // explicitly to the same id.
        if let base = URL(string: "webkit-extension://\(record.id)/"), base.host != nil {
            context.baseURL = base
        }
        context.isInspectable = BrowserPaneView.settings.inspectable
        grantRequestedPermissions(of: webExtension, to: context)
        var record = record
        record.version = webExtension.version ?? record.version
        let item = Installed(record: record, webExtension: webExtension, context: context)
        if record.enabled, isEnabled { load(item) }
        return item
    }

    /// Grant every permission and match pattern the manifest requested, all at once; the install
    /// prompt already listed them for the user.
    /// Note that the Date in the dictionary form is an **expiration date**, so passing `Date()` there
    /// expires the grant on the spot. Use the single-item setPermissionStatus interface instead, where
    /// omitting expirationDate means the distant future.
    private func grantRequestedPermissions(of webExtension: WKWebExtension, to context: WKWebExtensionContext) {
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        // allRequestedMatchPatterns is the superset: besides host_permissions it also covers the
        // matches from content_scripts, and without granting that set the content scripts never get
        // injected.
        for pattern in webExtension.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    private func load(_ item: Installed) {
        guard !item.context.isLoaded else { return }
        do {
            try controller.load(item.context)
        } catch {
            Self.logger.warning("failed to enable extension id=\(item.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func unload(_ item: Installed) {
        guard item.context.isLoaded else { return }
        try? controller.unload(item.context)
    }

    /// Reconcile the contexts attached to the controller with `isEnabled` and each extension's own
    /// enabled bit.
    private func syncLoadedContexts() {
        for item in installed {
            if isEnabled, item.enabled { load(item) } else { unload(item) }
        }
    }

    // MARK: - Enable / disable / remove

    func setEnabled(_ enabled: Bool, for item: Installed) {
        guard item.record.enabled != enabled else { return }
        item.record.enabled = enabled
        if enabled, isEnabled { load(item) } else { unload(item) }
        saveRecords()
        notifyExtensionsChanged()
    }

    /// Pin to or unpin from the toolbar (Chrome's "Pin to toolbar").
    func setPinned(_ pinned: Bool, for item: Installed) {
        guard item.record.pinned != pinned else { return }
        item.record.pinned = pinned
        saveRecords()
        notifyExtensionsChanged()
    }

    func remove(_ item: Installed) {
        unload(item)
        try? FileManager.default.removeItem(at: directory(for: item.id))
        installed.removeAll { $0 === item }
        saveRecords()
        notifyExtensionsChanged()
    }

    func directory(for id: String) -> URL {
        storeDirectory.appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - The page-side externally_connectable shim

    /// The `chrome.runtime` alias injected into ordinary web pages (see
    /// BrowserExtensionCompat.externalMessagingScript). The list of addresses comes from each
    /// extension manifest's `externally_connectable.matches`: if nothing declares any, this stays nil
    /// and nothing is injected.
    private(set) var externalMessagingUserScript: WKUserScript?

    /// Recompute the page-side shim after the set of extensions, or their enabled state, changes.
    private func refreshExternalMessagingScript() {
        let matches = isEnabled
            ? installed.filter(\.enabled).flatMap {
                BrowserExtensionCompat.externallyConnectableMatches(in: directory(for: $0.id))
            }
            : []
        externalMessagingUserScript = BrowserExtensionCompat.externalMessagingUserScript(matches: matches)
    }

    /// The single exit after an install, a removal or an enable/disable: compute the page-side shim
    /// first, then broadcast, so panes reinstall their injected scripts when they receive it.
    private func notifyExtensionsChanged() {
        refreshExternalMessagingScript()
        NotificationCenter.default.post(name: .browserExtensionsDidChange, object: self)
    }

    func installedExtension(withID id: String) -> Installed? {
        installed.first { $0.id == id }
    }

    /// Returns the context when the URL points at a **loaded** extension's own page
    /// (`webkit-extension://<id>/...`). The main frame of such a page can only be loaded in a WebView
    /// built from `context.webViewConfiguration`: WebKit rejects it outright in a WebView with an
    /// ordinary configuration (NSURLErrorResourceUnavailable), and conversely a WebView with an
    /// extension configuration cannot reach http(s).
    func extensionContext(forResourceURL url: URL) -> WKWebExtensionContext? {
        // Short-circuit the common schemes; only ask the controller about what is left.
        guard isEnabled, let scheme = url.scheme?.lowercased(),
              !["http", "https", "file", "about", "data", "blob"].contains(scheme) else { return nil }
        return controller.extensionContext(for: url)
    }

    /// An extension's options page: opened in a new tab of the focused browser pane.
    /// Remember that a `webkit-extension://` main-frame load can only happen in a WebView built from
    /// `context.webViewConfiguration`; `BrowserPaneView.addTab` picks the configuration from the URL
    /// itself (see makeWebView there).
    @discardableResult
    func openOptions(for item: Installed) -> Bool {
        guard let url = item.context.optionsPageURL else { return false }
        return openInBrowser(url)
    }

    /// Returns whether a tab was actually opened. False when no pane is available, which the delegate
    /// needs in order to report an error rather than claim a success that did not happen.
    @discardableResult
    private func openInBrowser(_ url: URL) -> Bool {
        if let pane = host?.focusedBrowserPane ?? host?.browserPanes.first {
            pane.addTab(url: url, activate: true)
            return true
        }
        return host?.openBrowserWindow(url: url) != nil
    }

    // MARK: - Installation (Chrome Web Store / a local directory / import from Chrome)

    /// Direct CRX link on the Web Store: the same update-service endpoint Chrome itself uses.
    nonisolated static func webStoreDownloadURL(id: String) -> URL {
        URL(string: "https://clients2.google.com/service/update2/crx?response=redirect"
            + "&prodversion=131.0.0.0&x=id%3D\(id)%26installsource%3Dondemand%26uc"
            + "&acceptformat=crx2,crx3")!
    }

    /// Web Store detail page URL -> extension ID (`.../detail/<slug>/<id>`; both hostnames accepted).
    nonisolated static func extensionID(fromWebStoreURL url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == "chromewebstore.google.com" || host == "chrome.google.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let detail = parts.firstIndex(of: "detail") else { return nil }
        return parts[(detail + 1)...].first { isValidExtensionID($0) }
    }

    /// Extension ID: 32 letters from a-p, Chrome's variant base16 encoding.
    nonisolated static func isValidExtensionID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { $0.isASCII && $0 >= "a" && $0 <= "p" }
    }

    /// An extension that has been downloaded and unpacked but not yet installed into the store: the
    /// install confirmation prompt needs its name and permission list first.
    @MainActor
    struct Staged {
        let id: String
        /// Temporary container, deleted after commit or discard.
        let container: URL
        /// The extension's root directory, the one holding manifest.json.
        let directory: URL
        let webExtension: WKWebExtension

        var displayName: String { webExtension.displayName ?? id }
        /// The permission list shown to the user: permission names plus match patterns.
        var permissionSummary: [String] {
            webExtension.requestedPermissions.map(\.rawValue).sorted()
                + webExtension.allRequestedMatchPatterns.map(\.string).sorted()
        }
    }

    /// Download and unpack from the Chrome Web Store; nothing is installed yet.
    func stageWebStoreInstall(id: String, progress: @escaping (String) -> Void = { _ in }) async throws -> Staged {
        guard Self.isValidExtensionID(id) else { throw BrowserExtensionError.invalidID }
        progress(L("browser.install.progress.downloading"))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: Self.webStoreDownloadURL(id: id))
        } catch {
            throw BrowserExtensionError.download(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BrowserExtensionError.download("HTTP \(http.statusCode)")
        }
        guard let zip = CRX.zipData(from: data) else { throw BrowserExtensionError.notCRX }
        progress(L("browser.install.progress.unpacking"))
        let unpacked = try Self.unpack(zip: zip)
        do {
            let webExtension = try await WKWebExtension(resourceBaseURL: unpacked.payload)
            return Staged(id: id, container: unpacked.container, directory: unpacked.payload,
                          webExtension: webExtension)
        } catch {
            try? FileManager.default.removeItem(at: unpacked.container)
            throw error
        }
    }

    /// Actually install into the store, once confirmed.
    @discardableResult
    func commit(_ staged: Staged) async throws -> Installed {
        defer { try? FileManager.default.removeItem(at: staged.container) }
        // The user explicitly clicked "Add to QuickTerm" on the store page, so pin to the toolbar by
        // default, exactly as Chrome does.
        return try await install(directory: staged.directory, id: staged.id, source: .webStore, pinned: true)
    }

    /// The user cancelled: delete the temporary files.
    func discard(_ staged: Staged) {
        try? FileManager.default.removeItem(at: staged.container)
    }

    /// Install from the Chrome Web Store. Updates take the same path: an existing directory is
    /// removed first.
    @discardableResult
    func install(fromWebStore id: String, progress: @escaping (String) -> Void = { _ in }) async throws -> Installed {
        let staged = try await stageWebStoreInstall(id: id, progress: progress)
        progress(L("browser.install.progress.installing"))
        return try await commit(staged)
    }

    /// Install an already-unpacked extension directory into the store. Local extensions, Chrome
    /// imports and unpacked Web Store downloads all go through here.
    @discardableResult
    func install(directory: URL, id: String, source: Source, pinned: Bool = false) async throws -> Installed {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) else {
            throw BrowserExtensionError.noManifest
        }
        let destination = self.directory(for: id)
        let existing = installedExtension(withID: id)
        if let existing {
            unload(existing)
            installed.removeAll { $0 === existing }
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try fm.copyItem(at: directory, to: destination)
        applyCompatShim(to: destination, id: id)
        // A reinstall or an update - and the store page's "Add to QuickTerm" is also this path - keeps
        // whatever pinning choice the user already made: if they unpinned it by hand, an update must
        // not shove the button back into the toolbar (Chrome likewise leaves pinned_extensions alone
        // when it updates an extension). Only a first install uses the caller's default.
        let record = Record(id: id, source: source, version: nil, installedAt: Date(), enabled: true,
                            pinned: existing?.record.pinned ?? pinned)
        let item = try await makeInstalled(record: record, directory: destination)
        installed = Self.sorted(installed + [item])
        saveRecords()
        notifyExtensionsChanged()
        return item
    }

    /// Extract the zip inside a CRX into a temporary directory. Returns (temporary container, the real
    /// extension root).
    private static func unpack(zip: Data) throws -> (container: URL, payload: URL) {
        let fm = FileManager.default
        let container = fm.temporaryDirectory.appendingPathComponent("quickterm-ext-\(UUID().uuidString)",
                                                                     isDirectory: true)
        let payload = container.appendingPathComponent("payload", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        let zipURL = container.appendingPathComponent("extension.zip")
        try zip.write(to: zipURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, payload.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw BrowserExtensionError.unpackFailed(error.localizedDescription)
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BrowserExtensionError.unpackFailed(String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if fm.fileExists(atPath: payload.appendingPathComponent("manifest.json").path) {
            return (container, payload)
        }
        // A few packages wrap everything in one extra directory.
        let inner = (try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil))?
            .first { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
        guard let inner else { throw BrowserExtensionError.noManifest }
        return (container, inner)
    }

    // MARK: - Import from the local Chrome

    nonisolated static var defaultChromeProfile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default", isDirectory: true)
    }

    /// Scan `<profile>/Extensions/<id>/<version>/manifest.json`, taking the highest-versioned
    /// directory for each extension. Themes (a manifest with `theme`), packaged apps (`app`) and
    /// anything without a `name` are skipped.
    nonisolated static func chromeCandidates(inExtensions extensionsDirectory: URL) -> [(id: String, directory: URL)] {
        let fm = FileManager.default
        let ids = (try? fm.contentsOfDirectory(at: extensionsDirectory, includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles])) ?? []
        var result: [(id: String, directory: URL)] = []
        for idDir in ids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = idDir.lastPathComponent
            guard isValidExtensionID(id) else { continue }
            let versions = ((try? fm.contentsOfDirectory(at: idDir, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? [])
                .filter { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
                .sorted { compareVersions($0.lastPathComponent, $1.lastPathComponent) }
            guard let newest = versions.last, isImportableManifest(at: newest) else { continue }
            result.append((id, newest))
        }
        return result
    }

    /// Whether a manifest is installable: it has a name, and it is neither a theme nor a packaged app.
    nonisolated static func isImportableManifest(at directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if json["theme"] != nil || json["app"] != nil { return false }
        // The name may be a __MSG_xxx__ localization placeholder; all that matters is that it exists.
        guard let name = json["name"] as? String, !name.isEmpty else { return false }
        return true
    }

    /// Numeric segment comparison, so that "1.2.0" < "1.10"; when the segment counts differ the
    /// shorter one is padded with zeros.
    /// Chrome names its version directories `<version>_<installCount>` (`1.15.4_1`), and `Int("4_1")`
    /// is nil: without stripping the `_N` first, the last segment reads as 0 and `1.15.4_1` compares
    /// equal to `1.15.5_0`, which picks the older version.
    nonisolated static func compareVersions(_ lhs: String, _ rhs: String) -> Bool {
        func parse(_ s: String) -> (segments: [Int], install: Int) {
            let parts = s.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
            let segments = parts[0].split(separator: ".").map { Int($0) ?? 0 }
            let install = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            return (segments, install)
        }
        let a = parse(lhs), b = parse(rhs)
        for i in 0..<max(a.segments.count, b.segments.count) {
            let x = i < a.segments.count ? a.segments[i] : 0
            let y = i < b.segments.count ? b.segments[i] : 0
            if x != y { return x < y }
        }
        // Equal versions fall back to the install count, which is how Chrome tells reinstall
        // directories of the same version apart.
        return a.install < b.install
    }

    /// The ids Chrome has pinned to its toolbar: `extensions.pinned_extensions` in the JSON at
    /// `<profile>/Preferences`. A missing file, non-JSON content or a missing key all return the empty
    /// set, meaning nothing is pinned after the import - which is not an error.
    nonisolated static func chromePinnedExtensionIDs(preferences: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: preferences),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extensions = json["extensions"] as? [String: Any],
              let pinned = extensions["pinned_extensions"] as? [Any] else { return [] }
        return Set(pinned.compactMap { $0 as? String })
    }

    /// Import the extensions installed in the local Chrome; anything already installed is skipped.
    @discardableResult
    func importFromChrome(profile: URL = BrowserExtensionManager.defaultChromeProfile)
        async -> (imported: Int, skipped: Int, failed: [String]) {
        let candidates = Self.chromeCandidates(inExtensions: profile.appendingPathComponent("Extensions",
                                                                                            isDirectory: true))
        // Whatever was pinned to the toolbar in Chrome stays pinned after the import; the rest live
        // only in the puzzle menu, so a few dozen extensions do not squeeze out the address bar.
        let pinned = Self.chromePinnedExtensionIDs(preferences: profile.appendingPathComponent("Preferences"))
        var imported = 0, skipped = 0
        var failed: [String] = []
        for candidate in candidates {
            if installedExtension(withID: candidate.id) != nil { skipped += 1; continue }
            do {
                _ = try await install(directory: candidate.directory, id: candidate.id, source: .chrome,
                                      pinned: pinned.contains(candidate.id))
                imported += 1
            } catch {
                failed.append(candidate.id)
                Self.logger.warning("failed to import Chrome extension id=\(candidate.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        return (imported, skipped, failed)
    }

    // MARK: - WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        host?.browserPanes ?? []
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        host?.focusedBrowserPane
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let pane = (configuration.window as? BrowserPaneView) ?? host?.focusedBrowserPane ?? host?.browserPanes.first
        guard let pane else {
            completionHandler(nil, Self.unsupported("No browser pane is available."))
            return
        }
        let tab = pane.addTab(url: configuration.url ?? BrowserPaneView.settings.homeURL,
                              activate: configuration.shouldBeActive)
        completionHandler(tab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        guard let pane = host?.openBrowserWindow(url: configuration.tabURLs.first) else {
            completionHandler(nil, Self.unsupported("No browser window is available."))
            return
        }
        completionHandler(pane, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openOptionsPageFor context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let url = context.optionsPageURL else {
            completionHandler(Self.unsupported("This extension has no options page."))
            return
        }
        guard openInBrowser(url) else {
            completionHandler(Self.unsupported("No browser pane is available."))
            return
        }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let names = permissions.map(\.rawValue).sorted()
        let allowed = confirmPermission(context: context, items: names)
        completionHandler(allowed ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let names = urls.map(\.absoluteString).sorted()
        let allowed = confirmPermission(context: context, items: names)
        completionHandler(allowed ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let names = patterns.map(\.string).sorted()
        let allowed = confirmPermission(context: context, items: names)
        completionHandler(allowed ? patterns : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        NotificationCenter.default.post(name: .browserExtensionActionDidUpdate, object: context)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        let pane = (action.associatedTab as? BrowserPaneView.Tab)?.pane ?? host?.focusedBrowserPane
        guard let pane else {
            completionHandler(Self.unsupported("No browser pane is available."))
            return
        }
        pane.presentExtensionPopup(action, of: context)
        completionHandler(nil)
    }

    /// Native messaging (chrome.runtime.connectNative / sendNativeMessage): QuickTerm ships no host
    /// program, so report an explicit error.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any,
                                toApplicationWithIdentifier applicationIdentifier: String?,
                                for context: WKWebExtensionContext,
                                replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        replyHandler(nil, Self.unsupported("QuickTerm does not support native messaging."))
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                connectUsing port: WKWebExtension.MessagePort,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(Self.unsupported("QuickTerm does not support native messaging."))
    }

    static func unsupported(_ message: String) -> NSError {
        NSError(domain: "QuickTerm.BrowserExtensions", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// The permission prompt. A sheet attached to the key window cannot return synchronously, and what
    /// is needed here is an immediate allow/deny answer, so use runModal.
    private func confirmPermission(context: WKWebExtensionContext, items: [String]) -> Bool {
        let name = context.webExtension.displayName ?? L("browser.extension.unnamed")
        let alert = NSAlert()
        alert.messageText = L("browser.permission.title", name)
        alert.informativeText = items.isEmpty ? L("browser.permission.none") : items.joined(separator: "\n")
        alert.addButton(withTitle: L("browser.permission.allow"))
        alert.addButton(withTitle: L("browser.permission.deny"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// A CRX (a Chrome extension package) is a custom header followed by a zip. Strip the header to get
/// the zip bytes.
enum CRX {
    static func zipData(from data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, bytes[0...3].elementsEqual(Array("Cr24".utf8)) else { return nil }
        let header: UInt64
        switch le32(bytes, 4) {
        case 2:
            // v2: a 16-byte fixed header, then the public key, then the signature.
            header = 16 + UInt64(le32(bytes, 8)) + UInt64(le32(bytes, 12))
        case 3:
            // v3: a 12-byte fixed header, then a protobuf header.
            header = 12 + UInt64(le32(bytes, 8))
        default:
            return nil
        }
        guard header <= UInt64(bytes.count) else { return nil }
        return Data(bytes[Int(header)...])
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
