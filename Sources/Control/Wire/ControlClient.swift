import Darwin
import Foundation

/// Connects to QuickTerm's control socket, writes one line of NDJSON, reads one line of reply.
/// The connection is reusable (the Phase 4 event stream is this same connection held open), but in
/// Phase 1 every command is a single round trip.
struct ControlClient {
    enum ClientError: Error {
        case notRunning([String])
        case system(String)
        case badResponse(String)
    }

    let path: String
    private let fd: Int32

    /// Tries the candidate paths in order; if none of them connects -> notRunning.
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

    /// Writes one NDJSON request line (does not read the reply).
    func write(_ request: ControlRequest) throws {
        let line = try ControlJSON.line(request)
        try line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += n; continue }
                if errno == EINTR { continue }
                throw ClientError.system("socket write failed: \(String(cString: strerror(errno)))")
            }
        }
    }

    /// `events follow`: write the request once, then read forever, handing each line to `onReply`.
    /// When the peer closes (QuickTerm quit, or the service was stopped) we return normally —
    /// **that is the only way this stream ever ends**; the client side never hangs up on its own
    /// (the user pressing Ctrl-C is what ends this process).
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
            if n == 0 { return }                  // peer closed: end of stream
            if errno == EINTR { continue }
            throw ClientError.system("socket read failed: \(String(cString: strerror(errno)))")
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
                        throw ClientError.badResponse(String(data: lineData, encoding: .utf8) ?? "<not UTF-8>")
                    }
                }
                continue
            }
            if n == 0 { throw ClientError.badResponse("QuickTerm closed the connection before replying") }
            if errno == EINTR { continue }
            throw ClientError.system("socket read failed: \(String(cString: strerror(errno)))")
        }
    }

    /// `--start`: launch QuickTerm and wait for the socket to appear (10s at most).
    /// Failing silently and doing nothing is the one behavior an agent cannot recover from.
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
