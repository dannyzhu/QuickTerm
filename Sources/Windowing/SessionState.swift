import AppKit

// MARK: - 存档 v5 的数据结构（spec v9 §3.1）
//
// 「一键复原」的定义（用户 2026-09-08）：退出再打开能还原之前的每个「屏幕」、每个屏幕上的
// pane 与布局、每个终端 pane 的所在目录、每个浏览器 pane 已经打开的网页。
// 前三样在 v4 时代就已经在存了（`WorkspaceLayout` / `ScrollingStrip.Column` / `SplitTree` /
// `FloatingPane` / `PaneCodable`）——v5 **只换信封**：把单窗口的三个字段包进 `windows[]`，
// 再补上「这个窗口在哪台显示器、多大、是不是全屏」。pane / 布局的编码字节一律不动，
// 于是 v2–v4 的存档只要换个信封就能读，pane 级的用例也一个都不用改。

/// 显示器身份：UUID 主、名称次、frame 只用于重新定位（分辨率 / 排列一变就不同，绝不能当身份）
struct DisplayRef: Codable, Equatable {
    /// `CGDisplayCreateUUIDFromDisplayID` 的 UUID 字符串（跨重连 / 重启稳定）
    var uuid: String?
    /// `NSScreen.localizedName`（UUID 没命中时的兜底；同型号会重名）
    var name: String?
    /// 存档时该显示器的 frame（仅供参考 / 调试）
    var frame: CGRect?

    init(uuid: String? = nil, name: String? = nil, frame: CGRect? = nil) {
        self.uuid = uuid
        self.name = name
        self.frame = frame
    }

    /// 从 NSScreen 取身份（screen 为 nil → nil，表示「不知道在哪」= 按主屏居中的历史行为）
    init?(screen: NSScreen?) {
        guard let screen else { return nil }
        self.uuid = screen.displayUUID?.uuidString
        self.name = screen.localizedName
        self.frame = screen.frame
    }
}

/// 一个「屏幕」（窗口）的存档
struct WindowState: Codable {
    var id: UUID
    /// 每工作区布局（编码与 v2–v4 完全一致）
    var layouts: [WorkspaceLayout]
    /// 每工作区浮动层（v3 起；缺省 = 空浮动层）
    var floatings: [[FloatingPane]]?
    var activeIndex: Int
    /// scrolling 每屏可见列数（nil = 用全局默认 / config）
    var visibleColumns: Int?
    /// 存档时窗口所在的显示器（nil = 未知 → 主屏）
    var display: DisplayRef?
    /// 非全屏 frame（全局坐标；全屏中存的是退出全屏后要恢复的那个）
    var frame: CGRect?
    var isFullscreen: Bool
    var joinAllSpaces: Bool
    /// 存档时持有焦点的 pane（信封字段：pane 编码字节不动）。nil / 找不到 → 第一块 pane
    var focusedPaneID: UUID?

    init(id: UUID = UUID(), layouts: [WorkspaceLayout], floatings: [[FloatingPane]]? = nil,
         activeIndex: Int = 0, visibleColumns: Int? = nil, display: DisplayRef? = nil,
         frame: CGRect? = nil, isFullscreen: Bool = false, joinAllSpaces: Bool = false,
         focusedPaneID: UUID? = nil) {
        self.id = id
        self.layouts = layouts
        self.floatings = floatings
        self.activeIndex = activeIndex
        self.visibleColumns = visibleColumns
        self.display = display
        self.frame = frame
        self.isFullscreen = isFullscreen
        self.joinAllSpaces = joinAllSpaces
        self.focusedPaneID = focusedPaneID
    }

    /// 这个窗口一个 pane 都没有（平铺与浮动都空）——恢复时直接丢掉，绝不开一个空窗口出来
    var isEmpty: Bool {
        layouts.allSatisfy(\.isEmpty) && (floatings ?? []).allSatisfy(\.isEmpty)
    }

    private enum CodingKeys: String, CodingKey {
        case id, layouts, floatings, activeIndex, visibleColumns, display, frame, isFullscreen,
             joinAllSpaces, focusedPaneID
    }

    /// 手写解码：缺字段一律走默认值（合成的解码器对非可选字段缺键会直接抛错，
    /// 而 v5 以后新增字段必须能被老存档「缺着读」——否则加一个字段就废掉一次用户会话）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        layouts = try c.decode([WorkspaceLayout].self, forKey: .layouts)
        floatings = try c.decodeIfPresent([[FloatingPane]].self, forKey: .floatings)
        activeIndex = try c.decodeIfPresent(Int.self, forKey: .activeIndex) ?? 0
        visibleColumns = try c.decodeIfPresent(Int.self, forKey: .visibleColumns)
        display = try c.decodeIfPresent(DisplayRef.self, forKey: .display)
        frame = try c.decodeIfPresent(CGRect.self, forKey: .frame)
        isFullscreen = try c.decodeIfPresent(Bool.self, forKey: .isFullscreen) ?? false
        joinAllSpaces = try c.decodeIfPresent(Bool.self, forKey: .joinAllSpaces) ?? false
        focusedPaneID = try c.decodeIfPresent(UUID.self, forKey: .focusedPaneID)
    }
}

/// 存档信封 v5：多屏幕 + 哪个屏幕是 key
struct PersistedState: Codable {
    static let currentVersion = 5

    var version: Int
    var windows: [WindowState]
    var keyWindowID: UUID?
    /// 叠放次序（前 → 后）。`windows[]` 保持注册表/创建顺序（屏幕序号与标题按它分配），
    /// 谁压着谁另存这一份。nil / 缺项 = 未知，按存档顺序排
    var stackingOrder: [UUID]?

    init(windows: [WindowState], keyWindowID: UUID? = nil, stackingOrder: [UUID]? = nil,
         version: Int = PersistedState.currentVersion) {
        self.version = version
        self.windows = windows
        self.keyWindowID = keyWindowID
        self.stackingOrder = stackingOrder
    }

    private enum CodingKeys: String, CodingKey { case version, windows, keyWindowID, stackingOrder }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? PersistedState.currentVersion
        stackingOrder = try c.decodeIfPresent([UUID].self, forKey: .stackingOrder)
        // 逐个窗口宽松解码：某个屏幕的存档坏了（引擎拒绝某个 pane、字段被手改坏）
        // 只丢它一个，其余屏幕照常恢复——一份坏窗口不该带走整个会话
        windows = try c.decode([LossyWindow].self, forKey: .windows).compactMap(\.value)
        keyWindowID = try c.decodeIfPresent(UUID.self, forKey: .keyWindowID)
    }

    /// 解码失败即视为「没有这个窗口」的包装（元素自己的解码器永远成功，不会打断整个数组）
    private struct LossyWindow: Decodable {
        let value: WindowState?
        init(from decoder: Decoder) throws { value = try? WindowState(from: decoder) }
    }
}

/// v2–v4 的单窗口存档（只用于读旧文件；v5 起不再写出这个形状）
struct LegacyPersistedState: Codable {
    var version = 4   // v4：叶子带 kind（terminal/browser）；v2/v3 无 kind = 终端
    var layouts: [WorkspaceLayout]
    /// v3 起；v2 存档缺省为空浮动层
    var floatings: [[FloatingPane]]?
    var activeIndex: Int
}

// MARK: - 读盘 / 迁移 / 写盘（spec v9 §3.2–§3.4）

/// 会话存档（进程唯一，挂在 `AppSession` 上）。
/// 与 1.5.x 的差别：不再「只在退出时存一次」——布局变化 / 窗口移动缩放 / 开关屏幕 / 全屏切换
/// 都会 `scheduleSave()`（防抖 1.5s），退出时再同步写一次。
@MainActor
final class SessionStore {
    /// 布局变化后的写盘防抖（连续变化只写一次）
    static let debounceInterval: TimeInterval = 1.5

    static var defaultURL: URL {
        EngineOverlay.url.deletingLastPathComponent().appendingPathComponent("state.json")
    }

    let url: URL
    /// v5 首次写盘前留下的旧档副本（v5 不可降级：老版本读不懂会当损坏档，退出时用 v4 覆盖）
    var backupURL: URL { backupURL(forVersion: PersistedState.currentVersion - 1) }

    /// 「别的版本写的存档」的副本落点：
    /// - 老版本（< v5）一律 `state.pre-v5.json`（升级路径只会有一份）；
    /// - 更新的版本（> v5，用户从新版回滚到本版时会遇到）按版本号各存一份 `state.v<N>.json`，
    ///   互不覆盖——本版**拒读**新版存档，但绝不能悄悄把它覆盖掉
    func backupURL(forVersion version: Int) -> URL {
        let name = version < PersistedState.currentVersion
            ? "state.pre-v\(PersistedState.currentVersion).json"
            : "state.v\(version).json"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// 屏幕注册表（强引用：注册表不反向持有本对象，不成环）
    private let screens: ScreenRegistry
    /// 测试宿主里绝不碰用户真实存档：只有显式注入了 URL（临时目录）才允许写盘
    private let writesAllowed: Bool
    /// 测试注入的快照来源（nil = 从注册表取）
    var snapshotOverride: (() -> PersistedState)?
    /// 实际写盘次数（防抖用例的计数桩）
    private(set) var writeCount = 0
    /// 排过多少次防抖存档（触发点用例的计数桩；测试宿主里不写盘也照记）
    private(set) var scheduleCount = 0
    private var pendingSave: DispatchWorkItem?
    private var didCheckBackup = false

    init(screens: ScreenRegistry, url: URL? = nil) {
        self.screens = screens
        self.url = url ?? Self.defaultURL
        self.writesAllowed = url != nil || !AppDelegate.isRunningTests
    }

    // MARK: 读

    /// 读档并迁移到 v5。返回 nil = 没有存档 / 损坏 / 全空（→ 全新开始，与 1.5.x 行为一致）
    func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Self.decode(data)
    }

    /// 版本探针：先只读 version，再决定走哪条解码路径
    private struct VersionProbe: Codable { var version: Int? }

    /// 解码 + 迁移：v5 直读；v2–v4 包成 `windows[0]`（display / frame 均 nil → 保持今天的主屏居中行为）。
    /// 全空的窗口一律丢掉；一个都不剩 → nil
    ///
    /// 版本**精确匹配**：更新的版本（v6+）一律拒读。按 v5 的形状去读一份 v6 存档是有损的——
    /// 本版不认识的 pane 种类会让整个窗口解码失败（`LossyWindow` 把它丢掉），
    /// 随后启动 1.5s 的防抖存档就会把截断后的结果写回去。宁可「全新开始」，
    /// 再由 `backupForeignArchiveIfNeeded` 把原档整份留下来。
    static func decode(_ data: Data) -> PersistedState? {
        let version = (try? JSONDecoder().decode(VersionProbe.self, from: data))?.version ?? 0
        var state: PersistedState
        switch version {
        case PersistedState.currentVersion:
            guard let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) else { return nil }
            state = decoded
        case 2...4:
            guard let legacy = try? JSONDecoder().decode(LegacyPersistedState.self, from: data) else { return nil }
            let window = WindowState(
                layouts: legacy.layouts, floatings: legacy.floatings, activeIndex: legacy.activeIndex)
            state = PersistedState(windows: [window], keyWindowID: window.id)
        default:
            return nil
        }
        state.windows.removeAll(where: \.isEmpty)
        guard !state.windows.isEmpty else { return nil }
        if let key = state.keyWindowID, !state.windows.contains(where: { $0.id == key }) {
            state.keyWindowID = state.windows.first?.id
        }
        return state
    }

    // MARK: 写

    /// 防抖写盘：连续变化（拖列宽、连开 pane、拖窗口）只落一次盘
    func scheduleSave() {
        scheduleCount += 1
        guard writesAllowed else { return }
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: item)
    }

    /// 立即同步写盘（`applicationWillTerminate` / 关掉最后一个屏幕）
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard writesAllowed else { return }
        let state = snapshot()
        // 一个窗口都没有（全关掉了 / 都 teardown 过）绝不写：否则会用空档覆盖掉用户的会话
        guard !state.windows.isEmpty else { return }
        backupForeignArchiveIfNeeded()
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
        writeCount += 1
    }

    /// 当前所有屏幕的快照（teardown 过的屏幕不进档）
    func snapshot() -> PersistedState {
        if let snapshotOverride { return snapshotOverride() }
        let live = screens.controllers.filter { !$0.isClosed }
        // key 用 `current` 而不是 `key`：sheet（JS 对话框 / 文件选择器）或下载 popover 是 key 窗口时
        // `screens.key` 为 nil，退回 primary 会把「下次启动置前哪个屏幕」记成第一个屏幕
        let key = screens.current
        // 叠放次序：orderedWindows 是前 → 后；最小化 / 尚未 order-in 的窗口不在里面，补到末尾
        var stacking = NSApp.orderedWindows
            .compactMap { $0.windowController as? MainWindowController }
            .filter { !$0.isClosed }
            .map(\.windowID)
        stacking += live.map(\.windowID).filter { !stacking.contains($0) }
        return PersistedState(windows: live.map { $0.windowState() },
                              keyWindowID: key?.windowID,
                              stackingOrder: stacking)
    }

    /// 第一次写盘前，把「别的版本写的存档」原封不动留一份（只做一次，且不覆盖已有副本）。
    /// 老档（v2–v4）是升级留痕；新档（v6+）是降级保命——本版拒读它，更不能无声覆盖掉
    private func backupForeignArchiveIfNeeded() {
        guard !didCheckBackup else { return }
        didCheckBackup = true
        guard let data = try? Data(contentsOf: url),
              let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
              let version = probe.version, version != PersistedState.currentVersion else { return }
        let backup = backupURL(forVersion: version)
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? data.write(to: backup, options: .atomic)
    }

    // MARK: 显示器解析与 frame 约束（spec v9 §3.3）

    /// 按存档里的显示器身份找回 NSScreen：UUID → 名称（唯一命中才算）→ 没有。
    /// 纯函数（可注入屏幕列表）以便用例覆盖
    static func matchScreen(for ref: DisplayRef?, in screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        guard let ref else { return nil }
        if let uuid = ref.uuid,
           let hit = screens.first(where: { $0.displayUUID?.uuidString == uuid }) {
            return hit
        }
        if let name = ref.name {
            let named = screens.filter { $0.localizedName == name }
            if named.count == 1 { return named[0] }
        }
        return nil
    }

    /// 恢复窗口时的落点显示器：解析不到一律回主屏——**绝不因为显示器没了就丢掉窗口和布局**
    static func resolveScreen(for ref: DisplayRef?, in screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        matchScreen(for: ref, in: screens) ?? NSScreen.main
    }

    /// 把 frame 收进可见区：先夹尺寸再夹位置（存档时的显示器更大 / 分辨率变了 / 显示器没了都靠它兜底）
    static func constrain(_ frame: CGRect, into visible: CGRect) -> CGRect {
        var f = frame
        f.size.width = min(max(f.width, 200), visible.width)
        f.size.height = min(max(f.height, 150), visible.height)
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }
}
