import CryptoKit
import Foundation

/// The control-plane environment variables injected into every new surface (kitty's
/// `KITTY_LISTEN_ON`, wezterm's `$WEZTERM_PANE` and iTerm2's `ITERM2_COOKIE` are the same
/// trick). This is the whole of the machinery behind "an agent inside a pane can drive its own
/// terminal with zero configuration".
///
/// ⚠️ `QUICKTERM_TOKEN` is **proof of origin, not a permission boundary**.
/// Environment variables are inherited by child processes and readable by any program running
/// as this user; the one question the token can answer is "this command came from a pane
/// QuickTerm opened".
/// Therefore: **no code anywhere may skip a confirmation because the token matched**.
/// The token does exactly two things: (a) it decides whether a browser pane's URL / title get
/// redacted; (b) it lets the consent alert say where the request came from.
/// There is exactly one identity check that cannot be worked around: the same-uid
/// `LOCAL_PEERCRED` verification done after accept.
///
/// ⚠️ `QUICKTERM_PANE_TOKEN` is **a different thing**; do not read the two as one.
/// It differs per pane (`HMAC(per-launch secret, paneID)`), so it answers the question
/// `QUICKTERM_TOKEN` never can: **"which pane did this command come from"**. Exactly one place
/// in the whole control plane uses it — `input send-text` skips the confirmation when it writes
/// into the caller's own pane (`ControlCommandRunner.writesIntoOwnPane`), on the grounds that
/// the tty already belongs to the calling process, which could write to it without going
/// through QuickTerm at all.
/// It is **not a permission boundary** either: holding it amounts to "I am inside this pane"
/// and nothing more.
enum ControlEnvironment {
    /// Regenerated on every launch (32 random bytes → hex)
    static let token: String = {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()

    /// The secret behind the per-pane origin marker (regenerated on every launch, **kept inside
    /// the process and never injected into any environment**).
    /// Derived rather than tabulated: panes get restored from the saved state, move between
    /// screens, and briefly leave the window hierarchy while SwiftUI rebuilds them — a table
    /// with a lifecycle to maintain would eventually miss one of those paths.
    /// `HMAC(secret, paneID)` has no lifecycle, so it has nothing to miss
    private static let paneSecret: SymmetricKey = {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return SymmetricKey(data: Data(bytes))
    }()

    /// This pane's origin marker. **Only a program running inside this pane (or in one of its
    /// child processes) can get hold of it** — another pane holds a different value, and the
    /// paneID itself is public (`state` hands it out), so all of the proof lives in this HMAC
    static func paneToken(for paneID: UUID) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(paneID.uuidString.utf8), using: paneSecret)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison (both sides are hex HMACs, so the length is fixed).
    /// `==` short-circuits on the first differing byte — not a real threat for a local
    /// comparison that can be retried at will, but a comparison whose timing depends on its
    /// input is the kind of bad template that eventually gets copied somewhere it does matter
    static func constantTimeEquals(_ a: String?, _ b: String) -> Bool {
        guard let a, a.utf8.count == b.utf8.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a.utf8, b.utf8) { diff |= x ^ y }
        return diff == 0
    }

    /// The socket path while the server is listening (not listening = nil, and then neither
    /// SOCKET nor TOKEN is injected)
    nonisolated(unsafe) static var socketPath: String?

    /// Merge the control-plane variables into the environment the caller handed us.
    /// - screen / workspace are the indices **at creation time** (hints): they are not updated
    ///   when the pane is moved later, so the authoritative reading of `@self` is always
    ///   `QUICKTERM_PANE` (a UUID, which travels with the pane).
    static func inject(into environment: [String: String], paneID: UUID,
                       screen: Int?, workspace: Int?) -> [String: String] {
        var out = environment
        out[ControlProtocol.Env.pane] = paneID.uuidString
        if let screen { out[ControlProtocol.Env.screen] = String(screen) }
        if let workspace { out[ControlProtocol.Env.workspace] = String(workspace) }
        if let socketPath {
            out[ControlProtocol.Env.socket] = socketPath
            out[ControlProtocol.Env.token] = token
            // One per pane, derived from the paneID (a restored pane still matches, precisely
            // because it is derived rather than looked up)
            out[ControlProtocol.Env.paneToken] = paneToken(for: paneID)
        }
        return out
    }
}
