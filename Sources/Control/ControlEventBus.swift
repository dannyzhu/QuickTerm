import AppKit

/// 事件总线（Phase 4）：单调 `seq` 的唯一所有者 + 类型化事件的产地 + 长轮询 / 流的等待队列。
///
/// **事件是"快照相减"出来的，不是在每个调用点手写的。**
/// `MainWindowController` 里已经有一组 Combine sink（layouts / floatings / activeIndex），
/// 关闭动效、焦点交接、OSC 7 的 cwd、浏览器标题也各有自己的触发点；
/// 如果每处都手写一句 `emit(.paneOpened(...))`，那么：
/// - 漏一处 = agent 永远收不到那类变化，而且没有任何用例会发现；
/// - 一次布局重排里同一件事会被报好几遍（`perform()` 是可重入的）。
/// 所以这里只接受一个信号——"有东西可能变了"（`scheduleScan()`）——然后把整棵注册表
/// 与上一份快照相减。**合并是免费的**：一次 run loop 里发生的 N 次变更只会扫一遍。
///
/// ⚠️ 任何事件都**不得携带 pane 的输出内容**（见 `ControlEventType` 的注释）。
/// 这里能读到的只有结构、标题与 cwd，而标题 / cwd 对浏览器 pane 还要按 `state` 的同一条规则打码。
@MainActor
final class ControlEventBus {
    static let shared = ControlEventBus()

    /// 环里的一条：线上的事件 + "这条的 title / cwd 要不要按浏览器规则打码"。
    /// 打码**在投递时**做而不是在产生时做：同一条事件要同时发给带 token 与不带 token 的两个调用方
    private struct Record {
        var event: ControlEvent
        var redactable: Bool
    }

    private weak var screens: ScreenRegistry?
    /// 单调状态序号。每条事件 +1；没有任何类型化事件覆盖到的变更由 `settleMutation()` 补一次
    private(set) var seq = 0
    private var ring: [Record] = []
    private var snapshot = Snapshot()
    private var scanScheduled = false
    private var waiters: [Waiter] = []
    private var followers: [Follower] = []
    /// 每条 follow / poll 的内部编号（取消用）
    private var nextTicket = 0

    private init() {}

    // MARK: 生命周期

    /// 挂上注册表并**不发事件地**把当下的状态记成基线。
    /// 不这么做的话，应用启动后第一次扫描会把每一块屏幕、每一个 pane 都当成"刚刚新建"
    func attach(screens: ScreenRegistry) {
        self.screens = screens
        resync()
    }

    /// 把当下的状态记成基线（不产生任何事件）。用例的夹具也用它，免得上一条用例留下的
    /// pane 在这一条里变成一串莫名其妙的 pane.closed
    func resync() {
        scanScheduled = false
        snapshot = screens.map { Snapshot.capture($0) } ?? Snapshot()
    }

    /// 只给用例：清空环与等待队列（`seq` **不复位**——它是单调的，复位会让"更旧的 seq"合法化）
    func resetForTesting() {
        ring.removeAll()
        for waiter in waiters { waiter.timeout.cancel() }
        waiters.removeAll()
        followers.removeAll()
        resync()
    }

    // MARK: 扫描

    /// "有东西可能变了"。同一轮 run loop 里叫多少次都只扫一遍——**这就是合并**
    func scheduleScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scanScheduled else { return }
            self.scanScheduled = false
            self.rescan()
        }
    }

    /// 从没有 actor 标注的地方（`PaneView.focusDidChange`、`ScreenRegistry`）报一声
    /// "有东西可能变了"。它们都只在主线程上跑，但工程是 Swift 5.10 且
    /// `MainWindowController` / `PaneView` 都没有 `@MainActor` 标注，
    /// 所以走 `assumeIsolated`——与 `ControlUndo.invalidate()` 同一个写法
    nonisolated static func noteChange() {
        MainActor.assumeIsolated { shared.scheduleScan() }
    }

    /// 立刻扫一遍（控制命令落地后用：响应里的 `seq` 要已经涵盖这条命令产生的事件）
    func flush() {
        scanScheduled = false
        rescan()
    }

    /// 一条控制命令真的落地了。先扫出类型化事件；一个都没有（`app set theme`、
    /// `screen set --fullscreen` 这类不动布局的）就补一次 `seq`——
    /// agent 拿 `seq` 判断手里的快照是否过期，"改了但 seq 没动"是最坏的一种谎
    func settleMutation() {
        let mark = seq
        flush()
        if seq == mark { seq += 1 }
    }

    private func rescan() {
        guard let screens else { return }
        let fresh = Snapshot.capture(screens)
        let records = Snapshot.diff(old: snapshot, new: fresh)
        snapshot = fresh
        guard !records.isEmpty else { return }
        let now = Date()
        for var record in records {
            seq += 1
            record.event.seq = seq
            record.event.ts = ControlEvent.stamp(now)
            ring.append(record)
        }
        if ring.count > ControlEventLimits.ringCapacity {
            ring.removeFirst(ring.count - ControlEventLimits.ringCapacity)
        }
        notify()
    }

    // MARK: 读

    var oldestSeq: Int? { ring.first?.event.seq }

    /// 一次取批的结果。`cursor` 是**下一次 `--since` 该给的那个数**，而不是当下的全局 `seq`：
    /// 两者只有在这一批没被 `--limit` 截断时才相等。
    ///
    /// 这个区别是整条事件流唯一会**静默丢事件**的地方，所以它单独有个类型。
    /// 曾经的写法是"回的永远是全局 seq"，于是 `events poll --limit 10` 手里压着 50 条时
    /// 回 10 条、却告诉调用方"你已经看到第 50 条了"——另外 40 条既没送出去，
    /// 也不会被 `missed` 标出来（`missed` 只管环被挤掉，这里环一条都没丢）。
    /// 截断时把游标钉在**最后一条真的送出去的事件**上，那 40 条下一轮就会补上。
    struct Batch {
        var events: [ControlEvent]
        var missed: Bool
        /// 下一次 `--since`
        var cursor: Int
        /// 这一批被 `--limit` 截断了，环里还压着更多——调用方不必等 timeout，立刻再轮一次
        var truncated: Bool
    }

    /// 取 `since` 之后的一批。**只回真正错过的那些**：`seq <= since` 的一条都不回
    func batch(since: Int, limit: Int, types: Set<String>?, exposesBrowser: Bool) -> Batch {
        var matched = ring.filter { $0.event.seq > since }
        if let types { matched = matched.filter { types.contains($0.event.type) } }
        // 环被挤掉过：调用方要的那一段有一部分已经没了
        let missed = since >= 0 && (ring.first.map { $0.event.seq > since + 1 } ?? false)
        let truncated = matched.count > limit
        let capped = truncated ? Array(matched.prefix(limit)) : matched
        // 没截断才能说"你已经追到 seq 了"：被 `--types` 滤掉的那些确实不必再送，
        // 但被 `--limit` 砍掉的那些还在环里等着
        let cursor = truncated ? (capped.last?.event.seq ?? seq) : seq
        return Batch(events: capped.map { project($0, exposesBrowser: exposesBrowser) },
                     missed: missed, cursor: cursor, truncated: truncated)
    }

    /// 打码：浏览器 pane 的标题 / cwd 对没有 token 的调用方一律 `<redacted>`。
    /// `state` 已经这么做了；事件流要是漏掉这一条，它就成了绕过打码的旁路
    private func project(_ record: Record, exposesBrowser: Bool) -> ControlEvent {
        guard record.redactable, !exposesBrowser else { return record.event }
        return Self.redact(record.event)
    }

    /// 打码本体（静态，好让用例直接钉住它——环里那份是私有的）
    static func redact(_ event: ControlEvent) -> ControlEvent {
        var out = event
        if out.title != nil { out.title = ControlEvent.redactedPlaceholder }
        if out.cwd != nil { out.cwd = ControlEvent.redactedPlaceholder }
        out.redacted = true
        return out
    }

    // MARK: 长轮询（`events poll`）

    private struct Waiter {
        var ticket: Int
        var since: Int
        var limit: Int
        var types: Set<String>?
        var exposesBrowser: Bool
        var deliver: (ControlEventsPayload) -> Void
        var timeout: DispatchWorkItem
    }

    /// 长轮询。**手里已经有新事件就立刻回**（不必等 timeout）；
    /// 没有就挂起，直到有新事件或到点，到点回一批空的并标 `timedOut`
    func poll(since: Int, limit: Int, types: Set<String>?, exposesBrowser: Bool,
              timeout: TimeInterval, deliver: @escaping (ControlEventsPayload) -> Void) {
        let ready = batch(since: since, limit: limit, types: types, exposesBrowser: exposesBrowser)
        if !ready.events.isEmpty || ready.missed || timeout <= 0 {
            deliver(payload(ready, timedOut: ready.events.isEmpty && !ready.missed ? true : nil))
            return
        }
        nextTicket += 1
        let ticket = nextTicket
        let work = DispatchWorkItem { [weak self] in
            guard let self, let index = self.waiters.firstIndex(where: { $0.ticket == ticket }) else { return }
            let waiter = self.waiters.remove(at: index)
            waiter.deliver(self.payload(Batch(events: [], missed: false, cursor: self.seq,
                                              truncated: false), timedOut: true))
        }
        waiters.append(Waiter(ticket: ticket, since: since, limit: limit, types: types,
                              exposesBrowser: exposesBrowser, deliver: deliver, timeout: work))
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    // MARK: 流（`events follow`）

    private struct Follower {
        var ticket: Int
        /// 连接编号：对端一走，这条流就要被摘掉（否则写到一个已经关掉的 fd 上，永远不停）
        var connection: UInt64
        var lastSeq: Int
        var limit: Int
        var types: Set<String>?
        var exposesBrowser: Bool
        var deliver: (ControlEventsPayload) -> Void
    }

    var followerCount: Int { followers.count }

    /// 注册一条流。返回 false = 已经太多条了（每条占住一条连接）
    @discardableResult
    func follow(connection: UInt64, since: Int, limit: Int, types: Set<String>?,
                exposesBrowser: Bool, deliver: @escaping (ControlEventsPayload) -> Void) -> Bool {
        guard followers.count < ControlEventLimits.maxFollowers else { return false }
        nextTicket += 1
        let ticket = nextTicket
        // 游标从 `since` 起，由 `pump` 一批批往前推——**绝不能直接写成全局 seq**：
        // 注册那一刻的补发同样会被 `--limit` 截断，写成 seq 的话被砍掉的那些永远不会再推过来
        followers.append(Follower(ticket: ticket, connection: connection, lastSeq: since,
                                  limit: limit, types: types, exposesBrowser: exposesBrowser,
                                  deliver: deliver))
        // 先补上 `--since` 之后已经发生的那一段（哪怕是空的：调用方要知道从哪个 seq 开始），
        // 再接着推新的
        pump(ticket: ticket, deliverEmptyFirstBatch: true)
        return true
    }

    /// 把一条流积压的事件推干净。**截断了就接着推**：`--limit` 只该限制单批大小，
    /// 不该让一条流卡在那里等下一次事件才继续（`events follow --limit 1` 曾经就是这样，
    /// 一次扫描出五条事件只推走第一条，剩下四条要等到下一次有别的变化才轮得上）
    private func pump(ticket: Int, deliverEmptyFirstBatch: Bool = false) {
        var rounds = 0
        var first = true
        // 每一轮都重新按 ticket 找：`deliver` 会往 socket 上写，写失败会把这条流摘掉
        while let index = followers.firstIndex(where: { $0.ticket == ticket }) {
            let follower = followers[index]
            let ready = batch(since: follower.lastSeq, limit: follower.limit, types: follower.types,
                              exposesBrowser: follower.exposesBrowser)
            followers[index].lastSeq = ready.cursor
            let empty = ready.events.isEmpty && !ready.missed
            if empty, !(first && deliverEmptyFirstBatch) { break }
            follower.deliver(payload(ready, timedOut: nil, follow: true))
            first = false
            rounds += 1
            // 上限只是防呆：环最多 ringCapacity 条，limit 最小是 1
            guard ready.truncated, rounds <= ControlEventLimits.ringCapacity else { break }
        }
    }

    /// 对端走了：把它的流全部摘掉。**这是 follow 唯一的终止条件**
    func connectionDidClose(_ connection: UInt64) {
        followers.removeAll { $0.connection == connection }
    }

    /// 服务停了（配置改成 off / 应用退出）：每一条流都断了
    func dropAllFollowers() {
        followers.removeAll()
    }

    // MARK: 投递

    /// `seq` 填的是 `batch` 算出来的**游标**（下一次 `--since`），不是全局 seq——
    /// 只有这一批没被截断时两者才相等
    private func payload(_ batch: Batch, timedOut: Bool?,
                         follow: Bool? = nil) -> ControlEventsPayload {
        ControlEventsPayload(events: batch.events, seq: batch.cursor, oldest: oldestSeq,
                             missed: batch.missed ? true : nil, timedOut: timedOut,
                             truncated: batch.truncated ? true : nil, follow: follow)
    }

    private func notify() {
        for waiter in waiters {
            let ready = batch(since: waiter.since, limit: waiter.limit, types: waiter.types,
                              exposesBrowser: waiter.exposesBrowser)
            guard !ready.events.isEmpty || ready.missed else { continue }
            waiter.timeout.cancel()
            waiters.removeAll { $0.ticket == waiter.ticket }
            waiter.deliver(payload(ready, timedOut: nil))
        }
        // 先把 ticket 抄下来：`deliver` 可能把某条流摘掉，直接按下标遍历会越界
        for ticket in followers.map(\.ticket) { pump(ticket: ticket) }
    }

    // MARK: 快照

    private struct PaneState {
        var handle: String
        var kind: String
        var screenIndex: Int
        var screenID: UUID
        var workspace: Int
        var title: String
        var cwd: String?
        /// 浏览器 pane：标题 / cwd 要按 `expose-browser` 打码
        var redactable: Bool
    }

    private struct WorkspaceState {
        var layout: String
        /// 结构指纹（列宽 / split 比例 / zoom / 浮动层都在内）：变了就是一次 layout.changed
        var signature: String
    }

    private struct ScreenState {
        var index: Int
        var title: String
        var activeWorkspace: Int
        var workspaces: [WorkspaceState]
        var focused: UUID?
        var focusedHandle: String?
        var focusedWorkspace: Int
    }

    @MainActor
    private struct Snapshot {
        var screens: [UUID: ScreenState] = [:]
        var screenOrder: [UUID] = []
        var panes: [UUID: PaneState] = [:]
        var paneOrder: [UUID] = []

        /// 当下的一份完整快照。**与 `state` 同一口径**：正在淡出（`closingPanes`）的 pane
        /// 不算活着——所以 `pane close` 一发出去就是一条 pane.closed，而不是等 0.28s 动效跑完
        static func capture(_ screens: ScreenRegistry) -> Snapshot {
            var out = Snapshot()
            for controller in screens.controllers {
                let model = controller.model
                let closing = model.closingPanes
                var workspaces: [WorkspaceState] = []
                for index in model.layouts.indices {
                    let layout = model.layouts[index]
                    workspaces.append(WorkspaceState(
                        layout: layout.name,
                        signature: signature(layout, floating: model.floatings[index], closing: closing)))
                    for pane in layout.paneList where !closing.contains(pane.id) {
                        out.record(pane, controller: controller, workspace: index)
                    }
                    for floating in model.floatings[index] where !closing.contains(floating.pane.id) {
                        out.record(floating.pane, controller: controller, workspace: index)
                    }
                }
                let focused = controller.focusedPane.flatMap { closing.contains($0.id) ? nil : $0 }
                out.screens[controller.windowID] = ScreenState(
                    index: controller.screenIndex + 1,
                    title: controller.window?.title ?? ScreenRegistry.title(forIndex: controller.screenIndex),
                    activeWorkspace: model.activeIndex + 1,
                    workspaces: workspaces,
                    focused: focused?.id,
                    focusedHandle: focused.map { ControlHandleRegistry.shared.handle(for: $0) },
                    focusedWorkspace: model.activeIndex + 1)
                out.screenOrder.append(controller.windowID)
            }
            return out
        }

        private mutating func record(_ pane: PaneView, controller: MainWindowController, workspace: Int) {
            guard panes[pane.id] == nil else { return }
            panes[pane.id] = PaneState(
                handle: ControlHandleRegistry.shared.handle(for: pane),
                kind: pane.kind.rawValue,
                screenIndex: controller.screenIndex + 1,
                screenID: controller.windowID,
                workspace: workspace + 1,
                title: pane.paneTitle,
                cwd: pane.workingDirectory,
                redactable: pane is BrowserPaneView)
            paneOrder.append(pane.id)
        }

        /// 结构指纹。列宽 / split 比例四舍五入到千分位——浮点噪声不该变成一条事件
        static func signature(_ layout: WorkspaceLayout, floating: [FloatingPane],
                              closing: Set<UUID>) -> String {
            func handle(_ pane: PaneView) -> String { ControlHandleRegistry.shared.handle(for: pane) }
            func number(_ value: Double) -> String { String(Int((value * 1000).rounded())) }
            var out = layout.name + "|"
            switch layout {
            case .scrolling(let strip):
                out += strip.columns.map { column in
                    number(column.widthFactor) + ":"
                        + column.panes.filter { !closing.contains($0.id) }.map(handle)
                        .joined(separator: ",")
                }.joined(separator: ";")
                if let zoomed = strip.zoomedPane, !closing.contains(zoomed.id) {
                    out += "|zoom=" + handle(zoomed)
                }
            case .dwindle(let tree):
                func walk(_ node: SplitTree<PaneView>.Node) -> String {
                    switch node {
                    case .leaf(let view):
                        return closing.contains(view.id) ? "-" : handle(view)
                    case .split(let split):
                        return "(\(split.direction)\(number(split.ratio)) "
                            + walk(split.left) + " " + walk(split.right) + ")"
                    }
                }
                out += tree.root.map(walk) ?? ""
                if let zoomed = tree.zoomed, case .leaf(let view) = zoomed, !closing.contains(view.id) {
                    out += "|zoom=" + handle(view)
                }
            }
            out += "|float=" + floating.filter { !closing.contains($0.pane.id) }
                .map { handle($0.pane) }.joined(separator: ",")
            return out
        }

        /// 相减。顺序是刻意的（开 → 结构 → 元数据 → 焦点 → 关），
        /// 这样一条流读下来是"先有东西，再摆好，最后焦点落定"
        static func diff(old: Snapshot, new: Snapshot) -> [Record] {
            var out: [Record] = []

            // 1) 屏幕开
            for id in new.screenOrder where old.screens[id] == nil {
                guard let state = new.screens[id] else { continue }
                out.append(Record(event: ControlEvent(type: .screenOpened, screen: state.index,
                                                      screenID: id.uuidString, title: state.title),
                                  redactable: false))
            }
            // 2) pane 开
            for id in new.paneOrder where old.panes[id] == nil {
                guard let pane = new.panes[id] else { continue }
                out.append(Record(event: ControlEvent(
                    type: .paneOpened, screen: pane.screenIndex, screenID: pane.screenID.uuidString,
                    workspace: pane.workspace, pane: pane.handle, paneID: id.uuidString,
                    kind: pane.kind, title: pane.title, cwd: pane.cwd),
                    redactable: pane.redactable))
            }
            // 3) 工作区切换 / 结构变化
            for id in new.screenOrder {
                guard let now = new.screens[id], let before = old.screens[id] else { continue }
                if before.activeWorkspace != now.activeWorkspace {
                    out.append(Record(event: ControlEvent(
                        type: .workspaceChanged, screen: now.index, screenID: id.uuidString,
                        workspace: now.activeWorkspace), redactable: false))
                }
                for index in now.workspaces.indices {
                    guard index < before.workspaces.count else { continue }
                    let a = before.workspaces[index]
                    let b = now.workspaces[index]
                    guard a.layout != b.layout || a.signature != b.signature else { continue }
                    out.append(Record(event: ControlEvent(
                        type: .layoutChanged, screen: now.index, screenID: id.uuidString,
                        workspace: index + 1, layout: b.layout), redactable: false))
                }
            }
            // 4) 标题 / cwd
            for id in new.paneOrder {
                guard let now = new.panes[id], let before = old.panes[id] else { continue }
                if before.title != now.title {
                    out.append(Record(event: ControlEvent(
                        type: .paneTitleChanged, screen: now.screenIndex,
                        screenID: now.screenID.uuidString, workspace: now.workspace,
                        pane: now.handle, paneID: id.uuidString, kind: now.kind, title: now.title),
                        redactable: now.redactable))
                }
                if before.cwd != now.cwd, let cwd = now.cwd {
                    out.append(Record(event: ControlEvent(
                        type: .paneCwdChanged, screen: now.screenIndex,
                        screenID: now.screenID.uuidString, workspace: now.workspace,
                        pane: now.handle, paneID: id.uuidString, kind: now.kind, cwd: cwd),
                        redactable: now.redactable))
                }
            }
            // 5) 焦点
            for id in new.screenOrder {
                guard let now = new.screens[id], let before = old.screens[id],
                      before.focused != now.focused else { continue }
                out.append(Record(event: ControlEvent(
                    type: .focusChanged, screen: now.index, screenID: id.uuidString,
                    workspace: now.focusedWorkspace, pane: now.focusedHandle,
                    paneID: now.focused?.uuidString), redactable: false))
            }
            // 6) pane 关
            for id in old.paneOrder where new.panes[id] == nil {
                guard let pane = old.panes[id] else { continue }
                out.append(Record(event: ControlEvent(
                    type: .paneClosed, screen: pane.screenIndex, screenID: pane.screenID.uuidString,
                    workspace: pane.workspace, pane: pane.handle, paneID: id.uuidString,
                    kind: pane.kind), redactable: false))
            }
            // 7) 屏幕关
            for id in old.screenOrder where new.screens[id] == nil {
                guard let state = old.screens[id] else { continue }
                out.append(Record(event: ControlEvent(type: .screenClosed, screen: state.index,
                                                      screenID: id.uuidString, title: state.title),
                                  redactable: false))
            }
            return out
        }
    }
}
