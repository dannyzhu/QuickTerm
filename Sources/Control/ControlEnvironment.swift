import Foundation

/// 注入每个新建 surface 的控制面环境变量（kitty 的 `KITTY_LISTEN_ON` / wezterm 的 `$WEZTERM_PANE`
/// / iTerm2 的 `ITERM2_COOKIE` 是同一招）。这是"pane 里的 agent 零配置就能驱动自己这台终端"的全部机关。
///
/// ⚠️ `QUICKTERM_TOKEN` 是**来源证明，不是权限边界**。
/// 环境变量会被子进程继承、能被任何以本用户身份运行的程序读到；它唯一能回答的问题是
/// "这条命令来自 QuickTerm 开出来的 pane"。
/// 因此：**没有任何一处代码可以因为 token 匹配就跳过确认**。
/// token 只做两件事：(a) 决定浏览器 pane 的 URL / 标题是否打码；(b) 让确认框能说清来源。
/// 真正不可绕过的身份检查只有一条：accept 之后的 `LOCAL_PEERCRED` 同 uid 校验。
enum ControlEnvironment {
    /// 每次启动重新生成（32 字节随机 → hex）
    static let token: String = {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()

    /// 服务在监听时的 socket 路径（没监听 = nil，此时不注入 SOCKET / TOKEN）
    nonisolated(unsafe) static var socketPath: String?

    /// 把控制面变量并进调用方给的环境。
    /// - screen / workspace 是**创建时**的序号（提示值）：pane 之后被移走也不会更新，
    ///   所以 `@self` 的权威解释永远是 `QUICKTERM_PANE`（UUID，跟着 pane 走）。
    static func inject(into environment: [String: String], paneID: UUID,
                       screen: Int?, workspace: Int?) -> [String: String] {
        var out = environment
        out[ControlProtocol.Env.pane] = paneID.uuidString
        if let screen { out[ControlProtocol.Env.screen] = String(screen) }
        if let workspace { out[ControlProtocol.Env.workspace] = String(workspace) }
        if let socketPath {
            out[ControlProtocol.Env.socket] = socketPath
            out[ControlProtocol.Env.token] = token
        }
        return out
    }
}
