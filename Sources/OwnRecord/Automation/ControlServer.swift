import Darwin
import Foundation

/// Listens for the `ownrecord` tool on a Unix domain socket (see `ControlChannel`). Only
/// processes running as the same user can connect.
@MainActor
final class ControlServer {
    /// Answers one request with its encoded result. `progress` sends a progress line.
    typealias Handler = @MainActor (_ command: String, _ request: Data,
                                    _ progress: @escaping @Sendable (Double) -> Void) async throws -> Data

    let socketURL: URL
    private let handler: Handler
    private var listener: DispatchSourceRead?

    init(socketURL: URL = ControlChannel.socketURL, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    var isRunning: Bool { listener != nil }

    func start() throws {
        guard listener == nil else { return }
        let path = socketURL.path
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard var address = ControlChannel.address(for: path) else {
            throw ControlError("The socket path is too long: \(path)")
        }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // A socket left behind by a previous run would block bind.
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(socket, 16) == 0,
              fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK) == 0 else {
            let code = errno
            close(socket)
            unlink(path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptConnections(on: socket) }
        }
        source.setCancelHandler { close(socket) }
        source.resume()
        listener = source
    }

    func stop() {
        guard let listener else { return }
        listener.cancel()
        self.listener = nil
        unlink(socketURL.path)
    }

    private func acceptConnections(on socket: Int32) {
        while true {
            let client = accept(socket, nil, nil)
            guard client >= 0 else { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client)
                continue
            }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            ControlChannel.setOption(SO_NOSIGPIPE, on: client)
            ControlChannel.setTimeout(SO_RCVTIMEO, seconds: 10, on: client)
            ControlChannel.setTimeout(SO_SNDTIMEO, seconds: 30, on: client)
            let connection = ControlConnection(socket: client)
            connection.readRequest { [weak self] request in
                Task { @MainActor in
                    guard let self else { return connection.close() }
                    await self.answer(request, on: connection)
                }
            }
        }
    }

    private func answer(_ request: Data?, on connection: ControlConnection) async {
        guard let request, let head = try? ControlCoding.decoder.decode(ControlRequestHead.self, from: request) else {
            connection.finish(error: "That isn't a valid request.")
            return
        }
        let handler = self.handler
        let task = Task { @MainActor in
            try await handler(head.command, request) { connection.send(progress: $0) }
        }
        // E.g. the tool was stopped with ⌃C: stop exporting for it.
        connection.watchForDisconnect { task.cancel() }
        do {
            connection.finish(result: try await task.value)
        } catch {
            if task.isCancelled {
                connection.close()
            } else {
                connection.finish(error: error.localizedDescription)
            }
        }
    }
}

/// One connection from the tool. Writes happen in order on the connection's own queue, so a
/// slow reader never blocks the main thread.
final class ControlConnection: @unchecked Sendable {
    private let socket: Int32
    private let queue = DispatchQueue(label: "com.ownrecord.control.connection")
    private var disconnectSource: DispatchSourceRead?
    private var isClosed = false

    init(socket: Int32) {
        self.socket = socket
    }

    /// Reads the request line in the background; `completion` gets nil if none arrives.
    func readRequest(_ completion: @escaping @Sendable (Data?) -> Void) {
        queue.async { [socket] in
            var reader = LineReader(socket: socket)
            completion(try? reader.next())
        }
    }

    /// Calls `handler` once if the tool goes away before the answer is sent.
    func watchForDisconnect(_ handler: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard !isClosed else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
            source.setEventHandler { [self] in
                // The tool sends nothing after its request, so this is the end of the stream.
                var byte: UInt8 = 0
                if read(socket, &byte, 1) <= 0 {
                    closeNow()
                    handler()
                }
            }
            // The socket may only be closed once the source is done with it.
            source.setCancelHandler { [socket] in Darwin.close(socket) }
            source.resume()
            disconnectSource = source
        }
    }

    func send(progress: Double) {
        send(ControlProgress(progress: progress))
    }

    func finish(result: Data) {
        var line = Data(#"{"result":"#.utf8)
        line.append(result)
        line.append(Data("}".utf8))
        write(line)
        close()
    }

    func finish(error message: String) {
        send(ControlFailure(error: message))
        close()
    }

    func close() {
        queue.async { [self] in closeNow() }
    }

    /// On `queue`.
    private func closeNow() {
        guard !isClosed else { return }
        isClosed = true
        if let disconnectSource {
            disconnectSource.cancel()
            self.disconnectSource = nil
        } else {
            Darwin.close(socket)
        }
    }

    private func send(_ message: some Encodable) {
        guard let data = try? ControlCoding.encoder.encode(message) else { return }
        write(data)
    }

    private func write(_ line: Data) {
        var line = line
        line.append(0x0A)
        queue.async { [self] in
            guard !isClosed else { return }
            ControlChannel.write(line, to: socket)
        }
    }
}
