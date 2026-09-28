import Foundation
import Observation

enum VideoQuality: String, CaseIterable, Identifiable, Codable {
    case standard, high
    var id: String { rawValue }
    var title: String { self == .standard ? "Standard" : "High" }
    /// Encoded bits per pixel per frame for HEVC screen recordings.
    var bitsPerPixel: Double { self == .standard ? 0.07 : 0.12 }
}

enum BubbleSize: String, CaseIterable, Identifiable, Codable {
    case small, medium, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// Height of the floating camera bubble in points.
    var points: CGFloat {
        switch self {
        case .small: 140
        case .medium: 200
        case .large: 280
        }
    }

    var next: BubbleSize {
        switch self {
        case .small: .medium
        case .medium: .large
        case .large: .small
        }
    }
}

/// User preferences, persisted in UserDefaults.
@MainActor @Observable
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults = UserDefaults.standard

    // Recording
    var frameRate: Int { didSet { defaults.set(frameRate, forKey: "frameRate") } }
    var countdown: Int { didSet { defaults.set(countdown, forKey: "countdown") } }
    var showCursor: Bool { didSet { defaults.set(showCursor, forKey: "showCursor") } }
    var highlightClicks: Bool { didSet { defaults.set(highlightClicks, forKey: "highlightClicks") } }
    var hideDesktopIcons: Bool { didSet { defaults.set(hideDesktopIcons, forKey: "hideDesktopIcons") } }
    var videoQuality: VideoQuality { didSet { defaults.set(videoQuality.rawValue, forKey: "videoQuality") } }

    // After recording
    var openEditorAfterRecording: Bool { didSet { defaults.set(openEditorAfterRecording, forKey: "openEditorAfterRecording") } }
    var autoTranscribe: Bool { didSet { defaults.set(autoTranscribe, forKey: "autoTranscribe") } }
    var transcriptionLocale: String { didSet { defaults.set(transcriptionLocale, forKey: "transcriptionLocale") } }

    // Camera
    var cameraStyle: CameraOverlayStyle { didSet { store(cameraStyle, forKey: "cameraStyle") } }
    var bubbleSize: BubbleSize { didSet { defaults.set(bubbleSize.rawValue, forKey: "bubbleSize") } }

    // Recorder selections
    var captureMode: CaptureMode { didSet { defaults.set(captureMode.rawValue, forKey: "captureMode") } }
    var cameraID: String? { didSet { defaults.set(cameraID ?? "", forKey: "cameraID") } }
    /// nil = no microphone.
    var microphoneID: String? { didSet { defaults.set(microphoneID ?? "", forKey: "microphoneID") } }
    var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: "captureSystemAudio") } }
    var lastArea: AreaSelection? { didSet { store(lastArea, forKey: "lastArea") } }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "frameRate": 60,
            "countdown": 3,
            "showCursor": true,
            "highlightClicks": false,
            "hideDesktopIcons": false,
            "openEditorAfterRecording": true,
            "autoTranscribe": true,
            "captureSystemAudio": true,
        ])
        frameRate = d.integer(forKey: "frameRate")
        countdown = d.integer(forKey: "countdown")
        showCursor = d.bool(forKey: "showCursor")
        highlightClicks = d.bool(forKey: "highlightClicks")
        hideDesktopIcons = d.bool(forKey: "hideDesktopIcons")
        videoQuality = VideoQuality(rawValue: d.string(forKey: "videoQuality") ?? "") ?? .standard
        openEditorAfterRecording = d.bool(forKey: "openEditorAfterRecording")
        autoTranscribe = d.bool(forKey: "autoTranscribe")
        transcriptionLocale = d.string(forKey: "transcriptionLocale")
            ?? TranscriptionEngine.defaultLocaleIdentifier()
        cameraStyle = Self.load(CameraOverlayStyle.self, from: d, key: "cameraStyle") ?? CameraOverlayStyle()
        bubbleSize = BubbleSize(rawValue: d.string(forKey: "bubbleSize") ?? "") ?? .medium
        captureMode = CaptureMode(rawValue: d.string(forKey: "captureMode") ?? "") ?? .display
        cameraID = d.string(forKey: "cameraID").flatMap { $0.isEmpty ? nil : $0 }
        // First launch: default to the system microphone. Afterwards "" means "no microphone".
        if let stored = d.string(forKey: "microphoneID") {
            microphoneID = stored.isEmpty ? nil : stored
        } else {
            microphoneID = CaptureDevices.defaultMicrophoneID
        }
        captureSystemAudio = d.bool(forKey: "captureSystemAudio")
        lastArea = Self.load(AreaSelection.self, from: d, key: "lastArea")
    }

    private func store<T: Encodable>(_ value: T?, forKey key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
