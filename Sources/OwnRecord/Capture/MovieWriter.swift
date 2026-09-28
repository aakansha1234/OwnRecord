@preconcurrency import AVFoundation
import CoreMedia

enum CaptureError: LocalizedError {
    case writerSetupFailed(String)
    case noDisplay
    case windowUnavailable
    case areaUnavailable
    case permissionDenied
    case interrupted

    var errorDescription: String? {
        switch self {
        case .writerSetupFailed(let reason): "Couldn't prepare the recording file. \(reason)"
        case .noDisplay: "No display is available to record."
        case .windowUnavailable: "The selected window is no longer available. Choose another window."
        case .areaUnavailable: "Select an area of the screen to record."
        case .permissionDenied: "OwnRecord needs Screen Recording permission. Enable it in System Settings › Privacy & Security, then relaunch OwnRecord."
        case .interrupted: "Capture stopped before recording began — the window or display may no longer be available."
        }
    }
}

/// Writes video frames and audio buffers to a QuickTime movie.
///
/// Not thread-safe: all calls for one writer must come from the same serial queue.
final class MovieWriter: @unchecked Sendable {
    struct VideoSettings {
        var width: Int
        var height: Int
        var codec: AVVideoCodecType
        var bitrate: Int
        var frameRate: Int

        static func screen(size: CGSize, frameRate: Int, quality: VideoQuality) -> VideoSettings {
            let pixels = Double(size.width * size.height)
            let bitrate = (pixels * Double(frameRate) * quality.bitsPerPixel).clamped(to: 6_000_000...120_000_000)
            return VideoSettings(width: Int(size.width), height: Int(size.height), codec: .hevc,
                                 bitrate: Int(bitrate), frameRate: frameRate)
        }

        static func camera(width: Int, height: Int) -> VideoSettings {
            let bitrate = Double(width * height) * 30 * 0.15
            return VideoSettings(width: width & ~1, height: height & ~1, codec: .h264,
                                 bitrate: Int(bitrate.clamped(to: 2_000_000...16_000_000)), frameRate: 30)
        }
    }

    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audioInputs: [AudioTrackKind: AVAssetWriterInput] = [:]
    private var sessionStarted = false
    private var finished = false
    private var lastVideoTime = CMTime.invalid
    /// Where the next audio buffer of each track should start (end of the last appended one).
    private var nextAudioTime: [AudioTrackKind: CMTime] = [:]
    /// Timing mismatch tolerated before inserting silence or trimming overlap.
    private static let audioTolerance = 0.005
    private var lastPixelBuffer: CVPixelBuffer?

    init(url: URL, video: VideoSettings, audioTracks: [AudioTrackKind]) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw CaptureError.writerSetupFailed(error.localizedDescription)
        }
        // Periodic movie fragments keep the file playable if the app or Mac dies mid-recording.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: video.codec,
            AVVideoWidthKey: video.width,
            AVVideoHeightKey: video.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: video.bitrate,
                AVVideoExpectedSourceFrameRateKey: video.frameRate,
                AVVideoMaxKeyFrameIntervalKey: video.frameRate * 2,
                AVVideoAllowFrameReorderingKey: false,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoInput) else {
            throw CaptureError.writerSetupFailed("The video format isn't supported (\(video.width)×\(video.height)).")
        }
        writer.add(videoInput)

        for kind in audioTracks {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: kind == .system ? 2 : 1,
                AVEncoderBitRateKey: kind == .system ? 192_000 : 128_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { continue }
            writer.add(input)
            audioInputs[kind] = input
        }

        guard writer.startWriting() else {
            throw CaptureError.writerSetupFailed(writer.error?.localizedDescription ?? "Unknown error.")
        }
    }

    /// Starts the output timeline. Samples before `time` are ignored by the clock.
    func start(at time: CMTime) {
        guard !sessionStarted else { return }
        writer.startSession(atSourceTime: time)
        sessionStarted = true
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard sessionStarted, !finished, writer.status == .writing else { return }
        guard !lastVideoTime.isValid || time > lastVideoTime else { return }
        guard videoInput.isReadyForMoreMediaData else { return } // Drop the frame rather than stall capture.
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            lastVideoTime = time
            lastPixelBuffer = pixelBuffer
        }
    }

    /// Appends audio at `time`, keeping the track continuous.
    ///
    /// AAC encoding ignores timestamp gaps, so a missing buffer (device switch, dropped buffer,
    /// pause boundary) would shift all later audio earlier. Gaps are filled with silence and
    /// overlaps trimmed so audio stays locked to the video timeline.
    func appendAudio(_ sampleBuffer: CMSampleBuffer, kind: AudioTrackKind, at time: CMTime) {
        guard sessionStarted, !finished, writer.status == .writing,
              let input = audioInputs[kind], input.isReadyForMoreMediaData,
              var buffer = Self.retime(sampleBuffer, to: time),
              let format = buffer.formatDescription,
              let description = format.audioStreamBasicDescription, description.mSampleRate > 0 else { return }
        let rate = description.mSampleRate
        var start = time

        if let expected = nextAudioTime[kind] {
            let delta = (time - expected).seconds
            if delta > Self.audioTolerance {
                var cursor = expected
                var remaining = Int((delta * rate).rounded())
                while remaining > 0, input.isReadyForMoreMediaData {
                    let frames = min(remaining, Int(rate / 2))
                    guard let silence = Self.silence(frames: frames, format: format, description: description, at: cursor),
                          input.append(silence) else { break }
                    cursor = cursor + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate))
                    remaining -= frames
                }
                nextAudioTime[kind] = cursor
                guard remaining == 0, input.isReadyForMoreMediaData else { return }
            } else if delta < -Self.audioTolerance {
                let overlap = Int((-delta * rate).rounded())
                let frames = CMSampleBufferGetNumSamples(buffer)
                var trimmed: CMSampleBuffer?
                guard overlap < frames,
                      CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                                                             sampleRange: CFRange(location: overlap, length: frames - overlap),
                                                             sampleBufferOut: &trimmed) == noErr,
                      let trimmed else { return }
                buffer = trimmed
                start = expected
            }
        }

        if input.append(buffer) {
            let frames = CMSampleBufferGetNumSamples(buffer)
            nextAudioTime[kind] = start + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate))
        }
    }

    /// Holds the last frame until `endTime` and closes all inputs. Call on the writer's queue.
    func prepareToFinish(at endTime: CMTime) {
        guard !finished else { return }
        finished = true
        defer { lastPixelBuffer = nil }
        guard sessionStarted, writer.status == .writing else { return }
        if let pixelBuffer = lastPixelBuffer, lastVideoTime.isValid, endTime > lastVideoTime,
           videoInput.isReadyForMoreMediaData {
            adaptor.append(pixelBuffer, withPresentationTime: endTime)
        }
        videoInput.markAsFinished()
        audioInputs.values.forEach { $0.markAsFinished() }
        writer.endSession(atSourceTime: endTime)
    }

    /// Finalizes the file. Returns true if a playable movie with at least one frame was written.
    func finishWriting() async throws -> Bool {
        guard writer.status == .writing else {
            // Cancelled or failed: calling finishWriting now would raise an exception.
            if writer.status == .failed {
                throw CaptureError.writerSetupFailed(writer.error?.localizedDescription ?? "Writing failed.")
            }
            return false
        }
        guard sessionStarted, lastVideoTime.isValid else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return false
        }
        await writer.finishWriting()
        switch writer.status {
        case .completed: return true
        case .failed: throw CaptureError.writerSetupFailed(writer.error?.localizedDescription ?? "Writing failed.")
        default: return false
        }
    }

    func cancel() {
        finished = true
        lastPixelBuffer = nil
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }

    /// The kind of each audio track actually present in a finished movie, in track order.
    /// System audio is written as stereo and the microphone as mono.
    static func audioTrackKinds(in url: URL) async -> [AudioTrackKind]? {
        guard let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio) else { return nil }
        var kinds: [AudioTrackKind] = []
        for track in tracks.sorted(by: { $0.trackID < $1.trackID }) {
            let descriptions = (try? await track.load(.formatDescriptions)) ?? []
            let channels = descriptions.first?.audioStreamBasicDescription?.mChannelsPerFrame ?? 2
            kinds.append(channels == 1 ? .microphone : .system)
        }
        return kinds
    }

    private static func silence(frames: Int, format: CMAudioFormatDescription,
                                description: AudioStreamBasicDescription, at time: CMTime) -> CMSampleBuffer? {
        guard frames > 0, description.mBytesPerFrame > 0 else { return nil }
        let nonInterleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let length = frames * Int(description.mBytesPerFrame) * (nonInterleaved ? Int(description.mChannelsPerFrame) : 1)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: length,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }

    private static func retime(_ sampleBuffer: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        guard var timings = try? sampleBuffer.sampleTimingInfos(), !timings.isEmpty else { return nil }
        let delta = time - sampleBuffer.presentationTimeStamp
        for index in timings.indices {
            timings[index].presentationTimeStamp = timings[index].presentationTimeStamp + delta
            timings[index].decodeTimeStamp = .invalid
        }
        return try? CMSampleBuffer(copying: sampleBuffer, withNewTiming: timings)
    }
}
