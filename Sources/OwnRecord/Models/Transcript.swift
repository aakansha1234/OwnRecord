import Foundation

struct TranscriptWord: Codable, Hashable {
    var text: String
    /// Seconds from the start of the recording.
    var start: Double
    var end: Double
}

struct SubtitleCue: Codable, Hashable, Identifiable {
    var id = UUID()
    /// Seconds from the start of the recording (not the trimmed timeline).
    var start: Double
    var end: Double
    var text: String
}

struct Transcript: Codable, Hashable {
    var localeIdentifier: String
    var createdAt: Date
    var words: [TranscriptWord]
    var cues: [SubtitleCue]

    var fullText: String {
        cues.map(\.text).joined(separator: " ")
    }

    func cue(at time: Double) -> SubtitleCue? {
        cues.first { time >= $0.start && time < $0.end }
    }
}
