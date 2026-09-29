import Foundation

/// One tool of `ownrecord mcp` (see `MCPServer`). The tools group the command line tool's commands
/// so an AI app has fewer to choose from; the destructive ones stay separate, so apps can ask
/// before using them.
struct MCPTool {
    let name: String
    let title: String
    let description: String
    var properties: [String: Any] = [:]
    var required: [String] = []
    var readOnly = false
    var destructive = false
    var idempotent = false
    /// Shown with progress reports, e.g. "Exporting".
    var activity: String?
    let run: (MCPArguments, MCPContext) throws -> [MCPContent]

    static func named(_ name: String) -> MCPTool? {
        all.first { $0.name == name }
    }

    var definition: [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "title": title, "description": description, "inputSchema": schema,
                "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive,
                                "idempotentHint": idempotent, "openWorldHint": false]]
    }

    /// Runs the tool. Failures become results the AI can read and act on.
    func call(_ arguments: [String: Any], _ context: MCPContext) -> [String: Any] {
        do {
            let content = try run(try MCPArguments(arguments, allowed: Set(properties.keys)), context)
            return ["content": content.map(\.object)]
        } catch {
            return ["content": [MCPContent.text(Self.message(for: error)).object], "isError": true]
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case let error as UsageError: error.message
        case is CancellationError: "Cancelled."
        default: adapted(error.localizedDescription)
        }
    }

    /// The app's messages suggest `ownrecord` commands and options; name the tools instead.
    static func adapted(_ message: String) -> String {
        let replacements = [
            ("Run `ownrecord stop` first", "Stop it first with control_recording"),
            ("Run `ownrecord discard` to cancel it", "Use discard_recording to cancel it"),
            ("Run `ownrecord sources` to see them", "get_status with sources lists them"),
            ("Run `ownrecord list` to see them", "list_recordings lists them"),
            ("`ownrecord show` lists them", "show_recording lists them"),
            ("See `ownrecord help set`", "See the settings in edit_recording's description"),
            ("Add --raw to see", "Use raw to see"),
            ("Add --force to replace it", "Use overwrite to replace it"),
            ("--rect", "rect"), ("--px", "pixels"),
        ]
        var text = message
        for (old, new) in replacements {
            text = text.replacingOccurrences(of: old, with: new)
        }
        return text.replacingOccurrences(of: "Run `ownrecord transcribe [^`]*`", with: "Use transcribe first",
                                         options: .regularExpression)
    }

    static let instructions = """
    OwnRecord is a Mac screen recorder with a non-destructive editor. These tools record the screen, a \
    window or an area, and edit and export recordings; the OwnRecord app does the work, so recordings show \
    its usual controls.

    Name a recording by its ID (or the first 8 characters), title, or "latest". Times are seconds in the \
    original recording, as show_recording and get_transcript give them, so they don't shift as you cut.

    A typical session: start_recording (with wait and a duration), transcribe, get_transcript to find what \
    to cut, edit_recording, get_frame to check the result, export_video.
    """

    static let all: [MCPTool] = [
        // Recording
        MCPTool(
            name: "get_status", title: "OwnRecord status",
            description: """
            What OwnRecord is doing (idle, countdown, recording, paused or saving) and for how long, which \
            permissions it's missing, and how many recordings there are. With sources, also the displays, \
            windows (with IDs), cameras and microphones start_recording can use.
            """,
            properties: ["sources": boolean("Also list what can be recorded.")],
            readOnly: true
        ) { arguments, context in
            let status: StatusInfo = try context.send(.status, NoParams())
            guard try arguments.bool("sources") == true else { return [.json(status)] }
            let sources: SourcesInfo = try context.send(.sources, NoParams())
            return [.json(status), .json(sources)]
        },
        MCPTool(
            name: "start_recording", title: "Start recording",
            description: """
            Starts recording the screen, a window or an area, and returns once it's rolling (after the \
            countdown). OwnRecord shows its usual recording controls, and the user can stop it too. Without \
            window or area, it records the whole display.

            The camera, microphone and system audio default to what's chosen in OwnRecord's recorder, so \
            the camera may be on. Pass camera "none" and microphone "none" unless the user wants them.

            With wait, the call returns when the recording ends, with the saved recording; give a duration \
            so it ends by itself. Otherwise end it with control_recording.
            """,
            properties: [
                "window": string("A window to record: its ID, or (part of) its app name or title, e.g. \"Safari\"."),
                "area": numbers(4, "An area to record: [x, y, width, height] in points from the display's top-left corner."),
                "display": string("The display to record, or to put the area on: its ID or name. Default: the main display."),
                "camera": string("A camera by name or ID, or \"none\"."),
                "microphone": string("A microphone by name or ID, \"default\", or \"none\"."),
                "system_audio": boolean("Record the sound of the Mac's apps."),
                "countdown": integer("Seconds of countdown. Default: as set in OwnRecord's settings."),
                "duration": number("Stop by itself after this many seconds of recording (pauses don't count)."),
                "wait": boolean("Return when the recording ends, with the saved recording."),
            ]
        ) { arguments, context in
            let params = RecordParams(
                display: try arguments.string("display"), window: try arguments.string("window"), area: try arguments.rect("area"),
                camera: try arguments.string("camera"), microphone: try arguments.string("microphone"),
                systemAudio: try arguments.bool("system_audio"), countdown: try arguments.int("countdown"),
                duration: try arguments.time("duration"), wait: try arguments.bool("wait"))
            let result: RecordResult = try context.send(.record, params)
            if result.recording != nil { return [saved(result)] }
            let next = params.duration.map {
                "It stops by itself after \(ControlFormat.seconds($0)); control_recording with action wait returns when it has."
            } ?? "Stop it with control_recording."
            return [.json(result.status, "Recording. \(next)")]
        },
        MCPTool(
            name: "control_recording", title: "Stop, pause or resume recording",
            description: """
            Controls the recording in progress: stop it (and save), pause (the pause is left out of the \
            video), resume, or wait until it ends by itself (after its duration, or when the user stops \
            it). stop and wait return the saved recording.
            """,
            properties: [
                "action": string("What to do.", choices: ["stop", "pause", "resume", "wait"]),
                "open": boolean("With stop: open the saved recording in OwnRecord's editor."),
            ],
            required: ["action"]
        ) { arguments, context in
            switch try arguments.string("action") {
            case "stop":
                return [saved(try context.send(.stop, StopParams(open: try arguments.bool("open"))))]
            case "wait":
                return [saved(try context.send(.wait, NoParams()))]
            case "pause":
                let status: StatusInfo = try context.send(.pause, NoParams())
                return [.json(status, "Paused.")]
            case "resume":
                let status: StatusInfo = try context.send(.resume, NoParams())
                return [.json(status, "Recording again.")]
            default:
                throw ControlError("action takes stop, pause, resume or wait.")
            }
        },
        MCPTool(
            name: "discard_recording", title: "Discard the recording",
            description: "Stops the recording in progress (or its countdown) and throws it away without saving it.",
            destructive: true
        ) { _, context in
            let _: StatusInfo = try context.send(.discard, NoParams())
            return [.text("Discarded the recording.")]
        },

        // Library
        MCPTool(
            name: "list_recordings", title: "List recordings",
            description: """
            Lists recordings, newest first, with their IDs, lengths (recorded, and in the edited video) and \
            what they contain. A search matches titles, sources and transcripts.
            """,
            properties: ["search": string("Text to look for."), "limit": integer("At most this many. Default: 25.")],
            readOnly: true
        ) { arguments, context in
            let params = ListParams(search: try arguments.string("search"), limit: try arguments.int("limit") ?? 25)
            let recordings: [RecordingInfo] = try context.send(.list, params)
            return [.json(recordings, recordings.isEmpty ? "No recordings." : nil)]
        },
        MCPTool(
            name: "show_recording", title: "Show a recording",
            description: """
            A recording's details: its sections (recording time, where each plays in the edited video, and \
            what's cut, hidden, muted, blurred or styled differently), the trim, and every layout, camera, \
            subtitle and audio setting.
            """,
            properties: ["recording": recording],
            required: ["recording"], readOnly: true
        ) { arguments, context in
            let details: RecordingDetails = try context.send(.show, RecordingParams(recording: try arguments.recording()))
            return [.json(details)]
        },
        MCPTool(
            name: "open_recording", title: "Open in OwnRecord",
            description: "Opens the recording in OwnRecord's editor and brings OwnRecord to the front, e.g. so the user can watch or fine-tune an edit.",
            properties: ["recording": recording],
            required: ["recording"], idempotent: true
        ) { arguments, context in
            let result: EditResult = try context.send(.open, RecordingParams(recording: try arguments.recording()))
            return [.text(result.message)]
        },
        MCPTool(
            name: "delete_recording", title: "Delete a recording",
            description: "Moves the recording's folder to the Trash (it can be put back from there).",
            properties: ["recording": recording],
            required: ["recording"], destructive: true
        ) { arguments, context in
            let result: EditResult = try context.send(.delete, RecordingParams(recording: try arguments.recording()))
            return [.text(result.message)]
        },

        // Editing
        MCPTool(
            name: "edit_recording", title: "Edit a recording",
            description: """
            Edits a recording without touching its files: trim, cut and restore stretches, blur areas, \
            change the look, and rename. Give any of them; they're applied in that order. With the \
            recording open in OwnRecord's editor, ⌘Z undoes them there. Times are seconds in the original \
            recording.
            """,
            properties: [
                "recording": recording,
                "trim": object([
                    "start": number("Where the video starts."),
                    "end": number("Where it ends."),
                    "reset": boolean("Remove the trim (with start or end: replace it)."),
                ], "Where the video starts and ends."),
                "cut": ranges("Stretches to remove from the video, e.g. [[4.2, 6.8]]."),
                "restore": ranges("Bring back cut parts that overlap these stretches."),
                "blur": [
                    "type": "array",
                    "description": "Areas of the screen to blur or pixelate, e.g. a password; the camera and subtitles stay sharp.",
                    "items": object([
                        "rect": numbers(4, "[x, y, width, height] as fractions (0 to 1) of the screen recording, from its top-left corner."),
                        "pixels": numbers(4, "The same in pixels of the screen recording (instead of rect)."),
                        "pixelate": boolean("Pixelate instead of blurring."),
                        "from": number("Only from this time."),
                        "to": number("Only until this time."),
                    ], nil),
                ],
                "unblur": [
                    "type": "array", "items": ["type": "string"],
                    "description": "Blurred areas to remove, by ID (show_recording lists them), or [\"all\"].",
                ],
                "settings": [
                    "type": "object",
                    "description": settingsDescription,
                    "additionalProperties": ["type": ["string", "number", "boolean", "object"]],
                ],
                "settings_from": number("Apply subtitles settings only from this time, so the subtitles change style there."),
                "settings_to": number("With settings_from: only until this time. Default: the end."),
                "title": string("A new title for the recording."),
            ],
            required: ["recording"]
        ) { arguments, context in
            try edit(arguments, context)
        },
        MCPTool(
            name: "find_silences", title: "Find pauses",
            description: """
            Finds the pauses in the speech (the microphone, or system audio without one) and lists them in \
            recording time. With action split, splits the timeline around them; with delete, removes them \
            from the video (edit_recording's restore brings them back).
            """,
            properties: [
                "recording": recording,
                "action": string("What to do with the pauses. Default: list.", choices: ["list", "split", "delete"]),
                "threshold": number("Quieter than this many dB is silence, e.g. -45. Default: chosen for the recording."),
                "min_pause": number("Shortest pause in seconds. Default: 0.8."),
                "padding": number("Seconds of sound kept around speech. Default: 0.15."),
            ],
            required: ["recording"]
        ) { arguments, context in
            let action = try arguments.choice("action", ["list": nil, "split": SilenceAction.split, "delete": .delete]) ?? nil
            let params = SilencesParams(recording: try arguments.recording(), threshold: try arguments.number("threshold"),
                                        minimumPause: try arguments.time("min_pause"), padding: try arguments.time("padding"),
                                        apply: action)
            let result: SilencesInfo = try context.send(.silences, params)
            let count = result.pauses.count == 1 ? "1 pause" : "\(result.pauses.count) pauses"
            let summary = switch result.applied {
            case .delete: "Removed \(count) (\(ControlFormat.seconds(result.total))). \(videoLength(result.recording))"
            case .split: "Split around \(count) (\(ControlFormat.seconds(result.total)))."
            case nil: "Found \(count) (\(ControlFormat.seconds(result.total))) quieter than \(ControlFormat.number(result.threshold)) dB."
            }
            return [.json(result, summary)]
        },
        MCPTool(
            name: "transcribe", title: "Generate subtitles",
            description: """
            Transcribes the recording's speech on this Mac with Apple's speech recognition and turns on \
            subtitles. Replaces an existing transcript. Takes a while for long recordings.
            """,
            properties: [
                "recording": recording,
                "locale": string("The language, e.g. en-US or de-DE. Default: the last one used."),
            ],
            required: ["recording"], destructive: true, activity: "Transcribing"
        ) { arguments, context in
            let params = TranscribeParams(recording: try arguments.recording(), locale: try arguments.string("locale"))
            let result: EditResult = try context.send(.transcribe, params)
            return [.json(result.recording, result.message)]
        },
        MCPTool(
            name: "get_transcript", title: "Get the transcript",
            description: """
            The recording's transcript: one subtitle per line with its recording time, e.g. to find what to \
            cut. With words, every word with its time. With format, a subtitle file of the edited video \
            instead (cut parts left out).
            """,
            properties: [
                "recording": recording,
                "words": boolean("Also every word with its time."),
                "format": string("A subtitle file instead.", choices: SubtitleFileFormat.allCases.map(\.rawValue)),
            ],
            required: ["recording"], readOnly: true
        ) { arguments, context in
            let format = try arguments.choice("format", Dictionary(uniqueKeysWithValues: SubtitleFileFormat.allCases.map { ($0.rawValue, $0) }))
            let result: TranscriptInfo = try context.send(.transcript, TranscriptParams(recording: try arguments.recording(), format: format))
            if let file = result.file { return [.text(file)] }
            if try arguments.bool("words") == true { return [.json(result)] }
            let lines = result.cues.map { cue in
                "[\(ControlFormat.span(cue.start..<cue.end))]\(cue.videoStart == nil ? " (cut)" : "") \(cue.text)"
            }
            return [.text((["Recording times; (cut) marks lines cut from the video."] + lines).joined(separator: "\n"))]
        },

        // Output
        MCPTool(
            name: "get_frame", title: "Look at a frame",
            description: """
            Renders one frame of the edited video (layout, camera, blurs and subtitles applied) and returns \
            it as an image, to check an edit or find what to blur. With raw, the screen recording as captured.
            """,
            properties: [
                "recording": recording,
                "at": number("Recording time in seconds. Default: the start of the video."),
                "video_time": boolean("at is a time in the edited video instead."),
                "raw": boolean("The screen recording as captured, without the edit."),
                "size": integer("Longest side in pixels. Default: 1280."),
            ],
            required: ["recording"], readOnly: true
        ) { arguments, context in
            let params = FrameParams(recording: try arguments.recording(), time: try arguments.time("at"),
                                     videoTime: try arguments.bool("video_time"), raw: try arguments.bool("raw"),
                                     size: try arguments.int("size") ?? 1280, jpeg: true)
            let result: FilesResult = try context.send(.frame, params)
            defer { Delivery.cleanUp(result.files) }
            guard let file = result.files.first else { throw ControlError("OwnRecord didn't make the frame.") }
            let image = try Data(contentsOf: URL(fileURLWithPath: file))
            var caption = "The frame at \(ControlFormat.seconds(result.time ?? 0)) in the recording"
            caption += result.videoTime.map { " (\(ControlFormat.seconds($0)) in the video)" } ?? " (cut from the video)"
            if let width = result.width, let height = result.height { caption += ", \(width) × \(height) pixels" }
            return [.image(image, mimeType: "image/jpeg"), .text(caption + ".")]
        },
        MCPTool(
            name: "export_video", title: "Export the video",
            description: """
            Exports the edited video and returns where it went. Default: an MP4 (H.264, 1080p) named after \
            the recording, in the Movies folder.
            """,
            properties: [
                "recording": recording,
                "output": string("Where to save it: a full path, or one starting with ~. For iMovie, a folder."),
                "format": string("Default: from output's extension, else mp4. imovie is a folder of clips with the edit applied.",
                                 choices: ExportFormat.allCases.map(\.rawValue)),
                "codec": string("h264 plays everywhere; hevc is smaller.", choices: ExportCodec.allCases.map(\.rawValue)),
                "resolution": string("Never upscales. Default: 1080p.", choices: ExportResolution.allCases.map { $0.title.lowercased() }),
                "clips": string("For iMovie: the screen and camera separately, the finished video, or both.",
                                choices: IMovieClips.allCases.map(\.rawValue)),
                "gif_width": integer("Width of a GIF in pixels."),
                "gif_fps": integer("Frames per second of a GIF."),
                "subtitles": boolean("Burn in subtitles. Default: as set in the edit."),
                "srt": boolean("Also save the subtitles as an .srt file next to the video."),
                "overwrite": boolean("Replace what's at output."),
            ],
            required: ["recording"], activity: "Exporting"
        ) { arguments, context in
            try export(arguments, context)
        },
    ]

    // MARK: Running

    private static func saved(_ result: RecordResult) -> MCPContent {
        guard let recording = result.recording else { return .json(result.status) }
        return .json(recording, "Saved “\(recording.title)” (\(ControlFormat.seconds(recording.duration))).")
    }

    private static func videoLength(_ recording: RecordingInfo) -> String {
        "The video is now \(ControlFormat.seconds(recording.videoDuration)) long."
    }

    private static func edit(_ arguments: MCPArguments, _ context: MCPContext) throws -> [MCPContent] {
        let recording = try arguments.recording()
        // Check every argument before changing anything.
        var steps: [(command: ControlCommand, params: Encodable)] = []
        if let trim = try arguments.object("trim", allowed: ["start", "end", "reset"]) {
            let params = TrimParams(recording: recording, start: try trim.time("start"), end: try trim.time("end"),
                                    reset: try trim.bool("reset"))
            guard params.start != nil || params.end != nil || params.reset == true else {
                throw ControlError("trim takes start, end or reset.")
            }
            steps.append((.trim, params))
        }
        for (name, command) in [("restore", ControlCommand.restore), ("cut", .cut)] {
            for range in try arguments.ranges(name) {
                steps.append((command, RangeParams(recording: recording, from: range.lowerBound, to: range.upperBound)))
            }
        }
        for area in try arguments.objects("blur", allowed: ["rect", "pixels", "pixelate", "from", "to"]) {
            let params = BlurParams(recording: recording, rect: try area.rect("rect"), pixels: try area.rect("pixels"),
                                    style: try area.bool("pixelate") == true ? .pixelate : .blur,
                                    from: try area.time("from"), to: try area.time("to"))
            guard (params.rect == nil) != (params.pixels == nil) else { throw ControlError("Give each blurred area a rect or pixels.") }
            steps.append((.blur, params))
        }
        if let ids = try arguments.strings("unblur") {
            for id in ids {
                steps.append((.unblur, UnblurParams(recording: recording, id: id.lowercased() == "all" ? nil : id)))
            }
        }
        let from = try arguments.time("settings_from")
        let to = try arguments.time("settings_to")
        if let settings = try arguments.object("settings") {
            let values = try settings.settingValues()
            guard !values.isEmpty else { throw ControlError("settings is empty.") }
            steps.append((.set, SetParams(recording: recording, values: values, from: from, to: to)))
        } else if from != nil || to != nil {
            throw ControlError("settings_from and settings_to need settings.")
        }
        if let title = try arguments.string("title") {
            steps.append((.rename, RenameParams(recording: recording, title: title)))
        }
        guard !steps.isEmpty else {
            throw ControlError("Give at least one edit: trim, cut, restore, blur, unblur, settings or title.")
        }

        var messages: [String] = []
        var ids: [UUID] = []
        var latest: RecordingInfo?
        for step in steps {
            do {
                let result: EditResult = try context.send(step.command, AnyEncodable(step.params))
                messages.append(result.message)
                ids += result.ids ?? []
                latest = result.recording
            } catch where !messages.isEmpty {
                throw ControlError("\(message(for: error))\nAlready done: \(messages.joined(separator: " "))")
            }
        }
        guard let latest else { throw ControlError("OwnRecord didn't answer.") }
        return [.json(EditResult(message: messages.joined(separator: " "), recording: latest, ids: ids.isEmpty ? nil : ids),
                      "\(messages.joined(separator: " ")) \(videoLength(latest))")]
    }

    private static func export(_ arguments: MCPArguments, _ context: MCPContext) throws -> [MCPContent] {
        let formats = Dictionary(uniqueKeysWithValues: ExportFormat.allCases.map { ($0.rawValue, $0) })
        let destination = try arguments.string("output").map { path in
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw ControlError("Give output as a full path, e.g. ~/Movies/Demo.mp4.") }
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        let format = try arguments.choice("format", formats)
            ?? destination.flatMap { formats[$0.pathExtension.lowercased()] }
            ?? .mp4
        if let destination, format != .imovie, destination.pathExtension.lowercased() != format.fileExtension {
            throw ControlError("output should end in .\(format.fileExtension) for \(format.title).")
        }
        if let destination { try Delivery.checkFree(destination, force: try arguments.bool("overwrite") == true) }
        let params = ExportParams(
            recording: try arguments.recording(), format: format,
            codec: try arguments.choice("codec", Dictionary(uniqueKeysWithValues: ExportCodec.allCases.map { ($0.rawValue, $0) })),
            resolution: try arguments.choice("resolution", Dictionary(uniqueKeysWithValues: ExportResolution.allCases.map {
                ($0.title.lowercased(), $0)
            })),
            clips: try arguments.choice("clips", Dictionary(uniqueKeysWithValues: IMovieClips.allCases.map { ($0.rawValue, $0) })),
            gifWidth: try arguments.int("gif_width"), gifFrameRate: try arguments.int("gif_fps"),
            burnSubtitles: try arguments.bool("subtitles"), subtitleFile: try arguments.bool("srt"))
        var result: FilesResult = try context.send(.export, params)
        let staged = result.files
        defer { Delivery.cleanUp(staged) }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        result.files = try Delivery.deliverExport(result, format: format, to: destination, folder: movies)
        return [.json(result, "Exported to \(result.files.joined(separator: ", ")).")]
    }

    // MARK: Schemas

    private static let recording = string("The recording: its ID (or the first 8 characters), title, or \"latest\".")

    private static var settingsDescription: String {
        let settings = ToolCommand.settingChoices.map { "\($0.path) (\($0.values))" }.joined(separator: "; ")
        return """
        Layout, camera, subtitle and audio settings by name, e.g. {"layout.aspect": "portrait", \
        "subtitles.outlineWidth": 0.12}. Sizes and margins are fractions of the video's shorter side; \
        subtitles.outlineWidth is a fraction of the text size; volumes go from 0 to 1; colors are \
        {"red": 1, "green": 1, "blue": 1, "alpha": 1}. show_recording gives the current values. \
        Settings: \(settings).
        """
    }

    private static func string(_ description: String, choices: [String]? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "string", "description": description]
        if let choices { schema["enum"] = choices }
        return schema
    }

    private static func number(_ description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }

    private static func integer(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    private static func boolean(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    private static func numbers(_ count: Int, _ description: String) -> [String: Any] {
        ["type": "array", "items": ["type": "number"], "minItems": count, "maxItems": count, "description": description]
    }

    private static func ranges(_ description: String) -> [String: Any] {
        ["type": "array", "items": numbers(2, "[from, to] in seconds."), "description": description]
    }

    private static func object(_ properties: [String: Any], _ description: String?) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if let description { schema["description"] = description }
        return schema
    }
}

/// What a tool returns: text (often a message and JSON) or an image.
enum MCPContent {
    case text(String)
    case image(Data, mimeType: String)

    /// The value as JSON, after a message if there is one.
    static func json<Value: Encodable>(_ value: Value, _ message: String? = nil) -> MCPContent {
        let json = (try? ControlCoding.encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return .text([message, json].compactMap { $0 }.joined(separator: "\n"))
    }

    var object: [String: Any] {
        switch self {
        case .text(let text): ["type": "text", "text": text]
        case .image(let data, let mimeType): ["type": "image", "data": data.base64EncodedString(), "mimeType": mimeType]
        }
    }
}

/// How a tool reaches the app, and reports progress while it waits.
struct MCPContext {
    var socketURL = ControlChannel.socketURL
    var progress: ((Double) -> Void)?
    var cancellation: ControlCancellation?

    func send<Params: Encodable, Result: Decodable>(_ command: ControlCommand, _ params: Params) throws -> Result {
        try ControlClient.send(command, params, progress: progress, cancellation: cancellation, socketURL: socketURL)
    }
}

/// A tool call's arguments, checked against what the tool takes.
struct MCPArguments {
    private let values: [String: Any]

    init(_ values: [String: Any], allowed: Set<String>) throws {
        if let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw ControlError("There's no argument “\(unknown)”. This tool takes \(allowed.sorted().joined(separator: ", ")).")
        }
        self.values = values.filter { !($0.value is NSNull) }
    }

    func recording() throws -> String {
        guard let text = try string("recording"), !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ControlError("Name a recording: its ID (or the start of it), title, or “latest”.")
        }
        return text
    }

    func string(_ name: String) throws -> String? {
        guard let value = values[name] else { return nil }
        guard let text = value as? String else { throw ControlError("\(name) takes text.") }
        return text
    }

    func strings(_ name: String) throws -> [String]? {
        guard let value = values[name] else { return nil }
        guard let items = value as? [Any], let texts = items as? [String] else { throw ControlError("\(name) takes a list of text.") }
        return texts
    }

    func bool(_ name: String) throws -> Bool? {
        guard let value = values[name] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ControlError("\(name) takes true or false.")
        }
        return number.boolValue
    }

    func number(_ name: String) throws -> Double? {
        try values[name].map { try Self.number($0, name) }
    }

    func int(_ name: String) throws -> Int? {
        guard let value = try number(name) else { return nil }
        guard value == value.rounded(), abs(value) < 1e9 else { throw ControlError("\(name) takes a whole number.") }
        return Int(value)
    }

    /// Seconds, as a number or as text like "1:02.5".
    func time(_ name: String) throws -> Double? {
        try values[name].map { try Self.time($0, name) }
    }

    /// x, y, width and height.
    func rect(_ name: String) throws -> [Double]? {
        guard let value = values[name] else { return nil }
        guard let items = value as? [Any], items.count == 4 else { throw ControlError("\(name) takes [x, y, width, height].") }
        return try items.map { try Self.number($0, name) }
    }

    /// [from, to] pairs.
    func ranges(_ name: String) throws -> [Range<Double>] {
        guard let value = values[name] else { return [] }
        guard let items = value as? [Any] else { throw ControlError("\(name) takes a list of [from, to] pairs.") }
        return try items.map { item in
            guard let pair = item as? [Any], pair.count == 2 else { throw ControlError("\(name) takes a list of [from, to] pairs.") }
            let from = try Self.time(pair[0], name), to = try Self.time(pair[1], name)
            guard to > from else { throw ControlError("In \(name), each stretch has to end after it starts.") }
            return from..<to
        }
    }

    func choice<Value>(_ name: String, _ choices: [String: Value]) throws -> Value? {
        guard let text = try string(name) else { return nil }
        guard let value = choices[text.lowercased()] else {
            throw ControlError("\(name) takes \(choices.keys.sorted().joined(separator: ", ")), not “\(text)”.")
        }
        return value
    }

    /// A nested object; nil `allowed` takes any keys.
    func object(_ name: String, allowed: Set<String>? = nil) throws -> MCPArguments? {
        guard let value = values[name] else { return nil }
        guard let object = value as? [String: Any] else { throw ControlError("\(name) takes an object.") }
        return try MCPArguments(object, allowed: allowed ?? Set(object.keys))
    }

    func objects(_ name: String, allowed: Set<String>) throws -> [MCPArguments] {
        guard let value = values[name] else { return [] }
        guard let items = value as? [Any] else { throw ControlError("\(name) takes a list.") }
        return try items.map { item in
            guard let object = item as? [String: Any] else { throw ControlError("\(name) takes a list of objects.") }
            return try MCPArguments(object, allowed: allowed)
        }
    }

    /// The values as `set` takes them: text as it is, anything else as JSON.
    func settingValues() throws -> [String: String] {
        try values.mapValues { value in
            if let text = value as? String { return text }
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
    }

    private static func number(_ value: Any, _ name: String) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
            throw ControlError("\(name) takes a number.")
        }
        return number.doubleValue
    }

    private static func time(_ value: Any, _ name: String) throws -> Double {
        if let text = value as? String {
            do {
                return try Options.time(text)
            } catch let error as UsageError {
                throw ControlError(error.message)
            }
        }
        let seconds = try number(value, name)
        guard seconds >= 0 else { throw ControlError("\(name) can't be negative.") }
        return seconds
    }
}

/// Lets requests of different types share one list.
private struct AnyEncodable: Encodable {
    let value: Encodable

    init(_ value: Encodable) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}
