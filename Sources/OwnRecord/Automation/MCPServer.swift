import Darwin
import Foundation

/// `ownrecord mcp`: serves OwnRecord's tools (see `MCPTool`) to AI apps over the Model Context
/// Protocol, one JSON-RPC message per line on standard input and output. Each tool call becomes
/// requests to the running app, as with the command line tool.
///
/// Speaks both eras of MCP: the per-request metadata of 2026-07-28 (with `server/discover`), and
/// the `initialize` handshake of 2025-11-25 and earlier, which most apps still use.
final class MCPServer: @unchecked Sendable {
    /// Versions whose requests carry their own metadata.
    static let modernVersions = ["2026-07-28"]
    /// Versions that start with `initialize`, newest first.
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private static let versionKey = "io.modelcontextprotocol/protocolVersion"
    private static let capabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    private static let serverInfoKey = "io.modelcontextprotocol/serverInfo"
    /// How long apps may keep the tool list (it only changes with OwnRecord itself).
    private static let cacheTime = 3_600_000

    /// The command AI apps should start, with the argument `mcp`: this app's executable.
    static var executablePath: String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? "/Applications/OwnRecord.app/Contents/MacOS/OwnRecord"
    }

    private let socketURL: URL
    private let write: (Data) -> Void
    private let writeLock = NSLock()
    private let lock = NSLock()
    /// Tool calls in progress, by request ID.
    private var calls: [String: ControlCancellation] = [:]
    private let running = DispatchGroup()

    /// - Parameter write: Sends one message (without its newline). Never called concurrently.
    init(socketURL: URL = ControlChannel.socketURL, write: @escaping (Data) -> Void) {
        self.socketURL = socketURL
        self.write = write
    }

    /// Serves standard input until it closes.
    static func serve() {
        // An app that stops reading shouldn't kill the server mid-answer.
        signal(SIGPIPE, SIG_IGN)
        let server = MCPServer { message in
            do {
                try FileHandle.standardOutput.write(contentsOf: message + [0x0A])
            } catch {
                exit(0)
            }
        }
        while let line = readLine() {
            server.receive(Data(line.utf8))
        }
        // Answer what's quick (e.g. when requests were piped in); leaving cancels the rest in the app.
        _ = server.running.wait(timeout: .now() + 10)
    }

    /// Handles one message. Tool calls are answered from another thread when they finish.
    func receive(_ line: Data) {
        guard !line.allSatisfy({ [0x20, 0x09, 0x0D].contains($0) }) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: line) else {
            return fail(nil, code: -32700, "Parse error: each line must be one JSON-RPC message.")
        }
        guard let message = json as? [String: Any] else {
            return fail(nil, code: -32600, "Expected one JSON-RPC message (batches aren't supported).")
        }
        // Without a method it's a response, and this server sends no requests.
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id = message["id"], !(id is NSNull) else { return notified(method, params) }
        guard id is String || id is NSNumber else { return fail(nil, code: -32600, "A request's ID must be a string or a number.") }
        handle(Request(id: id, method: method, params: params))
    }

    private struct Request {
        let id: Any
        let method: String
        let params: [String: Any]
        /// Answer in the 2026-07-28 style, with `resultType` and the server's identity.
        var isModern = false
    }

    private func handle(_ request: Request) {
        var request = request
        let meta = request.params["_meta"] as? [String: Any] ?? [:]
        if let requested = meta[Self.versionKey] {
            guard let version = requested as? String, (Self.modernVersions + Self.legacyVersions).contains(version) else {
                return fail(request.id, code: -32022, "Unsupported protocol version",
                            data: ["supported": Self.modernVersions + Self.legacyVersions, "requested": requested])
            }
            if Self.modernVersions.contains(version) {
                guard meta[Self.capabilitiesKey] is [String: Any] else {
                    return fail(request.id, code: -32602, "Requests need \(Self.capabilitiesKey) in _meta.")
                }
                request.isModern = true
            }
        }
        switch request.method {
        case "initialize":
            let requested = request.params["protocolVersion"] as? String
            let version = requested.flatMap { Self.legacyVersions.contains($0) ? $0 : nil } ?? Self.legacyVersions[0]
            answer(request, ["protocolVersion": version, "capabilities": Self.capabilities, "serverInfo": Self.serverInfo,
                             "instructions": MCPTool.instructions])
        case "server/discover":
            guard request.isModern else {
                return fail(request.id, code: -32602, "server/discover needs \(Self.versionKey) in _meta.")
            }
            answer(request, ["supportedVersions": Self.modernVersions, "capabilities": Self.capabilities,
                             "instructions": MCPTool.instructions, "ttlMs": Self.cacheTime, "cacheScope": "public"])
        case "ping":
            answer(request, [:])
        case "tools/list":
            var result: [String: Any] = ["tools": MCPTool.all.map(\.definition)]
            if request.isModern {
                result["ttlMs"] = Self.cacheTime
                result["cacheScope"] = "public"
            }
            answer(request, result)
        case "tools/call":
            call(request)
        default:
            fail(request.id, code: -32601, "Method not found: \(request.method)")
        }
    }

    private func call(_ request: Request) {
        guard let name = request.params["name"] as? String, let tool = MCPTool.named(name) else {
            return fail(request.id, code: -32602, "Unknown tool: \(request.params["name"].map { "\($0)" } ?? "no name given")")
        }
        guard let arguments = (request.params["arguments"] ?? [String: Any]()) as? [String: Any] else {
            return fail(request.id, code: -32602, "A tool's arguments must be an object.")
        }
        let key = Self.key(request.id)
        let cancellation = ControlCancellation()
        lock.withLock { calls[key] = cancellation }
        let token = (request.params["_meta"] as? [String: Any])?["progressToken"]
        DispatchQueue.global(qos: .userInitiated).async(group: running) { [self] in
            var reported = 0.0
            let progress: ((Double) -> Void)? = token.map { token in
                { [self] value in
                    // Whole percents, always increasing, and nothing once the call is cancelled.
                    let value = min(1, (value * 100).rounded(.down) / 100)
                    guard value > reported, !cancellation.isCancelled else { return }
                    reported = value
                    var params: [String: Any] = ["progressToken": token, "progress": value, "total": 1]
                    if let activity = tool.activity { params["message"] = "\(activity)… \(Int(value * 100))%" }
                    send(["jsonrpc": "2.0", "method": "notifications/progress", "params": params])
                }
            }
            let result = tool.call(arguments, MCPContext(socketURL: socketURL, progress: progress, cancellation: cancellation))
            let cancelled = lock.withLock {
                calls[key] = nil
                return cancellation.isCancelled
            }
            if !cancelled { answer(request, result) }
        }
    }

    private func notified(_ method: String, _ params: [String: Any]) {
        guard method == "notifications/cancelled", let id = params["requestId"] else { return }
        lock.withLock { calls[Self.key(id)] }?.cancel()
    }

    private func answer(_ request: Request, _ result: [String: Any]) {
        var result = result
        if request.isModern {
            result["resultType"] = "complete"
            result["_meta"] = [Self.serverInfoKey: Self.serverInfo]
        }
        send(["jsonrpc": "2.0", "id": request.id, "result": result])
    }

    private func fail(_ id: Any?, code: Int, _ message: String, data: Any? = nil) {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error])
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        writeLock.withLock { write(data) }
    }

    /// A request ID as written, so "7" and 7 stay different.
    private static func key(_ id: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed)).map { String(decoding: $0, as: UTF8.self) } ?? "\(id)"
    }

    private static let capabilities: [String: Any] = ["tools": ["listChanged": false]]

    private static var serverInfo: [String: Any] {
        ["name": "ownrecord", "title": "OwnRecord",
         "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"]
    }
}
