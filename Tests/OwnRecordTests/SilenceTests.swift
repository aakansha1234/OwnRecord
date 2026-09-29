@preconcurrency import AVFoundation
import Foundation
@testable import OwnRecord
import Testing

@Suite struct SilenceTests {
    /// Levels from (seconds, dBFS) segments.
    private func levels(_ segments: [(Double, Float)]) -> AudioLevels {
        var decibels: [Float] = []
        for (length, level) in segments {
            decibels += Array(repeating: level, count: Int((length / AudioLevels.windowDuration).rounded()))
        }
        return AudioLevels(decibels: decibels)
    }

    private func approx(_ ranges: [Range<Double>], _ expected: [Range<Double>]) -> Bool {
        ranges.count == expected.count && zip(ranges, expected).allSatisfy {
            abs($0.lowerBound - $1.lowerBound) < 0.011 && abs($0.upperBound - $1.upperBound) < 0.011
        }
    }

    @Test func findsPausesWithPadding() {
        // Leading silence, speech, a long pause, speech, a short gap, speech, trailing silence.
        let audio = levels([(1, -65), (2, -20), (1.5, -62), (1, -22), (0.3, -60), (1, -18), (0.8, -64)])
        let pauses = audio.pauses(threshold: -45, minimumDuration: 0.6, padding: 0.1)
        // The edges of the recording aren't padded; the 0.3 s gap is too short.
        #expect(approx(pauses, [0..<0.9, 3.1..<4.4, 6.9..<7.6]), "\(pauses)")
        #expect(audio.pauses(threshold: -45, minimumDuration: 2, padding: 0.1).isEmpty)
        // Quieter threshold: nothing is that quiet.
        #expect(audio.pauses(threshold: -70, minimumDuration: 0.6, padding: 0.1).isEmpty)
    }

    @Test func clicksDontBreakAPause() {
        let audio = levels([(1, -20), (0.6, -60), (0.04, -10), (0.6, -60), (1, -20)])
        let pauses = audio.pauses(threshold: -45, minimumDuration: 1, padding: 0)
        #expect(approx(pauses, [1..<2.24]), "\(pauses)")
    }

    @Test func suggestsAThresholdBetweenNoiseAndSpeech() {
        let audio = levels([(3, -58), (6, -22), (2, -60)])
        let threshold = audio.suggestedThreshold
        #expect(threshold > -55 && threshold < -30, "\(threshold)")
        // Gated microphones record digital silence between words.
        let gated = levels([(2, AudioLevels.floor), (5, -18), (2, AudioLevels.floor)]).suggestedThreshold
        #expect(gated > -75 && gated < -30, "\(gated)")
    }

    @Test func cutsOnlyWhatIsInTheVideo() {
        var edit = EditSettings()
        edit.trimStart = 0.5
        edit.split(at: 6, duration: 10)
        edit.sections[1].isDeleted = true
        let cut = edit.cutPauses([0..<1.5, 3..<4, 5.5..<7], deleting: true, duration: 10)
        // Clipped to the trim and to the deleted section after 6 s.
        #expect(approx(cut, [0.5..<1.5, 3..<4, 5.5..<6]), "\(cut)")
        #expect(edit.sections.map(\.start) == [0, 0.5, 1.5, 3, 4, 5.5, 6])
        #expect(edit.sections.map(\.isDeleted) == [false, true, false, true, false, true, true])
        #expect(edit.keptRanges(duration: 10, applyingTrim: true) == [1.5..<3, 4..<5.5])
        // What was trimmed away isn't deleted, so it comes back with the trim.
        #expect(edit.keptRanges(duration: 10, applyingTrim: false).first == 0..<0.5)
    }

    @Test func pausesNextToExistingSplitsStillGetDeleted() {
        var edit = EditSettings()
        edit.split(at: 2, duration: 10)
        // Starts 50 ms after a split: too close to split again, but the sliver is part of the pause.
        edit.cutPauses([2.05..<4], deleting: true, duration: 10)
        #expect(edit.sections.map(\.start) == [0, 2, 4])
        #expect(edit.sections.map(\.isDeleted) == [false, true, false])
    }

    @Test func measuresAnAudioFile() async throws {
        let folder = PipelineTests.scratchRoot.appendingPathComponent("silence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("audio.m4a")

        // 1 s tone, 1.5 s silence, 1 s tone, as AAC like real recordings.
        try Self.writeTone(to: url, segments: [(1.0, 0.3), (1.5, 0), (1.0, 0.3)])

        let levels = try await SilenceDetector.levels(of: url, trackIndex: 0)
        #expect(abs(levels.duration - 3.5) < 0.1)
        let pauses = levels.pauses(threshold: levels.suggestedThreshold, minimumDuration: 0.8, padding: 0.1)
        try #require(pauses.count == 1, "\(pauses)")
        #expect(abs(pauses[0].lowerBound - 1.1) < 0.06)
        #expect(abs(pauses[0].upperBound - 2.4) < 0.06)
    }

    /// Writes a 440 Hz tone with the given (seconds, amplitude) segments. The file closes when released.
    static func writeTone(to url: URL, segments: [(Double, Float)]) throws {
        let rate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        for (length, amplitude) in segments {
            let frames = AVAudioFrameCount(length * rate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            let data = buffer.floatChannelData![0]
            for index in 0..<Int(frames) {
                data[index] = amplitude * sin(Float(index) * 2 * .pi * 440 / Float(rate))
            }
            try file.write(from: buffer)
        }
    }
}
