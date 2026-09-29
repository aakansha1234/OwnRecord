import AppKit
import Darwin

/// `ownrecord`: controls OwnRecord from a terminal, scripts and AI agents. It's the app's own
/// executable started under that name (or with a command as its first argument). Each command
/// is a request to the running app (see `ControlChannel`), which is started if needed.
enum CommandLineTool {
    /// Passed when the tool starts the app, so it starts without showing the library.
    static let backgroundLaunchArgument = "--background"

    /// Runs the tool if the process was started as it, returning its exit status; nil to start the app.
    static func run(_ arguments: [String]) -> Int32? {
        let name = URL(fileURLWithPath: arguments.first ?? "").lastPathComponent
        let rest = Array(arguments.dropFirst())
        // The app's own launch arguments start with "-" (e.g. -NSDocumentRevisionsDebugMode).
        guard name == "ownrecord" || rest.first.map({ !$0.hasPrefix("-") }) == true else { return nil }
        return execute(rest)
    }

    static func execute(_ arguments: [String]) -> Int32 {
        var arguments = arguments
        let json = arguments.contains("--json")
        arguments.removeAll { $0 == "--json" }
        guard let name = arguments.first, !["help", "--help", "-h"].contains(name) else {
            let topic = arguments.dropFirst().first
            if let topic, ToolCommand.named(topic) == nil {
                printError("ownrecord: there's no command “\(topic)”. Run `ownrecord help` to see them.")
                return 2
            }
            print(topic.flatMap(ToolCommand.named)?.help ?? ToolCommand.overview)
            return 0
        }
        guard let command = ToolCommand.named(name) else {
            printError("ownrecord: there's no command “\(name)”. Run `ownrecord help` to see them.")
            return 2
        }
        if arguments.contains("--help") || arguments.contains("-h") {
            print(command.help)
            return 0
        }
        do {
            let options = try Options(Array(arguments.dropFirst()), values: command.values, flags: command.flags)
            try command.run(options, Output(json: json))
            return 0
        } catch let error as UsageError {
            printError("ownrecord \(name): \(error.message)\nRun `ownrecord help \(name)` to see how to use it.")
            return 2
        } catch {
            printError("ownrecord: \(error.localizedDescription)")
            return 1
        }
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

// MARK: - Talking to the app

enum ControlClient {
    /// Sends one request to the app and waits for its answer.
    /// - Parameters:
    ///   - activity: Shown with the progress (in a terminal), e.g. "Exporting".
    ///   - progress: Called with the app's progress reports, from 0 to 1.
    ///   - cancellation: Lets another thread abandon the request, which cancels it in the app.
    static func send<Params: Encodable, Result: Decodable>(_ command: ControlCommand, _ params: Params,
                                                           activity: String? = nil,
                                                           progress: ((Double) -> Void)? = nil,
                                                           cancellation: ControlCancellation? = nil,
                                                           socketURL: URL = ControlChannel.socketURL) throws -> Result {
        let socket = socketURL == ControlChannel.socketURL ? try connectToApp() : try ControlChannel.connect(to: socketURL)
        defer {
            cancellation?.detach()
            close(socket)
        }
        try cancellation?.attach(socket)
        var request = try ControlCoding.encoder.encode(ControlRequest(command: command.rawValue, params: params))
        request.append(0x0A)
        guard ControlChannel.write(request, to: socket) else { throw ControlError("Couldn't reach OwnRecord.") }
        let meter = activity.map(ProgressMeter.init)
        defer { meter?.finish() }
        var reader = LineReader(socket: socket)
        while let line = try reader.next() {
            let message: ControlMessage<Result>
            do {
                message = try ControlCoding.decoder.decode(ControlMessage<Result>.self, from: line)
            } catch {
                throw ControlError("OwnRecord's answer couldn't be read. If you just updated OwnRecord, quit and reopen it.")
            }
            if let error = message.error { throw ControlError(error) }
            if let result = message.result { return result }
            if let value = message.progress {
                meter?.update(value)
                progress?(value)
            }
        }
        if cancellation?.isCancelled == true { throw CancellationError() }
        throw ControlError("OwnRecord stopped answering. It may have quit.")
    }

    /// Connects to the app, starting it if it isn't running.
    private static func connectToApp() throws -> Int32 {
        if let socket = try? ControlChannel.connect(to: ControlChannel.socketURL) { return socket }
        guard isAllowed else {
            throw ControlError("OwnRecord doesn't take commands yet. Turn on “Allow control from the command line and AI apps” in OwnRecord › Settings.")
        }
        let isRunning = NSRunningApplication.runningApplications(withBundleIdentifier: ControlChannel.bundleIdentifier)
            .contains { $0.processIdentifier != getpid() }
        if !isRunning { try launchApp() }
        let deadline = Date().addingTimeInterval(isRunning ? 3 : 20)
        repeat {
            usleep(100_000)
            if let socket = try? ControlChannel.connect(to: ControlChannel.socketURL) { return socket }
        } while Date() < deadline
        throw ControlError(isRunning
            ? "OwnRecord is running but doesn't answer. If you just updated it, quit and reopen OwnRecord."
            : "OwnRecord didn't start in time.")
    }

    private static var isAllowed: Bool {
        let app = ControlChannel.bundleIdentifier as CFString
        CFPreferencesAppSynchronize(app)
        return CFPreferencesCopyAppValue(ControlChannel.preferenceKey as CFString, app) as? Bool ?? false
    }

    private static func launchApp() throws {
        guard let appURL = enclosingApp ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: ControlChannel.bundleIdentifier)
        else { throw ControlError("Couldn't find OwnRecord.app.") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = [CommandLineTool.backgroundLaunchArgument]
        final class Outcome: @unchecked Sendable { var error: Error? }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            outcome.error = error
            done.signal()
        }
        done.wait()
        if let error = outcome.error { throw error }
    }

    /// The app this executable is part of (also when started through a link to it).
    private static var enclosingApp: URL? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var path = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&path, &size) == 0 else { return nil }
        let app = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }
}

/// Abandons a request from another thread: closing the connection makes the app cancel its work.
final class ControlCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: Int32?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let socket { shutdown(socket, SHUT_RDWR) }
        }
    }

    fileprivate func attach(_ socket: Int32) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            self.socket = socket
        }
    }

    /// Before the socket is closed, so a later cancel can't hit a reused descriptor.
    fileprivate func detach() {
        lock.withLock { socket = nil }
    }
}

/// Progress on standard error, only in a terminal (agents and scripts don't need it).
private final class ProgressMeter {
    private let activity: String
    private let isTerminal = isatty(STDERR_FILENO) != 0
    private var shown = -1

    init(activity: String) {
        self.activity = activity
    }

    func update(_ progress: Double) {
        let percent = Int((progress * 100).rounded(.down)).clamped(to: 0...100)
        guard isTerminal, percent != shown else { return }
        shown = percent
        FileHandle.standardError.write(Data("\r\(activity)… \(percent)%".utf8))
    }

    func finish() {
        guard isTerminal, shown >= 0 else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
    }
}

// MARK: - Arguments

struct UsageError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// A command's arguments: positional ones, `--name value` (or `--name=value`) and `--flag`.
struct Options {
    private(set) var positionals: [String] = []
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    static let aliases = ["o": "output", "microphone": "mic"]

    init(_ arguments: [String], values valueNames: Set<String> = [], flags flagNames: Set<String> = []) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                positionals += arguments[index...]
                break
            }
            guard argument.hasPrefix("-"), argument.count > 1, Double(argument) == nil else {
                positionals.append(argument)
                continue
            }
            var name = String(argument.drop { $0 == "-" })
            var inline: String?
            if let equals = name.firstIndex(of: "=") {
                inline = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            name = Self.aliases[name] ?? name
            if valueNames.contains(name) {
                guard let value = inline ?? (index < arguments.count ? arguments[index] : nil) else {
                    throw UsageError("--\(name) needs a value.")
                }
                if inline == nil { index += 1 }
                values[name] = value
            } else if flagNames.contains(name), inline == nil {
                flags.insert(name)
            } else {
                throw UsageError("There's no option \(argument.split(separator: "=")[0]).")
            }
        }
    }

    func string(_ name: String) -> String? { values[name] }

    func flag(_ name: String) -> Bool { flags.contains(name) }

    /// The recording argument (the first positional one).
    func recording() throws -> String {
        guard let reference = positionals.first else {
            throw UsageError("Name a recording: its ID (or the start of it), title, or “latest”.")
        }
        // A folder given relative to the current directory.
        return reference.contains("/") ? URL(fileURLWithPath: (reference as NSString).expandingTildeInPath).path : reference
    }

    func positional(_ index: Int, _ name: String) throws -> String {
        guard positionals.indices.contains(index) else { throw UsageError("Give the \(name).") }
        return positionals[index]
    }

    func expectPositionals(atMost count: Int) throws {
        if positionals.count > count { throw UsageError("Didn't expect “\(positionals[count])”.") }
    }

    func int(_ name: String) throws -> Int? {
        try values[name].map { text in
            guard let value = Int(text) else { throw UsageError("--\(name) takes a whole number, not “\(text)”.") }
            return value
        }
    }

    func number(_ name: String) throws -> Double? {
        try values[name].map { text in
            guard let value = Double(text), value.isFinite else { throw UsageError("--\(name) takes a number, not “\(text)”.") }
            return value
        }
    }

    func time(_ name: String) throws -> Double? {
        try values[name].map(Self.time)
    }

    /// x,y,width,height.
    func rect(_ name: String) throws -> [Double]? {
        try values[name].map { text in
            let numbers = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 4, numbers.allSatisfy({ $0?.isFinite == true }) else {
                throw UsageError("--\(name) takes x,y,width,height, e.g. 0.1,0.2,0.3,0.05.")
            }
            return numbers.compactMap { $0 }
        }
    }

    func choice<Value>(_ name: String, _ choices: [String: Value]) throws -> Value? {
        try values[name].map { text in
            guard let value = choices[text.lowercased()] else {
                throw UsageError("--\(name) takes \(choices.keys.sorted().joined(separator: ", ")), not “\(text)”.")
            }
            return value
        }
    }

    /// Seconds ("12.5", "12.5s") or minutes:seconds ("1:02.5") or hours:minutes:seconds.
    static func time(_ text: String) throws -> Double {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("s") { trimmed.removeLast() }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        var seconds = 0.0
        for part in parts {
            guard parts.count <= 3, let value = Double(part), value >= 0, value.isFinite else {
                throw UsageError("“\(text)” isn't a time. Use seconds (12.5) or minutes:seconds (1:02.5).")
            }
            seconds = seconds * 60 + value
        }
        return seconds
    }
}

// MARK: - Output

struct Output {
    let json: Bool

    /// Prints the result as JSON with --json, else as text.
    func emit<Result: Encodable>(_ result: Result, _ text: (Result) -> String) {
        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(result) { print(String(decoding: data, as: UTF8.self)) }
        } else {
            let text = text(result)
            if !text.isEmpty { print(text) }
        }
    }
}

private enum Report {
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func path(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func features(_ recording: RecordingInfo) -> String {
        var features: [String] = []
        if recording.hasCamera { features.append("camera") }
        if recording.audioTracks.contains(.microphone) { features.append("mic") }
        if recording.audioTracks.contains(.system) { features.append("system audio") }
        if recording.hasTranscript { features.append("subtitles") }
        return features.joined(separator: ", ")
    }

    static func lengths(_ recording: RecordingInfo) -> String {
        let video = abs(recording.videoDuration - recording.duration) < 0.005
            ? "" : ", \(ControlFormat.seconds(recording.videoDuration)) in the video"
        return ControlFormat.seconds(recording.duration) + " recorded" + video
    }

    static func saved(_ recording: RecordingInfo) -> String {
        """
        Saved “\(recording.title)” (\(ControlFormat.seconds(recording.duration))).
          ID      \(recording.id.uuidString.lowercased())
          Folder  \(recording.folder.map(path) ?? "")
        """
    }

    static func status(_ status: StatusInfo) -> String {
        var state = status.state
        if let countdown = status.countdown { state += " \(countdown)" }
        if let elapsed = status.elapsed { state += " (\(ControlFormat.seconds(elapsed)))" }
        let missing = status.permissions.filter { $0.value != "granted" }.keys.sorted()
        var lines = ["OwnRecord \(status.version): \(state)",
                     "\(status.recordingCount) recordings in \(path(status.recordingsFolder))"]
        if !missing.isEmpty { lines.append("Not allowed yet: \(missing.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    static func details(_ details: RecordingDetails) -> String {
        let recording = details.recording
        let source = "\(recording.captureMode.title) · \(recording.source) · \(recording.width) × \(recording.height) · \(recording.frameRate) fps"
        let audio = recording.audioTracks.map { $0 == .system ? "system" : "microphone" }.joined(separator: ", ")
        let subtitles = details.subtitleCount.map { "\($0) (\(details.transcriptLocale ?? ""))" }
            ?? "none (ownrecord transcribe \(ControlFormat.shortID(recording.id)))"
        let trim = details.trimStart == 0 && details.trimEnd == nil
            ? "none" : ControlFormat.span(details.trimStart..<(details.trimEnd ?? recording.duration))
        var lines = [
            recording.title,
            "  ID         \(recording.id.uuidString.lowercased())",
            "  Created    \(dateFormatter.string(from: recording.createdAt))",
            "  Source     \(source)",
            "  Length     \(lengths(recording))",
            "  Camera     \(recording.hasCamera ? "yes" : "no")",
            "  Audio      \(audio.isEmpty ? "none" : audio)",
            "  Subtitles  \(subtitles)",
            "  Trim       \(trim)",
            "  Folder     \(recording.folder.map(path) ?? "")",
            "",
            "Sections (recording time → video time):",
        ]
        for section in details.sections {
            var notes: [String] = []
            if !section.showsScreen { notes.append("screen hidden") }
            if !section.showsCamera, recording.hasCamera { notes.append("camera hidden") }
            if section.muted { notes.append("muted") }
            if section.subtitles != nil { notes.append("own subtitle style") }
            let played = section.deleted ? "cut"
                : section.videoStart.map { "→ " + ControlFormat.span($0..<(section.videoEnd ?? $0)) } ?? "trimmed"
            let span = ControlFormat.span(section.start..<section.end)
            lines.append("  \(section.number)  \(span.padding(toLength: max(16, span.count), withPad: " ", startingAt: 0))  \(played)"
                         + (notes.isEmpty ? "" : "  (\(notes.joined(separator: ", ")))"))
            for blur in section.blurs {
                let rect = blur.rect.map(ControlFormat.number).joined(separator: ",")
                lines.append("       \(blur.style.rawValue) \(ControlFormat.shortID(blur.id)) at \(rect)")
            }
        }
        lines.append("")
        lines.append("Layout, camera, subtitle and audio settings: ownrecord show \(ControlFormat.shortID(recording.id)) --json")
        return lines.joined(separator: "\n")
    }
}

/// Moves files the app staged (see `ControlChannel.stagingRoot`) to where they were asked for.
enum Delivery {
    /// The output path the user gave, made absolute.
    static func destination(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    static func checkFree(_ url: URL, force: Bool) throws {
        if !force, FileManager.default.fileExists(atPath: url.path) {
            throw ControlError("\(url.path) already exists. Add --force to replace it.")
        }
    }

    /// A name in `folder` (default: the current directory) that's not taken: "Demo.mp4", else "Demo 2.mp4", …
    static func freeURL(named name: String, extension pathExtension: String,
                        in folder: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> URL {
        func url(_ suffix: String) -> URL {
            let file = folder.appendingPathComponent(name + suffix)
            return pathExtension.isEmpty ? file : file.appendingPathExtension(pathExtension)
        }
        var candidate = url("")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url(" \(number)")
            number += 1
        }
        return candidate
    }

    static func move(_ staged: String, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: URL(fileURLWithPath: staged), to: destination)
    }

    /// Moves an export into place: to `destination`, else named after the recording in `folder`.
    /// Returns where the files went.
    static func deliverExport(_ result: FilesResult, format: ExportFormat, to destination: URL?, folder: URL) throws -> [String] {
        let name = result.name ?? "Recording"
        var delivered: [String] = []
        if format == .imovie {
            let target = destination ?? freeURL(named: "\(name) for iMovie", extension: "", in: folder)
            for file in result.files {
                let fileTarget = target.appendingPathComponent(URL(fileURLWithPath: file).lastPathComponent)
                try move(file, to: fileTarget)
                delivered.append(fileTarget.path)
            }
        } else {
            let target = destination ?? freeURL(named: name, extension: format.fileExtension, in: folder)
            for file in result.files {
                let fileTarget = URL(fileURLWithPath: file).pathExtension == "srt"
                    ? target.deletingPathExtension().appendingPathExtension("srt") : target
                try move(file, to: fileTarget)
                delivered.append(fileTarget.path)
            }
        }
        return delivered
    }

    /// Removes the staging folders of `files` (and anything not moved out of them).
    static func cleanUp(_ files: [String]) {
        // The app's temporary folder can differ from this process's (TMPDIR), so go by the names.
        for folder in Set(files.map { URL(fileURLWithPath: $0).deletingLastPathComponent() })
        where UUID(uuidString: folder.lastPathComponent) != nil
            && folder.deletingLastPathComponent().lastPathComponent == ControlChannel.stagingRoot.lastPathComponent {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

// MARK: - Commands

struct ToolCommand {
    let name: String
    let summary: String
    let usage: String
    let details: String
    var values: Set<String> = []
    var flags: Set<String> = []
    let run: (Options, Output) throws -> Void

    var help: String {
        "Usage: \(usage)\n\n\(details)"
    }

    static func named(_ name: String) -> ToolCommand? {
        all.first { $0.name == name }
    }

    static var overview: String {
        func rows(_ names: [String]) -> String {
            names.compactMap(named).map { "  \($0.name.padding(toLength: 12, withPad: " ", startingAt: 0))\($0.summary)" }
                .joined(separator: "\n")
        }
        return """
        ownrecord: record, edit and export with OwnRecord from the terminal, scripts and AI agents.

        Usage: ownrecord <command> [arguments] [--json]

        Recording
        \(rows(["record", "stop", "wait", "pause", "resume", "discard", "status", "sources"]))

        Library
        \(rows(["list", "show", "open", "rename", "delete"]))

        Editing (when the recording is open in the editor, ⌘Z undoes these there)
        \(rows(["trim", "cut", "restore", "silences", "blur", "unblur", "set", "transcribe", "transcript"]))

        Output
        \(rows(["frame", "export"]))

        AI apps
        \(rows(["mcp"]))

        Recordings are named by ID (or its start, e.g. 4f3a2b1c), title, folder, or "latest".
        Times are in the original recording, as `show` and `transcript` print them, so they don't
        shift as you cut: seconds (12.5) or minutes:seconds (1:02.5).
        --json prints any result as JSON. `ownrecord help <command>` explains a command.

        Typical session:
          ownrecord record --window Simulator --countdown 0 --duration 20 --wait
          ownrecord transcribe latest && ownrecord transcript latest
          ownrecord cut latest 4.2 6.8
          ownrecord silences latest --delete
          ownrecord frame latest --at 10 -o check.png
          ownrecord export latest -o demo.mp4

        OwnRecord has to allow this first: Settings › Command Line & AI Apps. The app does the work
        (and is started if it isn't running), so recording uses its Screen Recording permission, and
        recordings it starts show the usual controls.
        """
    }

    static let all: [ToolCommand] = [
        // Recording
        ToolCommand(
            name: "record", summary: "Start recording the screen, a window or an area",
            usage: "ownrecord record [--window <app, title or ID> | --area <x,y,w,h>] [--display <name or ID>]\n"
                + "                        [--camera <name, ID or none>] [--mic <name, ID or none>] [--system-audio | --no-system-audio]\n"
                + "                        [--countdown <seconds>] [--duration <seconds>] [--wait]",
            details: """
            Starts recording and returns once it's rolling (after the countdown). Without --window or
            --area it records the whole screen. The usual recording controls and menu bar timer show
            while recording, and the user can stop it too.

            The camera, microphone and system audio default to what's chosen in the recorder. What you
            choose here is only for this recording.

              --window <…>       A window by ID, or by app name or title (see `ownrecord sources`)
              --area <x,y,w,h>   An area in points from the display's top-left corner
              --display <…>      The display to record (or put the area on); default: the main one
              --camera <…>       A camera by name or ID, or none
              --mic <…>          A microphone by name or ID, default, or none
              --system-audio, --no-system-audio
              --countdown <s>    Seconds of countdown; default: as set in Settings
              --duration <s>     Stop by itself after this much recording (pauses don't count)
              --wait             Return when the recording ends, and print the saved recording

            Examples:
              ownrecord record --window Safari --countdown 0 --duration 30 --wait
              ownrecord record --area 0,0,1280,720 --camera none --mic default
            """,
            values: ["window", "area", "display", "camera", "mic", "countdown", "duration"],
            flags: ["system-audio", "no-system-audio", "wait"]
        ) { options, output in
            try options.expectPositionals(atMost: 0)
            if options.flag("system-audio"), options.flag("no-system-audio") {
                throw UsageError("Choose --system-audio or --no-system-audio.")
            }
            let params = RecordParams(
                display: options.string("display"), window: options.string("window"), area: try options.rect("area"),
                camera: options.string("camera"), microphone: options.string("mic"),
                systemAudio: options.flag("system-audio") ? true : options.flag("no-system-audio") ? false : nil,
                countdown: try options.int("countdown"), duration: try options.time("duration"), wait: options.flag("wait"))
            let result: RecordResult = try ControlClient.send(.record, params)
            output.emit(result) { result in
                if let recording = result.recording { return Report.saved(recording) }
                return params.duration.map {
                    "Recording. It stops by itself after \(ControlFormat.seconds($0)); `ownrecord wait` waits for it, `ownrecord stop` stops it now."
                } ?? "Recording. Stop it with `ownrecord stop`."
            }
        },
        ToolCommand(
            name: "stop", summary: "Stop recording and save",
            usage: "ownrecord stop [--open]",
            details: """
            Stops the recording and saves it, then prints the saved recording.

              --open   Open it in the editor
            """,
            flags: ["open"]
        ) { options, output in
            try options.expectPositionals(atMost: 0)
            let result: RecordResult = try ControlClient.send(.stop, StopParams(open: options.flag("open")))
            output.emit(result) { $0.recording.map(Report.saved) ?? "" }
        },
        ToolCommand(
            name: "wait", summary: "Wait for the recording to end",
            usage: "ownrecord wait",
            details: "Waits until the recording in progress ends (stopped, or after its --duration) and prints the saved recording."
        ) { options, output in
            try options.expectPositionals(atMost: 0)
            let result: RecordResult = try ControlClient.send(.wait, NoParams())
            output.emit(result) { $0.recording.map(Report.saved) ?? "" }
        },
        ToolCommand(
            name: "pause", summary: "Pause recording",
            usage: "ownrecord pause", details: "Pauses the recording. The pause is left out of the video."
        ) { options, output in
            try options.expectPositionals(atMost: 0)
            let status: StatusInfo = try ControlClient.send(.pause, NoParams())
            output.emit(status, Report.status)
        },
        ToolCommand(
            name: "resume", summary: "Resume recording",
            usage: "ownrecord resume", details: "Resumes a paused recording."
        ) { options, output in
            try options.expectPositionals(atMost: 0)
            let status: StatusInfo = try ControlClient.send(.resume, NoParams())
            output.emit(status, Report.status)
        },
        ToolCommand(
            name: "discard", summary: "Throw away the recording in progress",
            usage: "ownrecord discard", details: "Stops the recording (or its countdown) without saving it."
        ) { options, output in
            try options.expectPositionals(atMost: 0)
            let status: StatusInfo = try ControlClient.send(.discard, NoParams())
            output.emit(status) { _ in "Discarded the recording." }
        },
        ToolCommand(
            name: "status", summary: "What OwnRecord is doing",
            usage: "ownrecord status",
            details: "Prints whether OwnRecord is recording (idle, starting, countdown, recording, paused or saving), for how long, and which permissions are missing."
        ) { options, output in
            try options.expectPositionals(atMost: 0)
            let status: StatusInfo = try ControlClient.send(.status, NoParams())
            output.emit(status, Report.status)
        },
        ToolCommand(
            name: "sources", summary: "Displays, windows, cameras and microphones",
            usage: "ownrecord sources",
            details: "Lists what `ownrecord record` can record, with IDs: displays, windows, cameras and microphones (* marks the recorder's choice)."
        ) { options, output in
            try options.expectPositionals(atMost: 0)
            let sources: SourcesInfo = try ControlClient.send(.sources, NoParams())
            output.emit(sources) { sources in
                var lines = ["Displays"]
                lines += sources.displays.map {
                    "  \($0.id)  \($0.name)  \($0.width) × \($0.height) points (\($0.pixelWidth) × \($0.pixelHeight) pixels)\($0.isMain ? "  main" : "")"
                }
                lines += ["", "Windows"]
                lines += sources.windows.map {
                    "  \(String($0.id).padding(toLength: max(7, String($0.id).count + 2), withPad: " ", startingAt: 0))\($0.app)\($0.title.isEmpty ? "" : " — \($0.title)")  \($0.width) × \($0.height)"
                }
                for (title, devices) in [("Cameras", sources.cameras), ("Microphones", sources.microphones)] {
                    lines += ["", title]
                    lines += devices.map { "  \($0.isSelected ? "*" : " ") \($0.name)  (\($0.id))" }
                }
                lines += ["", "System audio: \(sources.systemAudio ? "on" : "off")"]
                return lines.joined(separator: "\n")
            }
        },

        // Library
        ToolCommand(
            name: "list", summary: "Recordings, newest first",
            usage: "ownrecord list [<search>] [--limit <count>]",
            details: """
            Lists recordings, newest first. A search matches titles, sources and transcripts.

              --search <text>   The same as giving the search as an argument
              --limit <n>       Only the newest n
            """,
            values: ["limit", "search"]
        ) { options, output in
            try options.expectPositionals(atMost: 1)
            let search = options.string("search") ?? options.positionals.first
            let recordings: [RecordingInfo] = try ControlClient.send(.list, ListParams(search: search,
                                                                                      limit: try options.int("limit")))
            output.emit(recordings) { recordings in
                guard !recordings.isEmpty else { return "No recordings." }
                return recordings.map { recording in
                    let length = String(format: "%7.1fs", recording.videoDuration)
                    let features = Report.features(recording)
                    return "\(ControlFormat.shortID(recording.id))  \(Report.dateFormatter.string(from: recording.createdAt))  \(length)  \(recording.title)"
                        + (features.isEmpty ? "" : "  (\(features))")
                }.joined(separator: "\n")
            }
        },
        ToolCommand(
            name: "show", summary: "A recording's details, sections and settings",
            usage: "ownrecord show <recording> [--json]",
            details: "Prints a recording's details, its sections (with cuts and blurred areas) and where it's stored. With --json, also every layout, camera, subtitle and audio setting (see `ownrecord help set`)."
        ) { options, output in
            try options.expectPositionals(atMost: 1)
            let details: RecordingDetails = try ControlClient.send(.show, RecordingParams(recording: try options.recording()))
            output.emit(details, Report.details)
        },
        ToolCommand(
            name: "open", summary: "Open a recording in the editor",
            usage: "ownrecord open <recording>",
            details: "Opens the recording in OwnRecord's editor and brings OwnRecord to the front."
        ) { options, output in
            try options.expectPositionals(atMost: 1)
            let result: EditResult = try ControlClient.send(.open, RecordingParams(recording: try options.recording()))
            output.emit(result) { $0.message }
        },
        ToolCommand(
            name: "rename", summary: "Rename a recording",
            usage: "ownrecord rename <recording> <title>",
            details: "Gives the recording a new title (also used for exported file names)."
        ) { options, output in
            try options.expectPositionals(atMost: 2)
            let params = RenameParams(recording: try options.recording(), title: try options.positional(1, "new title"))
            let result: EditResult = try ControlClient.send(.rename, params)
            output.emit(result) { $0.message }
        },
        ToolCommand(
            name: "delete", summary: "Move a recording to the Trash",
            usage: "ownrecord delete <recording>",
            details: "Moves the recording's folder to the Trash (it can be put back from there)."
        ) { options, output in
            try options.expectPositionals(atMost: 1)
            let result: EditResult = try ControlClient.send(.delete, RecordingParams(recording: try options.recording()))
            output.emit(result) { $0.message }
        },

        // Editing
        ToolCommand(
            name: "trim", summary: "Set where the video starts and ends",
            usage: "ownrecord trim <recording> [--start <time>] [--end <time>] [--reset]",
            details: """
            Trims the start and end off the video. The recording itself is kept, so this can be undone.

              --start <time>   Where the video starts (recording time)
              --end <time>     Where it ends
              --reset          No trim (combine with --start or --end to replace the trim)
            """,
            values: ["start", "end"], flags: ["reset"]
        ) { options, output in
            try options.expectPositionals(atMost: 1)
            guard options.string("start") != nil || options.string("end") != nil || options.flag("reset") else {
                throw UsageError("Give --start, --end or --reset.")
            }
            let params = TrimParams(recording: try options.recording(), start: try options.time("start"),
                                    end: try options.time("end"), reset: options.flag("reset"))
            let result: EditResult = try ControlClient.send(.trim, params)
            output.emit(result) { $0.message }
        },
        ToolCommand(
            name: "cut", summary: "Remove a stretch of the recording",
            usage: "ownrecord cut <recording> <from> <to>",
            details: """
            Removes the stretch between two recording times from the video (it splits there and
            deletes the section between). `restore` brings it back.

            Example: ownrecord cut latest 1:02.5 1:07
            """
        ) { options, output in
            try options.expectPositionals(atMost: 3)
            let params = RangeParams(recording: try options.recording(), from: try Options.time(options.positional(1, "start time")),
                                     to: try Options.time(options.positional(2, "end time")))
            let result: EditResult = try ControlClient.send(.cut, params)
            output.emit(result) { $0.message }
        },
        ToolCommand(
            name: "restore", summary: "Bring back cut parts",
            usage: "ownrecord restore <recording> <from> <to>",
            details: "Puts the cut (deleted) sections that overlap this stretch of the recording back into the video."
        ) { options, output in
            try options.expectPositionals(atMost: 3)
            let params = RangeParams(recording: try options.recording(), from: try Options.time(options.positional(1, "start time")),
                                     to: try Options.time(options.positional(2, "end time")))
            let result: EditResult = try ControlClient.send(.restore, params)
            output.emit(result) { $0.message }
        },
        ToolCommand(
            name: "silences", summary: "Find pauses, and split around or remove them",
            usage: "ownrecord silences <recording> [--split | --delete] [--threshold <dB>] [--min-pause <s>] [--padding <s>]",
            details: """
            Finds the pauses in the voice (the microphone, or system audio without one) and lists them.

              --delete            Remove them from the video
              --split             Only split around them, to delete some by hand
              --threshold <dB>    Quieter than this is silence, e.g. -45; default: chosen for the recording
              --min-pause <s>     Shortest pause (default 0.8)
              --padding <s>       Sound kept around speech (default 0.15)
            """,
            values: ["threshold", "min-pause", "padding"], flags: ["split", "delete"]
        ) { options, output in
            try options.expectPositionals(atMost: 1)
            if options.flag("split"), options.flag("delete") { throw UsageError("Choose --split or --delete.") }
            let params = SilencesParams(recording: try options.recording(), threshold: try options.number("threshold"),
                                        minimumPause: try options.time("min-pause"), padding: try options.time("padding"),
                                        apply: options.flag("delete") ? .delete : options.flag("split") ? .split : nil)
            let result: SilencesInfo = try ControlClient.send(.silences, params)
            output.emit(result) { result in
                let count = result.pauses.count == 1 ? "1 pause" : "\(result.pauses.count) pauses"
                let total = ControlFormat.seconds(result.total)
                switch result.applied {
                case .delete: return "Removed \(count) (\(total)). The video is now \(ControlFormat.seconds(result.recording.videoDuration)) long."
                case .split: return "Split around \(count) (\(total))."
                case nil:
                    guard !result.pauses.isEmpty else {
                        return "No pauses quieter than \(ControlFormat.number(result.threshold)) dB in the video."
                    }
                    let track = result.track == .microphone ? "microphone" : "system audio"
                    return (["\(count) (\(total)) quieter than \(ControlFormat.number(result.threshold)) dB in the \(track):"]
                        + result.pauses.map { "  " + ControlFormat.span($0[0]..<$0[1]) }
                        + ["Add --delete to remove them, or --split to split around them."]).joined(separator: "\n")
                }
            }
        },
        ToolCommand(
            name: "blur", summary: "Blur or pixelate an area",
            usage: "ownrecord blur <recording> (--rect <x,y,w,h> | --px <x,y,w,h>) [--pixelate] [--from <time>] [--to <time>]",
            details: """
            Blurs an area of the screen recording, e.g. a password or an email address, for the whole
            recording or a stretch of it (it splits there). The camera overlay and subtitles stay sharp.

              --rect <x,y,w,h>   The area as fractions (0 to 1) of the screen recording, from its top-left corner
              --px <x,y,w,h>     The area in pixels of the screen recording (see `frame --raw`)
              --pixelate         Pixelate instead of blurring
              --from, --to       Only this stretch (recording time)

            Example: ownrecord blur latest --rect 0.62,0.08,0.3,0.05 --from 12 --to 20
            """,
            values: ["rect", "px", "from", "to"], flags: ["pixelate"]
        ) { options, output in
            try options.expectPositionals(atMost: 1)
            let params = BlurParams(recording: try options.recording(), rect: try options.rect("rect"), pixels: try options.rect("px"),
                                    style: options.flag("pixelate") ? .pixelate : .blur,
                                    from: try options.time("from"), to: try options.time("to"))
            guard (params.rect == nil) != (params.pixels == nil) else { throw UsageError("Give the area with either --rect or --px.") }
            let result: EditResult = try ControlClient.send(.blur, params)
            output.emit(result) { $0.message }
        },
        ToolCommand(
            name: "unblur", summary: "Remove blurred areas",
            usage: "ownrecord unblur <recording> (<blur ID> | --all)",
            details: "Removes a blurred or pixelated area (IDs are in `ownrecord show`), or all of them.",
            flags: ["all"]
        ) { options, output in
            try options.expectPositionals(atMost: 2)
            let id = options.positionals.count > 1 ? options.positionals[1] : nil
            guard (id == nil) == options.flag("all") else { throw UsageError("Give a blurred area's ID, or --all.") }
            let result: EditResult = try ControlClient.send(.unblur, UnblurParams(recording: try options.recording(), id: id))
            output.emit(result) { $0.message }
        },
        ToolCommand(
            name: "set", summary: "Change layout, camera, subtitle and audio settings",
            usage: "ownrecord set <recording> <setting>=<value> … [--from <time>] [--to <time>]",
            details: settingsHelp,
            values: ["from", "to"]
        ) { options, output in
            let recording = try options.recording()
            var values: [String: String] = [:]
            for pair in options.positionals.dropFirst() {
                guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                    throw UsageError("Give settings as setting=value, e.g. layout.aspect=portrait.")
                }
                values[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            }
            guard !values.isEmpty else { throw UsageError("Give at least one setting=value.") }
            let params = SetParams(recording: recording, values: values, from: try options.time("from"), to: try options.time("to"))
            let result: EditResult = try ControlClient.send(.set, params)
            output.emit(result) { $0.message }
        },
        ToolCommand(
            name: "transcribe", summary: "Generate subtitles",
            usage: "ownrecord transcribe <recording> [--locale <language>]",
            details: """
            Transcribes the recording on this Mac with Apple's speech recognition and turns on burned-in
            subtitles. Replaces an existing transcript.

              --locale <id>   The language, e.g. en-US or de-DE; default: the last one used
            """,
            values: ["locale"]
        ) { options, output in
            try options.expectPositionals(atMost: 1)
            let params = TranscribeParams(recording: try options.recording(), locale: options.string("locale"))
            let result: EditResult = try ControlClient.send(.transcribe, params, activity: "Transcribing")
            output.emit(result) { $0.message }
        },
        ToolCommand(
            name: "transcript", summary: "Print the transcript or subtitles",
            usage: "ownrecord transcript <recording> [--format srt | vtt | txt]",
            details: """
            Prints the transcript, one subtitle per line with its recording time, e.g. to find what to cut.
            With --json, also every word with its time.

              --format srt|vtt|txt   A subtitle file for the edited video instead (cut parts left out)
            """,
            values: ["format"]
        ) { options, output in
            try options.expectPositionals(atMost: 1)
            let format = try options.choice("format", Dictionary(uniqueKeysWithValues: SubtitleFileFormat.allCases.map { ($0.rawValue, $0) }))
            let result: TranscriptInfo = try ControlClient.send(.transcript, TranscriptParams(recording: try options.recording(),
                                                                                             format: format))
            output.emit(result) { result in
                if let file = result.file { return file.hasSuffix("\n") ? String(file.dropLast()) : file }
                return result.cues.map { cue in
                    let span = "[\(ControlFormat.span(cue.start..<cue.end))]"
                    return "\(span)\(cue.videoStart == nil ? " (cut)" : "") \(cue.text)"
                }.joined(separator: "\n")
            }
        },

        // Output
        ToolCommand(
            name: "frame", summary: "Save a still of the video",
            usage: "ownrecord frame <recording> [--at <time>] [--video] [--raw] [--size <pixels>] [-o <file.png|.jpg>] [--force]",
            details: """
            Saves one frame of the edited video (layout, camera, blurs and subtitles applied), e.g. to
            check an edit or to find what to blur, and prints where it went.

              --at <time>     Recording time; default: the start of the video
              --video         --at is a time in the edited video instead
              --raw           The screen recording as captured, at full size (for --px coordinates)
              --size <px>     Longest side, default 1920
              -o <file>       Where to save it (.png or .jpg); default: "<title> at <time>.png" here
              --force         Replace the file if it exists
            """,
            values: ["at", "size", "output"], flags: ["video", "raw", "force"]
        ) { options, output in
            try options.expectPositionals(atMost: 1)
            let destination = options.string("output").map(Delivery.destination)
            if let destination { try Delivery.checkFree(destination, force: options.flag("force")) }
            let jpeg = ["jpg", "jpeg"].contains(destination?.pathExtension.lowercased() ?? "")
            let params = FrameParams(recording: try options.recording(), time: try options.time("at"), videoTime: options.flag("video"),
                                     raw: options.flag("raw"), size: try options.int("size"), jpeg: jpeg)
            var result: FilesResult = try ControlClient.send(.frame, params)
            let staged = result.files
            defer { Delivery.cleanUp(staged) }
            let target = destination ?? Delivery.freeURL(named: "\(result.name ?? "Frame") at \(ControlFormat.number(result.time ?? 0))s",
                                                         extension: "png")
            try Delivery.move(result.files[0], to: target)
            result.files = [target.path]
            output.emit(result) { _ in target.path }
        },
        ToolCommand(
            name: "export", summary: "Export MP4, MOV, GIF or clips for iMovie",
            usage: "ownrecord export <recording> [-o <path>] [--format mp4|mov|gif|imovie] [--codec h264|hevc]\n"
                + "                        [--resolution original|4k|1440p|1080p|720p] [--clips separate|finished|both]\n"
                + "                        [--gif-width <px>] [--gif-fps <n>] [--subtitles | --no-subtitles] [--srt] [--force]",
            details: """
            Exports the edited video and prints where it went. The format follows -o's extension unless
            --format says otherwise; default MP4, H.264, 1080p.

              -o <path>        The file (or for iMovie, the folder); default: named after the title, here
              --format <f>     mp4, mov, gif, or imovie (a folder of clips with the edit applied)
              --codec <c>      h264 (plays everywhere) or hevc (smaller)
              --resolution <r> original, 4k, 1440p, 1080p or 720p (never upscales)
              --clips <c>      For iMovie: separate (screen and camera), finished (the video) or both
              --gif-width <px>, --gif-fps <n>
              --subtitles, --no-subtitles   Burn in subtitles or not (default: as set in the editor)
              --srt            Also save the subtitles as an .srt file next to the video
              --force          Replace what's at -o

            Examples:
              ownrecord export latest -o ~/Desktop/demo.mp4
              ownrecord export latest --format imovie --clips both -o ~/Desktop/Demo\\ for\\ iMovie
            """,
            values: ["output", "format", "codec", "resolution", "clips", "gif-width", "gif-fps"],
            flags: ["subtitles", "no-subtitles", "srt", "force"]
        ) { options, output in
            try options.expectPositionals(atMost: 1)
            if options.flag("subtitles"), options.flag("no-subtitles") { throw UsageError("Choose --subtitles or --no-subtitles.") }
            let formats = Dictionary(uniqueKeysWithValues: ExportFormat.allCases.map { ($0.rawValue, $0) })
            let destination = options.string("output").map(Delivery.destination)
            let format = try options.choice("format", formats)
                ?? destination.flatMap { formats[$0.pathExtension.lowercased()] }
                ?? .mp4
            if let destination, format != .imovie, destination.pathExtension.lowercased() != format.fileExtension {
                throw UsageError("-o should end in .\(format.fileExtension) for \(format.title).")
            }
            if let destination { try Delivery.checkFree(destination, force: options.flag("force")) }
            let params = ExportParams(
                recording: try options.recording(), format: format,
                codec: try options.choice("codec", Dictionary(uniqueKeysWithValues: ExportCodec.allCases.map { ($0.rawValue, $0) })),
                resolution: try options.choice("resolution", Dictionary(uniqueKeysWithValues: ExportResolution.allCases.map {
                    ($0.title.lowercased(), $0)
                })),
                clips: try options.choice("clips", Dictionary(uniqueKeysWithValues: IMovieClips.allCases.map { ($0.rawValue, $0) })),
                gifWidth: try options.int("gif-width"), gifFrameRate: try options.int("gif-fps"),
                burnSubtitles: options.flag("subtitles") ? true : options.flag("no-subtitles") ? false : nil,
                subtitleFile: options.flag("srt"))
            var result: FilesResult = try ControlClient.send(.export, params, activity: "Exporting")
            let staged = result.files
            defer { Delivery.cleanUp(staged) }
            result.files = try Delivery.deliverExport(result, format: format, to: destination,
                                                      folder: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            output.emit(result) { $0.files.joined(separator: "\n") }
        },

        // AI apps
        ToolCommand(
            name: "mcp", summary: "Serve these commands to AI apps over MCP",
            usage: "ownrecord mcp",
            details: """
            Runs an MCP (Model Context Protocol) server on standard input and output, so AI apps such as
            Claude Desktop, ChatGPT or Cursor can record, edit and export with OwnRecord. Its tools do what
            these commands do, and a frame comes back as an image the AI can look at.

            Add it to the AI app's MCP servers rather than running it yourself. For example, in Claude
            Desktop's claude_desktop_config.json (Settings › Developer › Edit Config):

              { "mcpServers": { "ownrecord": { "command": "\(MCPServer.executablePath)", "args": ["mcp"] } } }

            In Claude Code: claude mcp add ownrecord -- ownrecord mcp
            OwnRecord › Settings › Command Line & AI Apps › Copy Configuration copies this for you.
            """
        ) { options, _ in
            try options.expectPositionals(atMost: 0)
            MCPServer.serve()
        },
    ]

    /// Every setting `set` changes, with its choices or default, e.g. ("layout.aspect", "original, landscape, …").
    static var settingChoices: [(path: String, values: String)] {
        let defaults = EditSettings()
        let groups: [(String, Encodable)] = [("layout", defaults.layout), ("camera", defaults.camera),
                                             ("subtitles", defaults.subtitles), ("audio", defaults.audio)]
        let choices: [String: String] = [
            "layout.aspect": AspectPreset.allCases.map(\.rawValue).joined(separator: ", "),
            "layout.background": BackgroundPreset.allCases.map(\.rawValue).joined(separator: ", "),
            "camera.shape": CameraShape.allCases.map(\.rawValue).joined(separator: ", "),
            "camera.position": CameraPosition.allCases.map(\.rawValue).joined(separator: ", "),
            "subtitles.position": SubtitlePosition.allCases.map(\.rawValue).joined(separator: ", "),
        ]
        var settings: [(path: String, values: String)] = []
        for (group, value) in groups {
            guard let data = try? JSONEncoder().encode(value),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for key in object.keys.sorted() {
                let path = "\(group).\(key)"
                let current: String
                if let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    current = "\(number.doubleValue)".replacingOccurrences(of: #"\.0$"#, with: "", options: .regularExpression)
                } else {
                    current = (try? JSONSerialization.data(withJSONObject: object[key]!, options: [.fragmentsAllowed, .sortedKeys]))
                        .map { String(decoding: $0, as: UTF8.self) } ?? ""
                }
                settings.append((path, choices[path] ?? "default \(current)"))
            }
        }
        return settings
    }

    private static var settingsHelp: String {
        let lines = settingChoices.map { "  \($0.path.padding(toLength: max(28, $0.path.count + 2), withPad: " ", startingAt: 0))\($0.values)" }
        return """
        Changes the edited video's look. Values are numbers, true/false, the names listed, or JSON
        (colors are {"red":1,"green":1,"blue":1,"alpha":1}). Sizes and margins are fractions of the
        video's shorter side, subtitles.outlineWidth is a fraction of the text size, and volumes go
        from 0 to 1. Per-section camera placement is set in the editor.

        \(lines.joined(separator: "\n"))

          --from <time>, --to <time>   Change subtitles settings only in this stretch (recording time),
                                       which gets a subtitle style of its own

        Examples:
          ownrecord set latest layout.aspect=portrait layout.background=aurora camera.shape=roundedSquare
          ownrecord set latest subtitles.outlineWidth=0.12 subtitles.shadow=false --from 30
        """
    }
}
