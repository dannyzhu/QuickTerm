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

    init(now: Date = Date()) {
        global = Bucket(tokens: Self.globalLimit.capacity, at: now)
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

    /// Tests and config reloads only: wipe the ledger
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
