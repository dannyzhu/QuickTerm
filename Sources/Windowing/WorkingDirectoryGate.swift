import Darwin
import Foundation
import OSLog

/// TCC (privacy) gate: confirm a working directory **can actually be opened** before handing it to
/// libghostty.
///
/// Why this exists (the 2026-09-11 launch hang):
/// macOS treats `~/Desktop`, `~/Documents` and `~/Downloads` as protected directories. TCC records
/// the grant against the **code signing identity** (for an ad-hoc signature, against the cdhash),
/// so a binary from any fresh build is not covered by the existing grant.
/// If the process was launched by LaunchServices (`open` / Dock / Finder), tccd then neither
/// prompts nor denies - `open(2)` simply hangs there **forever**, at 0% CPU.
/// While restoring a session, `Ghostty.SurfaceView.init` calls `ghostty_surface_new` synchronously
/// and the engine `openat`s the cwd from the archive inside it, so the whole app wedges in
/// `applicationDidFinishLaunching` and not a single window ever appears.
/// (Running the same binary straight from a terminal does not hang: TCC attributes the access to
/// the "responsible process", which is the already-authorized terminal.)
///
/// There is no cheap probe: `stat` and `access` on a protected directory both return 0 immediately,
/// and only a real `open` trips TCC - and once it does, it never returns. So the only option is to
/// run the `open` on a **separate thread** and have the main thread wait on it with a timeout.
/// A timeout means this root is unusable; we remember that (each root is probed exactly once) and
/// the pane falls back to the default directory and starts its shell as usual.
/// When the grant is in place (a release build) `open` takes microseconds and nothing changes.
enum WorkingDirectoryGate {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "WorkingDirectoryGate")

    /// Probe timeout. Paid at most once per protected root: worst case 0.9s across the three
    /// roots, after which launch carries on as normal.
    static var deadline: TimeInterval = 0.3

    /// Injectable for tests: can `root` be opened within `deadline`?
    static var prober: (_ root: String, _ deadline: TimeInterval) -> Bool = probeByOpening

    private static let lock = NSLock()
    private static var cache: [String: Bool] = [:]

    /// The roots TCC protects. Only a path under one of these needs probing; everything else is
    /// passed through untouched.
    static func protectedRoots(home: String = NSHomeDirectory()) -> [String] {
        ["\(home)/Desktop", "\(home)/Documents", "\(home)/Downloads"]
    }

    /// Which protected root `path` falls under (a pure function, so tests can cover it)
    static func protectedRoot(for path: String, home: String = NSHomeDirectory()) -> String? {
        let standardized = (path as NSString).standardizingPath
        return protectedRoots(home: home).first {
            standardized == $0 || standardized.hasPrefix($0 + "/")
        }
    }

    /// The single entry point: returns the path unchanged when it is usable, or nil when the probe
    /// does not come back (for the caller that means: let the engine use its default directory)
    static func usable(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return path }
        guard let root = protectedRoot(for: path) else { return path }
        guard isRootUsable(root) else {
            // No TCC grant and no answer at all - neither a prompt nor a denial.
            logger.error(
                "working directory unusable, TCC did not answer: \(path, privacy: .public) - using default")
            return nil
        }
        return path
    }

    /// Each root is probed once (the result is cached for the lifetime of the process; a late
    /// success flips the cache back to usable, see `noteLateSuccess`)
    static func isRootUsable(_ root: String) -> Bool {
        lock.lock()
        if let cached = cache[root] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let ok = prober(root, deadline)
        lock.lock()
        // The `open` may have succeeded after we already timed out (the permission prompt was up
        // and the user hit "Allow" a moment later). It has written its result in by now, so do not
        // overwrite it with the false we just computed.
        let result = cache[root] ?? ok
        cache[root] = result
        lock.unlock()
        return result
    }

    /// The probe thread succeeded after the timeout: mark this root usable again.
    /// A timeout is not a denial - the permission prompt may well be up and the user clicks "Allow"
    /// a few seconds later.
    /// Panes created after that get the real directory. The ones restored during this launch
    /// already fell back to the default directory, but their archived path is kept verbatim in
    /// `SurfaceView.deniedWorkingDirectory`, so it is not lost.
    static func noteLateSuccess(_ root: String) {
        lock.lock()
        cache[root] = true
        lock.unlock()
    }

    /// The default probe: `open` on a separate thread, with the main thread waiting on a timeout.
    /// After a timeout that thread **cannot be cancelled** (it is stuck inside the kernel) and
    /// stays around - at most three of them, and only when the grant is missing.
    static func probeByOpening(_ root: String, _ deadline: TimeInterval) -> Bool {
        final class Box: @unchecked Sendable { var ok = false }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let thread = Thread {
            let fd = open(root, O_RDONLY | O_DIRECTORY)
            if fd >= 0 {
                Darwin.close(fd)
                box.ok = true
                noteLateSuccess(root)   // May be arriving after the timeout: see the comment there
            }
            semaphore.signal()
        }
        thread.name = "dev.danny.quickterm.tcc-probe"
        thread.stackSize = 64 << 10
        thread.start()
        guard semaphore.wait(timeout: .now() + deadline) == .success else { return false }
        return box.ok
    }

    /// Reset between tests (cache, probe and timeout)
    static func resetForTesting() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
        prober = probeByOpening
        deadline = 0.3
    }
}
