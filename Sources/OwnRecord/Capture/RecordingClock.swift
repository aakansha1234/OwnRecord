import CoreMedia
import Foundation

/// Maps host-clock sample timestamps onto the recording's output timeline.
///
/// Every writer (screen, camera) starts its session at the same host time, so their files
/// line up without any post-processing. Pauses are removed by shifting later samples back
/// by the total paused duration; samples captured while paused are dropped.
final class RecordingClock: @unchecked Sendable {
    private struct Pause {
        var start: CMTime
        var end: CMTime?
    }

    private let lock = NSLock()
    private var start: CMTime?
    private var pauses: [Pause] = []
    private var ended = false

    static func now() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    var startTime: CMTime? {
        lock.lock(); defer { lock.unlock() }
        return start
    }

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return pauses.last.map { $0.end == nil } ?? false
    }

    func begin(at time: CMTime) {
        lock.lock(); defer { lock.unlock() }
        start = time
        pauses.removeAll()
        ended = false
    }

    func pause(at time: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard start != nil, !ended, pauses.last.map({ $0.end != nil }) ?? true else { return }
        pauses.append(Pause(start: time, end: nil))
    }

    func resume(at time: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard let last = pauses.last, last.end == nil else { return }
        pauses[pauses.count - 1].end = max(time, last.start)
    }

    /// Stops accepting samples. Anything still in flight is dropped.
    func end() {
        lock.lock(); defer { lock.unlock() }
        ended = true
    }

    /// The output timestamp for a host-clock timestamp, or nil if the sample should be dropped.
    func outputTime(for hostTime: CMTime) -> CMTime? {
        lock.lock(); defer { lock.unlock() }
        guard !ended, let start, hostTime.isValid, hostTime >= start else { return nil }
        var offset = CMTime.zero
        for pause in pauses where hostTime >= pause.start {
            guard let end = pause.end, hostTime >= end else { return nil }
            offset = offset + (end - pause.start)
        }
        return hostTime - offset
    }

    /// The output timestamp at which a recording stopped at `hostTime` ends (pause-aware).
    func endTime(at hostTime: CMTime) -> CMTime? {
        lock.lock(); defer { lock.unlock() }
        guard let start else { return nil }
        var offset = CMTime.zero
        var effective = hostTime
        for pause in pauses {
            if let end = pause.end {
                offset = offset + (end - pause.start)
            } else {
                effective = pause.start
            }
        }
        return max(start, effective - offset)
    }

    /// Recorded (unpaused) seconds as of `hostTime`.
    func elapsed(at hostTime: CMTime) -> Double {
        guard let start = startTime, let end = endTime(at: hostTime) else { return 0 }
        return max(0, (end - start).seconds)
    }
}
