import AppKit

/// `events poll` / `events follow`.
///
/// **Long polling is the primary form, streaming is the secondary one.** A never-ending NDJSON
/// stream is an expensive thing for a model: every line lands in the context, and it has to work
/// out for itself when to stop reading and go do the work. `poll --since <seq>` is an ordinary
/// request-response instead, and it answers the question an agent actually wants to ask - "what
/// has happened since the last time I looked". `follow` is there for humans and shell scripts
/// (`quickterm events follow | while read line; ...`).
///
/// ⚠️ Both commands are `read` class, so **both go through exactly the same redaction rules
/// as `state`**: a caller without a token cannot read the titles of browser panes. If the event
/// stream skipped that, it would become a side channel around `expose-browser` - read out the web
/// pages the user is looking at one `pane.title.changed` at a time, while `state` is dutifully
/// redacting them.
@MainActor
extension ControlCommandRunner {
    func runEvents(_ ctx: ControlContext, completion: @escaping (ControlResponse) -> Void) throws {
        let bus = ControlEventBus.shared
        let exposes = ctx.encoder.exposesBrowser
        let types = try ControlEventLimits.parseTypes(ctx.string("types"))
        let limit = min(max(ctx.int("limit") ?? ControlEventLimits.maxBatch, 1),
                        ControlEventLimits.maxBatch)
        // No `--since` = start from "right now": wait only for what happens next. That is the one
        // default that does not lie - backfilling the whole ring would mean an agent's very first
        // call hands it a pile of historical events it had nothing to do with.
        let since = ctx.int("since") ?? bus.seq
        guard since >= 0 else {
            throw ControlErrorBody(.badRequest, "--since cannot be negative (got \(since))",
                                   hint: "Leave --since out on the first call, or pass the seq "
                                       + "that state returned.")
        }

        let id = ctx.request.id
        switch ctx.spec.verb {
        case "poll":
            let timeout = try ControlEventLimits.parseTimeout(ctx.string("timeout"))
            bus.poll(since: since, limit: limit, types: types, exposesBrowser: exposes,
                     timeout: timeout) { payload in
                // The envelope's seq is the **global state counter** ("is the snapshot I hold
                // stale"), while the `seq` inside the payload is the **event cursor** ("what to
                // pass as --since next time"). When a batch is truncated by `--limit` the two
                // differ; each answers its own question, so do not mix them up.
                completion(.success(id: id, seq: bus.seq, resolved: nil, data: payload))
            }

        case "follow":
            // The connection id comes from the moment the kernel accepted the socket
            // (`ControlSocket.Peer`): as soon as the peer goes away, `ControlServer` tears this
            // stream down. **That is the only termination condition follow has.**
            let connection = ctx.peer.connectionID
            let ok = bus.follow(connection: connection, since: since, limit: limit, types: types,
                                exposesBrowser: exposes) { payload in
                completion(.success(id: id, seq: bus.seq, resolved: nil, data: payload))
            }
            guard ok else {
                throw ControlErrorBody(
                    .busy, "At most \(ControlEventLimits.maxFollowers) events follow streams "
                        + "at once (each one holds a connection open)",
                    hint: "Use quickterm events poll --since <seq> instead: that is the primary "
                        + "form for agents.",
                    retryAfterMs: 1000)
            }

        default:
            throw ControlErrorBody(.unknownCommand, "events has no verb \(ctx.spec.verb)",
                                   candidates: ControlCommandTable.commands(inGroup: "events").map(\.verb))
        }
    }
}
