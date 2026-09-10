import CryptoKit
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
///
/// ⚠️ `QUICKTERM_PANE_TOKEN` 是**另一回事**，别把两者混起来读。
/// 它每个 pane 各不相同（`HMAC(每次启动的密钥, paneID)`），因此能回答 `QUICKTERM_TOKEN`
/// 永远答不了的那个问题：**"这条命令来自哪一个 pane"**。整个控制面里只有一处用它——
/// `input send-text` 写调用方自己那个 pane 时免确认（`ControlCommandRunner.writesIntoOwnPane`），
/// 理由是那个 tty 本来就是调用进程自己的，它不经过 QuickTerm 也能往上写。
/// 它同样**不是权限边界**：拿到它只等于"我在这个 pane 里"，别的什么都不代表。
enum ControlEnvironment {
    /// 每次启动重新生成（32 字节随机 → hex）
    static let token: String = {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()

    /// 每 pane 一枚的来源标记所用的密钥（每次启动重新生成，**只留在进程里，从不注入任何环境**）。
    /// 派生而不是建表：pane 从存档里复原、跨屏移动、SwiftUI 重建期间短暂脱离窗口，
    /// 一张需要维护生命周期的表在这些路径上迟早会漏一处；
    /// `HMAC(secret, paneID)` 没有生命周期，也就没有能漏的地方
    private static let paneSecret: SymmetricKey = {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return SymmetricKey(data: Data(bytes))
    }()

    /// 这个 pane 的来源标记。**只有跑在这个 pane 里（或它的子进程里）的程序才拿得到**——
    /// 别的 pane 手里的那一枚是另一个值，而 paneID 本身是公开的（`state` 里就有），
    /// 所以证明力全部来自这个 HMAC
    static func paneToken(for paneID: UUID) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(paneID.uuidString.utf8), using: paneSecret)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// 定长比较（两串都是十六进制 HMAC，长度固定）。
    /// `==` 会在第一个不同的字节上短路——对一个本地的、可以随便重试的比较来说这不是现实威胁，
    /// 但安全判定里写一个会因输入而改变耗时的比较，是一种迟早会被抄去别处的坏样板
    static func constantTimeEquals(_ a: String?, _ b: String) -> Bool {
        guard let a, a.utf8.count == b.utf8.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a.utf8, b.utf8) { diff |= x ^ y }
        return diff == 0
    }

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
            // 每 pane 一枚，跟着 paneID 走（复原出来的 pane 也对得上，因为它是派生的）
            out[ControlProtocol.Env.paneToken] = paneToken(for: paneID)
        }
        return out
    }
}
