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
        #expect(edit.keptRanges(duration: 10, applyingTrim: true) == [0..<2, 4..<6, 8..<10])
        #expect(edit.restoreSections(overlapping: 3..<3.5, duration: 10) == 1)
        #expect(edit.keptRanges(duration: 10, applyingTrim: true) == [0..<6, 8..<10])
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
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}
