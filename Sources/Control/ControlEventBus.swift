import AppKit

/// The event bus (Phase 4): sole owner of the monotonic `seq`, the place typed events are
/// produced, and the wait queue behind long polling and streaming.
///
/// **Events are derived by subtracting snapshots, not hand-written at each call site.**
/// `MainWindowController` already carries a set of Combine sinks (layouts / floatings /
/// activeIndex), and the close animation, the focus handover, OSC 7's cwd and browser titles all
/// have trigger points of their own; if every one of those hand-wrote an
/// `emit(.paneOpened(...))`, then:
/// - miss one and an agent never hears about that class of change, with no test to catch it;
/// - the same thing gets reported several times within one relayout (`perform()` is reentrant).
/// So this accepts exactly one signal — "something may have changed" (`scheduleScan()`) — and
/// then diffs the whole registry against the previous snapshot. **Coalescing is free**: N
/// changes within a single run loop turn produce exactly one scan.
///
/// ⚠️ No event may **ever carry the contents of a pane's output** (see the comments on
/// `ControlEventType`). All this code can read is structure, titles and cwd — and for browser
/// panes even title / cwd go through the same redaction rule `state` applies.
@MainActor
final class ControlEventBus {
    static let shared = ControlEventBus()

    /// One slot in the ring: the event as it goes on the wire, plus "does this one's title /
    /// cwd need the browser redaction rule".
    /// Redaction happens **at delivery**, not at production: the very same event has to go out
    /// both to a caller carrying the token and to one that is not
    private struct Record {
        var event: ControlEvent
        var redactable: Bool
    }

    private weak var screens: ScreenRegistry?
    /// The monotonic state counter. Every event bumps it by one; a change that no typed event
    /// covers gets its one bump from `settleMutation()`
    private(set) var seq = 0
    private var ring: [Record] = []
    private var snapshot = Snapshot()
    private var scanScheduled = false
    private var waiters: [Waiter] = []
    private var followers: [Follower] = []
    /// Internal ticket number for each follow / poll (this is what cancels them)
    private var nextTicket = 0

    private init() {}

    // MARK: Lifecycle

    /// Attach the registry and record the current state as the baseline, **emitting no events**.
    /// Without this, the first scan after launch treats every screen and every pane as having
    /// just been created
    func attach(screens: ScreenRegistry) {
        self.screens = screens
        resync()
    }

    /// Record the current state as the baseline, producing no events. The test fixtures use it
    /// too, so that panes left behind by the previous test do not turn into a burst of
    /// nonsensical pane.closed events in this one
    func resync() {
        scanScheduled = false
        snapshot = screens.map { Snapshot.capture($0) } ?? Snapshot()
    }

    /// Tests only: clear the ring and the wait queue (`seq` is **not** reset — it is monotonic,
    /// and resetting it would make an older seq legitimate again)
    func resetForTesting() {
        ring.removeAll()
        for waiter in waiters { waiter.timeout.cancel() }
        waiters.removeAll()
        followers.removeAll()
        resync()
    }

    // MARK: Scanning

    /// "Something may have changed." Call it as many times as you like within one run loop turn
    /// and it still scans once — **that is what the coalescing is**
    func scheduleScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scanScheduled else { return }
            self.scanScheduled = false
            self.rescan()
        }
    }

    /// Report "something may have changed" from the places that carry no actor annotation
    /// (`PaneView.focusDidChange`, `ScreenRegistry`). They all run on the main thread anyway,
    /// but the project is Swift 5.10 and neither `MainWindowController` nor `PaneView` is
    /// annotated `@MainActor`, so this goes through `assumeIsolated` — the same shape as
    /// `ControlUndo.invalidate()`
    nonisolated static func noteChange() {
        MainActor.assumeIsolated { shared.scheduleScan() }
    }

    /// Scan right now (used once a control command has landed: the `seq` in the response has to
    /// already cover the events that command produced)
    func flush() {
        scanScheduled = false
        rescan()
    }

    /// A control command really landed. Scan the typed events out first; if there were none at
    /// all (`app set theme`, `screen set --fullscreen` and the like, which do not touch the
    /// layout) bump `seq` once anyway — an agent reads `seq` to tell whether the snapshot in its
    /// hands is stale, and "it changed but seq did not move" is the worst lie on offer
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

    // MARK: Reading

    var oldestSeq: Int? { ring.first?.event.seq }

    /// The result of taking one batch. `cursor` is **the number to pass as `--since` next
    /// time**, not the current global `seq`: the two are equal only when this batch was not
    /// truncated by `--limit`.
    ///
    /// That distinction is the one place in the whole event stream where events can be
    /// **dropped silently**, which is why it gets a type of its own.
    /// It used to return the global seq unconditionally, so with 50 events pending
    /// `events poll --limit 10` would hand back 10 of them and tell the caller "you have now
    /// seen event 50" — the other 40 were never delivered and were not flagged by `missed`
    /// either (`missed` only covers events pushed out of the ring, and here the ring had lost
    /// nothing). When truncating, pin the cursor to **the last event that actually went out**,
    /// and those 40 arrive on the next round.
    struct Batch {
        var events: [ControlEvent]
        var missed: Bool
        /// The next `--since`
        var cursor: Int
        /// This batch was cut short by `--limit` and the ring still holds more — the caller need
        /// not wait out a timeout, it can poll again straight away
        var truncated: Bool
    }

    /// Take a batch of what follows `since`. **Only what was genuinely missed comes back**: not
    /// one event with `seq <= since`
    func batch(since: Int, limit: Int, types: Set<String>?, exposesBrowser: Bool) -> Batch {
        var matched = ring.filter { $0.event.seq > since }
        if let types { matched = matched.filter { types.contains($0.event.type) } }
        // Entries have been pushed out of the ring: part of the range the caller asked for is
        // already gone
        let missed = since >= 0 && (ring.first.map { $0.event.seq > since + 1 } ?? false)
        let truncated = matched.count > limit
        let capped = truncated ? Array(matched.prefix(limit)) : matched
        // Only an untruncated batch may say "you have caught up to seq": what `--types` filtered
        // out genuinely need not be sent again, but what `--limit` cut off is still sitting in
        // the ring
        let cursor = truncated ? (capped.last?.event.seq ?? seq) : seq
        return Batch(events: capped.map { project($0, exposesBrowser: exposesBrowser) },
                     missed: missed, cursor: cursor, truncated: truncated)
    }

    /// Redaction: a browser pane's title / cwd are always `<redacted>` for a caller without the
    /// token. `state` already does this, and if the event stream skipped it, the stream would be
    /// a way around the redaction
    private func project(_ record: Record, exposesBrowser: Bool) -> ControlEvent {
        guard record.redactable, !exposesBrowser else { return record.event }
        return Self.redact(record.event)
    }

    /// The redaction itself, kept static so tests can pin it down directly — the copy in the
    /// ring is private
    static func redact(_ event: ControlEvent) -> ControlEvent {
        var out = event
        if out.title != nil { out.title = ControlEvent.redactedPlaceholder }
        if out.cwd != nil { out.cwd = ControlEvent.redactedPlaceholder }
        out.redacted = true
        return out
    }

    // MARK: Long polling (`events poll`)

    private struct Waiter {
        var ticket: Int
        var since: Int
        var limit: Int
        var types: Set<String>?
        var exposesBrowser: Bool
        var deliver: (ControlEventsPayload) -> Void
        var timeout: DispatchWorkItem
    }

    /// Long poll. **If there are new events in hand already, return immediately** rather than
    /// waiting out the timeout; otherwise suspend until either new events arrive or the deadline
    /// passes, at which point return an empty batch flagged `timedOut`
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

    // MARK: Streaming (`events follow`)

    private struct Follower {
        var ticket: Int
        /// The connection number: the moment the peer leaves, this stream has to be torn down,
        /// or it writes to an already-closed fd forever
        var connection: UInt64
        var lastSeq: Int
        var limit: Int
        var types: Set<String>?
        var exposesBrowser: Bool
        var deliver: (ControlEventsPayload) -> Void
    }

    var followerCount: Int { followers.count }

    /// Register a stream. false = there are already too many of them (each one ties up a
    /// connection)
    @discardableResult
    func follow(connection: UInt64, since: Int, limit: Int, types: Set<String>?,
                exposesBrowser: Bool, deliver: @escaping (ControlEventsPayload) -> Void) -> Bool {
        guard followers.count < ControlEventLimits.maxFollowers else { return false }
        nextTicket += 1
        let ticket = nextTicket
        // The cursor starts at `since` and `pump` walks it forward batch by batch — **it must
        // never be written as the global seq**: the catch-up at registration time is subject to
        // `--limit` as well, and writing seq would mean whatever got cut is never pushed at all
        followers.append(Follower(ticket: ticket, connection: connection, lastSeq: since,
                                  limit: limit, types: types, exposesBrowser: exposesBrowser,
                                  deliver: deliver))
        // First catch up on what has already happened since `--since` (even when that is empty:
        // the caller needs to know which seq it is starting from), then keep pushing new ones
        pump(ticket: ticket, deliverEmptyFirstBatch: true)
        return true
    }

    /// Push a stream's backlog out until it is empty. **Truncated means keep going**: `--limit`
    /// should cap the size of a single batch, not park a stream until the next event comes along
    /// (`events follow --limit 1` used to do exactly that: one scan that produced five events
    /// pushed only the first, and the other four waited for some unrelated change to happen)
    private func pump(ticket: Int, deliverEmptyFirstBatch: Bool = false) {
        var rounds = 0
        var first = true
        // Look the follower up by ticket on every round: `deliver` writes to the socket, and a
        // failed write tears this stream down
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
            // The cap is only a backstop: the ring holds ringCapacity events at most, and limit
            // is at least 1
            guard ready.truncated, rounds <= ControlEventLimits.ringCapacity else { break }
        }
    }

    /// The peer left: drop every stream it held. **This is follow's only termination condition**
    func connectionDidClose(_ connection: UInt64) {
        followers.removeAll { $0.connection == connection }
    }

    /// The server stopped (config switched to off, or the app is quitting): every stream is cut
    func dropAllFollowers() {
        followers.removeAll()
    }

    // MARK: Delivery

    /// `seq` here carries the **cursor** `batch` computed (what to pass as `--since` next time),
    /// not the global seq — the two are equal only when this batch was not truncated
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
        // Copy the tickets out first: `deliver` may tear a stream down, and iterating by index
        // would then run off the end
        for ticket in followers.map(\.ticket) { pump(ticket: ticket) }
    }

    // MARK: Snapshots

    private struct PaneState {
        var handle: String
        var kind: String
        var screenIndex: Int
        var screenID: UUID
        var workspace: Int
        var title: String
        /// Has the title been taken over (`pane set --title`, or the rename sheet)? It is part of
        /// the snapshot, not a decoration on the event: pinning a pane to the exact title the shell
        /// is already reporting changes no text at all, and without this the stream would go silent
        /// on a change `state` does report.
        var titleSet: Bool
        var cwd: String?
        /// A browser pane: title / cwd have to be redacted according to `expose-browser`
        var redactable: Bool
    }

    private struct WorkspaceState {
        var layout: String
        /// Structural fingerprint — column widths, split ratios, zoom and the floating layer are
        /// all in it: if it changed, that is one layout.changed
        var signature: String
        /// The slot's name: a change here reports one workspace.changed (**no new event type** —
        /// "something about this workspace changed" is exactly what that event already means, and
        /// another type would only make subscribers write another branch). What tells a rename
        /// apart from a switch is the title field: absent = a switch, `""` = the name was cleared
        /// (see `diff`)
        var title: String?
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

        /// A complete snapshot of right now. **The same reading as `state`**: a pane that is
        /// fading out (`closingPanes`) does not count as alive — so `pane close` produces a
        /// pane.closed the moment it is issued, not 0.28 s later when the animation finishes
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
                        signature: signature(layout, floating: model.floatings[index], closing: closing),
                        title: model.title(at: index)))
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
                titleSet: pane.customTitle != nil,
                cwd: pane.workingDirectory,
                redactable: pane is BrowserPaneView)
            paneOrder.append(pane.id)
        }

        /// The structural fingerprint. Column widths and split ratios are rounded to three
        /// decimals: floating-point noise must not turn into an event
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

        /// The subtraction. The order is deliberate (opened → structure → metadata → focus →
        /// closed), so that reading a stream top to bottom goes "things appear, then they are
        /// arranged, then the focus settles"
        static func diff(old: Snapshot, new: Snapshot) -> [Record] {
            var out: [Record] = []

            // 1) Screens opened
            for id in new.screenOrder where old.screens[id] == nil {
                guard let state = new.screens[id] else { continue }
                out.append(Record(event: ControlEvent(type: .screenOpened, screen: state.index,
                                                      screenID: id.uuidString, title: state.title),
                                  redactable: false))
            }
            // 2) Panes opened
            for id in new.paneOrder where old.panes[id] == nil {
                guard let pane = new.panes[id] else { continue }
                out.append(Record(event: ControlEvent(
                    type: .paneOpened, screen: pane.screenIndex, screenID: pane.screenID.uuidString,
                    workspace: pane.workspace, pane: pane.handle, paneID: id.uuidString,
                    kind: pane.kind, title: pane.title, cwd: pane.cwd),
                    redactable: pane.redactable))
            }
            // 3) Workspace switches / structural changes
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
                    // Renaming: words the user wrote themselves, the same class as a pane
                    // title — not redacted.
                    // **`?? ""` is the whole point of this line.** One event type covers both "the
                    // screen switched workspace" and "this workspace was renamed" (deliberately:
                    // "something about this workspace changed" is what the type already means, and
                    // a second type would only make every subscriber write a second branch). With
                    // a nil title the two are the same bytes on the wire — a switch and a cleared
                    // name both arrive as `{type:"workspace.changed", workspace:N}`. An empty
                    // string separates them: no title field = a switch, `""` = the name was
                    // cleared, any other string = the new name. That is the convention
                    // pane.title.changed already follows.
                    if a.title != b.title {
                        out.append(Record(event: ControlEvent(
                            type: .workspaceChanged, screen: now.index, screenID: id.uuidString,
                            workspace: index + 1, title: b.title ?? ""), redactable: false))
                    }
                    guard a.layout != b.layout || a.signature != b.signature else { continue }
                    out.append(Record(event: ControlEvent(
                        type: .layoutChanged, screen: now.index, screenID: id.uuidString,
                        workspace: index + 1, layout: b.layout), redactable: false))
                }
            }
            // 4) Titles / cwd
            for id in new.paneOrder {
                guard let now = new.panes[id], let before = old.panes[id] else { continue }
                if before.title != now.title || before.titleSet != now.titleSet {
                    out.append(Record(event: ControlEvent(
                        type: .paneTitleChanged, screen: now.screenIndex,
                        screenID: now.screenID.uuidString, workspace: now.workspace,
                        pane: now.handle, paneID: id.uuidString, kind: now.kind, title: now.title,
                        titleSet: now.titleSet ? true : nil),
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
            // 5) Focus
            for id in new.screenOrder {
                guard let now = new.screens[id], let before = old.screens[id],
                      before.focused != now.focused else { continue }
                out.append(Record(event: ControlEvent(
                    type: .focusChanged, screen: now.index, screenID: id.uuidString,
                    workspace: now.focusedWorkspace, pane: now.focusedHandle,
                    paneID: now.focused?.uuidString), redactable: false))
            }
            // 6) Panes closed
            for id in old.paneOrder where new.panes[id] == nil {
                guard let pane = old.panes[id] else { continue }
                out.append(Record(event: ControlEvent(
                    type: .paneClosed, screen: pane.screenIndex, screenID: pane.screenID.uuidString,
                    workspace: pane.workspace, pane: pane.handle, paneID: id.uuidString,
                    kind: pane.kind), redactable: false))
            }
            // 7) Screens closed
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
