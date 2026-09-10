import Darwin
import Foundation
import OSLog

/// AF_UNIX / SOCK_STREAM 监听器。
///
/// 为什么是裸 BSD socket 而不是 `NWListener`：安全模型需要在**已 accept 的 fd** 上做
/// `getsockopt(LOCAL_PEERCRED / LOCAL_PEERPID)`，NWListener 不暴露这两样。
///
/// 绑定前的四道检查（都在 `prepare` 里）：
/// 1. `sun_path` 只有 104 字节 —— home 太长就回退 `$TMPDIR/quickterm.sock` 并记日志；
/// 2. 路径本身是符号链接 → 拒绝（否则等于让别人指定我们往哪写）；
/// 3. 父目录必须存在且强制 0700，且自身不是符号链接；
/// 4. 陈旧 socket：先探测性 connect，确认没人在听才 unlink。真有人在听就**不抢**。
final class ControlSocket {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "ControlSocket")

    /// 已 accept 的对端。`pid` 来自内核（LOCAL_PEERPID），所以确认框里显示的进程名是**真的**——
    /// 即使调用方抄走了别人的 QUICKTERM_TOKEN
    struct Peer {
        let fd: Int32
        let uid: uid_t
        let pid: pid_t
        let processName: String
    }

    enum SocketError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case symlink(String)
        case insecureDirectory(String)
        case alreadyListening(String)
        case system(String, Int32)

        var description: String {
            switch self {
            case .pathTooLong(let p): "socket 路径超过 sun_path 上限：\(p)"
            case .symlink(let p): "socket 路径是符号链接，拒绝绑定：\(p)"
            case .insecureDirectory(let p): "socket 父目录权限不安全且无法收紧：\(p)"
            case .alreadyListening(let p): "已有 QuickTerm 在监听 \(p)"
            case .system(let what, let err): "\(what) 失败：\(String(cString: strerror(err)))（errno \(err)）"
            }
        }
    }

    private(set) var path: String?
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dev.danny.quickterm.control.accept")

    var isListening: Bool { listenFD >= 0 }

    // MARK: 绑定前的准备

    /// 目录建好并收紧到 0700；陈旧 socket 清掉。返回真正可用的路径（可能是 $TMPDIR 回退）。
    /// `allowFallback` 只对**默认**路径开：显式指定路径（用例注入）时绝不悄悄换地方——
    /// 否则一个路径过长的用例会去抢用户正在跑的那个 QuickTerm 的 $TMPDIR socket
    static func prepare(preferred: String, allowFallback: Bool = true) throws -> String {
        var path = preferred
        if !ControlPaths.fits(path) {
            guard allowFallback else { throw SocketError.pathTooLong(path) }
            let fallback = ControlPaths.fallbackSocketPath
            logger.warning("控制 socket 路径超过 sun_path 104 字节，回退到 \(fallback, privacy: .public)")
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
                throw SocketError.system("创建目录 \(directory)", errno)
            }
        }
    }

    /// 探测：能连上说明真有实例在听（不抢）；ECONNREFUSED / ENOENT 说明是陈旧残留，删掉
    static func reclaimStaleSocket(at path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        if (st.st_mode & S_IFMT) == S_IFLNK { throw SocketError.symlink(path) }
        guard (st.st_mode & S_IFMT) == S_IFSOCK else {
            // 不是 socket 的普通文件：绝不替用户删东西
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

    // MARK: 监听

    /// 绑定并开始 accept。`onPeer` 在内部 accept 队列上调用（**不是**主线程）
    func start(path preferred: String, allowFallback: Bool = true,
               onPeer: @escaping (Peer) -> Void) throws {
        precondition(listenFD < 0, "ControlSocket 已在监听")
        let path = try Self.prepare(preferred: preferred, allowFallback: allowFallback)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket()", errno) }
        var ok = false
        defer { if !ok { close(fd) } }

        var addr = try Self.sockaddrUn(path)
        // umask 收紧到 0600：bind 建出来的 socket 文件不能有组/其他位（chmod 之前那一瞬也不行）
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
        Self.logger.info("控制 socket 已监听 \(path, privacy: .public)")
    }

    private func acceptPending(onPeer: @escaping (Peer) -> Void) {
        while true {
            let client = Darwin.accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // EAGAIN / EWOULDBLOCK：这轮收完了
            }
            guard let peer = Self.peerIdentity(of: client) else {
                close(client)
                continue
            }
            // 同 uid 硬校验：这是唯一一道**不可绕过**的身份检查
            guard Self.accepts(peer) else {
                Self.logger.error("拒绝 uid \(peer.uid) 的控制连接（本进程 uid \(getuid())）")
                close(client)
                continue
            }
            onPeer(peer)
        }
    }

    /// 唯一不可绕过的身份检查：对端必须与本进程同 uid。
    /// （应用是 ad-hoc 签名、hardened runtime 关闭的，所以对端的**代码签名**证明不了任何东西——
    /// 身份到 uid + pid 为止，设计文档就是这么写的，不假装更多。）
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

    /// 内核视角的真实进程名（确认框里显示它，而不是调用方自称的任何东西）
    static func processName(for pid: pid_t) -> String {
        guard pid > 0 else { return "未知进程" }
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
