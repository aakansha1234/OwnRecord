import Darwin
import Foundation

/// How the `ownrecord` command line tool talks to the running app: over a Unix domain socket that
/// only the user's own processes can use, one request per connection. The tool sends one JSON
/// line (`ControlRequest`); the app answers with any number of `{"progress": 0.5}` lines and then
/// `{"result": …}` or `{"error": "…"}`.
///
/// The app does the work, so recording uses its Screen Recording, camera and microphone access,
/// and edits go through the open editor (where they can be undone).
enum ControlChannel {
    static let bundleIdentifier = "com.ownrecord.OwnRecord"
    /// The preference that turns the socket on. Off until the user allows it in Settings.
    static let preferenceKey = "commandLineControl"

    static var socketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OwnRecord/control.sock")
    }

    /// Where the app writes exports and frames for the tool, which then moves them into place
    /// itself. So the tool's own file access applies (the app needs no access to e.g. ~/Desktop).
    static var stagingRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OwnRecord Control", isDirectory: true)
    }

    /// A Unix socket address, or nil if the path is too long for one.
    static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// Connects to the app's socket. Throws if it isn't listening.
    static func connect(to url: URL) throws -> Int32 {
        guard var address = address(for: url.path) else { throw ControlError("The socket path is too long: \(url.path)") }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            close(socket)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .ECONNREFUSED)
        }
        setOption(SO_NOSIGPIPE, on: socket)
        return socket
    }

    static func setOption(_ option: Int32, on socket: Int32) {
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, option, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setTimeout(_ option: Int32, seconds: Int, on socket: Int32) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Writes all of `data`, or returns false.
    @discardableResult
    static func write(_ data: Data, to socket: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(socket, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}

/// Reads newline-separated messages from a socket.
struct LineReader {
    private let socket: Int32
    private var buffer = Data()

    init(socket: Int32) {
        self.socket = socket
    }

    /// The next line (without its newline), or nil at the end of the stream.
    mutating func next() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[(newline + 1)...])
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = read(socket, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count < 0 {
                if errno == EAGAIN { throw ControlError("Timed out waiting for a request.") }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard count > 0 else {
                return buffer.isEmpty ? nil : buffer
            }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}

struct ControlError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

enum ControlCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Requests

enum ControlCommand: String, CaseIterable {
    case status, sources, list, show, open, rename, delete
    case record, wait, stop, pause, resume, discard
    case trim, cut, restore, silences, blur, unblur, set, transcribe, transcript
    case frame, export
}

struct ControlRequest<Params> {
    var command: String
    var params: Params
}

extension ControlRequest: Encodable where Params: Encodable {}
extension ControlRequest: Decodable where Params: Decodable {}

/// Just the command of a request, to know how to decode the rest.
struct ControlRequestHead: Decodable {
    var command: String
}

struct NoParams: Codable {}

struct RecordingParams: Codable {
    /// An ID, the start of one, a title, a folder, or "latest".
    var recording: String
}

struct ListParams: Codable {
    var search: String?
    var limit: Int?
}

struct RenameParams: Codable {
    var recording: String
    var title: String
}

struct RecordParams: Codable {
    /// A display ID or name. Without `window` or `area`, the whole display is recorded.
    var display: String?
    /// A window ID, or (part of) its app name or title.
    var window: String?
    /// x, y, width and height in points from the display's top-left corner.
    var area: [Double]?
    /// A camera ID or (part of) its name, or "none". nil keeps the recorder's choice.
    var camera: String?
    var microphone: String?
    var systemAudio: Bool?
    var countdown: Int?
    /// Stop by itself after this many seconds of recording.
    var duration: Double?
    /// Answer when the recording ends (with the saved recording), not when it starts.
    var wait: Bool?
}

struct StopParams: Codable {
    /// Open the saved recording in the editor.
    var open: Bool?
}

struct TrimParams: Codable {
    var recording: String
    var start: Double?
    var end: Double?
    var reset: Bool?
}

/// A stretch of a recording, in recording time.
struct RangeParams: Codable {
    var recording: String
    var from: Double
    var to: Double
}

enum SilenceAction: String, Codable {
    case split, delete
}

struct SilencesParams: Codable {
    var recording: String
    /// dBFS; nil uses the threshold suggested for the recording.
    var threshold: Double?
    var minimumPause: Double?
    var padding: Double?
    /// nil only lists the pauses.
    var apply: SilenceAction?
}

struct BlurParams: Codable {
    var recording: String
    /// x, y, width and height as fractions (0...1) of the screen recording, from its top-left corner.
    var rect: [Double]?
    /// The same in pixels of the screen recording.
    var pixels: [Double]?
    var style: RedactionStyle?
    /// Recording time. Without `from` and `to`, the whole recording.
    var from: Double?
    var to: Double?
}

struct UnblurParams: Codable {
    var recording: String
    /// A blurred area's ID (or its start); nil removes all of them.
    var id: String?
}

struct SetParams: Codable {
    var recording: String
    /// Setting paths like "layout.aspect" and their values, as JSON or plain text.
    var values: [String: String]
    /// Recording time. With `from` or `to`, subtitle settings change only there: those sections
    /// get a subtitle style of their own.
    var from: Double?
    var to: Double?
}

struct TranscribeParams: Codable {
    var recording: String
    var locale: String?
}

struct TranscriptParams: Codable {
    var recording: String
    /// "srt", "vtt" or "txt" for a subtitle file of the edited video; nil for timed cues and words.
    var format: SubtitleFileFormat?
}

struct FrameParams: Codable {
    var recording: String
    /// Recording time; nil for the start of the video.
    var time: Double?
    /// `time` is a time in the edited video rather than in the recording.
    var videoTime: Bool?
    /// The screen recording as captured, without the edit's layout, camera, blurs and subtitles.
    var raw: Bool?
    /// Longest side in pixels.
    var size: Int?
    var jpeg: Bool?
}

struct ExportParams: Codable {
    var recording: String
    var format: ExportFormat
    var codec: ExportCodec?
    var resolution: ExportResolution?
    var clips: IMovieClips?
    var gifWidth: Int?
    var gifFrameRate: Int?
    /// Overrides the recording's subtitle setting for this export.
    var burnSubtitles: Bool?
    var subtitleFile: Bool?
}

// MARK: - Responses

struct ControlProgress: Codable {
    var progress: Double
}

struct ControlFailure: Codable {
    var error: String
}

struct ControlResult<Result> {
    var result: Result
}

extension ControlResult: Encodable where Result: Encodable {}

/// One line of the app's answer.
struct ControlMessage<Result: Decodable>: Decodable {
    var progress: Double?
    var error: String?
    var result: Result?
}

struct StatusInfo: Codable {
    /// idle, starting, countdown, recording, paused or saving.
    var state: String
    var countdown: Int?
    /// Seconds recorded so far.
    var elapsed: Double?
    var version: String
    var recordingsFolder: String
    var recordingCount: Int
    var permissions: [String: String]
}

struct SourcesInfo: Codable {
    struct Display: Codable {
        var id: UInt32
        var name: String
        /// Points.
        var width: Int
        var height: Int
        var pixelWidth: Int
        var pixelHeight: Int
        var isMain: Bool
    }

    struct Window: Codable {
        var id: UInt32
        var app: String
        var title: String
        var width: Int
        var height: Int
    }

    struct Device: Codable {
        var id: String
        var name: String
        var isSelected: Bool
    }

    var displays: [Display]
    var windows: [Window]
    var cameras: [Device]
    var microphones: [Device]
    var systemAudio: Bool
}

struct RecordingInfo: Codable {
    var id: UUID
    var title: String
    var createdAt: Date
    /// Seconds in the recording.
    var duration: Double
    /// Seconds in the edited video (trimmed, cut parts left out).
    var videoDuration: Double
    var captureMode: CaptureMode
    var source: String
    var width: Int
    var height: Int
    var frameRate: Int
    var hasCamera: Bool
    var audioTracks: [AudioTrackKind]
    var hasTranscript: Bool
    var folder: String?
}

struct RecordingDetails: Codable {
    struct Section: Codable {
        /// 1 for the first section.
        var number: Int
        /// Recording time.
        var start: Double
        var end: Double
        /// Where the section plays in the edited video; nil when it's cut or trimmed away.
        var videoStart: Double?
        var videoEnd: Double?
        var deleted: Bool
        var showsScreen: Bool
        var showsCamera: Bool
        var muted: Bool
        var blurs: [Blur]
        /// The section's own subtitle style; nil when it uses the recording's.
        var subtitles: SubtitleStyle?
    }

    struct Blur: Codable {
        var id: UUID
        var style: RedactionStyle
        /// x, y, width and height as fractions of the screen recording.
        var rect: [Double]
    }

    var recording: RecordingInfo
    var trimStart: Double
    var trimEnd: Double?
    var sections: [Section]
    var layout: LayoutStyle
    var camera: CameraOverlayStyle
    var subtitles: SubtitleStyle
    var audio: AudioMixSettings
    var transcriptLocale: String?
    var subtitleCount: Int?
    var files: [String: String]
}

struct RecordResult: Codable {
    var status: StatusInfo
    /// The saved recording, once the recording has ended.
    var recording: RecordingInfo?
}

struct EditResult: Codable {
    var message: String
    var recording: RecordingInfo
    /// IDs of what was added, e.g. blurred areas.
    var ids: [UUID]?
}

struct SilencesInfo: Codable {
    var track: AudioTrackKind
    var threshold: Double
    var suggestedThreshold: Double
    /// [start, end] in recording time.
    var pauses: [[Double]]
    var total: Double
    var applied: SilenceAction?
    var recording: RecordingInfo
}

struct TranscriptInfo: Codable {
    struct Cue: Codable {
        var start: Double
        var end: Double
        /// Where the cue plays in the edited video; nil when it's cut away.
        var videoStart: Double?
        var videoEnd: Double?
        var text: String
    }

    var locale: String
    var cues: [Cue]
    var words: [TranscriptWord]
    /// The subtitle file, when a format was asked for.
    var file: String?
}

/// Files the app wrote into `ControlChannel.stagingRoot`, for the tool to move into place.
struct FilesResult: Codable {
    var files: [String]
    /// A file name for the output, from the recording's title.
    var name: String?
    var width: Int?
    var height: Int?
    /// Seconds of video.
    var duration: Double?
    /// For a frame: its time in the recording and in the edited video.
    var time: Double?
    var videoTime: Double?
}

// MARK: - Formatting

enum ControlFormat {
    /// "12.4 s"; up to two decimals.
    static func seconds(_ value: Double) -> String {
        number(value) + " s"
    }

    /// "1.25–3.5 s"
    static func span(_ range: Range<Double>) -> String {
        "\(number(range.lowerBound))–\(seconds(range.upperBound))"
    }

    static func number(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// The start of an ID, enough to name a recording or blurred area.
    static func shortID(_ id: UUID) -> String {
        id.uuidString.prefix(8).lowercased()
    }
}
