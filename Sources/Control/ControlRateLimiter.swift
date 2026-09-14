import Foundation

/// Rate limiting for mutation commands (token bucket). **A pure value type with an injected
/// clock**, so tests can pin it down without a window.
///
/// Why the bucket on `ControlServer.Connection` is not enough on its own: the CLI opens **a new
/// connection per command** (`quickterm pane new` exits the moment it is done), so every command
/// gets a fresh full bucket — connection-level limiting does nothing about the most typical
/// runaway loop there is, "for i in {1..200}; do quickterm pane new; done".
/// So there is a second limit here, keyed by **origin**, plus a process-wide bucket on top of
/// that: the origin key is the caller's self-reported `QUICKTERM_PANE` when there is one (one
/// agent session is one pane), falling back to the pid the kernel reports. Both can be worked
/// around — rate limiting is not a security boundary. What it guards against is an agent
/// charging head-first into a retry loop, where all the user gets to see is an app that has
/// seized up and a state file thrashing, with nothing to explain either.
struct ControlRateLimiter {
    struct Limit: Equatable {
        /// Burst ceiling (the bucket's capacity)
        var capacity: Double
        /// Refill per second
        var perSecond: Double
    }

    /// Process-wide total: one layout change is one relayout plus one debounced save, and 20/s
    /// is already far past anything a pair of hands can do
    static let globalLimit = Limit(capacity: 40, perSecond: 20)
    /// A single origin (pane or pid)
    static let originLimit = Limit(capacity: 30, perSecond: 10)
    /// How many panes one workspace may hold (an agent will happily create 40)
    static let maxPanesPerWorkspace = 32

    /// **Reports** (`agent-event`): one bucket per proven pane, sized for `hook-detail = tools`
    /// — Claude Code runs tools in parallel, so a burst of a dozen hooks inside one second is
    /// normal — plus a global ceiling so ten busy panes cannot starve the main thread.
    ///
    /// Separate from `admit(origin:)` **by construction**: an agent's own `quickterm pane new`
    /// loop and its hooks must never share a bucket, or a chatty agent would rate-limit its own
    /// reports out of existence (and a report that is refused is lost for good — the hook exits 0
    /// and never retries).
    static let reportLimit = Limit(capacity: 60, perSecond: 20)
    static let reportGlobalLimit = Limit(capacity: 240, perSecond: 60)

    enum Verdict: Equatable {
        case allowed
        /// Over the limit: how long to wait before retrying (ms)
        case limited(retryAfterMs: Int, scope: String)
    }

    private struct Bucket {
        var tokens: Double
        var at: Date
    }

    private var global: Bucket
    private var origins: [String: Bucket] = [:]
    /// The second ledger: reports, keyed by the **proven** pane (plan §2.1).
    private var reportGlobal: Bucket
    private var reports: [UUID: Bucket] = [:]

    init(now: Date = Date()) {
        global = Bucket(tokens: Self.globalLimit.capacity, at: now)
        reportGlobal = Bucket(tokens: Self.reportGlobalLimit.capacity, at: now)
    }

    /// Take a token. **Only an actual admission spends one** — a refused request must not drain
    /// the bucket further with every refusal
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

    /// Take a token from the **report** ledger. The key is a pane id that has already been
    /// proven by its `QUICKTERM_PANE_TOKEN`, so one runaway pane cannot spend another's budget.
    mutating func admitReport(pane: UUID, now: Date = Date()) -> Verdict {
        var paneBucket = reports[pane] ?? Bucket(tokens: Self.reportLimit.capacity, at: now)
        Self.refill(&paneBucket, Self.reportLimit, now: now)
        Self.refill(&reportGlobal, Self.reportGlobalLimit, now: now)
        guard paneBucket.tokens >= 1 else {
            reports[pane] = paneBucket
            return .limited(retryAfterMs: Self.retryMs(paneBucket, Self.reportLimit), scope: "pane")
        }
        guard reportGlobal.tokens >= 1 else {
            reports[pane] = paneBucket
            return .limited(retryAfterMs: Self.retryMs(reportGlobal, Self.reportGlobalLimit),
                            scope: "global")
        }
        paneBucket.tokens -= 1
        reportGlobal.tokens -= 1
        reports[pane] = paneBucket
        return .allowed
    }

    /// Tests and config reloads only: wipe **both** ledgers
    mutating func reset(now: Date = Date()) {
        origins.removeAll()
        global = Bucket(tokens: Self.globalLimit.capacity, at: now)
        reports.removeAll()
        reportGlobal = Bucket(tokens: Self.reportGlobalLimit.capacity, at: now)
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
