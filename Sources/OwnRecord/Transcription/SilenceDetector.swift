@preconcurrency import AVFoundation
import Accelerate

/// How loud a recording's audio is over time, in short windows. Used to find pauses.
struct AudioLevels: Equatable, Sendable {
    static let windowDuration = 0.02
    /// Level reported for digital silence.
    static let floor: Float = -100

    /// RMS level of each window in dBFS, from the start of the recording.
    let decibels: [Float]
    /// A threshold between the background noise and speech, from the level distribution.
    let suggestedThreshold: Double

    init(decibels: [Float]) {
        self.decibels = decibels
        suggestedThreshold = Self.threshold(for: decibels)
    }

    var duration: Double { Double(decibels.count) * Self.windowDuration }

    private static func threshold(for decibels: [Float]) -> Double {
        // Digital silence (e.g. from a mic with a noise gate) counts as background too.
        let sorted = decibels.sorted()
        guard sorted.count > 10 else { return -50 }
        let noise = Double(sorted[sorted.count / 10])
        let speech = Double(sorted[sorted.count * 9 / 10])
        let gap = speech - noise
        let threshold = gap < 12 ? noise + 6 : noise + gap * 0.3
        return threshold.clamped(to: -70...(-20))
    }

    /// Stretches quieter than `threshold` that last at least `minimumDuration` seconds, shrunk by
    /// `padding` on sides that border sound (so word endings and breaths stay in).
    func pauses(threshold: Double, minimumDuration: Double, padding: Double) -> [Range<Double>] {
        let window = Self.windowDuration
        // Clicks and taps shorter than this don't interrupt a pause.
        let bridge = 2
        var quiet = decibels.map { Double($0) < threshold }
        var index = 0
        while index < quiet.count {
            guard !quiet[index] else { index += 1; continue }
            var end = index
            while end < quiet.count, !quiet[end] { end += 1 }
            if end - index <= bridge, index > 0, end < quiet.count {
                for loud in index..<end { quiet[loud] = true }
            }
            index = end
        }

        var pauses: [Range<Double>] = []
        var start: Int?
        for position in 0...quiet.count {
            let isQuiet = position < quiet.count && quiet[position]
            if isQuiet, start == nil {
                start = position
            } else if !isQuiet, let first = start {
                start = nil
                guard Double(position - first) * window >= minimumDuration else { continue }
                let lower = first == 0 ? 0 : Double(first) * window + padding
                let upper = position == quiet.count ? duration : Double(position) * window - padding
                if upper - lower >= EditSettings.minimumSectionLength * 2 {
                    pauses.append(lower..<upper)
                }
            }
        }
        return pauses
    }
}

enum SilenceDetector {
    private static let sampleRate = 16_000.0

    /// Measures the level of one audio track of `url` (index in track ID order).
    static func levels(of url: URL, trackIndex: Int) async throws -> AudioLevels {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        guard tracks.indices.contains(trackIndex) else { throw TranscriptionError.noAudio }
        let duration = try await asset.load(.duration).seconds

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[trackIndex], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TranscriptionError.noAudio }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TranscriptionError.noAudio }

        let windowCount = max(1, Int((duration / AudioLevels.windowDuration).rounded(.up)))
        var sums = [Double](repeating: 0, count: windowCount)
        var counts = [Int](repeating: 0, count: windowCount)
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            samples = [Float](repeating: 0, count: count)
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                               destination: raw.baseAddress!)
            }
            // Place samples by their timestamps, so audio that starts late stays in sync.
            let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            for (offset, sample) in samples.enumerated() {
                let window = Int((start + Double(offset) / sampleRate) / AudioLevels.windowDuration)
                guard window >= 0, window < windowCount else { continue }
                sums[window] += Double(sample * sample)
                counts[window] += 1
            }
        }
        if reader.status == .failed { throw reader.error ?? TranscriptionError.noAudio }

        let decibels = zip(sums, counts).map { sum, count -> Float in
            guard count > 0, sum > 0 else { return AudioLevels.floor }
            return max(AudioLevels.floor, Float(10 * log10(sum / Double(count))))
        }
        return AudioLevels(decibels: decibels)
    }
}

extension Recording {
    /// The track pauses are found in: the microphone (your voice) unless it's muted in the mix.
    var silenceTrack: AudioTrackKind? {
        if hasMicrophone, edit.audio.microphoneVolume > 0 || !hasSystemAudio { return .microphone }
        return hasSystemAudio ? .system : nil
    }
}

extension EditSettings {
    /// The parts of `pauses` that are in the video (not trimmed or deleted) and long enough to cut.
    func pausesInVideo(_ pauses: [Range<Double>], duration: Double) -> [Range<Double>] {
        let kept = keptRanges(duration: duration, applyingTrim: true)
        var result: [Range<Double>] = []
        for pause in pauses {
            for range in kept {
                let lower = max(pause.lowerBound, range.lowerBound)
                let upper = min(pause.upperBound, range.upperBound)
                if upper - lower >= Self.minimumSectionLength * 2 { result.append(lower..<upper) }
            }
        }
        return result
    }

    /// Splits the video around `pauses` (recording time), leaving out the parts that aren't in the
    /// video anyway, and with `deleting` removes them. Returns the pauses that were cut.
    @discardableResult
    mutating func cutPauses(_ pauses: [Range<Double>], deleting: Bool, duration: Double) -> [Range<Double>] {
        let kept = keptRanges(duration: duration, applyingTrim: true)
        let cut = pausesInVideo(pauses, duration: duration)
        // Splitting at trim edges too keeps material outside the trim out of deleted pauses, so
        // it's still there when the trim is reset.
        for pause in cut {
            split(at: pause.lowerBound, duration: duration)
            split(at: pause.upperBound, duration: duration)
        }
        if deleting {
            // A split refused next to an existing one leaves a sliver; it's still part of the pause.
            let slack = Self.minimumSectionLength
            func isPause(_ part: Range<Double>) -> Bool {
                cut.contains { $0.lowerBound - slack <= part.lowerBound && part.upperBound <= $0.upperBound + slack }
            }
            for index in sections.indices where !sections[index].isDeleted {
                let range = self.range(ofSectionAt: index, duration: duration)
                // Only the part of the section that's in the video has to be silent.
                let parts = kept.map { $0.clamped(to: range) }.filter { $0.upperBound - $0.lowerBound > 1e-6 }
                if !parts.isEmpty, parts.allSatisfy(isPause) {
                    sections[index].isDeleted = true
                }
            }
        }
        return cut
    }
}
