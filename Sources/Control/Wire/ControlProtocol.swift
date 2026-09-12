import Foundation

/// Control-plane wire types (Phase 1). **This directory (`Sources/Control/Wire`) is compiled into
/// both the app and the `quickterm` tool target, so it may only `import Foundation`** — the moment
/// AppKit or GhosttyKit gets pulled in, the CLI carries the whole engine on its back.
///
/// The protocol: NDJSON over AF_UNIX / SOCK_STREAM, one JSON object per line, `id` correlates
/// request with response, connections are reusable. Never an escape-sequence side channel, and
/// never a TCP listener.
enum ControlProtocol {
    /// Wire protocol version. Both request and response carry `v`; a mismatch exits with code 8 and
    /// reports both sides' versions.
    static let version = 1

    /// Names of the environment variables injected into every new pane (the discovery mechanism,
    /// the same idea as kitty's KITTY_LISTEN_ON or wezterm's WEZTERM_PANE).
    enum Env {
        static let socket = "QUICKTERM_SOCKET"
        static let pane = "QUICKTERM_PANE"
        static let screen = "QUICKTERM_SCREEN"
        static let workspace = "QUICKTERM_WORKSPACE"
        /// **Proof of origin, not a permission boundary.** Environment variables are inherited and
        /// readable, so anyone can copy one; all this can answer is "the command came from a pane
        /// QuickTerm opened", and it must never be used to skip a confirmation. Any
        /// `if token == expected { skipConsent() }` is wrong (see ControlConsent).
        static let token = "QUICKTERM_TOKEN"
        /// **Different for every pane** (`HMAC(per-launch secret, paneID)`), so it proves exactly
        /// the thing `QUICKTERM_TOKEN` cannot: **which** pane the command came from. The whole
        /// control plane uses it in one place — `input send-text` skips the confirmation when the
        /// caller is writing into its own pane. It is not a permission boundary either: holding it
        /// only means "I am inside this pane".
        static let paneToken = "QUICKTERM_PANE_TOKEN"
    }
}

/// Exit codes (both `--help` and `describe` are generated from here; a model should never have to
/// grep the prose).
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
        case .ok: "success"
        case .failure: "generic failure"
        case .notRunning: "QuickTerm is not running"
        case .badTarget: "bad or ambiguous target (the response body lists the candidates)"
        case .confirmationRequired: "confirmation required"
        case .denied: "denied by policy"
        case .busy: "busy or rate-limited (carries retryAfterMs)"
        case .noop: "nothing changed, a no-op (only with --fail-if-noop)"
        case .protocolMismatch: "protocol version mismatch"
        }
    }
}

/// Stable error codes. **New ones may only be appended** — agents branch on `code`, never on the
/// message.
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
    /// Already in the requested state, nothing changed (**an error only under `--fail-if-noop`**).
    /// The price of absolute set-value semantics is that the second call does nothing, and an agent
    /// needs a signal that tells it so.
    case noop = "noop"
    /// `spec apply` failed halfway through: the workspace **has already been modified** (the old
    /// panes are closed, the new layout never landed). It gets its own code because "nothing
    /// happened" and "half of it happened" demand completely different things from an agent, and it
    /// must never have to tell them apart by reading the error prose.
    case partialApply = "partial_apply"

    var exit: ControlExit {
        switch self {
        case .failed, .badRequest, .unknownCommand, .unknownAction, .internalError, .partialApply: .failure
        case .protocolMismatch: .protocolMismatch
        case .badTarget, .ambiguousTarget, .notFound, .wrongPaneKind: .badTarget
        case .interactiveAction, .denied: .denied
        case .confirmationRequired: .confirmationRequired
        case .busy, .rateLimited: .busy
        case .notRunning: .notRunning
        case .noop: .noop
        }
    }

    var summary: String {
        switch self {
        case .failed: "the command failed"
        case .badRequest: "malformed request"
        case .protocolMismatch: "protocol version mismatch"
        case .unknownCommand: "unknown command"
        case .unknownAction: "unknown action (quickterm action --list)"
        case .badTarget: "bad target syntax"
        case .ambiguousTarget: "the target matched more than one (candidates lists them all)"
        case .notFound: "the target does not exist"
        case .interactiveAction: "this action opens a panel that needs keyboard interaction, so it cannot run over the socket"
        case .wrongPaneKind: "the target pane's kind does not support this action"
        case .confirmationRequired: "needs confirmation inside QuickTerm"
        case .denied: "refused by the [control] config or by the user"
        case .busy: "the main thread is busy (a modal dialog, or another command is running)"
        case .rateLimited: "over the rate limit"
        case .notRunning: "QuickTerm is not running"
        case .internalError: "internal error"
        case .noop: "already in the target state, nothing changed (an error only with --fail-if-noop)"
        case .partialApply: "spec was only half applied: the workspace has already changed, read the state again"
        }
    }
}

struct ControlErrorBody: Codable, Equatable {
    var code: String
    var message: String
    var hint: String?
    /// On an ambiguous target, lists every candidate handle — never "just take the first one".
    var candidates: [String]?
    var retryAfterMs: Int?
    /// The CLI uses this directly as its process exit code, so neither side has to keep its own
    /// copy of the mapping table.
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

/// The on-the-wire error body is also a throwable error: code in the Wire layer itself
/// (`SpecParser` and friends) needs to `throw ControlErrorBody(...)` directly, so both sides share
/// one set of error codes and one exit mapping.
extension ControlErrorBody: Error {}

/// Where the command actually landed, echoed back on every response: an agent learns which screen
/// and which workspace it hit without having to issue a second query.
struct ResolvedTarget: Codable, Equatable {
    var screen: Int?
    var screenID: String?
    var workspace: Int?
    var pane: String?
    var paneID: String?
}

struct ControlRequestOrigin: Codable, Equatable {
    /// The pane the calling process sits in (read from `QUICKTERM_PANE`) — the first-choice reading
    /// of "current".
    /// **This is self-reported by the caller and the server can verify none of it**: it is only
    /// used to resolve relative forms like `@self`, to bucket rate limiting, and to write a "claims
    /// to come from" line into the confirmation dialog. No security decision may rest on it alone.
    var pane: String?
    var screen: Int?
    var workspace: Int?
    var pid: Int32?
    /// `QUICKTERM_PANE_TOKEN`: a **verifiable** proof of origin, one per pane.
    /// The server recomputes the HMAC from the target pane's id and compares, so what it proves is
    /// that the calling process really is running inside that pane (or in a child of it).
    var paneToken: String?
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

/// A type-erased encodable payload: the dispatch table has to be homogeneous while every command's
/// `data` has a different shape. This is **not** hand-assembled JSON — it all still goes through
/// JSONEncoder in the end.
struct AnyEncodablePayload: Encodable {
    private let wrapped: any Encodable
    init(_ wrapped: any Encodable) { self.wrapped = wrapped }
    func encode(to encoder: Encoder) throws { try wrapped.encode(to: encoder) }
}

/// The response the server writes out.
struct ControlResponse: Encodable {
    var v: Int = ControlProtocol.version
    var id: String
    var ok: Bool
    /// Monotonically increasing state sequence number: an agent uses it to tell whether the
    /// snapshot it holds is stale (+1 on every successful mutation).
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

/// The response as the client reads it (the same wire shape as `ControlResponse`;
/// `ControlWireTests` pins the two key sets to each other).
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
    /// Sorted keys plus unescaped slashes: stable output (test cases can diff it) and URLs do not
    /// come out as `https:\/\/`.
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

    /// One NDJSON line (guaranteed free of bare newlines: JSONEncoder escapes newlines inside
    /// strings).
    static func line(_ value: some Encodable) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}

/// Where the socket lands. `sun_path` is only 104 bytes, so when home is too long we fall back to
/// $TMPDIR.
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

    /// Whether the path fits in `sockaddr_un.sun_path` (including the terminating NUL).
    static func fits(_ path: String) -> Bool {
        path.utf8.count + 1 <= sunPathMax
    }

    /// The app and the CLI resolve this the same way: Application Support first, fall back only
    /// when it does not fit.
    static func resolvedSocketPath() -> String {
        let preferred = preferredSocketPath
        return fits(preferred) ? preferred : fallbackSocketPath
    }

    /// Lookup order on the CLI side: the environment variable (zero config inside a pane) -> the
    /// resolved path -> the other path.
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
