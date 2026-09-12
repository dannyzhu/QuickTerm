import SwiftUI

/// 多工作区状态（spec §5.2 + §4.2-bis：默认 5 个、每工作区独立布局，
/// 新工作区默认 scrolling 无限画布）。AppKit 控制器是唯一写入方，SwiftUI 纯读。
final class WorkspaceModel: ObservableObject {
    static let workspaceCount = 5

    @Published var layouts: [WorkspaceLayout]
    /// 每工作区的浮动层（与 layouts 平行索引；spec v7）
    @Published var floatings: [[FloatingPane]]
    /// 每工作区的名字（与 layouts 平行索引；nil = 没起过名）。
    ///
    /// 名字是给**槽位**起的，不是给里面那堆 pane 起的：`workspace clear`、关掉最后一个 pane、
    /// `spec apply --replace` 都不碰它——只有改名（或清空）才改它。
    /// 写入一律走 `setTitle(_:at:)`（它负责规范化与越界保护）
    @Published var titles: [String?]
    /// 每工作区上一次离开的布局（Cmd+L 往返恢复用；不持久化）
    private var alternates: [WorkspaceLayout?] = []
    @Published var activeIndex: Int = 0
    @Published var barVisible = true

    init() {
        layouts = (0..<Self.workspaceCount).map { _ in .empty }
        floatings = Array(repeating: [], count: Self.workspaceCount)
        titles = Array(repeating: nil, count: Self.workspaceCount)
    }

    /// 活动工作区布局
    var layout: WorkspaceLayout {
        get { layouts[activeIndex] }
        set { layouts[activeIndex] = newValue }
    }

    /// 活动工作区浮动层
    var floating: [FloatingPane] {
        get { floatings[activeIndex] }
        set { floatings[activeIndex] = newValue }
    }

    /// 全部工作区的所有 pane（主题重载/按 id 反查用）
    var allPanes: [PaneView] {
        layouts.flatMap(\.paneList)
            + floatings.flatMap { $0.map(\.pane) }
            + (scratchpadSurface.map { [$0] } ?? [])
    }

    var allEmpty: Bool {
        layouts.allSatisfy(\.isEmpty) && floatings.allSatisfy(\.isEmpty)
    }

    func switchTo(_ index: Int) {
        guard layouts.indices.contains(index) else { return }
        activeIndex = index
    }

    func isEmpty(_ index: Int) -> Bool {
        guard layouts.indices.contains(index) else { return true }
        return layouts[index].isEmpty && floatings[index].isEmpty
    }

    // MARK: 工作区名字

    /// 规范形态：首尾空白去掉，空串 = 没起名。
    /// 长度上限与控制字符由各入口自己把关（控制面要**报错**，对话框是滤掉再截断，
    /// 见 `titleFromInput`——在这里一刀切会让 `workspace set --title`
    /// 静默接受一个它本该拒绝的值）
    static func normalizedTitle(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// 控制字符（换行、制表、DEL、C1）不算名字的一部分。
    /// 命令行与 spec 见到它**报错**——那头是程序在调，写错了得知道；
    /// 对话框只能**滤掉**：人粘进来一个换行不值得弹个错误框，可留着它状态条就废了——
    /// 条高 26pt 是写死的，`Text` 多排一行就顶到背景外面去
    static func isTitleScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value)
    }

    /// 人在对话框里敲 / 粘进来的那一串变成名字：滤掉控制字符，再截到与命令行同一个上限
    static func titleFromInput(_ raw: String) -> String {
        let printable = String(String.UnicodeScalarView(raw.unicodeScalars.filter(isTitleScalar)))
        return String(printable.prefix(ControlCommandRunner.maxTitleLength))
    }

    /// 状态条画出来的那一排的名字：**只有真实存在的槽位**。
    /// `titles` 缩容时不裁（名字是槽位的，工作区数调回来还得在），所以要按 layouts 截一次——
    /// 拿原始的 `titles` 去算"放不放得下"，会替几个根本不画的胶囊买单，
    /// 整排名字就被几个看不见的名字吓回序号了
    var visibleTitles: [String?] { (0..<layouts.count).map { title(at: $0) } }

    /// 这个槽位的名字。**不存在的槽位一律没名字**——工作区数是热重载的，
    /// `titles` 里可能还留着缩容前那几个（见 `alignTitles`），但一个不存在的工作区
    /// 不该在状态条、`state` 或 spec 里冒出一个名字来
    func title(at index: Int) -> String? {
        guard layouts.indices.contains(index), titles.indices.contains(index) else { return nil }
        return titles[index]
    }

    /// 起名 / 改名 / 清空（nil 或空串 = 清空）。返回是否真的改了（幂等命令靠它退 7）
    @discardableResult
    func setTitle(_ raw: String?, at index: Int) -> Bool {
        guard layouts.indices.contains(index) else { return false }
        alignTitles()
        let next = Self.normalizedTitle(raw)
        guard titles[index] != next else { return false }
        titles[index] = next
        return true
    }

    /// 与 layouts 对齐。**缩容时不裁**：名字是槽位的，工作区数调小再调回来
    /// （config 热重载一改就是一次扩缩容）不该把名字弄丢；多出来的那几个谁也读不到
    private func alignTitles() {
        guard titles.count < layouts.count else { return }
        titles.append(contentsOf: Array(repeating: nil, count: layouts.count - titles.count))
    }

    /// Cmd+L：优先恢复该工作区上次离开的另一种布局——只要 pane 集合没变，
    /// 列栈/列宽/顺序原样回来（转换是有损的：dwindle→scrolling 会把叠栈摊成独立列，
    /// 5 个 pane 变 5 列就溢出视口）；pane 有增减时才退回保 pane 保序的转换。
    func toggleLayout(columnFactor: Double = ScrollingStrip.defaultWidth) {
        if alternates.count != layouts.count {  // 状态恢复/扩缩容后对齐
            alternates = (0..<layouts.count).map { alternates.indices.contains($0) ? alternates[$0] : nil }
        }
        let current = layout
        let remembered = alternates[activeIndex]
        let next: WorkspaceLayout
        if let remembered, remembered.name != current.name, remembered.hasSamePanes(as: current) {
            next = remembered
        } else {
            next = current.toggled(columnFactor: columnFactor)
        }
        alternates[activeIndex] = current
        layout = next
    }

    /// **绝对设值**：把任意工作区（含**非活动**工作区）切成指定布局。
    /// `toggleLayout` 只作用于活动工作区，而且是 toggle——agent 看不到状态，重试一次就把自己撤销了。
    /// 记忆（alternates）与 toggle 共用：pane 集合没变时原样恢复上次的那一份，
    /// 否则退回保 pane 保序的有损转换。返回是否真的改了（已经是目标布局 = false）
    @discardableResult
    func setLayout(_ name: String, at index: Int,
                   columnFactor: Double = ScrollingStrip.defaultWidth) -> Bool {
        guard layouts.indices.contains(index), layouts[index].name != name else { return false }
        if alternates.count != layouts.count {
            alternates = (0..<layouts.count).map { alternates.indices.contains($0) ? alternates[$0] : nil }
        }
        let current = layouts[index]
        let remembered = alternates[index]
        let next: WorkspaceLayout
        if let remembered, remembered.name == name, remembered.hasSamePanes(as: current) {
            next = remembered
        } else {
            next = current.toggled(columnFactor: columnFactor)
        }
        guard next.name == name else { return false }   // 转换没给出目标布局：宁可什么都不做
        alternates[index] = current
        layouts[index] = next
        return true
    }

    /// 控制面刚刚做了什么（状态栏闪一下）。`mutate` 类命令静默执行的前提就是事后可见
    @Published var controlFlash: ControlFlash?
    struct ControlFlash: Equatable, Identifiable {
        let id = UUID()
        var text: String
    }
    /// 闪烁停留时长
    static let controlFlashDuration: TimeInterval = 2.5

    func showControlFlash(_ text: String) {
        let flash = ControlFlash(text: text)
        controlFlash = flash
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.controlFlashDuration) { [weak self] in
            guard self?.controlFlash?.id == flash.id else { return }   // 期间又来了一条：让新的那条走完自己的时长
            self?.controlFlash = nil
        }
    }

    /// config workspaces=N（1–10）：扩容补空；缩容仅当被裁的全空（否则保留至最后非空）
    func setWorkspaceCount(_ n: Int) {
        defer { alignTitles() }
        let target = min(max(n, 1), 10)
        if target > layouts.count {
            layouts.append(contentsOf: (layouts.count..<target).map { _ in WorkspaceLayout.empty })
            floatings.append(contentsOf: Array(repeating: [], count: target - floatings.count))
        } else if target < layouts.count {
            let lastNonEmpty = (0..<layouts.count).last { !isEmpty($0) }.map { $0 + 1 } ?? 0
            let safeTarget = max(target, lastNonEmpty)
            layouts.removeLast(layouts.count - safeTarget)
            floatings.removeLast(floatings.count - safeTarget)
        }
        activeIndex = min(activeIndex, layouts.count - 1)
    }

    // 浮动面板 UI 状态（键盘导航由控制器监视器驱动）
    @Published var activePanel: OverlayPanel?
    @Published var panelSelection: Int = 0

    // Scratchpad（spec §4.1：跨工作区浮动终端）
    @Published var scratchpadVisible = false
    @Published var scratchpadSurface: Ghostty.SurfaceView?

    /// 新建终端的当前绑定（空工作区提示用；控制器在键位表构建后写入）
    @Published var newTerminalCombo: String = "Cmd+Return"
    /// dwindle 刚分裂出的新 pane（局部动效：原 pane 收缩到 ratio、新 pane 渐显；动画结束后清空）
    @Published var appearingPane: UUID?
    /// 正在淡出的 pane（仍在布局里；视图层播放收拢/渐隐，动效结束后控制器才真正移除）
    @Published var closingPanes: Set<UUID> = []

    // 每屏可见列数（菜单显示用镜像）
    @Published var visibleColumnsDisplay: Int =
        UserDefaults.standard.object(forKey: "quickterm.visibleColumns") as? Int ?? 2

    /// 全部 scrolling 工作区的列因子是否已等于给定值（避免无谓重排）
    func layoutsMatch(factor: Double) -> Bool {
        layouts.allSatisfy { layout in
            guard case .scrolling(let strip) = layout else { return true }
            return strip.columns.allSatisfy { abs($0.widthFactor - factor) < 0.001 }
        }
    }

    // Cmd+K 速查数据（打开面板时由控制器按当前生效映射填充）
    @Published var keybindingRows: [(combo: String, action: WMAction)] = []

    // scrolling 画布的双指横滑（附带项）：控制器滚轮监视器投递，视图消费
    @Published var stripPan: StripPanEvent?
    struct StripPanEvent: Equatable {
        var delta: CGFloat
        var ended: Bool
        var serial: Int
    }
}

struct RootView: View {
    @ObservedObject var model: WorkspaceModel
    @EnvironmentObject var theme: ThemeManager
    let ghostty: Ghostty.App
    let stats: SystemStatsService
    let action: (TerminalSplitOperation) -> Void
    let onScrollingDrop: (PaneView, PaneView, TerminalSplitDropZone) -> Void
    let onSelectWorkspace: (Int) -> Void
    /// 右键工作区胶囊：起名 / 改名
    let onRenameWorkspace: (Int) -> Void
    let onPanelChoose: (Int) -> Void

    var body: some View {
        ZStack {
            // 连续壁纸层（spec §3.2）升为整窗背景：延伸到状态条身后，
            // 半透明状态条（与 pane-opacity 同源）才能真正透出壁纸。
            theme.background
            if let url = theme.currentBackgroundURL {
                WallpaperThumb(url: url).id(url)
            }
            content
        }
        .background(theme.background)
        .ignoresSafeArea(.container, edges: .top)
        .environmentObject(ghostty)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if model.barVisible {
                StatusBarView(
                    model: model, stats: stats,
                    onSelectWorkspace: onSelectWorkspace,
                    onRenameWorkspace: onRenameWorkspace,
                    onToggleMute: { [weak stats] in stats?.toggleMute() })
            }
            ZStack {
                switch model.layout {
                case .dwindle(let tree):
                    TerminalSplitTreeView(tree: tree, action: action, appearingPane: model.appearingPane,
                                          closingPanes: model.closingPanes)
                        .padding(theme.gapsEnabled ? theme.paneGap : 0)   // 外圈与 pane 留白同值
                case .scrolling(let strip):
                    ScrollingStripView(
                        strip: strip,
                        workspaceIndex: model.activeIndex,
                        pan: model.stripPan,
                        onDrop: onScrollingDrop,
                        closingPanes: model.closingPanes)
                        .padding(theme.gapsEnabled ? theme.paneGap : 0)   // 外圈与 pane 留白同值
                }

                // 空工作区：最后一个 pane 关掉后窗口保留，提示怎么开新终端
                if model.layout.isEmpty && model.floating.isEmpty {
                    VStack(spacing: 6) {
                        Text("\(model.newTerminalCombo)  新建终端")
                        Text("Cmd+Q  退出").opacity(0.6)
                    }
                    .font(.custom("Monaco", size: 14))
                    .foregroundStyle(theme.foreground.opacity(0.55))
                    .allowsHitTesting(false)
                }

                // 浮动层（spec v7）：悬浮于平铺之上；数组序 = z 序
                GeometryReader { geo in
                    ForEach(model.floating) { fp in
                        ScrollingPaneCell(surfaceView: fp.pane, onDrop: { _, _, _ in },
                                          floating: true,
                                          closing: model.closingPanes.contains(fp.id))
                            .frame(width: fp.rect.width * geo.size.width,
                                   height: fp.rect.height * geo.size.height)
                            .position(x: (fp.rect.origin.x + fp.rect.width / 2) * geo.size.width,
                                      y: (fp.rect.origin.y + fp.rect.height / 2) * geo.size.height)
                            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                    }
                }
                .allowsHitTesting(!model.floating.isEmpty)

                if model.scratchpadVisible, let scratch = model.scratchpadSurface {
                    Color.black.opacity(0.2)
                        .onTapGesture { model.scratchpadVisible = false }
                    GeometryReader { geo in
                        Ghostty.SurfaceWrapper(surfaceView: scratch)
                            .frame(width: geo.size.width * 0.7, height: geo.size.height * 0.6)
                            .border(theme.accent, width: 2)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                }

                if model.activePanel != nil {
                    Color.black.opacity(0.25).onTapGesture { model.activePanel = nil }
                    OverlayPanelView(model: model, onChoose: onPanelChoose)
                        .padding(40)
                }
            }
        }
    }
}
