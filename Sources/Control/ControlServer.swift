import AppKit
import Darwin
import Foundation
import OSLog

/// The control server: owner of the socket, NDJSON framing, and the hop to the main thread.
///
/// The threading model (there is exactly one; anything else is a bug):
/// accept / read / write run on `ioQueue`; **every** command execution reaches the main thread
/// through `DispatchQueue.main.async`; never `DispatchQueue.main.sync`, which deadlocks
/// outright against AppKit's run loop.
final class ControlServer {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "ControlServer")
    /// Per-line ceiling: an agent hallucinating one enormous argument must not be able to eat
    /// all of memory
    static let maxLineBytes = 1 << 20
    /// Mutation rate per connection (token bucket): an agent will happily create 40 panes in a
    /// loop
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

    // MARK: Lifecycle

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
            Self.logger.error("Control socket failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    @MainActor
    func stop() {
        guard socket.isListening else { return }
        ControlEventBus.shared.dropAllFollowers()   // server down = every events follow is cut
        socket.stop()
        ControlEnvironment.socketPath = nil
        ioQueue.async { [weak self] in
            guard let self else { return }
            for connection in self.connections.values { connection.close() }
            self.connections.removeAll()
        }
    }

    // MARK: Connections

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
                                            // The peer left: drop the `events follow` it was
                                            // holding. What gets dropped is the **connection
                                            // number**, not the fd — fd numbers are reused
                                            DispatchQueue.main.async { [weak self] in
                                                guard let self else { return }
                                                MainActor.assumeIsolated {
                                                    self.runner.connectionDidClose(peer.connectionID)
                                                }
                                            }
                                        })
            self.connections[peer.fd] = connection
            connection.resume()
            Self.logger.debug("Control connection: \(peer.processName, privacy: .public) pid \(peer.pid) uid \(peer.uid)")
        }
    }

    private func handle(_ line: Data, on connection: Connection) {
        let request: ControlRequest
        do {
            request = try ControlJSON.decoder.decode(ControlRequest.self, from: line)
        } catch {
            // Not even the id could be read: answer as "0" so the client at least gets one
            // structured error back
            connection.send(.failure(id: "0", seq: nil,
                                     error: ControlErrorBody(.badRequest, "The request is not a valid NDJSON object: \(error)")))
            return
        }
        if Self.isMutation(request), !connection.consumeMutationToken() {
            connection.send(.failure(id: request.id, seq: nil,
                                     error: ControlErrorBody(.rateLimited,
                                                             "Mutation rate above \(Int(Self.mutationsPerSecond))/s",
                                                             hint: "Batch the operations, or retry more slowly.",
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

    // MARK: A single connection

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
                        // **Already on the io queue, so this has to be written synchronously**.
                        // Going through send() would queue that write behind the close() that
                        // follows right after it, where write()'s `guard !closed` swallows it,
                        // and the peer would see nothing but EOF — a codeless "the connection
                        // was dropped" instead of the structured bad_request we promised
                        sendNow(.failure(id: "0", seq: nil,
                                         error: ControlErrorBody(.badRequest, "A single request went over 1 MiB",
                                                                 hint: "Split the arguments up; the per-line limit is 1 MiB.")))
                        close()
                        return
                    }
                    drainLines()
                    continue
                }
                if n == 0 { close(); return }              // the peer closed
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

        /// Callable from any thread (a command's completion runs on the main thread); the write
        /// itself always goes back onto the io queue
        func send(_ response: ControlResponse) {
            let data = Self.encode(response)
            queue.async { [weak self] in self?.write(data) }
        }

        /// Use this when already on the io queue and **a close() comes immediately after**:
        /// `send()`'s queue.async would land after that close() and be dropped by `guard !closed`.
        /// Paths that do not close still go through `send()` — the write there carries a 200 ms
        /// stall budget, and running that synchronously inside the read loop would let one
        /// client that is not reading hold up the entire io queue
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
                    error: ControlErrorBody(.internalError, "Failed to encode the response"))
                return (try? ControlJSON.line(fallback)) ?? Data("{\"ok\":false}\n".utf8)
            }
        }

        private func write(_ data: Data) {
            guard !closed else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                // Give up after at most 200 ms when the peer is not reading: better to drop one
                // response than to let a client that never reads wedge the io queue
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
