import AppKit

/// Phase 2 变更命令的共同骨架：**先算 diff，再决定要不要动手**。
///
/// 每条命令都被写成同一个形状：
/// 1. 只读地算出 `changes`（当前值 → 目标值）；
/// 2. 交给 `commit(_:apply:)`——它统一处理 `--dry-run` / `--fail-if-noop` / 撤销登记 /
///    状态栏闪烁 / 活动日志 / `seq` 自增。
///
/// 这个形状本身就是幂等性的**实现方式**，而不是一句承诺：
/// 空的 `changes` 就是"已经是目标状态"，`apply` 那一段根本不会被调用。
/// 于是"跑两次第二次是 no-op"不是某条命令的自觉，是所有命令共用的一条控制流。
@MainActor
struct ControlMutationRequest {
    /// 线上的命令名（`pane.set`）
    let command: String
    let request: ControlRequest
    let peer: ControlSocket.Peer
    /// 只读算出来的 diff。**空 = 什么都不用做**
    let changes: [ControlChange]
    /// 会被改动的控制器（撤销快照 + 状态栏闪烁的落点；跨屏幕移动时是两块）
    let controllers: [MainWindowController]
    /// 撤销项的名字；nil = 这一步不可撤销（比如关 pane：进程已经死了，撤销只会造一个假象）
    let undoName: String?
    /// 日志里显示的落点（`1:2.t7`）
    let target: String?
}

@MainActor
extension ControlCommandRunner {
    var isDryRun: Bool { currentFlags.dryRun }
    var failsIfNoop: Bool { currentFlags.failIfNoop }

    /// 变更命令的唯一出口。返回值里 `applied` / `changed` / `changes` 三件事都已经填好，
    /// 调用方只需要再补上"改完之后的实体"（pane / workspace / screen）
    func commit(_ mutation: ControlMutationRequest,
                apply: () throws -> Void) throws -> ControlMutationPayload {
        dispatchPrecondition(condition: .onQueue(.main))
        let changed = !mutation.changes.isEmpty
        let dryRun = isDryRun

        guard changed else {
            log(mutation, outcome: failsIfNoop ? "noop(exit 7)" : "noop")
            if failsIfNoop {
                throw ControlErrorBody(.noop, "Already in the requested state, nothing changed",
                                       hint: "Without --fail-if-noop this is a silent success, which is how an absolute setter is meant to behave.")
            }
            return ControlMutationPayload(command: mutation.command, applied: false,
                                          changed: false, dryRun: dryRun)
        }
        guard !dryRun else {
            log(mutation, outcome: "dry-run")
            return ControlMutationPayload(command: mutation.command, applied: false,
                                          changed: true, dryRun: true, changes: mutation.changes)
        }

        // 撤销快照要在动手**之前**拍：值类型的 layouts / floatings 拍下来就是完整的一份旧布局
        let generation = ControlUndo.generation
        var snapshots = mutation.undoName == nil ? [] : mutation.controllers.map { $0.controlSnapshot() }
        do {
            try apply()
        } catch {
            // apply 抛出 = 这一步没落地：seq 不动、不进撤销栈、不闪状态栏。
            // 但**要**记一笔——失败的变更正是用户最需要在活动日志里看到的那一类。
            // （命令体一律直接 `throw`，绝不用捕获变量把失败绕过 commit：
            //   那样 seq 会为一次没发生的变更 +1，撤销栈会多一个撤不到点子上的项，
            //   日志还会记成 applied）
            let body = (error as? ControlErrorBody) ?? ControlErrorBody(.failed, "\(error)")
            log(mutation, outcome: "失败：\(body.code)")
            throw body
        }
        seqDidMutate()
        if let undoName = mutation.undoName, !snapshots.isEmpty,
           ControlUndo.generation == generation {
            // apply 期间没有任何 pane 被关掉才登记：关掉过就说明快照里吊着一个已死的 pane
            for index in snapshots.indices { snapshots[index].stampExpectedPanes() }
            ControlUndo.register(name: undoName, before: snapshots)
        }
        flash(mutation)
        log(mutation, outcome: "applied")
        return ControlMutationPayload(command: mutation.command, applied: true, changed: true,
                                      dryRun: false, changes: mutation.changes,
                                      undo: mutation.undoName)
    }

    /// 状态栏闪一下：`mutate` 类命令是静默执行的，**可见性是它被允许静默的前提**。
    /// 文案里写清是哪条命令、来自哪个 pane（自称）——用户至少知道刚才不是自己按错了键
    private func flash(_ mutation: ControlMutationRequest) {
        let origin = originHandle(for: mutation.request)
        let text = "控制面 " + mutation.command + (origin.map { " ←\($0)" } ?? "")
        let controllers = mutation.controllers.isEmpty
            ? [screens.controlCurrent].compactMap { $0 }
            : mutation.controllers
        for controller in controllers { controller.model.showControlFlash(text) }
    }

    private func log(_ mutation: ControlMutationRequest, outcome: String) {
        ControlActivityLog.shared.record(.init(
            at: Date(),
            command: mutation.command,
            peer: "\(mutation.peer.processName)(pid \(mutation.peer.pid))",
            originPane: originHandle(for: mutation.request),
            target: mutation.target,
            outcome: outcome,
            changes: mutation.changes))
    }

    /// 读命令也记一笔？**不记**：读是高频且无害的，记下来只会把真正的变更淹掉。
    /// 被拒绝的变更倒是要记——那是用户最需要看到的一类
    func logRefusal(_ command: String, peer: ControlSocket.Peer, request: ControlRequest,
                    code: ControlErrorCode, message: String) {
        ControlActivityLog.shared.record(.init(
            at: Date(),
            command: command,
            peer: "\(peer.processName)(pid \(peer.pid))",
            originPane: originHandle(for: request),
            target: request.target,
            outcome: "拒绝：\(code.rawValue)",
            changes: []))
    }
}

/// 撤销登记。用的是 `AppDelegate.undoManager`——它一直存在却从来没人用过。
///
/// 快照式撤销（把 layouts / floatings / activeIndex 整份存下来再整份放回）而不是逐操作反算：
/// 布局是值类型，一份快照就是一份完整的旧状态，绝不会出现"反算漏了 zoom"这种半吊子回滚。
/// 代价是快照强引用着那些 PaneView，所以 `levelsOfUndo` 必须封顶——
/// 否则一个跑飞的 agent 会让撤销栈把几百个 surface 一直吊在内存里。
///
/// **关 pane / 关屏幕不登记撤销**：进程已经被杀了，把布局放回去只会造出一个"好像还在"的假象。
@MainActor
enum ControlUndo {
    static let levels = 25

    /// 每一次登记 / 每一次真正的关闭都 +1。`commit` 用它判断"拍完快照到落刀之间有没有 pane 被关掉"
    private(set) static var generation = 0

    private final class Target {
        static let shared = Target()
    }

    /// **关 pane / 关屏幕 = 整个控制面撤销栈作废。**
    ///
    /// 快照里的 layouts / floatings 是值类型，但里面装的是 `PaneView`（类），
    /// 也就是每个 pane 一份**强引用**；而关闭全靠"放弃最后一份引用"触发
    /// `SurfaceView.deinit → ghostty_surface_free`（`finishClose` / `removePane` / `teardown`
    /// 的注释写的都是这句）。留着快照的后果是两条，都与关闭路径的生命周期不变量直接冲突：
    /// 1. 关掉的 surface 不释放、shell 不退出（关屏幕更是明说"就该结束里面的进程"）；
    /// 2. ⌘Z 能把一个已经跑完一次性 `paneWillClose()` 的浏览器 pane 原样塞回布局，
    ///    而它再也不会重新向扩展报一次窗口事件。
    ///
    /// 真正的 `removeAllActions()` 排到下一轮：本方法可能正处在引擎 close_surface 的回调栈里，
    /// 同步释放会当场 free 一个仍在引擎栈上的 surface。排队时记下当时的代号，
    /// 期间若有新的登记（代号变了）就不清——那条新的撤销项是这次关闭**之后**拍的，本来就是干净的。
    nonisolated static func invalidate() {
        MainActor.assumeIsolated {
            generation &+= 1
            let queuedAt = generation
            guard let manager = (NSApp.delegate as? AppDelegate)?.undoManager,
                  manager.canUndo || manager.canRedo else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == queuedAt, !manager.isUndoing, !manager.isRedoing else { return }
                    manager.removeAllActions()
                }
            }
        }
    }

    static func register(name: String, before: [MainWindowController.ControlSnapshot]) {
        guard let manager = (NSApp.delegate as? AppDelegate)?.undoManager else { return }
        manager.levelsOfUndo = levels
        generation &+= 1
        // 反向那一半：撤销之后要能重做，所以撤销的时候把"现在"再拍一份登记回去
        let after = before.compactMap { $0.controller?.controlSnapshot() }
        manager.registerUndo(withTarget: Target.shared) { _ in
            MainActor.assumeIsolated {
                // 整份盖回去 = 换掉整个 pane 集合。所以只有每一块屏幕都还是这次变更留下的
                // 那一组 pane 时才撤销，而且全有全无（跨屏幕移动只回滚一半会凭空多出/少掉一个 pane）
                guard before.allSatisfy({ $0.matchesLive() }) else {
                    for snapshot in before {
                        snapshot.controller?.model.showControlFlash("布局已变，「\(name)」这一步撤销作废")
                    }
                    return
                }
                // 撤销会顺带关掉 pane（撤销 `pane new`）时不登记重做：
                // 重做快照会把那个已经跑完收尾的 pane 一直吊着，还能把它放回布局
                let closes = before.contains { $0.closesPanesOnRestore }
                for snapshot in before { _ = snapshot.restore() }
                if !after.isEmpty, !closes {
                    var redo = after
                    for index in redo.indices { redo[index].stampExpectedPanes() }
                    register(name: name, before: redo)
                }
                for snapshot in before { snapshot.controller?.model.showControlFlash("撤销 " + name) }
            }
        }
        manager.setActionName(name)
    }
}
