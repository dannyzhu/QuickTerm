import AppKit
import OSLog
import WebKit

/// 扩展管理器的宿主接口：拿到全部 / 焦点浏览器 pane，以及新开一个浏览器 pane。
/// 在 WebExtensions 的世界里，一个浏览器 pane 就是一个"窗口"，pane 里的标签就是"标签"。
/// MainWindowController 实现。
@MainActor
protocol BrowserExtensionHost: AnyObject {
    /// 全部工作区（含浮动层）里的浏览器 pane
    var browserPanes: [BrowserPaneView] { get }
    /// 持有键盘焦点的浏览器 pane；没有就取最近激活的那个
    var focusedBrowserPane: BrowserPaneView? { get }
    /// 新开一个浏览器 pane（扩展的 windows.create）
    @discardableResult func openBrowserWindow(url: URL?) -> BrowserPaneView?
}

extension Notification.Name {
    /// 安装 / 移除 / 启停之后（工具条按钮重建）
    static let browserExtensionsDidChange = Notification.Name("QuickTerm.browserExtensionsDidChange")
    /// 某个扩展动作的图标 / badge / 可用性变了（object = WKWebExtensionContext）
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
        case .invalidID: "不是有效的扩展 ID"
        case .download(let why): "下载失败：\(why)"
        case .notCRX: "下载到的不是 Chrome 扩展包（CRX）"
        case .unpackFailed(let why): "解包失败：\(why)"
        case .noManifest: "扩展包里没有 manifest.json"
        }
    }
}

/// WebExtensions（Chrome / Firefox 格式）的安装与运行时管理（macOS 15.4+ 的 WKWebExtension）。
///
/// 扩展解包后存在 `~/Library/Application Support/QuickTerm/Extensions/<id>/`，元数据在同目录的
/// `state.json`；WKWebExtensionController 用固定 UUID 的持久配置（扩展自己的 storage 落盘），
/// 并与浏览器标签共用默认的 WKWebsiteDataStore（登录态 / cookie 共享）。
///
/// 权限：安装时把 manifest 里 `requestedPermissions` / `requestedPermissionMatchPatterns` 全部授予
/// （用户在安装弹窗里已经看过一遍清单）；运行时扩展再要的东西走 promptFor… 代理弹窗。
@MainActor
final class BrowserExtensionManager: NSObject, WKWebExtensionControllerDelegate {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "BrowserExtensions")

    enum Source: String, Codable {
        case webStore = "webstore"
        case chrome
        case local
    }

    /// 落盘的安装记录（`<store>/state.json`）
    struct Record: Codable, Equatable {
        var id: String
        var source: Source
        var version: String?
        var installedAt: Date
        var enabled: Bool
        /// 固定到工具条（Chrome 语义）：只有固定的扩展在地址栏右边有按钮，其它的都在拼图菜单里
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

        /// 1.5.2 及更早的 state.json 没有 pinned 键：缺键 = 不固定（decodeIfPresent，不能让整条记录解不出来）
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

    /// 一个已安装扩展的运行时三元组
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

    /// 仅测试：把 pane / 工具条指向一个临时管理器（用完还原成 nil）
    static var overrideForTesting: BrowserExtensionManager?
    /// 运行时实际使用的管理器（pane、工具条、菜单都走这里）
    static var current: BrowserExtensionManager { overrideForTesting ?? shared }

    let storeDirectory: URL
    let controller: WKWebExtensionController
    weak var host: BrowserExtensionHost?
    private(set) var installed: [Installed] = []

    /// config `browser-extensions`：关掉时全部 unload，且 controller 不再挂到新建的 WebView 配置上
    var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            syncLoadedContexts()
            NotificationCenter.default.post(name: .browserExtensionsDidChange, object: self)
        }
    }

    override convenience init() {
        // 测试宿主（TEST_HOST = 真实 app）里绝不碰用户真实的扩展目录：不加载用户装的扩展，
        // 也不改写他的 state.json / controller-id
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

    /// 测试用：`.nonPersistent()` 配置 + 临时 store 目录
    init(configuration: WKWebExtensionController.Configuration, storeDirectory: URL) {
        // 扩展与标签共用默认数据存储：扩展看到的 cookie / 登录态与用户浏览的是同一份
        if configuration.isPersistent { configuration.defaultWebsiteDataStore = .default() }
        self.storeDirectory = storeDirectory
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    /// 持久 controller 标识：存在 `<store>/controller-id`，重启后扩展的 storage 才认得回来
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

    // MARK: - 安装列表

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

    /// 启动时加载 `<store>/<id>/` 下的全部扩展。坏扩展只记日志跳过，不影响其它扩展与浏览器
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
                result.append(try await makeInstalled(record: record, directory: dir))
            } catch {
                Self.logger.warning("扩展加载失败 id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        installed = Self.sorted(result)
        saveRecords()
        NotificationCenter.default.post(name: .browserExtensionsDidChange, object: self)
    }

    private static func sorted(_ items: [Installed]) -> [Installed] {
        items.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// 建 context：id 作为 uniqueIdentifier（扩展页面的 origin 稳定），授权，enabled 才挂上 controller
    private func makeInstalled(record: Record, directory: URL) async throws -> Installed {
        let webExtension = try await WKWebExtension(resourceBaseURL: directory)
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = record.id
        // uniqueIdentifier 不会连带改 baseURL（默认是每次新建都不同的随机 host）：扩展页面的 origin
        // （runtime.getURL、页面侧 localStorage/IndexedDB）要跨重启稳定，这里显式对齐成同一个 id
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

    /// manifest 里请求的权限与匹配模式一次性全部授予（安装弹窗已列给用户看过）。
    /// 注意字典里的 Date 是**过期时间**，直接写 `Date()` 等于当场失效——用 setPermissionStatus
    /// 的单项接口（不带 expirationDate = distant future）
    private func grantRequestedPermissions(of webExtension: WKWebExtension, to context: WKWebExtensionContext) {
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        // allRequestedMatchPatterns 是超集：除 host_permissions 外还含 content_scripts 的 matches，
        // 不授这一份内容脚本注入不进去
        for pattern in webExtension.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    private func load(_ item: Installed) {
        guard !item.context.isLoaded else { return }
        do {
            try controller.load(item.context)
        } catch {
            Self.logger.warning("扩展启用失败 id=\(item.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func unload(_ item: Installed) {
        guard item.context.isLoaded else { return }
        try? controller.unload(item.context)
    }

    /// 让 controller 上挂着的 context 与 `isEnabled` + 每个扩展的启用位一致
    private func syncLoadedContexts() {
        for item in installed {
            if isEnabled, item.enabled { load(item) } else { unload(item) }
        }
    }

    // MARK: - 启用 / 停用 / 移除

    func setEnabled(_ enabled: Bool, for item: Installed) {
        guard item.record.enabled != enabled else { return }
        item.record.enabled = enabled
        if enabled, isEnabled { load(item) } else { unload(item) }
        saveRecords()
        NotificationCenter.default.post(name: .browserExtensionsDidChange, object: self)
    }

    /// 固定 / 取消固定到工具条（Chrome 的「Pin to toolbar」）
    func setPinned(_ pinned: Bool, for item: Installed) {
        guard item.record.pinned != pinned else { return }
        item.record.pinned = pinned
        saveRecords()
        NotificationCenter.default.post(name: .browserExtensionsDidChange, object: self)
    }

    func remove(_ item: Installed) {
        unload(item)
        try? FileManager.default.removeItem(at: directory(for: item.id))
        installed.removeAll { $0 === item }
        saveRecords()
        NotificationCenter.default.post(name: .browserExtensionsDidChange, object: self)
    }

    func directory(for id: String) -> URL {
        storeDirectory.appendingPathComponent(id, isDirectory: true)
    }

    func installedExtension(withID id: String) -> Installed? {
        installed.first { $0.id == id }
    }

    /// URL 指向某个**已加载**扩展自己的页面（`webkit-extension://<id>/…`）时返回它的 context。
    /// 这种页面的主帧只能在 `context.webViewConfiguration` 建的 WebView 里加载：普通配置的 WebView
    /// 会被 WebKit 直接拒掉（NSURLErrorResourceUnavailable），反过来扩展配置的 WebView 也去不了 http(s)
    func extensionContext(forResourceURL url: URL) -> WKWebExtensionContext? {
        // 常见 scheme 直接短路，剩下的才问 controller
        guard isEnabled, let scheme = url.scheme?.lowercased(),
              !["http", "https", "file", "about", "data", "blob"].contains(scheme) else { return nil }
        return controller.extensionContext(for: url)
    }

    /// 扩展的选项页：在焦点浏览器 pane 里新标签打开。
    /// 注意 `webkit-extension://` 的主帧加载只能发生在 `context.webViewConfiguration` 建的 WebView 里，
    /// 这件事由 `BrowserPaneView.addTab` 按 URL 自己挑配置（见那里的 makeWebView）
    @discardableResult
    func openOptions(for item: Installed) -> Bool {
        guard let url = item.context.optionsPageURL else { return false }
        return openInBrowser(url)
    }

    /// 返回是否真的开出了标签（没有可用 pane 时 false，代理要据此回错，不能谎报成功）
    @discardableResult
    private func openInBrowser(_ url: URL) -> Bool {
        if let pane = host?.focusedBrowserPane ?? host?.browserPanes.first {
            pane.addTab(url: url, activate: true)
            return true
        }
        return host?.openBrowserWindow(url: url) != nil
    }

    // MARK: - 安装（Chrome Web Store / 本地目录 / 从 Chrome 导入）

    /// Web Store 的 CRX 直链（与 Chrome 自己用的更新服务同一个接口）
    nonisolated static func webStoreDownloadURL(id: String) -> URL {
        URL(string: "https://clients2.google.com/service/update2/crx?response=redirect"
            + "&prodversion=131.0.0.0&x=id%3D\(id)%26installsource%3Dondemand%26uc"
            + "&acceptformat=crx2,crx3")!
    }

    /// Web Store 详情页 URL → 扩展 ID（`…/detail/<slug>/<id>`；两种域名都认）
    nonisolated static func extensionID(fromWebStoreURL url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == "chromewebstore.google.com" || host == "chrome.google.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let detail = parts.firstIndex(of: "detail") else { return nil }
        return parts[(detail + 1)...].first { isValidExtensionID($0) }
    }

    /// 扩展 ID：32 个 a–p 字母（Chrome 的 base16 变体编码）
    nonisolated static func isValidExtensionID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { $0.isASCII && $0 >= "a" && $0 <= "p" }
    }

    /// 下载 + 解包好、但还没装进 store 的扩展：安装确认弹窗要先看它的名字与权限清单
    @MainActor
    struct Staged {
        let id: String
        /// 临时容器（commit / discard 之后删）
        let container: URL
        /// 扩展根目录（含 manifest.json）
        let directory: URL
        let webExtension: WKWebExtension

        var displayName: String { webExtension.displayName ?? id }
        /// 权限清单（权限名 + 匹配模式），给用户看的
        var permissionSummary: [String] {
            webExtension.requestedPermissions.map(\.rawValue).sorted()
                + webExtension.allRequestedMatchPatterns.map(\.string).sorted()
        }
    }

    /// 从 Chrome Web Store 下载并解包（还没装）
    func stageWebStoreInstall(id: String, progress: @escaping (String) -> Void = { _ in }) async throws -> Staged {
        guard Self.isValidExtensionID(id) else { throw BrowserExtensionError.invalidID }
        progress("正在下载扩展…")
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
        progress("正在解包…")
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

    /// 确认之后真正装进 store
    @discardableResult
    func commit(_ staged: Staged) async throws -> Installed {
        defer { try? FileManager.default.removeItem(at: staged.container) }
        // 用户在商店页明确点了「添加到 QuickTerm」：与 Chrome 一样默认固定到工具条
        return try await install(directory: staged.directory, id: staged.id, source: .webStore, pinned: true)
    }

    /// 用户取消：删掉临时文件
    func discard(_ staged: Staged) {
        try? FileManager.default.removeItem(at: staged.container)
    }

    /// 从 Chrome Web Store 安装（更新同路径：已存在的目录先删）
    @discardableResult
    func install(fromWebStore id: String, progress: @escaping (String) -> Void = { _ in }) async throws -> Installed {
        let staged = try await stageWebStoreInstall(id: id, progress: progress)
        progress("正在安装…")
        return try await commit(staged)
    }

    /// 把一个已解包的扩展目录装进 store（本地扩展 / Chrome 导入 / Web Store 解包后都走这里）
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
        // 重装 / 更新（商店页的「添加到 QuickTerm」也是这条路）沿用用户已有的固定选择——用户手动取消固定过，
        // 更新一下不能把按钮又塞回工具条（Chrome 更新扩展同样不动 pinned_extensions）；首次安装才用调用方的默认值
        let record = Record(id: id, source: source, version: nil, installedAt: Date(), enabled: true,
                            pinned: existing?.record.pinned ?? pinned)
        let item = try await makeInstalled(record: record, directory: destination)
        installed = Self.sorted(installed + [item])
        saveRecords()
        NotificationCenter.default.post(name: .browserExtensionsDidChange, object: self)
        return item
    }

    /// CRX 里的 zip 解到临时目录。返回 (临时容器, 真正的扩展根目录)
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
        // 少数包多套了一层目录
        let inner = (try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil))?
            .first { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
        guard let inner else { throw BrowserExtensionError.noManifest }
        return (container, inner)
    }

    // MARK: - 从本机 Chrome 导入

    nonisolated static var defaultChromeProfile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default", isDirectory: true)
    }

    /// 扫 `<profile>/Extensions/<id>/<version>/manifest.json`：每个扩展取版本号最大的那个目录。
    /// 主题（manifest 有 `theme`）、打包应用（`app`）、没有 `name` 的都跳过
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

    /// manifest 能不能装：有 name，且不是主题 / 打包应用
    nonisolated static func isImportableManifest(at directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if json["theme"] != nil || json["app"] != nil { return false }
        // 名字可以是 __MSG_xxx__ 的本地化占位，只要有就行
        guard let name = json["name"] as? String, !name.isEmpty else { return false }
        return true
    }

    /// "1.2.0" < "1.10" 的数字段比较（段数不同时短的补 0）。
    /// Chrome 的版本目录名是 `<version>_<installCount>`（`1.15.4_1`）：`Int("4_1")` 是 nil，
    /// 不先切掉 `_N` 的话最后一段会被当成 0，`1.15.4_1` 与 `1.15.5_0` 会比成相等（选到旧版本）
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
        // 版本相同就比安装计数（Chrome 用它区分同版本的重装目录）
        return a.install < b.install
    }

    /// Chrome 里"固定到工具条"的扩展 id：`<profile>/Preferences`（JSON）的 `extensions.pinned_extensions`。
    /// 文件不在 / 不是 JSON / 没这个键都返回空集合（= 导入后一个都不固定，不算错）
    nonisolated static func chromePinnedExtensionIDs(preferences: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: preferences),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extensions = json["extensions"] as? [String: Any],
              let pinned = extensions["pinned_extensions"] as? [Any] else { return [] }
        return Set(pinned.compactMap { $0 as? String })
    }

    /// 导入本机 Chrome 已装的扩展（已装过的跳过）
    @discardableResult
    func importFromChrome(profile: URL = BrowserExtensionManager.defaultChromeProfile)
        async -> (imported: Int, skipped: Int, failed: [String]) {
        let candidates = Self.chromeCandidates(inExtensions: profile.appendingPathComponent("Extensions",
                                                                                            isDirectory: true))
        // 在 Chrome 里固定到工具条的，导入后同样固定；其余只在拼图菜单里（几十个扩展不会把地址栏挤没）
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
                Self.logger.warning("Chrome 扩展导入失败 id=\(candidate.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
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
            completionHandler(nil, Self.unsupported("没有可用的浏览器 pane"))
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
            completionHandler(nil, Self.unsupported("没有可用的窗口"))
            return
        }
        completionHandler(pane, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openOptionsPageFor context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let url = context.optionsPageURL else {
            completionHandler(Self.unsupported("该扩展没有选项页"))
            return
        }
        guard openInBrowser(url) else {
            completionHandler(Self.unsupported("没有可用的浏览器 pane"))
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
            completionHandler(Self.unsupported("没有可用的浏览器 pane"))
            return
        }
        pane.presentExtensionPopup(action, of: context)
        completionHandler(nil)
    }

    /// 原生消息（chrome.runtime.connectNative / sendNativeMessage）：QuickTerm 不带宿主程序，明确回错
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any,
                                toApplicationWithIdentifier applicationIdentifier: String?,
                                for context: WKWebExtensionContext,
                                replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        replyHandler(nil, Self.unsupported("QuickTerm 不支持原生消息（nativeMessaging）"))
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                connectUsing port: WKWebExtension.MessagePort,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(Self.unsupported("QuickTerm 不支持原生消息（nativeMessaging）"))
    }

    static func unsupported(_ message: String) -> NSError {
        NSError(domain: "QuickTerm.BrowserExtensions", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// 权限弹窗：挂到 key window 的 sheet 做不到同步返回，这里要的是"允许/拒绝"的即时答案，用 runModal
    private func confirmPermission(context: WKWebExtensionContext, items: [String]) -> Bool {
        let name = context.webExtension.displayName ?? "扩展"
        let alert = NSAlert()
        alert.messageText = "扩展「\(name)」请求权限"
        alert.informativeText = items.isEmpty ? "（无具体项目）" : items.joined(separator: "\n")
        alert.addButton(withTitle: "允许")
        alert.addButton(withTitle: "拒绝")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// CRX（Chrome 扩展包）= 自定义头 + 一个 zip。剥掉头拿到 zip 字节。
enum CRX {
    static func zipData(from data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, bytes[0...3].elementsEqual(Array("Cr24".utf8)) else { return nil }
        let header: UInt64
        switch le32(bytes, 4) {
        case 2:
            // v2：16 字节固定头 + 公钥 + 签名
            header = 16 + UInt64(le32(bytes, 8)) + UInt64(le32(bytes, 12))
        case 3:
            // v3：12 字节固定头 + protobuf 头
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
