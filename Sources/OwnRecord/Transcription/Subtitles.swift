import Foundation

/// Groups timed words into readable subtitle cues.
enum CueBuilder {
    static func cues(from words: [TranscriptWord], maxCharacters: Int = 64, maxDuration: Double = 6,
                     maxGap: Double = 1.0, joiner: String = " ") -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var current: [TranscriptWord] = []
        var currentLength = 0

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: joiner)
            cues.append(SubtitleCue(start: first.start, end: last.end, text: text))
            current.removeAll()
            currentLength = 0
        }

        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let first = current.first, let last = current.last {
                let length = currentLength + joiner.count + text.count
                let endsSentence = last.text.last.map { ".?!…。？！".contains($0) } ?? false
                if length > maxCharacters
                    || word.end - first.start > maxDuration
                    || word.start - last.end > maxGap
                    || (endsSentence && currentLength >= 16) {
                    flush()
                }
            }
            currentLength += (current.isEmpty ? 0 : joiner.count) + text.count
            current.append(TranscriptWord(text: text, start: word.start, end: word.end))
        }
        flush()

        // Keep each cue on screen long enough to read, without overlapping the next one.
        for index in cues.indices {
            let nextStart = index + 1 < cues.count ? cues[index + 1].start : .greatestFiniteMagnitude
            let desired = max(cues[index].end + 0.3, cues[index].start + 1.0)
            cues[index].end = max(cues[index].end, min(desired, nextStart - 0.01))
        }
        return cues
    }

    /// Whether words in this language are separated by spaces.
    static func joiner(for localeIdentifier: String) -> String {
        let language = Locale(identifier: localeIdentifier).language.languageCode?.identifier ?? ""
        return ["zh", "ja", "th", "lo", "km", "my"].contains(language) ? "" : " "
    }
}

enum SubtitleFileFormat: String, CaseIterable, Identifiable {
    case srt, vtt, txt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .srt: "SubRip (.srt)"
        case .vtt: "WebVTT (.vtt)"
        case .txt: "Plain Text (.txt)"
        }
    }
}

enum SubtitleExporter {
    /// Moves cues onto the edited video's timeline, dropping those that were cut away.
    static func cues(_ cues: [SubtitleCue], timeline: TimelineMap) -> [SubtitleCue] {
        cues.compactMap { cue in
            let ranges = timeline.outputRanges(forSource: cue.start..<max(cue.start, cue.end))
            guard let first = ranges.first, let last = ranges.last else { return nil }
            return SubtitleCue(id: cue.id, start: first.lowerBound, end: last.upperBound, text: cue.text)
        }
    }

    static func string(for cues: [SubtitleCue], format: SubtitleFileFormat) -> String {
        switch format {
        case .srt:
            return cues.enumerated().map { index, cue in
                "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(cue.text)\n"
            }.joined(separator: "\n")
        case .vtt:
            let body = cues.map { cue in
                "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n\(cue.text)\n"
            }.joined(separator: "\n")
            return "WEBVTT\n\n" + body
        case .txt:
            return cues.map(\.text).joined(separator: "\n") + "\n"
        }
    }

    static func timestamp(_ seconds: Double, separator: String) -> String {
        let milliseconds = Int((max(0, seconds) * 1000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let secs = (milliseconds / 1000) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs) + separator + String(format: "%03d", milliseconds % 1000)
    }
}
