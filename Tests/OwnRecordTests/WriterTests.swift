@preconcurrency import AVFoundation
@testable import OwnRecord
import Testing

@Suite(.serialized) struct MovieWriterTests {
    private static func folder() throws -> URL {
        let url = PipelineTests.scratchRoot.appendingPathComponent("writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A Float32 PCM buffer of a 440 Hz tone, like the ones capture delivers.
    private static func tone(seconds: Double, channels: UInt32, start: CMTime) -> CMSampleBuffer {
        let rate = 48_000.0
        let frames = Int(seconds * rate)
        var description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var samples = [Float](repeating: 0, count: frames * Int(channels))
        for frame in 0..<frames {
            let value = Float(sin(Double(frame) / rate * 440 * 2 * .pi)) * 0.3
            for channel in 0..<Int(channels) { samples[frame * Int(channels) + channel] = value }
        }
        let length = samples.count * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: length,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length)
        }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!,
                                                             sampleCount: frames, presentationTimeStamp: start,
                                                             packetDescriptions: nil, sampleBufferOut: &buffer)
        return buffer!
    }

    private static func frame() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 200, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        return buffer!
    }

    private static func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }

    /// Writes a movie whose audio chunks are given as (start, duration) pairs, returning its URL.
    private static func write(_ chunks: [(Double, Double)], tracks: [AudioTrackKind] = [.microphone],
                              feed: AudioTrackKind = .microphone, end: Double) async throws -> URL {
        let url = try folder().appendingPathComponent("audio.mov")
        let writer = try MovieWriter(url: url, video: .camera(width: 320, height: 200), audioTracks: tracks)
        writer.start(at: .zero)
        writer.appendVideo(frame(), at: .zero)
        for (start, duration) in chunks {
            writer.appendAudio(tone(seconds: duration, channels: feed == .system ? 2 : 1, start: t(start)), kind: feed, at: t(start))
            try await Task.sleep(for: .milliseconds(20))
        }
        writer.prepareToFinish(at: t(end))
        #expect(try await writer.finishWriting())
        return url
    }

    private static func decodedSeconds(_ url: URL) async throws -> (seconds: Double, end: Double) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let range = try await track.load(.timeRange)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        reader.startReading()
        var frames = 0
        while let buffer = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(buffer) }
        return (Double(frames) / 48_000, range.end.seconds)
    }

    @Test func gapsAreFilledWithSilenceSoLaterAudioStaysInSync() async throws {
        // 0–1 s of audio, nothing for 2 s (e.g. mic reconnecting), then 3–4 s.
        let url = try await Self.write([(0, 1), (3, 1)], end: 4)
        let result = try await Self.decodedSeconds(url)
        #expect(abs(result.seconds - 4) < 0.1)
        #expect(abs(result.end - 4) < 0.1)
    }

    @Test func overlapsAreTrimmed() async throws {
        let url = try await Self.write([(0, 1), (0.5, 1)], end: 1.5)
        let result = try await Self.decodedSeconds(url)
        #expect(abs(result.seconds - 1.5) < 0.1)
    }

    @Test func audioTrackKindsComeFromTheFile() async throws {
        // Both tracks requested, but only the microphone ever delivers audio.
        let url = try await Self.write([(0, 1)], tracks: [.system, .microphone], feed: .microphone, end: 1)
        #expect(await MovieWriter.audioTrackKinds(in: url) == [.microphone])

        let stereo = try await Self.write([(0, 1)], tracks: [.system, .microphone], feed: .system, end: 1)
        #expect(await MovieWriter.audioTrackKinds(in: stereo) == [.system])
    }

    @Test func finishingACancelledWriterIsSafe() async throws {
        let url = try Self.folder().appendingPathComponent("cancelled.mov")
        let writer = try MovieWriter(url: url, video: .camera(width: 320, height: 200), audioTracks: [])
        writer.start(at: .zero)
        writer.appendVideo(Self.frame(), at: .zero)
        writer.cancel()
        writer.prepareToFinish(at: Self.t(1))
        #expect(try await writer.finishWriting() == false)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
