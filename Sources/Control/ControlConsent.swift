import AppKit
import OSLog

/// 破坏性 / 敏感命令的确认闸门。
///
/// 三个刻意的设计选择：
/// 1. **按 (对端 pid, 命令类) 缓存一次**（kitty 的做法）：agent 是成批发命令的，每条都问等于没问；
/// 2. **用 sheet，不用 `runModal()`**：`runModal` 会跑嵌套 run loop，把主线程连同整个控制服务一起卡住，
///    而 QuickTerm 自己已经有好几处 `runModal`（退出确认、关屏幕确认、浏览器的 JS 对话框）。
///    嵌套 run loop 期间用 `DispatchQueue.main.async` 排的块**会在用户的对话框背后执行**——
///    所以这里既不制造新的嵌套 run loop，也在别的模态挂着时直接拒（busy）；
/// 3. **对话框锚在应用自己的窗口上，不是请求方的 pane**（Zellij 有个已记录的洞：
///    后台插件没有 pane，永远拿不到授权）。所以从 Terminal.app / 后台任务发起的调用一样能被批准。
///
/// ⚠️ 这里没有、也绝不能有"带了正确 QUICKTERM_TOKEN 就跳过确认"的分支：
/// token 是来源证明，不是权限边界（见 ControlEnvironment）。确认框里显示的进程名来自内核
/// （LOCAL_PEERPID），所以就算 token 被抄走，用户看到的仍然是真实的 `node (pid 4821)`。
@MainActor
final class ControlConsent {
    enum Decision: String {
        case allow, deny, timeout
    }

    struct Request {
        var peerName: String
        var peerPID: pid_t
        /// 命令类（destructive / sensitive）
        var cls: ControlCommandClass
        /// 人话描述这条命令要干什么
        var summary: String
        /// 来源 pane 的句柄（有的话）。**这是调用方自报的**，服务端验不了——
        /// 所以文案里写"自称来自"，而且只有带着本次启动 token 的调用方才会有值
        /// （见 `ControlCommandRunner.originHandle(for:)`）。
        /// 内核给的 `peerName` / `peerPID` 才是这个框里唯一可信的身份
        var originPane: String?
        /// 来源 pane **被证明了**（`QUICKTERM_PANE_TOKEN` 与自报的 `origin.pane` 对得上）。
        /// 只影响措辞：证明了就直说"来自 pane t3"，没证明就仍然写"自称来自"
        var originVerified: Bool = false
        /// 请求带了本次启动生成的 token（只影响文案，不影响是否弹）
        var tokenPresent: Bool
        /// 这次批准能不能按 (pid, 类) 缓存起来。**`input send-text` 一律 false**：
        /// 关一个 pane 是用户看得见的一件事，缓存一次说得过去；而往别人的 tty 里注入文本
        /// 每一次的内容都可以完全不同，"批准过一次"根本不构成对下一次的同意
        var cacheable: Bool = true
        /// **只画给用户看**的正文预览（`input send-text` 才有；已净化并截断）。
        ///
        /// 它必须在框里，因为它是这一次确认与上一次唯一的区别：命令名与目标 pane 完全相同的两次调用，
        /// 一次是 `echo hi`，一次可以是 `curl … | sh`。没有它，用户读到的两句话一模一样，
        /// 那就不是一次知情的同意。
        ///
        /// ⚠️ 它**绝不进 `summary`**：`summary` 会以 `privacy: .public` 写进统一日志，
        /// 而"正文不进任何长期留存的记录"正是活动日志那边守着的同一条线
        var payload: String?
        /// 正文的**完整**字符数（预览是截断过的，用户得知道后面还有多少）
        var payloadLength: Int?
        /// 正文后面还跟一个回车——也就是那个 shell **真的会执行**它
        var payloadEnter: Bool = false
    }

    /// 未答复的等待上限：到点返回退出码 4，agent 可以告诉用户"去 QuickTerm 里确认"，而不是干等
    static let timeout: TimeInterval = 10

    private struct GrantKey: Hashable {
        var pid: pid_t
        var cls: ControlCommandClass
    }

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "ControlConsent")

    private var grants: Set<GrantKey> = []
    /// 同一时刻只允许一个确认框：第二条一律 busy（堆起 N 个 sheet 是 agent 循环时的真实后果）
    private(set) var isPrompting = false

    /// 用例注入的决策桩：测试宿主里绝不真的弹 sheet。
    /// **异步形状**（把答复交回给用例）而不是直接返回：真 sheet 就是异步的，
    /// 用例得能把"确认框正挂着"这个状态**保持住**，才能验证挂着期间别的命令会被挡下来
    var decisionStub: ((Request, @escaping (Decision) -> Void) -> Void)?

    weak var screens: ScreenRegistry?

    init(screens: ScreenRegistry?) {
        self.screens = screens
    }

    func reset() {
        grants.removeAll()
        isPrompting = false
    }

    /// 已授权？**pid 拿不到（<= 0）时永远返回 false**：
    /// 否则所有身份不明的对端会共用同一个 GrantKey(0, …)，第一个被批准之后
    /// 后面每一个都白拿授权——一次同意变成永久后门
    func hasGrant(pid: pid_t, cls: ControlCommandClass) -> Bool {
        guard pid > 0 else { return false }
        return grants.contains(GrantKey(pid: pid, cls: cls))
    }

    /// 同上：只有拿得到真实 pid 才缓存
    private func grant(pid: pid_t, cls: ControlCommandClass) {
        guard pid > 0 else { return }
        grants.insert(GrantKey(pid: pid, cls: cls))
    }

    /// 主线程上是否有别的模态在挂（sheet 或 NSAlert.runModal 的嵌套 run loop）。
    /// 有的话破坏性命令一律拒——绝不能让 agent 在用户盯着另一个对话框时把 pane 关掉
    var isModalBusy: Bool {
        if NSApp.modalWindow != nil { return true }
        if let screens {
            for controller in screens.controllers where controller.window?.attachedSheet != nil { return true }
        }
        return isPrompting
    }

    /// 确认框本体。**"拒绝"是第一个按钮**，所以它是默认按钮、回车落在它上面。
    ///
    /// 这不是排版偏好，是一次实测事故的修正：默认按钮原本是"允许"，
    /// 冒烟时一次落在窗口上的回车（谁都可能顺手按到）直接把一条破坏性命令批准了，
    /// 日志里留下的是 `控制面确认结果：allow` —— 用户根本没读那个框。
    /// 安全闸门的默认答案必须是"不"：允许要**点**，拒绝可以按回车 / Esc。
    static func makeAlert(_ request: Request) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "允许外部程序\(request.cls == .destructive ? "执行破坏性操作" : "执行敏感操作")？"
        let origin = request.originPane.map {
            request.originVerified ? "，来自 pane \($0)" : "，自称来自 pane \($0)"
        } ?? ""
        // 正文单独一段，并且明写"回车 = 它会被执行"——`--enter` 是"送文本"与"让它跑"
        // 之间唯一的分界，用户批准的到底是哪一件，必须在框里说出来
        let payload = request.payload.map { text in
            "\n\n要打进去的是（共 \(request.payloadLength ?? text.count) 个字符）：\n\(text)\n"
                + (request.payloadEnter
                    ? "（后面跟一个回车 —— 那个 shell 会**直接执行**它）"
                    : "（不带回车 —— 只是把字留在命令行上，不会执行）")
        } ?? ""
        alert.informativeText = """
        \(request.peerName)（pid \(request.peerPID)）\(origin)\
        要求：\(request.summary)\(payload)

        \(request.cacheable ? "允许之后，本次启动内该进程的同类命令不再询问。"
                             : "**这一次**允许。向别的 pane 注入文本每次都会重新询问。")
        \(request.tokenPresent ? "（该调用方带着 QuickTerm 注入的来源标记——这只说明它来自某个 pane，不代表被授权。）"
                               : "（该调用方没有 QuickTerm 的来源标记。）")
        """
        alert.addButton(withTitle: "拒绝")   // 第一个 = 默认按钮 = 回车
        alert.addButton(withTitle: "允许")
        // NSAlert 默认把第一个按钮的键等价设成回车；这里显式写死，免得将来改按钮顺序时悄悄漂移。
        // Esc 由 NSAlert 自己映射到最后一个按钮，所以"允许"还要再收回一次
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = ""
        alert.alertStyle = .warning
        return alert
    }

    /// "允许"是第二个按钮（第一个是默认的"拒绝"）
    static let allowResponse = NSApplication.ModalResponse.alertSecondButtonReturn

    /// 决策。`completion` 一定在主线程上被调用一次
    func evaluate(_ request: Request, completion: @escaping (Decision) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if request.cacheable, hasGrant(pid: request.peerPID, cls: request.cls) {
            completion(.allow)
            return
        }
        if let stub = decisionStub {
            // 与真 sheet 同一条生命周期：问出去的那一刻起 isPrompting 就是 true，
            // 答复回来才落下——用例才能验证"确认框挂着时变更命令一律 busy"
            isPrompting = true
            var answered = false
            stub(request) { [weak self] decision in
                guard !answered else { return }
                answered = true
                self?.isPrompting = false
                if decision == .allow, request.cacheable {
                    self?.grant(pid: request.peerPID, cls: request.cls)
                }
                completion(decision)
            }
            return
        }
        // 测试宿主里没有桩就一律拒绝：绝不在跑用例的机器上弹窗
        guard !AppDelegate.isRunningTests else {
            completion(.deny)
            return
        }
        guard !isModalBusy else {
            completion(.timeout)   // 调用方会翻译成 busy / 需确认
            return
        }
        guard let window = (screens?.key ?? screens?.primary)?.window else {
            completion(.deny)
            return
        }

        isPrompting = true
        Self.logger.notice("控制面确认：\(request.peerName, privacy: .public)(pid \(request.peerPID)) 请求 \(request.cls.rawValue, privacy: .public) —— \(request.summary, privacy: .public)")
        let alert = Self.makeAlert(request)

        var answered = false
        let finish: (Decision) -> Void = { [weak self] decision in
            guard !answered else { return }
            answered = true
            self?.isPrompting = false
            if decision == .allow, request.cacheable {
                self?.grant(pid: request.peerPID, cls: request.cls)
            }
            Self.logger.notice("控制面确认结果：\(decision.rawValue, privacy: .public)（pid \(request.peerPID)）")
            completion(decision)
        }

        alert.beginSheetModal(for: window) { response in
            finish(response == Self.allowResponse ? .allow : .deny)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak window, weak alert] in
            guard !answered else { return }
            // **先落定"超时"，再收 sheet**：`endSheet` 会同步回调上面那个 completion，
            // 于是 finish(.deny) 抢先跑掉，agent 收到的是"用户拒绝了这条命令"（退出码 5）——
            // 而用户其实一个字都没说。那是对 agent 谎报了一个不存在的拒绝，
            // 也和 describe / 文档里写死的"超时 → 退出码 4"直接对不上。
            // finish 里的 answered 置位保证随后那次 .deny 回调是空转
            finish(.timeout)
            if let window, let alert { window.endSheet(alert.window, returnCode: .cancel) }
        }
    }
}
