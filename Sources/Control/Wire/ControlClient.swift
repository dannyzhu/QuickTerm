import Darwin
import Foundation

/// 连到 QuickTerm 的控制 socket，发一行 NDJSON，读一行响应。
/// 连接可复用（Phase 4 的事件流就是同一条连接保持打开），但 Phase 1 每条命令一次往返。
struct ControlClient {
    enum ClientError: Error {
        case notRunning([String])
        case system(String)
        case badResponse(String)
    }

    let path: String
    private let fd: Int32

    /// 依次尝试候选路径；全部连不上 → notRunning
    static func connect(candidates: [String]) throws -> ControlClient {
        var tried: [String] = []
        for path in candidates {
            tried.append(path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes = Array(path.utf8)
            guard bytes.count + 1 <= ControlPaths.sunPathMax else {
                Darwin.close(fd)
                continue
            }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if ok == 0 { return ControlClient(path: path, fd: fd) }
            Darwin.close(fd)
        }
        throw ClientError.notRunning(tried)
    }

    func close() { Darwin.close(fd) }

    /// 写一行 NDJSON 请求（不读回应）
    func write(_ request: ControlRequest) throws {
        let line = try ControlJSON.line(request)
        try line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += n; continue }
                if errno == EINTR { continue }
                throw ClientError.system("写入 socket 失败：\(String(cString: strerror(errno)))")
            }
        }
    }

    /// `events follow`：写一次请求，然后一直读，每读到一行就交给 `onReply`。
    /// 对端关掉（QuickTerm 退出 / 服务停了）就正常返回——**流的终止只有这一种**，
    /// 客户端这边从不主动断（用户按 Ctrl-C 才结束这个进程）
    func stream(_ request: ControlRequest, onReply: (ControlReply) -> Void) throws {
        try write(request)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                while let index = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<index)
                    buffer.removeSubrange(buffer.startIndex...index)
                    guard !lineData.isEmpty else { continue }
                    guard let reply = try? ControlJSON.decoder.decode(ControlReply.self, from: lineData)
                    else { continue }
                    onReply(reply)
                }
                continue
            }
            if n == 0 { return }                  // 对端关闭：流结束
            if errno == EINTR { continue }
            throw ClientError.system("读取 socket 失败：\(String(cString: strerror(errno)))")
        }
    }

    func send(_ request: ControlRequest) throws -> ControlReply {
        try write(request)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if let index = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<index)
                    do {
                        return try ControlJSON.decoder.decode(ControlReply.self, from: lineData)
                    } catch {
                        throw ClientError.badResponse(String(data: lineData, encoding: .utf8) ?? "<非 UTF-8>")
                    }
                }
                continue
            }
            if n == 0 { throw ClientError.badResponse("QuickTerm 在应答之前关闭了连接") }
            if errno == EINTR { continue }
            throw ClientError.system("读取 socket 失败：\(String(cString: strerror(errno)))")
        }
    }

    /// `--start`：拉起 QuickTerm 并等 socket 出现（最长 10s）。
    /// 什么都不做地静默失败是 agent 唯一无法自救的行为
    static func launchAndWait(candidates: [String], timeout: TimeInterval = 10) -> ControlClient? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "QuickTerm"]
        try? process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let client = try? connect(candidates: candidates) { return client }
            usleep(200_000)
        }
        return nil
    }
}
