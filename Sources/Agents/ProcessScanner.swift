import AppKit
import Darwin
import Foundation

/// **One pass over QuickTerm's own descendants** (plan §2.7, spec §2.3).
///
/// A value, not an object: no actor, no stored state, nothing but the three readings it makes of
/// the world — so a case can hand it a synthetic process tree and read the answer on the next
/// line, and so the rules below are enforced here rather than trusted to a caller.
///
/// Three rules carry the privacy promise the README makes:
/// 1. **Descendants only.** The walk starts at QuickTerm's own pid and follows
///    `proc_listchildpids`; a process that is not ours is never even named.
/// 2. **Named processes only.** Of those descendants, the argument buffer is read *only* for a
///    process whose executable basename a loaded rule file lists. This is the rule that matters:
///    `KERN_PROCARGS2` hands over another program's whole environment, which is where its secrets
///    live, and the basename test costs one `proc_pidpath` and keeps us out of every buffer we
///    have no business in.
/// 3. **Nothing is kept.** A pass yields `(pid, name, pane)` per match. The buffer is released
///    before the next pid is looked at, and nothing else from it is ever copied out.
///
/// What the scan can and cannot see is a fact about macOS, not a choice (spec §2.3): the
/// environment of an Apple *platform* binary — `login`, `zsh`, `/bin/sleep` — is hidden from every
/// other process, its own parent included, so the scan never finds the pane's own shell. It finds
/// an agent, which is a non-platform binary (`node`, or Codex's own), carrying our marker.
struct ProcessScan {
    /// The three readings, each replaceable so that a case can describe a process tree that does
    /// not exist rather than the one the developer happens to be running.
    typealias ChildLister = @Sendable (pid_t) -> [pid_t]
    typealias NameReader = @Sendable (pid_t) -> String?
    typealias ArgumentReader = @Sendable (pid_t) -> Data?

    /// A process we were allowed to look at, and the one thing it told us.
    struct Match: Equatable {
        var pid: pid_t
        /// The executable basename, which is also the reason we read it at all.
        var name: String
        var pane: UUID
    }

    struct Result: Equatable {
        var matches: [Match] = []
        /// What was found in each pane, **per rule** — exactly what `PaneSignal.processes` carries.
        /// The name match below is the attribution: nothing downstream has to guess whose a
        /// process was, which is what keeps two agents in one pane two separate presences.
        var byPane: [UUID: AgentPresence] = [:]
    }

    /// A tree deeper than this is a runaway, not an agent: `shell → agent → tool → helper` is four.
    /// The bound is what stops a cycle or a fork bomb from turning one scan into a hang.
    static let maxDepth = 16

    /// Where the walk starts. QuickTerm's own pid in the app; a synthetic root in a case.
    var root: pid_t
    /// Executable basename → the ids of the **enabled** rules that name it. Two things in one
    /// map, because they are one question: whether a process is worth looking at, and whose it is
    /// if it is. Empty means there is nothing to look for, and then the walk does not happen at
    /// all.
    var rulesByName: [String: Set<String>]
    var listChildren: ChildLister
    var readName: NameReader
    var readArguments: ArgumentReader

    // MARK: The walk

    func run() -> Result {
        var result = Result()
        // No rules, no reason to touch the process table.
        guard !rulesByName.isEmpty else { return result }

        var visited: Set<pid_t> = [root]
        var frontier: [pid_t] = [root]
        var depth = 0
        while !frontier.isEmpty, depth < Self.maxDepth {
            var next: [pid_t] = []
            for parent in frontier {
                for child in listChildren(parent) where child > 0 && !visited.contains(child) {
                    visited.insert(child)
                    next.append(child)
                    inspect(child, into: &result)
                }
            }
            frontier = next
            depth += 1
        }
        return result
    }

    /// The name test comes first and the buffer second, always — reversing these two lines is the
    /// one change in this file that would break the promise in the README.
    private func inspect(_ pid: pid_t, into result: inout Result) {
        guard let name = readName(pid), let owners = rulesByName[name] else { return }
        // The buffer lives exactly as long as this statement: it is the only place in QuickTerm
        // that has ever held another program's environment, and it is gone before the next pid.
        guard let pane = readArguments(pid).flatMap(Self.paneMarker(in:)) else { return }
        result.matches.append(Match(pid: pid, name: name, pane: pane))
        result.byPane[pane, default: .empty].add(pid: pid, rules: owners)
    }

    // MARK: The marker

    /// `QUICKTERM_PANE=<uuid>` out of a `KERN_PROCARGS2` buffer, or nil.
    ///
    /// The buffer is `argc`, the executable path, NUL padding, `argc` arguments, then the
    /// environment. We walk past the arguments rather than searching the whole blob because an
    /// argument that *looks* like our marker (`env QUICKTERM_PANE=… some-command`) is a claim
    /// about a command line, not about the pane a process is running in.
    static func paneMarker(in buffer: Data) -> UUID? {
        let bytes = [UInt8](buffer)
        let header = MemoryLayout<Int32>.size
        guard bytes.count > header else { return nil }

        var argc = Int32(0)
        withUnsafeMutableBytes(of: &argc) { destination in
            for offset in 0..<header { destination[offset] = bytes[offset] }
        }

        var index = header
        // The executable path, then the NULs that pad it out to a word boundary.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        // argv.
        var remaining = max(0, Int(argc))
        while remaining > 0, index < bytes.count {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
            remaining -= 1
        }

        let key = Array("\(ControlProtocol.Env.pane)=".utf8)
        while index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            if index - start > key.count, Array(bytes[start..<(start + key.count)]) == key,
               let text = String(bytes: bytes[(start + key.count)..<index], encoding: .utf8),
               let pane = UUID(uuidString: text) {
                return pane
            }
            index += 1
        }
        return nil
    }

    // MARK: The real readings

    /// Every child of `pid`. Public API (`libproc.h`) and readable for any process of the same
    /// user; it answers pids and nothing else.
    /// Two things measured here rather than assumed, because the man page says neither and getting
    /// either wrong makes the scan silently blind:
    /// - the return value is a **count of pids**, not a byte count (macOS 26.7);
    /// - the usual "pass NULL to learn the size" form answers a number that has nothing to do with
    ///   this pid at all, so the buffer is sized generously and grown only when it comes back full.
    ///
    /// Reading the answer as a count is also the safe way round: were some future release to return
    /// bytes, this would look at four times as many slots, and the spare ones are zeros that the
    /// filter drops. The other way round loses every child.
    static func children(of pid: pid_t) -> [pid_t] {
        var capacity = 256
        var found: [pid_t] = []
        for attempt in 0..<3 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = Int(proc_listchildpids(pid, &pids,
                                               Int32(capacity * MemoryLayout<pid_t>.size)))
            guard count > 0 else { return [] }
            found = pids.prefix(min(count, capacity)).filter { $0 > 0 }
            // A full buffer may have been truncated; anything else is the whole answer.
            if count < capacity || attempt == 2 { break }
            capacity *= 8
        }
        return found
    }

    /// The executable's basename. The cheap reading that keeps `argumentBuffer` away from
    /// everything that is not an agent.
    static func executableName(of pid: pid_t) -> String? {
        // `PROC_PIDPATHINFO_MAXSIZE` is a macro (`4 * MAXPATHLEN`) that Swift does not import.
        var buffer = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
        let read = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard read > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : (path as NSString).lastPathComponent
    }

    /// `sysctl KERN_PROCARGS2` — what `ps -E` reads. nil for a platform binary (macOS hides its
    /// environment from everyone) and for a pid that is already gone.
    static func argumentBuffer(of pid: pid_t) -> Data? {
        var size = argMax
        guard size > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 0 else { return nil }
        return Data(buffer.prefix(size))
    }

    /// `kern.argmax`, read once: the largest a `KERN_PROCARGS2` answer can be.
    private static let argMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 0 }
        return Int(value)
    }()
}

/// **Who is running in which pane, when no hook has said so** (plan §2.7).
///
/// libghostty exposes no pid and no pty for a surface, so presence is answered the only way left:
/// every pane's shell is spawned with `QUICKTERM_PANE`, and an agent started inside it inherits
/// that marker. The scanner walks QuickTerm's own descendants, and hands the registry one
/// `PaneSignal.processes` per pane — pids per rule, never a state. Presence says "an agent is
/// there" and "an agent is gone"; what it is *doing* only a hook can say.
///
/// This is the weakest of the four evidences on purpose (§2.4 rule 3): it can create an `unknown`
/// status where nothing is known, and it can release one it had seen, and it can never contradict
/// a hook.
@MainActor
final class ProcessScanner {
    static let shared = ProcessScanner()

    /// At most one pass per this long, whatever asks. A hook-heavy turn under
    /// `hook-detail = "tools"` asks on every tool call; the walk costs a `proc_listchildpids` per
    /// node and a sysctl per agent, and doing that at hook rate would be absurd.
    static let coalescingWindow: TimeInterval = 0.25

    /// The presence heartbeat. **Owner decision Q7: it runs always**, not only while the app is
    /// active — losing presence is how a pending approval gets resolved as `agent-gone`, and the
    /// user being in another app is exactly when that matters. The cost is one walk every 5s.
    static let heartbeatInterval: TimeInterval = 5

    // MARK: Seams (the app uses the defaults; cases replace them)

    var listChildren: ProcessScan.ChildLister = { ProcessScan.children(of: $0) }
    var readName: ProcessScan.NameReader = { ProcessScan.executableName(of: $0) }
    var readArguments: ProcessScan.ArgumentReader = { ProcessScan.argumentBuffer(of: $0) }
    /// Where the walk starts. `getpid()` in the app; a synthetic root in a case.
    var root: pid_t = getpid()
    var clock: () -> Date = Date.init

    /// **The one test seam that changes timing.** With it set, a pass runs on the calling thread
    /// instead of the scan queue, and a coalesced request arms no timer — it writes the delay it
    /// worked out to `deferrals` and waits for `firePendingScan()`. That makes "one pass per
    /// 250 ms" a claim a case can make in microseconds rather than sleep for, and it keeps the
    /// app's own path (off the main thread, back on the main actor) the only one the app runs.
    var synchronous = false
    /// The delays `requestScan` worked out, in order. Recorded only under `synchronous`, so the
    /// app never grows this.
    private(set) var deferrals: [TimeInterval] = []
    /// The last pass's answer, for a case that wants to see what was found rather than what the
    /// registry made of it.
    private(set) var lastResult: ProcessScan.Result?

    // MARK: State

    private let registry: AgentRegistry
    private let queue: DispatchQueue
    private var pending = false
    private var lastScanAt: Date?
    /// The panes the previous pass found an agent in. A pane that drops out of this set is the
    /// only way presence loss is ever spelled, so it is kept here rather than asked of the
    /// registry: the registry holds the *status*, the scanner holds what it last saw.
    private var lastPanes: Set<UUID> = []
    private var heartbeat: Timer?
    private var installed = false
    /// Passes actually started. Read by the coalescing case; the app ignores it.
    private(set) var passes = 0

    init(registry: AgentRegistry? = nil) {
        self.queue = DispatchQueue(label: "dev.danny.quickterm.agents.scan")
        self.registry = registry ?? .shared
    }

    // MARK: Installation

    /// **Wire the scan into the app.** Idempotent.
    ///
    /// The one call site is `AppDelegate.ensureNoticeInterfaceInstalled`, immediately after
    /// `AgentRegistry.shared.attach(...)`, and it is guarded there by `isRunningTests`: until this
    /// runs the registry's `scanTrigger` stays the no-op it ships with, which is exactly right for
    /// a build — or a suite — without a scanner. Hooks still work; presence simply never appears.
    func install() {
        guard !installed else { return }
        installed = true
        registry.scanTrigger = { [weak self] in self?.requestScan() }
        // The test host never walks a real process tree: a suite that did would be reading the
        // environment blocks of whatever the developer happens to be running. The cases drive a
        // scanner of their own, and the one case that wants a real pass spawns its own child.
        guard !AppDelegate.isRunningTests else { return }
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval,
                                         repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.requestScan()
            }
        }
        // "Always on" (owner's Q7) has to include the minutes a consent sheet sits in runModal:
        // scheduledTimer lives in the default mode only, which a modal run loop does not spin, so
        // an agent that died while the user was reading a QuickTerm dialog would keep its stale
        // status until the sheet closed. .common covers the modal and event-tracking modes too.
        if let heartbeat { RunLoop.main.add(heartbeat, forMode: .common) }
        requestScan()
    }

    // MARK: Scanning

    /// Ask for a pass. Coalesced: a request while one is already scheduled is dropped, and a
    /// request soon after a pass waits out the rest of the window.
    func requestScan() {
        guard !pending else { return }
        pending = true
        let since = lastScanAt.map { clock().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let delay = max(0, Self.coalescingWindow - since)
        guard !synchronous else {
            deferrals.append(delay)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.firePendingScan()
            }
        }
    }

    /// The deferred pass, now. The main queue calls this in the app; a case calls it by hand.
    func firePendingScan() {
        pending = false
        scanNow()
    }

    /// One pass, now. The app reaches this only through `requestScan`; a case calls it directly.
    func scanNow() {
        guard let scan = makeScan() else { return }
        lastScanAt = clock()
        passes += 1
        guard !synchronous else {
            deliver(scan.run())
            return
        }
        // The walk is a `proc_listchildpids` per node and a sysctl per agent: not something to do
        // on the thread that draws.
        queue.async { [weak self] in
            let result = scan.run()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.deliver(result)
                }
            }
        }
    }

    /// nil when there is nothing to look for — detection switched off, or no enabled rule names a
    /// process. Both are answered **before** the walk, so "off" means the process table is not
    /// touched at all rather than walked and discarded.
    private func makeScan() -> ProcessScan? {
        guard registry.settings.detect else { return nil }
        var rulesByName: [String: Set<String>] = [:]
        for rules in registry.activeRules {
            // One basename may belong to more than one rule (two rule files both driven by
            // `node`), and then a process is presence for both until a hook says which.
            for name in rules.process { rulesByName[name, default: []].insert(rules.id) }
        }
        guard !rulesByName.isEmpty else { return nil }
        return ProcessScan(root: root, rulesByName: rulesByName, listChildren: listChildren,
                           readName: readName, readArguments: readArguments)
    }

    private func deliver(_ result: ProcessScan.Result) {
        lastResult = result
        // Losses first: a pane whose agents are gone hears about it before anything else moves,
        // so a released status can never be overwritten by the same pass that released it.
        for pane in lastPanes where result.byPane[pane] == nil {
            registry.apply(.processes([]), pane: pane)
        }
        for (pane, found) in result.byPane {
            registry.apply(.processes(found), pane: pane)
        }
        lastPanes = Set(result.byPane.keys)
        // A pass is also when we learn a pane is gone: the registry holds statuses by pane id and
        // only the locator knows which of those panes still exist (plan §2.5).
        registry.dropPanesThatAreGone()
    }

    /// Cases: forget what the last pass saw, and stop the heartbeat.
    func resetForTesting() {
        heartbeat?.invalidate()
        heartbeat = nil
        installed = false
        pending = false
        lastScanAt = nil
        lastPanes.removeAll()
        deferrals.removeAll()
        lastResult = nil
        passes = 0
    }
}
