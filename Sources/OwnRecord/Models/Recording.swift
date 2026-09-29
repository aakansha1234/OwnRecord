import CoreGraphics
import Foundation

enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case display, window, area

    var id: String { rawValue }

    var title: String {
        switch self {
        case .display: "Screen"
        case .window: "Window"
        case .area: "Area"
        }
    }

    var symbol: String {
        switch self {
        case .display: "display"
        case .window: "macwindow"
        case .area: "rectangle.dashed"
        }
    }
}

enum AudioTrackKind: String, Codable, Hashable {
    case system, microphone
}

/// Metadata for one recording. Stored as `recording.json` next to the media files.
struct Recording: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: Double
    var captureMode: CaptureMode
    var sourceName: String
    var pixelWidth: Int
    var pixelHeight: Int
    var frameRate: Int
    var hasCamera: Bool
    /// Audio tracks in `screen.mov`, in track order.
    var audioTracks: [AudioTrackKind]
    var edit: EditSettings
    var transcript: Transcript?

    var hasMicrophone: Bool { audioTracks.contains(.microphone) }
    var hasSystemAudio: Bool { audioTracks.contains(.system) }
    var hasAudio: Bool { !audioTracks.isEmpty }
    var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }

    /// Whether the title, source or transcript contains `query`.
    func matches(search query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query)
            || sourceName.localizedCaseInsensitiveContains(query)
            || (transcript?.fullText.localizedCaseInsensitiveContains(query) ?? false)
    }
}

/// File layout of a recording folder.
struct RecordingFiles {
    let folder: URL

    var metadata: URL { folder.appendingPathComponent("recording.json") }
    var screen: URL { folder.appendingPathComponent("screen.mov") }
    var camera: URL { folder.appendingPathComponent("camera.mov") }
    var thumbnail: URL { folder.appendingPathComponent("thumbnail.jpg") }
}

/// A user-selected region of a display, in display-local points with a top-left origin.
struct AreaSelection: Codable, Hashable {
    var displayID: CGDirectDisplayID
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(displayID: CGDirectDisplayID, rect: CGRect) {
        self.displayID = displayID
        x = rect.minX
        y = rect.minY
        width = rect.width
        height = rect.height
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
