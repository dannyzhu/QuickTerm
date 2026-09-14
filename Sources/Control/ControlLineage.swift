import Darwin
import Foundation

/// **Which of QuickTerm's own children a process descends from** (plan §2.2).
///
/// This is the identity behind `NoticeOrigin.lineageRoot`, and the reason a forged report cannot
/// silence somebody else's alarm. `QUICKTERM_PANE` is self-reported and `QUICKTERM_PANE_TOKEN`
/// proves only "I am inside *some* pane's process tree" — but the **process tree itself** is not
/// something a process in another pane can fake: its parent chain reaches a different child of
/// QuickTerm, and `NoticeOrigin.permits` compares exactly that.
///
/// It reads one number per process, the parent pid, out of the kernel's process table; nothing here
/// reads an argument buffer, an environment or a path.
enum ControlLineage {
    /// The parent of `pid`, or nil when the pid is gone or unreadable.
    ///
    /// Read through `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID, …)` — what `ps` itself uses —
    /// because that call answers for **any** pid whoever owns it. `proc_pidinfo(PROC_PIDTBSDINFO)`
    /// does not: for a process owned by another user it fails with EPERM. That is not a corner
    /// case here. Ghostty spawns each pane's shell through `/usr/bin/login`, which runs as uid 0,
    /// so an owner-limited walk stopped at that `login` — one hop short of QuickTerm's own child —
    /// and every hook posted from inside a pane resolved to no lineage at all.
    static func parent(of pid: pid_t) -> pid_t? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        if sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 {
            // A pid with no process behind it is not an error: the call succeeds and hands back an
            // empty record, so the size is what says whether anything was written.
            guard size >= MemoryLayout<kinfo_proc>.stride else { return nil }
            return info.kp_eproc.e_ppid
        }
        // The sysctl itself failed, which ownership never causes (that is the whole reason it is
        // the primary reader) — EINVAL, ENOMEM or EFAULT. Fall back to the older reader so a host
        // that refuses the sysctl for one of those reasons still resolves processes we do own.
        return parentViaProcInfo(pid)
    }

    /// The pre-`sysctl` reader, kept only as the fallback above: `proc_pidinfo` can read a process
    /// of the same user, and answers EPERM for anything else.
    private static func parentViaProcInfo(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard read == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// The **direct child of `ancestor`** that `pid` descends from, walking parents at most
    /// `maxDepth` steps.
    ///
    /// For a hook running inside a pane that child is the pane's own top process — on macOS the
    /// `/usr/bin/login` Ghostty spawns, which runs the shell — and that is precisely the
    /// granularity the lineage rule wants: every process in one pane answers with the same root,
    /// and no process in another pane can.
    ///
    /// nil means the chain never reaches `ancestor`: the caller is unrelated to QuickTerm, or the
    /// hook was reparented to launchd because its agent had already exited. A nil root fails
    /// `permits` against a stored lineage — which is correct, and nothing is then stuck: presence
    /// loss resolves that pane's alarm as `agent-gone`.
    static func root(of pid: pid_t, under ancestor: pid_t = getpid(), maxDepth: Int = 32) -> pid_t? {
        guard pid > 0, pid != ancestor else { return nil }
        var current = pid
        for _ in 0..<maxDepth {
            guard let parent = parent(of: current) else { return nil }
            if parent == ancestor { return current }
            // pid 1 (launchd) is the top of every chain: a walk that gets there has left our
            // subtree for good, and carrying on would only burn the remaining depth. It is
            // readable now — launchd's own parent is the kernel, pid 0 — so this is the stop, not
            // the failure it used to be.
            guard parent > 1 else { return nil }
            current = parent
        }
        return nil
    }
}
