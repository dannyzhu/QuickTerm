import AppKit

/// 「按描述造一个 pane」的**唯一**一份实现。
///
/// `pane new` 与 `spec apply` 都从这里造 pane。第二份实现的代价在这个应用里是具体的：
/// 引擎对带 command 的 surface 强制 wait-after-command（不接管 `closesOnChildExit` 的话
/// 命令跑完 pane 就永远僵在那儿）、文件管理器 pane 要登记会话否则关闭确认会回来、
/// 浏览器 pane 漏掉主题那一下底色就是白的——这三件事各写一遍必然漏掉一件。
@MainActor
enum ControlPaneFactory {
    struct Request {
        var kind = "terminal"
        /// 已经展开过 `~`、归一过 `..` 的绝对路径；nil = 继承锚点
        var cwd: String?
        var cmd: String?
        var hold = false
        var env: [String: String] = [:]
        var url: String?

        init(kind: String = "terminal", cwd: String? = nil, cmd: String? = nil,
             hold: Bool = false, env: [String: String] = [:], url: String? = nil) {
            self.kind = kind
            self.cwd = cwd
            self.cmd = cmd
            self.hold = hold
            self.env = env
            self.url = url
        }
    }

    /// 造出来了，但**还没插进任何布局**。插进去之后调 `register`，插不进去调 `discard`
    struct Made {
        var pane: PaneView
        var fileManagerSession: FileManagerLaunch.Session?
        var fileManagerFound = false
    }

    /// 参数互斥与取值检查。**造之前**做完：`spec apply` 靠它保证"校验不过就一个 pane 都不建"
    static func validate(_ request: Request) throws {
        switch request.kind {
        case "terminal", "file-manager", "browser": break
        default:
            throw ControlErrorBody(.badRequest, "认不得的 pane 种类 \(request.kind)",
                                   candidates: ["terminal", "browser", "file-manager"])
        }
        if request.kind != "browser", request.url != nil {
            throw ControlErrorBody(.badRequest, "--url 只对 --kind browser 有意义",
                                   hint: "quickterm pane new --kind browser --url …")
        }
        if request.kind == "browser", request.cmd != nil {
            throw ControlErrorBody(.badRequest, "--cmd 对浏览器 pane 没有意义")
        }
        if let cwd = request.cwd {
            guard cwd.hasPrefix("/"), !cwd.contains("\0") else {
                throw ControlErrorBody(.badRequest, "--cwd 不是一个可用的路径：\(cwd)")
            }
        }
        if request.kind == "browser" {
            _ = try browserURL(request)
        }
    }

    /// 目标目录真的存在吗。`spec apply` 在**动手之前**对整份 spec 走一遍——
    /// 半途才发现某个目录不在，工作区已经被拆了一半
    static func directoryProblem(_ cwd: String?) -> String? {
        guard let cwd else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) else {
            return "目录不存在：\(cwd)"
        }
        guard isDirectory.boolValue else { return "不是一个目录：\(cwd)" }
        return nil
    }

    /// 地址栏那套启发式认不得、但浏览器 pane 真的能打开的 scheme。
    /// `webkit-extension://` 是这里唯一的成员，也是 1.5.7 起的一等状态（内嵌扩展面板就是它）：
    /// `url(forInput:)` 只认 http/https/file/about，扩展页会先被当成"像域名"补成
    /// `https://webkit-extension://…`，不像域名的还会被百分号编码丢进搜索引擎——
    /// 于是 `spec dump → apply` 会把一个开着的扩展面板换成一次网页搜索
    static let passthroughSchemes: Set<String> = ["webkit-extension"]

    /// spec / 存档里回来的**绝对**网址 → URL。人手打进地址栏的那条路仍走 `url(forInput:)`
    ///（"quickterm" 这种词该去搜索，而不是被当成一个 scheme）
    static func resolveURL(_ raw: String) -> URL? {
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
           passthroughSchemes.contains(scheme) {
            return url
        }
        return BrowserPaneView.settings.url(forInput: raw)
    }

    static func browserURL(_ request: Request) throws -> URL {
        let raw = request.url ?? BrowserPaneView.settings.home
        guard let url = resolveURL(raw) else {
            throw ControlErrorBody(.badRequest, "解析不出一个网址：\(raw)")
        }
        return url
    }

    /// 造。**不插布局**（`spec apply` 要先把整个布局值算好再一次赋值）
    static func make(_ request: Request, controller: MainWindowController,
                     inheriting anchorDirectory: String?) throws -> Made {
        try validate(request)
        switch request.kind {
        case "browser":
            let pane = controller.controlMakeBrowserPane(url: try browserURL(request))
            return Made(pane: pane)
        case "file-manager":
            let start = request.cwd ?? anchorDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            let made = controller.makeFileManagerPane(startDirectory: start)
            return Made(pane: made.pane, fileManagerSession: made.launch.session,
                        fileManagerFound: made.launch.found)
        default:
            let directory = request.cwd ?? anchorDirectory
            let surface = controller.newSurface(workingDirectory: directory,
                                                command: request.cmd, environment: request.env)
            // 引擎对带 command 的 surface 强制 wait-after-command、自己不会 close：
            // 想要"命令跑完 pane 就消失"必须由我们接管（--hold 就是明确要求别接管）
            if request.cmd != nil, !request.hold { surface.closesOnChildExit = true }
            // 明确给了目录就**当场种进 pwd**（yazi pane 一直是这么做的）。
            // 否则 `spec dump` 读到的 cwd 要等 shell 的第一个提示符发 OSC 7 才出现，
            // 于是 `dump → apply → dump` 是否相等取决于两次 dump 之间等了多久——
            // 那不是不动点，那是一场赛跑
            if let directory { surface.pwd = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path }
            return Made(pane: surface)
        }
    }

    /// 已经插进布局了：把该登记的登记上
    static func register(_ made: Made, controller: MainWindowController) {
        guard let session = made.fileManagerSession else { return }
        // 只有真的跑起文件管理器才登记会话（免关闭确认 + 退出读目录）——与 perform(.fileManager) 同规则
        if made.fileManagerFound {
            controller.registerFileManagerSession(made.pane, session)
        } else {
            FileManagerLaunch.cleanup(session)
        }
    }

    /// 造出来却没能落进布局（插入失败 / 同一批里别的 pane 建失败）：**当场收掉**。
    /// 终端靠放弃最后一份引用触发 `SurfaceView.deinit → ghostty_surface_free`；
    /// 浏览器 pane 要跑一次 `paneWillClose()`（取消下载、告诉扩展窗口关了）；
    /// 文件管理器要删掉那个 cwd 临时文件。漏掉任何一样都是一次静默泄漏
    static func discard(_ made: Made, controller: MainWindowController) {
        if let session = made.fileManagerSession { FileManagerLaunch.cleanup(session) }
        (made.pane as? BrowserPaneView)?.paneWillClose()
    }
}
