import Darwin
import Foundation

/// `quickterm agent-event --agent <id>` — **the one command that never fails** (plan §2.2).
///
/// It is run by the hook script QuickTerm installs, once per lifecycle event, in the middle of
/// somebody's agent turn. Two rules follow from that and shape every line below:
///
/// - **It never blocks the agent.** Stdin is read to a hard cap and no further: a payload larger
///   than `AgentEventPayload.maxStdinBytes` is *cut*, never waited for. The writer on the other
///   end may well get EPIPE for the rest, which is exactly the intended bargain.
/// - **It never exits non-zero and never writes a byte.** Not running, protocol mismatch, refused,
///   rate limited, a socket that vanished mid-write: every one of them is `exit(0)` with empty
///   stdout and empty stderr. Exit 2 (`not_running`) is a *verdict* to an agent — Claude Code
///   surfaces a failing hook to the model — and a QuickTerm that happens to be closed must not
///   turn into a line of noise inside somebody's conversation.
///
/// That is also why this does not go through `run(_:)` / `send(_:over:)`: those two end in
/// `emit` / `fail`, which print and set an exit code. The request built here is the same request
/// they build (same token, same origin from the environment); only the ending differs.
enum AgentEvent {
    /// The whole command. Called from `run(_:)` before anything can connect or print.
    static func run(_ parsed: ParsedCommand) -> Never {
        let data: Data
        if let given = parsed.args["event"]?.stringValue, !given.isEmpty {
            // `--event` written out by hand (the help says it is for tests). It is reduced here
            // exactly like stdin would be, and reduced again by the server, so writing it by hand
            // buys nothing a real hook does not already have.
            data = Data(given.utf8)
        } else if isatty(STDIN_FILENO) == 1 {
            // A person typing this at a prompt, with nothing piped in. A hook's stdin is never a
            // terminal, so there is no payload coming — and waiting for one would look exactly
            // like the freeze this command exists not to cause.
            exit(0)
        } else {
            data = readStdin()
        }
        // The first of the two reductions (the server runs the same function again on what it
        // receives). nil = there is nothing usable in these bytes — an empty stdin, a payload cut
        // mid-string by the cap, a hook that sent something other than an object. Drop it: an
        // event we cannot name is an event no rule file can map.
        guard let payload = AgentEventPayload.reduce(data),
              let encoded = try? ControlJSON.encoder.encode(payload),
              let json = String(data: encoded, encoding: .utf8) else { exit(0) }

        var args = parsed.args
        args["event"] = .string(json)

        // **No `--start`.** A hook must never launch the application: an agent running in
        // Terminal.app with QuickTerm closed would otherwise put a window on the user's screen
        // because it called a tool.
        var candidates = ControlPaths.clientSocketCandidates()
        if let override = parsed.socketOverride { candidates = [override] }
        guard let client = try? ControlClient.connect(candidates: candidates) else { exit(0) }

        let environment = ProcessInfo.processInfo.environment
        let request = ControlRequest(
            id: "1",
            cmd: parsed.spec.name,
            target: nil,                       // a report is about the caller's own pane; there is no target
            args: args,
            token: environment[ControlProtocol.Env.token],
            origin: ControlRequestOrigin(
                pane: environment[ControlProtocol.Env.pane],
                screen: environment[ControlProtocol.Env.screen].flatMap(Int.init),
                workspace: environment[ControlProtocol.Env.workspace].flatMap(Int.init),
                pid: getpid(),
                // The verifiable half: the server recomputes this HMAC from the pane id above.
                // Only a process running inside that pane can have inherited it.
                paneToken: environment[ControlProtocol.Env.paneToken]))

        // The reply is read and thrown away. Reading it (rather than writing and exiting at once)
        // is what guarantees the server has taken the line off the socket before this process
        // goes away; what it *says* is of no interest to a hook, which has nobody to tell.
        _ = try? client.send(request)
        client.close()
        exit(0)
    }

    /// Stdin, to the cap, without ever blocking on more.
    ///
    /// The loop exists because a pipe hands over whatever it has: one `read(upToCount:)` can
    /// return 300 bytes of a 3 KB payload that the agent is still writing, and a JSON object cut
    /// at 300 bytes parses as nothing. It reads until EOF **or** the cap, and the cap is the
    /// promise that a runaway `tool_input` (a `Write` of a megabyte file) costs this process one
    /// buffer and not one second.
    private static func readStdin() -> Data {
        var out = Data()
        let handle = FileHandle.standardInput
        while out.count < AgentEventPayload.maxStdinBytes {
            let want = AgentEventPayload.maxStdinBytes - out.count
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            out.append(chunk)
        }
        return out
    }
}
