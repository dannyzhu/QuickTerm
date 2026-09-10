import Foundation

/// 控制面线材（Phase 1）。**本目录（`Sources/Control/Wire`）同时编进 app 与 `quickterm` 工具 target，
/// 因此只能 `import Foundation`**——一旦引入 AppKit / GhosttyKit，CLI 就会背上整个引擎。
///
/// 协议：AF_UNIX / SOCK_STREAM 上的 NDJSON，一行一个 JSON 对象，`id` 关联请求与响应，
/// 连接可复用。绝不走转义序列通道，绝不监听 TCP。
enum ControlProtocol {
    /// 线协议版本。请求与响应都带 `v`；不匹配 → 退出码 8，并同时报出两边版本
    static let version = 1

    /// 注入每个新建 pane 的环境变量名（发现机制 = kitty 的 KITTY_LISTEN_ON / wezterm 的 WEZTERM_PANE）
    enum Env {
        static let socket = "QUICKTERM_SOCKET"
        static let pane = "QUICKTERM_PANE"
        static let screen = "QUICKTERM_SCREEN"
        static let workspace = "QUICKTERM_WORKSPACE"
        /// **来源证明，不是权限边界**。环境变量可继承、可读取，谁都能复制一份；
        /// 它只能回答"这条命令来自 QuickTerm 开的 pane"，绝不能用来跳过任何确认。
        /// 任何 `if token == expected { skipConsent() }` 的写法都是错的（见 ControlConsent）。
        static let token = "QUICKTERM_TOKEN"
    }
}

/// 退出码（`--help` 与 `describe` 都从这里生成；模型绝不该去 grep 文案）
enum ControlExit: Int32, Codable, CaseIterable {
    case ok = 0
    case failure = 1
    case notRunning = 2
    case badTarget = 3
    case confirmationRequired = 4
    case denied = 5
    case busy = 6
    case noop = 7
    case protocolMismatch = 8

    var summary: String {
        switch self {
        case .ok: "成功 / success"
        case .failure: "一般失败 / generic failure"
        case .notRunning: "QuickTerm 没在运行 / QuickTerm is not running"
        case .badTarget: "目标非法或有歧义（响应体列出候选）/ bad or ambiguous target"
        case .confirmationRequired: "需要用户确认 / confirmation required"
        case .denied: "被策略拒绝 / denied by policy"
        case .busy: "忙 / 限流（带 retryAfterMs）/ busy or rate-limited"
        case .noop: "什么都没改（仅 --fail-if-noop）/ no-op"
        case .protocolMismatch: "协议版本不匹配 / protocol version mismatch"
        }
    }
}

/// 稳定错误码。**新增只能追加**——agent 会按 `code` 分支，绝不按 message 分支
enum ControlErrorCode: String, Codable, CaseIterable {
    case failed = "failed"
    case badRequest = "bad_request"
    case protocolMismatch = "protocol_mismatch"
    case unknownCommand = "unknown_command"
    case unknownAction = "unknown_action"
    case badTarget = "bad_target"
    case ambiguousTarget = "ambiguous_target"
    case notFound = "not_found"
    case interactiveAction = "interactive_action"
    case wrongPaneKind = "wrong_pane_kind"
    case confirmationRequired = "confirmation_required"
    case denied = "denied"
    case busy = "busy"
    case rateLimited = "rate_limited"
    case notRunning = "not_running"
    case internalError = "internal_error"

    var exit: ControlExit {
        switch self {
        case .failed, .badRequest, .unknownCommand, .unknownAction, .internalError: .failure
        case .protocolMismatch: .protocolMismatch
        case .badTarget, .ambiguousTarget, .notFound, .wrongPaneKind: .badTarget
        case .interactiveAction, .denied: .denied
        case .confirmationRequired: .confirmationRequired
        case .busy, .rateLimited: .busy
        case .notRunning: .notRunning
        }
    }

    var summary: String {
        switch self {
        case .failed: "命令失败"
        case .badRequest: "请求格式错误"
        case .protocolMismatch: "协议版本不匹配"
        case .unknownCommand: "未知命令"
        case .unknownAction: "未知动作（quickterm action --list）"
        case .badTarget: "目标语法非法"
        case .ambiguousTarget: "目标匹配到多个（candidates 列出全部）"
        case .notFound: "目标不存在"
        case .interactiveAction: "该动作会打开需要键盘交互的面板，不能经 socket 执行"
        case .wrongPaneKind: "目标 pane 的种类不支持该动作"
        case .confirmationRequired: "需要在 QuickTerm 里确认"
        case .denied: "被 [control] 配置或用户拒绝"
        case .busy: "主线程忙（模态对话框 / 另一条命令在执行）"
        case .rateLimited: "超出速率上限"
        case .notRunning: "QuickTerm 没在运行"
        case .internalError: "内部错误"
        }
    }
}

struct ControlErrorBody: Codable, Equatable {
    var code: String
    var message: String
    var hint: String?
    /// 歧义目标时列出全部候选句柄——绝不"取第一个"
    var candidates: [String]?
    var retryAfterMs: Int?
    /// CLI 直接用它当进程退出码：两边不必各存一份映射表
    var exit: Int32

    init(_ code: ControlErrorCode, _ message: String, hint: String? = nil,
         candidates: [String]? = nil, retryAfterMs: Int? = nil) {
        self.code = code.rawValue
        self.message = message
        self.hint = hint
        self.candidates = candidates
        self.retryAfterMs = retryAfterMs
        self.exit = code.exit.rawValue
    }
}

/// 命令落到了哪里（每条响应都回显）：agent 不必再发一次查询就知道自己打中了哪块屏幕 / 哪个工作区
struct ResolvedTarget: Codable, Equatable {
    var screen: Int?
    var screenID: String?
    var workspace: Int?
    var pane: String?
    var paneID: String?
}

struct ControlRequestOrigin: Codable, Equatable {
    /// 调用进程所在 pane（读 `QUICKTERM_PANE`）——"当前"的第一优先解释
    var pane: String?
    var screen: Int?
    var workspace: Int?
    var pid: Int32?
}

struct ControlRequest: Codable {
    var v: Int = ControlProtocol.version
    var id: String
    var cmd: String
    var target: String?
    var args: [String: JSONValue] = [:]
    var token: String?
    var origin: ControlRequestOrigin?

    init(id: String, cmd: String, target: String? = nil, args: [String: JSONValue] = [:],
         token: String? = nil, origin: ControlRequestOrigin? = nil) {
        self.id = id
        self.cmd = cmd
        self.target = target
        self.args = args
        self.token = token
        self.origin = origin
    }
}

/// 类型擦除的可编码负载：dispatch 表要同构，而每条命令的 data 形状不同。
/// **不是**手拼 JSON——最终仍然全部走 JSONEncoder
struct AnyEncodablePayload: Encodable {
    private let wrapped: any Encodable
    init(_ wrapped: any Encodable) { self.wrapped = wrapped }
    func encode(to encoder: Encoder) throws { try wrapped.encode(to: encoder) }
}

/// 服务端写出的响应
struct ControlResponse: Encodable {
    var v: Int = ControlProtocol.version
    var id: String
    var ok: Bool
    /// 单调递增的状态序号：agent 用它判断手里的快照是否过期（每次成功的变更 +1）
    var seq: Int?
    var resolved: ResolvedTarget?
    var data: AnyEncodablePayload?
    var error: ControlErrorBody?

    static func success(id: String, seq: Int, resolved: ResolvedTarget?, data: (any Encodable)?) -> ControlResponse {
        ControlResponse(id: id, ok: true, seq: seq, resolved: resolved,
                        data: data.map(AnyEncodablePayload.init), error: nil)
    }

    static func failure(id: String, seq: Int?, resolved: ResolvedTarget? = nil,
                        error: ControlErrorBody) -> ControlResponse {
        ControlResponse(id: id, ok: false, seq: seq, resolved: resolved, data: nil, error: error)
    }
}

/// 客户端读到的响应（与 `ControlResponse` 同一线形状；`ControlWireTests` 钉死两者的键一致）
struct ControlReply: Decodable {
    var v: Int
    var id: String
    var ok: Bool
    var seq: Int?
    var resolved: ResolvedTarget?
    var data: JSONValue?
    var error: ControlErrorBody?
}

enum ControlJSON {
    /// 排序键 + 不转义斜杠：输出稳定（用例可比对），URL 不会变成 `https:\/\/`
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static var prettyEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return e
    }

    static var decoder: JSONDecoder { JSONDecoder() }

    /// 一行 NDJSON（保证不含裸换行：JSONEncoder 会把字符串里的换行转义）
    static func line(_ value: some Encodable) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}

/// socket 落点。`sun_path` 只有 104 字节：home 太长时回退到 $TMPDIR
enum ControlPaths {
    static let sunPathMax = 104

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickTerm", isDirectory: true)
    }

    static var preferredSocketPath: String {
        supportDirectory.appendingPathComponent("control.sock").path
    }

    static var fallbackSocketPath: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("quickterm.sock")
    }

    /// 路径能否装进 `sockaddr_un.sun_path`（含结尾的 NUL）
    static func fits(_ path: String) -> Bool {
        path.utf8.count + 1 <= sunPathMax
    }

    /// app 与 CLI 用同一个决议：首选 Application Support，装不下才回退
    static func resolvedSocketPath() -> String {
        let preferred = preferredSocketPath
        return fits(preferred) ? preferred : fallbackSocketPath
    }

    /// CLI 侧的查找顺序：环境变量（pane 内零配置）→ 决议路径 → 另一条路径
    static func clientSocketCandidates(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var out: [String] = []
        if let injected = environment[ControlProtocol.Env.socket], !injected.isEmpty { out.append(injected) }
        out.append(resolvedSocketPath())
        for candidate in [preferredSocketPath, fallbackSocketPath] where !out.contains(candidate) {
            out.append(candidate)
        }
        return out
    }
}
