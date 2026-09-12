import Darwin
import Foundation
import OSLog

/// AF_UNIX / SOCK_STREAM listener.
///
/// Why raw BSD sockets rather than `NWListener`: the security model needs
/// `getsockopt(LOCAL_PEERCRED / LOCAL_PEERPID)` **on the already-accepted fd**, and NWListener
/// exposes neither of those.
///
/// Four checks before binding, all of them in `prepare`:
/// 1. `sun_path` is only 104 bytes — if home is too long, fall back to
///    `$TMPDIR/quickterm.sock` and log that;
/// 2. the path itself is a symlink → refuse (otherwise somebody else gets to pick where we
///    write);
/// 3. the parent directory must exist, is forced to 0700, and must not be a symlink itself;
/// 4. stale socket: connect to it first as a probe, and unlink only once it is established that
///    nobody is listening. If somebody really is, **do not take it from them**.
final class ControlSocket {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "ControlSocket")

    /// An accepted peer. `pid` comes from the kernel (LOCAL_PEERPID), so the process name the
    /// confirmation alert shows is **real** — even when the caller has copied somebody else's
    /// QUICKTERM_TOKEN
    struct Peer {
        let fd: Int32
        let uid: uid_t
        let pid: pid_t
        let processName: String
        /// Connection number, monotonic within this process. **The fd cannot stand in for it**:
        /// fd numbers are reused, so a connection that just closed and the next one accepted can
        /// be the same number — and then "the peer left, drop its events follow" tears down
        /// somebody else's stream
        var connectionID: UInt64 = 0
    }

    /// Issues connection numbers (only ever incremented on the accept queue)
    nonisolated(unsafe) private static var connectionCounter: UInt64 = 0

    enum SocketError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case symlink(String)
        case insecureDirectory(String)
        case alreadyListening(String)
        case system(String, Int32)

        var description: String {
            switch self {
            case .pathTooLong(let p): "socket path is over the sun_path limit: \(p)"
            case .symlink(let p): "socket path is a symlink, refusing to bind: \(p)"
            case .insecureDirectory(let p): "socket parent directory is insecure and cannot be tightened: \(p)"
            case .alreadyListening(let p): "another QuickTerm is already listening on \(p)"
            case .system(let what, let err): "\(what) failed: \(String(cString: strerror(err))) (errno \(err))"
            }
        }
    }

    private(set) var path: String?
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dev.danny.quickterm.control.accept")

    var isListening: Bool { listenFD >= 0 }

    // MARK: Preparation before binding

    /// Create the directory and tighten it to 0700, then clear away a stale socket. Returns the
    /// path that is actually usable (which may be the $TMPDIR fallback).
    /// `allowFallback` is on for the **default** path only: when a path is given explicitly (as
    /// tests do), never quietly move somewhere else — otherwise a test with an over-long path
    /// would go and take the $TMPDIR socket out from under the QuickTerm the user is running
    static func prepare(preferred: String, allowFallback: Bool = true) throws -> String {
        var path = preferred
        if !ControlPaths.fits(path) {
            guard allowFallback else { throw SocketError.pathTooLong(path) }
            let fallback = ControlPaths.fallbackSocketPath
            logger.warning("Control socket path is over the 104-byte sun_path limit, falling back to \(fallback, privacy: .public)")
            path = fallback
            guard ControlPaths.fits(path) else { throw SocketError.pathTooLong(path) }
        }
        let directory = (path as NSString).deletingLastPathComponent
        try prepareDirectory(directory)
        try reclaimStaleSocket(at: path)
        return path
    }

    static func prepareDirectory(_ directory: String) throws {
        var st = stat()
        if lstat(directory, &st) == 0 {
            if (st.st_mode & S_IFMT) == S_IFLNK { throw SocketError.symlink(directory) }
            if (st.st_mode & 0o077) != 0, chmod(directory, 0o700) != 0 {
                throw SocketError.insecureDirectory(directory)
            }
        } else {
            do {
                try FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch {
                throw SocketError.system("creating directory \(directory)", errno)
            }
        }
    }

    /// The probe: if it connects, a real instance is listening, so leave it alone;
    /// ECONNREFUSED / ENOENT mean stale leftovers, so delete them
    static func reclaimStaleSocket(at path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        if (st.st_mode & S_IFMT) == S_IFLNK { throw SocketError.symlink(path) }
        guard (st.st_mode & S_IFMT) == S_IFSOCK else {
            // A regular file that is not a socket: never delete something on the user's behalf
            throw SocketError.insecureDirectory(path)
        }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw SocketError.system("socket()", errno) }
        defer { close(probe) }
        var addr = try sockaddrUn(path)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 { throw SocketError.alreadyListening(path) }
        if unlink(path) != 0, errno != ENOENT {
            throw SocketError.system("unlink \(path)", errno)
        }
    }

    static func sockaddrUn(_ path: String) throws -> sockaddr_un {
        guard ControlPaths.fits(path) else { throw SocketError.pathTooLong(path) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    // MARK: Listening

    /// Bind and start accepting. `onPeer` is called on the internal accept queue (**not** on
    /// the main thread)
    func start(path preferred: String, allowFallback: Bool = true,
               onPeer: @escaping (Peer) -> Void) throws {
        precondition(listenFD < 0, "ControlSocket is already listening")
        let path = try Self.prepare(preferred: preferred, allowFallback: allowFallback)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket()", errno) }
        var ok = false
        defer { if !ok { close(fd) } }

        var addr = try Self.sockaddrUn(path)
        // umask tightened to 0600: the socket file bind creates must never carry group or other
        // bits, not even for the instant before the chmod
        let saved = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(saved)
        guard bound == 0 else { throw SocketError.system("bind \(path)", errno) }
        guard chmod(path, 0o600) == 0 else { throw SocketError.system("chmod 0600 \(path)", errno) }
        guard Darwin.listen(fd, 16) == 0 else { throw SocketError.system("listen", errno) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(onPeer: onPeer) }
        source.setCancelHandler { close(fd) }
        source.resume()

        listenFD = fd
        acceptSource = source
        self.path = path
        ok = true
        Self.logger.info("Control socket listening on \(path, privacy: .public)")
    }

    private func acceptPending(onPeer: @escaping (Peer) -> Void) {
        while true {
            let client = Darwin.accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // EAGAIN / EWOULDBLOCK: that is everything for this round
            }
            guard var peer = Self.peerIdentity(of: client) else {
                close(client)
                continue
            }
            Self.connectionCounter &+= 1
            peer.connectionID = Self.connectionCounter
            // Hard same-uid check: this is the one identity check that **cannot be bypassed**
            guard Self.accepts(peer) else {
                Self.logger.error("Refused a control connection from uid \(peer.uid) (this process runs as uid \(getuid()))")
                close(client)
                continue
            }
            onPeer(peer)
        }
    }

    /// The one identity check that cannot be bypassed: the peer must run under the same uid as
    /// this process.
    /// (The app is ad-hoc signed with the hardened runtime off, so the peer's **code signature**
    /// proves nothing whatsoever — identity stops at uid + pid, which is exactly what the design
    /// document says, and we do not pretend to more.)
    static func accepts(_ peer: Peer) -> Bool { peer.uid == getuid() }

    static func peerIdentity(of fd: Int32) -> Peer? {
        var cred = xucred()
        var credLen = socklen_t(MemoryLayout<xucred>.size)
        let credOK = withUnsafeMutablePointer(to: &cred) {
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, $0, &credLen)
        }
        guard credOK == 0 else { return nil }

        var pid: pid_t = 0
        var pidLen = socklen_t(MemoryLayout<pid_t>.size)
        _ = withUnsafeMutablePointer(to: &pid) {
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, $0, &pidLen)
        }
        return Peer(fd: fd, uid: cred.cr_uid, pid: pid, processName: processName(for: pid))
    }

    /// The real process name from the kernel's point of view (this is what the confirmation
    /// alert shows, never anything the caller claims about itself)
    static func processName(for pid: pid_t) -> String {
        guard pid > 0 else { return "unknown process" }
        var buffer = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return "pid \(pid)" }
        return String(cString: buffer)
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        if let path { unlink(path) }
        path = nil
    }

    deinit { stop() }
}
