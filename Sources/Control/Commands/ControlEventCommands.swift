import AppKit

/// `events poll` / `events follow`。
///
/// **长轮询是主形式，流是次要的。** 一条永不结束的 NDJSON 流对模型来说是昂贵的东西：
/// 每一行都要进上下文，还得自己判断什么时候该停下来去干活。`poll --since <seq>` 则是一次
/// 普通的请求-应答，回答的正是 agent 真正想问的那句话——"我上次看过之后，都发生了什么"。
/// `follow` 留给人和 shell 脚本（`quickterm events follow | while read line; …`）。
///
/// ⚠️ 两条命令都是 `read` 类，因此**都要走与 `state` 完全相同的打码规则**：
/// 没有 token 的调用方读不到浏览器 pane 的标题。事件流要是漏掉这一条，
/// 它就成了一个绕过 `expose-browser` 的旁路——用 `pane.title.changed` 把用户正在看的网页
/// 一条条读出来，而 `state` 那边明明已经打了码。
@MainActor
extension ControlCommandRunner {
    func runEvents(_ ctx: ControlContext, completion: @escaping (ControlResponse) -> Void) throws {
        let bus = ControlEventBus.shared
        let exposes = ctx.encoder.exposesBrowser
        let types = try ControlEventLimits.parseTypes(ctx.string("types"))
        let limit = min(max(ctx.int("limit") ?? ControlEventLimits.maxBatch, 1),
                        ControlEventLimits.maxBatch)
        // `--since` 不写 = 从"此刻"开始：只等接下来发生的事。
        // 这是唯一不会骗人的默认值——回补一整个环意味着 agent 第一次调用就会收到
        // 一堆它根本没参与过的历史事件
        let since = ctx.int("since") ?? bus.seq
        guard since >= 0 else {
            throw ControlErrorBody(.badRequest, "--since 不能是负数（给了 \(since)）",
                                   hint: "第一次调用不写 --since 即可，或用 state 回的 seq")
        }

        let id = ctx.request.id
        switch ctx.spec.verb {
        case "poll":
            let timeout = try ControlEventLimits.parseTimeout(ctx.string("timeout"))
            bus.poll(since: since, limit: limit, types: types, exposesBrowser: exposes,
                     timeout: timeout) { payload in
                // 信封的 seq 是**全局状态计数器**（"我手里的快照过期了没有"），
                // 负载里的 `seq` 是**事件游标**（"下一次 --since 给谁"）。
                // 一批被 `--limit` 截断时两者会不一样，各说各的那件事，别混用
                completion(.success(id: id, seq: bus.seq, resolved: nil, data: payload))
            }

        case "follow":
            // 连接编号来自内核 accept 的那一刻（`ControlSocket.Peer`）：
            // 对端一走，`ControlServer` 会把这条流摘掉。**这是 follow 唯一的终止条件**
            let connection = ctx.peer.connectionID
            let ok = bus.follow(connection: connection, since: since, limit: limit, types: types,
                                exposesBrowser: exposes) { payload in
                completion(.success(id: id, seq: bus.seq, resolved: nil, data: payload))
            }
            guard ok else {
                throw ControlErrorBody(
                    .busy, "同时最多 \(ControlEventLimits.maxFollowers) 条 events follow（每条占住一条连接）",
                    hint: "改用 quickterm events poll --since <seq>：它是给 agent 的主形式",
                    retryAfterMs: 1000)
            }

        default:
            throw ControlErrorBody(.unknownCommand, "events 没有 \(ctx.spec.verb) 这个动词",
                                   candidates: ControlCommandTable.commands(inGroup: "events").map(\.verb))
        }
    }
}
