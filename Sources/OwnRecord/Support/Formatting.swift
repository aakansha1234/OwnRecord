import CoreMedia
import Foundation

enum TimeFormat {
    /// "01:05" or "1:02:05".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// "01:05.3" — used in the editor where sub-second precision matters.
    static func precise(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let rest = clamped - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, rest)
    }

    /// "4.2 s" or "1 min 12 s", for amounts of time rather than positions.
    static func length(_ seconds: Double) -> String {
        guard seconds >= 60 else { return String(format: "%.1f s", max(0, seconds)) }
        let total = Int(seconds.rounded())
        return total % 60 == 0 ? "\(total / 60) min" : "\(total / 60) min \(total % 60) s"
    }
}

extension Double {
    var cmTime: CMTime { CMTime(seconds: self, preferredTimescale: 60_000) }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
