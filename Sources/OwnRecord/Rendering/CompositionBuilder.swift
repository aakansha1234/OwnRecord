@preconcurrency import AVFoundation

enum CompositionError: LocalizedError {
    case missingScreenVideo
    case emptyRange

    var errorDescription: String? {
        switch self {
        case .missingScreenVideo: "The screen recording file is missing or unreadable."
        case .emptyRange: "The trimmed recording is empty."
        }
    }
}

/// Builds an AVComposition from a recording's screen, camera and audio files.
enum CompositionBuilder {
    struct Result {
        let composition: AVMutableComposition
        let screenTrackID: CMPersistentTrackID
        let cameraTrackID: CMPersistentTrackID?
        let microphoneTrack: AVMutableCompositionTrack?
        let systemTrack: AVMutableCompositionTrack?
        let sourceSize: CGSize
        /// Duration of the composition in seconds.
        let duration: Double
    }

    /// - Parameter range: Source range to include (trimmed exports). nil includes everything.
    static func build(recording: Recording, files: RecordingFiles, range: CMTimeRange?) async throws -> Result {
        let screenAsset = AVURLAsset(url: files.screen)
        guard let screenVideo = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw CompositionError.missingScreenVideo
        }
        let assetDuration = try await screenAsset.load(.duration)
        let naturalSize = try await screenVideo.load(.naturalSize)
        let fullRange = CMTimeRange(start: .zero, duration: assetDuration)
        let timeRange = range.map { CMTimeRangeGetIntersection($0, otherRange: fullRange) } ?? fullRange
        guard timeRange.duration.seconds > 0 else { throw CompositionError.emptyRange }

        let composition = AVMutableComposition()
        guard let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CompositionError.missingScreenVideo }
        try screenTrack.insertTimeRange(timeRange, of: screenVideo, at: .zero)

        var cameraTrackID: CMPersistentTrackID?
        if recording.hasCamera, FileManager.default.fileExists(atPath: files.camera.path) {
            let cameraAsset = AVURLAsset(url: files.camera)
            if let cameraVideo = try? await cameraAsset.loadTracks(withMediaType: .video).first,
               let cameraRange = try? await cameraVideo.load(.timeRange) {
                let overlap = CMTimeRangeGetIntersection(timeRange, otherRange: cameraRange)
                if overlap.duration.seconds > 0,
                   let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try track.insertTimeRange(overlap, of: cameraVideo, at: overlap.start - timeRange.start)
                    cameraTrackID = track.trackID
                }
            }
        }

        var microphoneTrack: AVMutableCompositionTrack?
        var systemTrack: AVMutableCompositionTrack?
        let audioTracks = try await screenAsset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        for (index, sourceTrack) in audioTracks.enumerated() where index < recording.audioTracks.count {
            let sourceRange = try await sourceTrack.load(.timeRange)
            let overlap = CMTimeRangeGetIntersection(timeRange, otherRange: sourceRange)
            guard overlap.duration.seconds > 0,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try track.insertTimeRange(overlap, of: sourceTrack, at: overlap.start - timeRange.start)
            switch recording.audioTracks[index] {
            case .microphone: microphoneTrack = track
            case .system: systemTrack = track
            }
        }

        return Result(composition: composition, screenTrackID: screenTrack.trackID, cameraTrackID: cameraTrackID,
                      microphoneTrack: microphoneTrack, systemTrack: systemTrack,
                      sourceSize: naturalSize, duration: timeRange.duration.seconds)
    }

    static func videoComposition(for result: Result, recording: Recording, renderSize: CGSize,
                                 timeOffset: Double, highQuality: Bool) -> AVMutableVideoComposition {
        let state = RenderState(edit: recording.edit,
                                cues: recording.transcript?.cues ?? [],
                                timeOffset: timeOffset,
                                sourceSize: result.sourceSize,
                                hasCamera: result.cameraTrackID != nil,
                                highQuality: highQuality)
        let instruction = OverlayInstruction(timeRange: CMTimeRange(start: .zero, duration: result.composition.duration),
                                             screenTrackID: result.screenTrackID,
                                             cameraTrackID: result.cameraTrackID,
                                             state: state)
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = OverlayCompositor.self
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, recording.frameRate)))
        composition.renderSize = renderSize
        composition.instructions = [instruction]
        return composition
    }

    static func audioMix(for result: Result, settings: AudioMixSettings) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        var parameters: [AVMutableAudioMixInputParameters] = []
        if let track = result.microphoneTrack {
            let input = AVMutableAudioMixInputParameters(track: track)
            input.setVolume(Float(settings.microphoneVolume), at: .zero)
            parameters.append(input)
        }
        if let track = result.systemTrack {
            let input = AVMutableAudioMixInputParameters(track: track)
            input.setVolume(Float(settings.systemVolume), at: .zero)
            parameters.append(input)
        }
        mix.inputParameters = parameters
        return mix
    }
}
