import Foundation

/// 变更命令的限流（令牌桶）。**纯值类型 + 注入时钟**，所以能在没有窗口的用例层把它钉死。
///
/// 为什么不能只靠 `ControlServer.Connection` 上那只桶：CLI **每条命令开一条新连接**
/// （`quickterm pane new` 跑完就退出），于是每次都拿到一只满桶——连接级限流对
/// "for i in {1..200}; do quickterm pane new; done" 这种最典型的失控循环完全无效。
/// 所以这里按**来源**再限一次，并且再加一只全进程的总桶：
/// 来源标识优先用调用方自报的 `QUICKTERM_PANE`（同一个 agent 会话就是同一个 pane），
/// 拿不到就退回内核给的 pid。两者都可以被绕开——限流不是安全边界，
/// 它防的是"agent 一头撞进重试循环"，那时用户看到的只是应用卡住、存档抖动，毫无线索。
struct ControlRateLimiter {
    struct Limit: Equatable {
        /// 突发上限（桶容量）
        var capacity: Double
        /// 每秒回填
        var perSecond: Double
    }

    /// 全进程总量：一次布局变更就是一次重排 + 一次防抖存档，20/s 已经远超人手速度
    static let globalLimit = Limit(capacity: 40, perSecond: 20)
    /// 单一来源（pane 或 pid）
    static let originLimit = Limit(capacity: 30, perSecond: 10)
    /// 一个工作区里最多几个 pane（agent 会很开心地建 40 个）
    static let maxPanesPerWorkspace = 32

    enum Verdict: Equatable {
        case allowed
        /// 超了：多久之后再试（ms）
        case limited(retryAfterMs: Int, scope: String)
    }

    private struct Bucket {
        var tokens: Double
        var at: Date
    }

    private var global: Bucket
    private var origins: [String: Bucket] = [:]

    init(now: Date = Date()) {
        global = Bucket(tokens: Self.globalLimit.capacity, at: now)
    }

    /// 取一个令牌。**只有真的放行才扣**——被拒的请求不该把桶越拒越空
    mutating func admit(origin: String, now: Date = Date()) -> Verdict {
        var originBucket = origins[origin] ?? Bucket(tokens: Self.originLimit.capacity, at: now)
        Self.refill(&originBucket, Self.originLimit, now: now)
        Self.refill(&global, Self.globalLimit, now: now)
        guard originBucket.tokens >= 1 else {
            origins[origin] = originBucket
            return .limited(retryAfterMs: Self.retryMs(originBucket, Self.originLimit), scope: "origin")
        }
        guard global.tokens >= 1 else {
            origins[origin] = originBucket
            return .limited(retryAfterMs: Self.retryMs(global, Self.globalLimit), scope: "global")
        }
        originBucket.tokens -= 1
        global.tokens -= 1
        origins[origin] = originBucket
        return .allowed
    }

    /// 只给用例 / 配置重载：清空账本
    mutating func reset(now: Date = Date()) {
        origins.removeAll()
        global = Bucket(tokens: Self.globalLimit.capacity, at: now)
    }

    private static func refill(_ bucket: inout Bucket, _ limit: Limit, now: Date) {
        let elapsed = max(0, now.timeIntervalSince(bucket.at))
        bucket.tokens = min(limit.capacity, bucket.tokens + elapsed * limit.perSecond)
        bucket.at = now
    }

    private static func retryMs(_ bucket: Bucket, _ limit: Limit) -> Int {
        let needed = max(0, 1 - bucket.tokens)
        return max(50, Int((needed / limit.perSecond) * 1000) + 50)
    }
}
