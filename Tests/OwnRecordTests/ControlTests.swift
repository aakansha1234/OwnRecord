import Foundation
@testable import OwnRecord
import Testing

@Suite struct ControlTests {
    // MARK: Arguments

    @Test func parsesOptionsFlagsAndPositionals() throws {
        let options = try Options(["latest", "--at", "12.5", "--size=800", "-o", "out.png", "--raw", "--threshold", "-45"],
                                  values: ["at", "size", "output", "threshold"], flags: ["raw"])
        #expect(options.positionals == ["latest"])
        #expect(try options.time("at") == 12.5)
        #expect(try options.int("size") == 800)
        #expect(options.string("output") == "out.png")
        #expect(options.flag("raw"))
        #expect(try options.number("threshold") == -45)
        #expect(try options.recording() == "latest")
    }

    @Test func rejectsUnknownOptionsAndMissingValues() {
        #expect(throws: UsageError.self) { try Options(["--nope"], values: [], flags: []) }
        #expect(throws: UsageError.self) { try Options(["--at"], values: ["at"], flags: []) }
        // A flag can't take a value.
        #expect(throws: UsageError.self) { try Options(["--raw=1"], values: [], flags: ["raw"]) }
    }

    @Test func parsesTimes() throws {
        #expect(try Options.time("12.5") == 12.5)
        #expect(try Options.time("12.5s") == 12.5)
        #expect(try Options.time("1:02.5") == 62.5)
        #expect(try Options.time("1:00:01") == 3601)
        #expect(throws: UsageError.self) { try Options.time("soon") }
        #expect(throws: UsageError.self) { try Options.time("-3") }
        #expect(throws: UsageError.self) { try Options.time("1:2:3:4") }
    }

    @Test func parsesRects() throws {
        let options = try Options(["--rect", "0.1, 0.2,0.3,0.4", "--px", "1,2,3"], values: ["rect", "px"])
        #expect(try options.rect("rect") == [0.1, 0.2, 0.3, 0.4])
        #expect(throws: UsageError.self) { try options.rect("px") }
    }

    @Test func runsAsTheToolOnlyWhenAsked() {
        // Started by Finder or with the app's own launch arguments: the app.
        #expect(CommandLineTool.run(["/Applications/OwnRecord.app/Contents/MacOS/OwnRecord"]) == nil)
        #expect(CommandLineTool.run(["/x/OwnRecord", "-NSDocumentRevisionsDebugMode", "YES"]) == nil)
        #expect(CommandLineTool.run(["/x/OwnRecord", CommandLineTool.backgroundLaunchArgument]) == nil)
        // A usage error is reported without contacting the app.
        #expect(CommandLineTool.run(["/usr/local/bin/ownrecord", "cut"]) == 2)
        #expect(CommandLineTool.run(["/x/OwnRecord", "nonsense"]) == 2)
    }

    // MARK: Edits

    @Test func changesSettingsByPath() throws {
        let edit = try EditSettings().setting(["layout.aspect": "portrait", "layout.padding": "0.05",
                                               "camera.mirror": "false", "camera.borderColor.red": "0.5"])
        #expect(edit.layout.aspect == .portrait)
        #expect(edit.layout.padding == 0.05)
        #expect(!edit.camera.mirror)
        #expect(edit.camera.borderColor.red == 0.5)
        #expect(edit.sections.count == 1)
    }

    @Test func rejectsUnknownSettingsAndBadValues() {
        #expect(throws: ControlError.self) { try EditSettings().setting(["layout.aspekt": "portrait"]) }
        #expect(throws: ControlError.self) { try EditSettings().setting(["sections": "[]"]) }
        #expect(throws: ControlError.self) { try EditSettings().setting(["layout.aspect": "wide"]) }
        #expect(throws: ControlError.self) { try EditSettings().setting(["camera.mirror": "maybe"]) }
    }

    @Test func blursAStretchBySplittingThere() {
        var edit = EditSettings()
        edit.split(at: 4, duration: 10)
        let redaction = Redaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let indices = edit.addRedaction(redaction, from: 2, to: 6, duration: 10)
        #expect(edit.sections.map(\.start) == [0, 2, 4, 6])
        #expect(indices == [1, 2])
        #expect(edit.sections.map { $0.redactions.count } == [0, 1, 1, 0])

        var whole = EditSettings()
        whole.split(at: 5, duration: 10)
        #expect(whole.addRedaction(redaction, from: nil, to: nil, duration: 10) == [0, 1])
    }

    @Test func restoresCutSections() {
        var edit = EditSettings()
        edit.cutPauses([2..<4, 6..<8], deleting: true, duration: 10)
        #expect(edit.keptRanges(duration: 10) == [0..<2, 4..<6, 8..<10])
        #expect(edit.restoreSections(overlapping: 3..<3.5, duration: 10) == 1)
        #expect(edit.keptRanges(duration: 10) == [0..<6, 8..<10])
        #expect(edit.restoreSections(overlapping: 0..<1, duration: 10) == 0)
    }

    // MARK: Socket

    private func withServer(_ handler: @escaping ControlServer.Handler,
                            _ body: @Sendable (URL) async throws -> Void) async throws {
        try FileManager.default.createDirectory(at: PipelineTests.scratchRoot, withIntermediateDirectories: true)
        let url = PipelineTests.scratchRoot.appendingPathComponent("control-\(UUID().uuidString.prefix(8)).sock")
        let server = await ControlServer(socketURL: url, handler: handler)
        try await server.start()
        defer { Task { @MainActor in server.stop() } }
        try await body(url)
    }

    @Test func answersRequestsWithProgressAndResults() async throws {
        try await withServer({ command, request, progress in
            let params = try ControlCoding.decoder.decode(ControlRequest<RecordingParams>.self, from: request).params
            progress(0.5)
            guard params.recording != "missing" else { throw ControlError("No recording matches “missing”.") }
            return try ControlCoding.encoder.encode(EditResult(
                message: "\(command) \(params.recording)",
                recording: RecordingInfo(id: UUID(), title: "Demo", createdAt: Date(), duration: 3, videoDuration: 2,
                                         captureMode: .display, source: "Display", width: 4, height: 2, frameRate: 30,
                                         hasCamera: false, audioTracks: [], hasTranscript: false, folder: nil)))
        }) { url in
            let result: EditResult = try await Task.detached {
                try ControlClient.send(.show, RecordingParams(recording: "latest"), socketURL: url)
            }.value
            #expect(result.message == "show latest")
            #expect(result.recording.title == "Demo")

            await #expect(throws: ControlError.self) {
                let _: EditResult = try await Task.detached {
                    try ControlClient.send(.show, RecordingParams(recording: "missing"), socketURL: url)
                }.value
            }
        }
    }

    @Test func cancelsWorkWhenTheToolGoesAway() async throws {
        let cancelled = Flag()
        try await withServer({ _, _, _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.set()
                throw error
            }
            return Data("{}".utf8)
        }) { url in
            let socket = try ControlChannel.connect(to: url)
            ControlChannel.write(Data(#"{"command":"export","params":{}}"#.utf8 + [0x0A]), to: socket)
            try await Task.sleep(for: .milliseconds(200))
            close(socket)
            for _ in 0..<50 where !cancelled.isSet {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(cancelled.isSet)
        }
    }

    @Test func onlyLetsTheOwnerConnect() async throws {
        try await withServer({ _, _, _ in Data("{}".utf8) }) { url in
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)
        }
    }

    @Test func setsSubtitleStylesFromATime() throws {
        var edit = EditSettings()
        try edit.setSubtitleStyle(from: 3, to: 7, duration: 10) { style in
            var settings = EditSettings()
            settings.subtitles = style
            style = try settings.setting(["subtitles.outlineWidth": "0.12", "subtitles.shadow": "false"]).subtitles
        }
        #expect(edit.sections.map(\.start) == [0, 3, 7])
        #expect(edit.sections.map { $0.subtitles?.outlineWidth } == [nil, 0.12, nil])
        #expect(edit.sections[1].subtitles?.shadow == false)
    }

    // MARK: MCP

    private static let modernMeta: [String: Any] = ["io.modelcontextprotocol/protocolVersion": "2026-07-28",
                                                    "io.modelcontextprotocol/clientCapabilities": [String: Any]()]

    @Test func mcpAnswersBothHandshakes() async throws {
        let output = Messages()
        let server = MCPServer(socketURL: URL(fileURLWithPath: "/nonexistent.sock"), write: output.append)
        server.receive(Self.message(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any]()]))
        let legacy = try await output.result(1)
        #expect(legacy["protocolVersion"] as? String == "2025-06-18")
        #expect((legacy["serverInfo"] as? [String: Any])?["name"] as? String == "ownrecord")
        #expect(legacy["resultType"] == nil)

        // An unknown version gets the newest one this server knows.
        server.receive(Self.message(2, "initialize", ["protocolVersion": "2099-01-01"]))
        #expect(try await output.result(2)["protocolVersion"] as? String == MCPServer.legacyVersions[0])

        server.receive(Self.message(3, "server/discover", ["_meta": Self.modernMeta]))
        let discovered = try await output.result(3)
        #expect(discovered["supportedVersions"] as? [String] == ["2026-07-28"])
        #expect(discovered["resultType"] as? String == "complete")
        #expect(discovered["ttlMs"] != nil && discovered["cacheScope"] != nil)

        var unsupported = Self.modernMeta
        unsupported["io.modelcontextprotocol/protocolVersion"] = "1999-01-01"
        server.receive(Self.message(4, "tools/list", ["_meta": unsupported]))
        let error = try await output.error(4)
        #expect(error["code"] as? Int == -32022)

        server.receive(Self.message(5, "resources/list", [:]))
        #expect(try await output.error(5)["code"] as? Int == -32601)
        server.receive(Data("not json".utf8))
        #expect(output.all.contains { ($0["error"] as? [String: Any])?["code"] as? Int == -32700 })
    }

    @Test func mcpListsWellFormedTools() async throws {
        let output = Messages()
        let server = MCPServer(socketURL: URL(fileURLWithPath: "/nonexistent.sock"), write: output.append)
        server.receive(Self.message(1, "tools/list", ["_meta": Self.modernMeta]))
        let result = try await output.result(1)
        let tools = try #require(result["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        #expect(Set(names).count == tools.count)
        #expect(names.allSatisfy { $0.range(of: "^[a-z_]{1,64}$", options: .regularExpression) != nil })
        for tool in tools {
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect((tool["description"] as? String)?.isEmpty == false)
        }
        let destructive = tools.filter { (($0["annotations"] as? [String: Any])?["destructiveHint"] as? Bool) == true }
            .compactMap { $0["name"] as? String }
        #expect(Set(destructive) == ["discard_recording", "delete_recording", "transcribe"])
        #expect(result["cacheScope"] as? String == "public")
    }

    @Test func mcpCallsToolsThroughTheApp() async throws {
        let requests = Messages()
        try await withServer({ command, request, progress in
            requests.append(Data(#"{"command":"\#(command)","request":"# .utf8) + request + Data("}".utf8))
            if command == "transcribe" {
                for value in [0.25, 0.5, 0.5, 1] { progress(value) }
            }
            if command == "list" { throw ControlError("No recording matches “x”. Run `ownrecord list` to see them.") }
            return try ControlCoding.encoder.encode(EditResult(
                message: "\(command) done.",
                recording: RecordingInfo(id: UUID(), title: "Demo", createdAt: Date(), duration: 3, videoDuration: 2,
                                         captureMode: .display, source: "Display", width: 4, height: 2, frameRate: 30,
                                         hasCamera: false, audioTracks: [], hasTranscript: true, folder: nil)))
        }) { url in
            let output = Messages()
            let server = MCPServer(socketURL: url, write: output.append)
            server.receive(Self.message(1, "tools/call", ["name": "edit_recording", "arguments": [
                "recording": "latest", "cut": [[1, 2]],
                "settings": ["subtitles.outlineWidth": 0.12, "subtitles.shadow": false], "settings_from": 30,
            ]]))
            let edited = try await output.result(1)
            #expect(edited["isError"] == nil)
            #expect(Self.text(edited).hasPrefix("cut done. set done."))
            let sent = requests.all.map { $0["command"] as? String }
            #expect(sent == ["cut", "set"])
            let set = try #require((requests.all.last?["request"] as? [String: Any])?["params"] as? [String: Any])
            #expect(set["from"] as? Double == 30)
            #expect(set["values"] as? [String: String] == ["subtitles.outlineWidth": "0.12", "subtitles.shadow": "false"])

            // Progress is reported while it runs, increasing, before the answer.
            server.receive(Self.message(2, "tools/call", ["name": "transcribe", "arguments": ["recording": "latest"],
                                                          "_meta": ["progressToken": "t"]]))
            _ = try await output.result(2)
            let reports = output.all.filter { $0["method"] as? String == "notifications/progress" }
                .compactMap { ($0["params"] as? [String: Any])?["progress"] as? Double }
            #expect(reports == [0.25, 0.5, 1])
            let answer = try #require(output.all.firstIndex { $0["id"] as? Int == 2 })
            #expect(output.all.lastIndex { $0["method"] as? String == "notifications/progress" }! < answer)

            // The app's failures come back as tool errors, naming tools instead of commands.
            server.receive(Self.message(3, "tools/call", ["name": "list_recordings", "arguments": [String: Any]()]))
            let failed = try await output.result(3)
            #expect(failed["isError"] as? Bool == true)
            #expect(Self.text(failed) == "No recording matches “x”. list_recordings lists them.")

            server.receive(Self.message(4, "tools/call", ["name": "get_frame", "arguments": ["recording": "latest", "when": 3]]))
            #expect(Self.text(try await output.result(4)).hasPrefix("There's no argument “when”."))
            server.receive(Self.message(5, "tools/call", ["name": "no_such_tool"]))
            #expect(try await output.error(5)["code"] as? Int == -32602)
        }
    }

    @Test func mcpCancelsCallsInTheApp() async throws {
        let cancelled = Flag()
        try await withServer({ _, _, _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.set()
                throw error
            }
            return Data("{}".utf8)
        }) { url in
            let output = Messages()
            let server = MCPServer(socketURL: url, write: output.append)
            server.receive(Self.message("slow", "tools/call", ["name": "export_video", "arguments": ["recording": "latest"]]))
            try await Task.sleep(for: .milliseconds(200))
            server.receive(try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": "slow"],
            ]))
            for _ in 0..<50 where !cancelled.isSet {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(cancelled.isSet)
            try await Task.sleep(for: .milliseconds(200))
            #expect(output.all.isEmpty)
        }
    }

    private static func message(_ id: Any, _ method: String, _ params: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private static func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }
}

/// JSON messages written by a server under test.
private final class Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [[String: Any]] = []

    var all: [[String: Any]] { lock.withLock { messages } }

    func append(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lock.withLock { messages.append(message) }
    }

    func result(_ id: Int) async throws -> [String: Any] {
        try #require(try await response(id)["result"] as? [String: Any])
    }

    func error(_ id: Int) async throws -> [String: Any] {
        try #require(try await response(id)["error"] as? [String: Any])
    }

    private func response(_ id: Int) async throws -> [String: Any] {
        for _ in 0..<250 {
            if let message = all.first(where: { $0["id"] as? Int == id }) { return message }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ControlError("No answer to request \(id).")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}
