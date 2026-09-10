import AppKit
import Darwin
import Foundation
import OSLog

/// 控制服务：socket 的所有者 + NDJSON 分帧 + 主线程 hop。
///
/// 线程模型（只有这一种，别的一律是 bug）：
/// accept / read / write 在 `ioQueue`；**所有**命令执行经 `DispatchQueue.main.async` 到主线程；
/// 绝不 `DispatchQueue.main.sync`（会和 AppKit 的 run loop 直接死锁）。
final class ControlServer {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "ControlServer")
    /// 单行上限：agent 幻觉出一个巨大的参数不该把内存吃光
    static let maxLineBytes = 1 << 20
    /// 每条连接的变更速率（令牌桶）：agent 会很开心地在循环里建 40 个 pane
    static let mutationBurst = 20
    static let mutationsPerSecond = 20.0

    private let socket = ControlSocket()
    private let ioQueue = DispatchQueue(label: "dev.danny.quickterm.control.io")
    private let runner: ControlCommandRunner
    private var connections: [Int32: Connection] = [:]
    private let socketPathOverride: String?

    var socketPath: String? { socket.path }
    var isListening: Bool { socket.isListening }

    @MainActor
    init(screens: ScreenRegistry, consent: ControlConsent, socketPath: String? = nil) {
        self.runner = ControlCommandRunner(screens: screens, consent: consent)
        self.socketPathOverride = socketPath
    }

    // MARK: 生命周期

    @MainActor
    func apply(_ config: ControlCommandRunner.Config) {
        runner.config = config
        if config.isListening {
            start()
        } else {
            stop()
        }
    }

    @MainActor
    func start() {
        guard !socket.isListening else { return }
        let preferred = socketPathOverride ?? ControlPaths.resolvedSocketPath()
        do {
            try socket.start(path: preferred, allowFallback: socketPathOverride == nil) { [weak self] peer in
                self?.accept(peer)
            }
            ControlEnvironment.socketPath = socket.path
        } catch {
            ControlEnvironment.socketPath = nil
            Self.logger.error("控制 socket 启动失败：\(String(describing: error), privacy: .public)")
        }
    }

    @MainActor
    func stop() {
        guard socket.isListening else { return }
        ControlEventBus.shared.dropAllFollowers()   // 停服 = 每一条 events follow 都断了
        socket.stop()
        ControlEnvironment.socketPath = nil
        ioQueue.async { [weak self] in
            guard let self else { return }
            for connection in self.connections.values { connection.close() }
            self.connections.removeAll()
        }
    }

    // MARK: 连接

    private func accept(_ peer: ControlSocket.Peer) {
        ioQueue.async { [weak self] in
            guard let self else {
                Darwin.close(peer.fd)
                return
            }
            let connection = Connection(peer: peer, queue: self.ioQueue,
                                        onLine: { [weak self] line, connection in
                                            self?.handle(line, on: connection)
                                        },
                                        onClose: { [weak self] fd in
                                            self?.connections.removeValue(forKey: fd)
                                            // 对端走了：把它挂着的 `events follow` 摘掉。
                                            // 摘的是**连接编号**而不是 fd —— fd 号会被复用
                                            DispatchQueue.main.async { [weak self] in
                                                guard let self else { return }
                                                MainActor.assumeIsolated {
                                                    self.runner.connectionDidClose(peer.connectionID)
                                                }
                                            }
                                        })
            self.connections[peer.fd] = connection
            connection.resume()
            Self.logger.debug("控制连接：\(peer.processName, privacy: .public) pid \(peer.pid) uid \(peer.uid)")
        }
    }

    private func handle(_ line: Data, on connection: Connection) {
        let request: ControlRequest
        do {
            request = try ControlJSON.decoder.decode(ControlRequest.self, from: line)
        } catch {
            // id 都读不出来：用 "0" 应答，让客户端至少能报出一条结构化错误
            connection.send(.failure(id: "0", seq: nil,
                                     error: ControlErrorBody(.badRequest, "请求不是合法的 NDJSON 对象：\(error)")))
            return
        }
        if Self.isMutation(request), !connection.consumeMutationToken() {
            connection.send(.failure(id: request.id, seq: nil,
                                     error: ControlErrorBody(.rateLimited,
                                                             "变更速率超过 \(Int(Self.mutationsPerSecond))/s",
                                                             hint: "把批量操作合并，或放慢重试",
                                                             retryAfterMs: 250)))
            return
        }
        let peer = connection.peer
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.runner.handle(request, peer: peer) { [weak connection] response in
                    connection?.send(response)
                }
            }
        }
    }

    static func isMutation(_ request: ControlRequest) -> Bool {
        guard let spec = ControlCommandTable.command(request.cmd) else { return false }
        if spec.name == "action" { return request.args["list"]?.boolValue != true }
        return spec.cls.isMutation
    }

    // MARK: 一条连接

    private final class Connection {
        let peer: ControlSocket.Peer
        private let queue: DispatchQueue
        private let onLine: (Data, Connection) -> Void
        private let onClose: (Int32) -> Void
        private var source: DispatchSourceRead?
        private var buffer = Data()
        private var closed = false
        private var tokens: Double
        private var lastRefill = Date()

        init(peer: ControlSocket.Peer, queue: DispatchQueue,
             onLine: @escaping (Data, Connection) -> Void, onClose: @escaping (Int32) -> Void) {
            self.peer = peer
            self.queue = queue
            self.onLine = onLine
            self.onClose = onClose
            self.tokens = Double(ControlServer.mutationBurst)
            _ = fcntl(peer.fd, F_SETFL, fcntl(peer.fd, F_GETFL, 0) | O_NONBLOCK)
        }

        func resume() {
            let source = DispatchSource.makeReadSource(fileDescriptor: peer.fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { [fd = peer.fd] in Darwin.close(fd) }
            self.source = source
            source.resume()
        }

        func consumeMutationToken() -> Bool {
            let now = Date()
            tokens = min(Double(ControlServer.mutationBurst),
                         tokens + now.timeIntervalSince(lastRefill) * ControlServer.mutationsPerSecond)
            lastRefill = now
            guard tokens >= 1 else { return false }
            tokens -= 1
            return true
        }

        private func readAvailable() {
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = read(peer.fd, &chunk, chunk.count)
                if n > 0 {
                    buffer.append(contentsOf: chunk[0..<n])
                    if buffer.count > ControlServer.maxLineBytes {
                        // **已经在 io 队列上：必须同步写**。走 send() 的话那次 queue.async
                        // 会排在紧随其后的 close() 之后，再被 write() 的 `guard !closed` 吞掉，
                        // 对端只看到 EOF —— 成了一个没有 code 的"连接被断了"，
                        // 而不是我们承诺的结构化 bad_request
                        sendNow(.failure(id: "0", seq: nil,
                                         error: ControlErrorBody(.badRequest, "单条请求超过 1 MiB",
                                                                 hint: "把参数拆小；单行上限 1 MiB")))
                        close()
                        return
                    }
                    drainLines()
                    continue
                }
                if n == 0 { close(); return }              // 对端关闭
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                close()
                return
            }
        }

        private func drainLines() {
            while let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<index)
                buffer.removeSubrange(buffer.startIndex...index)
                guard !line.isEmpty else { continue }
                onLine(line, self)
            }
        }

        /// 从任意线程调用（命令的 completion 在主线程）；写永远排回 io 队列
        func send(_ response: ControlResponse) {
            let data = Self.encode(response)
            queue.async { [weak self] in self?.write(data) }
        }

        /// 已经在 io 队列上、且**紧接着要 close()** 时用这个：
        /// `send()` 的 queue.async 排在 close() 之后就会被 `guard !closed` 丢掉。
        /// 不 close 的路径仍走 `send()`——那里的 write 带着 200ms 停顿等待，
        /// 同步跑在读循环里会被一个不读的客户端拖住整条 io 队列
        func sendNow(_ response: ControlResponse) {
            dispatchPrecondition(condition: .onQueue(queue))
            write(Self.encode(response))
        }

        private static func encode(_ response: ControlResponse) -> Data {
            do {
                return try ControlJSON.line(response)
            } catch {
                let fallback = ControlResponse.failure(
                    id: response.id, seq: nil,
                    error: ControlErrorBody(.internalError, "响应编码失败"))
                return (try? ControlJSON.line(fallback)) ?? Data("{\"ok\":false}\n".utf8)
            }
        }

        private func write(_ data: Data) {
            guard !closed else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                // 对端不读时最多等 200ms 就放弃：宁可丢一条响应，也不能让 io 队列被一个不读的客户端卡死
                var stalls = 0
                while offset < raw.count {
                    let n = Darwin.write(peer.fd, base.advanced(by: offset), raw.count - offset)
                    if n > 0 { offset += n; stalls = 0; continue }
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        stalls += 1
                        guard stalls < 200 else { return }
                        usleep(1000)
                        continue
                    }
                    return
                }
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            source?.cancel()
            source = nil
            onClose(peer.fd)
        }
    }
}
