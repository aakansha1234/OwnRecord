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
        /// Duration of the whole recording in seconds.
        let sourceDuration: Double
        /// Maps composition time to recording time.
        let timeline: TimelineMap
    }

    /// - Parameter ranges: Recording-time ranges to include, played back to back (trimmed and
    ///   deleted parts left out). nil includes everything.
    static func build(recording: Recording, files: RecordingFiles, ranges: [Range<Double>]?) async throws -> Result {
        let screenAsset = AVURLAsset(url: files.screen)
        guard let screenVideo = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw CompositionError.missingScreenVideo
        }
        let assetDuration = try await screenAsset.load(.duration)
        let naturalSize = try await screenVideo.load(.naturalSize)
        let fullRange = CMTimeRange(start: .zero, duration: assetDuration)
        let timeRanges = (ranges ?? [0..<assetDuration.seconds]).compactMap { range -> CMTimeRange? in
            let end = range.upperBound.isFinite ? range.upperBound.cmTime : assetDuration
            let clipped = CMTimeRangeGetIntersection(CMTimeRange(start: range.lowerBound.cmTime, end: end), otherRange: fullRange)
            return clipped.duration.seconds > 0.001 ? clipped : nil
        }
        guard !timeRanges.isEmpty else { throw CompositionError.emptyRange }

        let composition = AVMutableComposition()
        guard let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CompositionError.missingScreenVideo }

        // Keeps the asset alive while its track is inserted (tracks don't retain their asset).
        var cameraSource: (asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange)?
        if recording.hasCamera, FileManager.default.fileExists(atPath: files.camera.path) {
            let cameraAsset = AVURLAsset(url: files.camera)
            if let cameraVideo = try? await cameraAsset.loadTracks(withMediaType: .video).first,
               let cameraRange = try? await cameraVideo.load(.timeRange) {
                cameraSource = (cameraAsset, cameraVideo, cameraRange)
            }
        }
        var cameraTrack: AVMutableCompositionTrack?

        var audioSources: [(track: AVAssetTrack, range: CMTimeRange, kind: AudioTrackKind)] = []
        let audioTracks = try await screenAsset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        for (index, sourceTrack) in audioTracks.enumerated() where index < recording.audioTracks.count {
            audioSources.append((sourceTrack, try await sourceTrack.load(.timeRange), recording.audioTracks[index]))
        }
        var audioTargets: [AudioTrackKind: AVMutableCompositionTrack] = [:]

        var cursor = CMTime.zero
        var pieces: [TimelineMap.Piece] = []
        for timeRange in timeRanges {
            try screenTrack.insertTimeRange(timeRange, of: screenVideo, at: cursor)

            if let cameraSource {
                let overlap = CMTimeRangeGetIntersection(timeRange, otherRange: cameraSource.range)
                if overlap.duration.seconds > 0 {
                    if cameraTrack == nil {
                        cameraTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    try cameraTrack?.insertTimeRange(overlap, of: cameraSource.track, at: cursor + (overlap.start - timeRange.start))
                }
            }

            for source in audioSources {
                let overlap = CMTimeRangeGetIntersection(timeRange, otherRange: source.range)
                guard overlap.duration.seconds > 0 else { continue }
                if audioTargets[source.kind] == nil {
                    audioTargets[source.kind] = composition.addMutableTrack(withMediaType: .audio,
                                                                            preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                try audioTargets[source.kind]?.insertTimeRange(overlap, of: source.track, at: cursor + (overlap.start - timeRange.start))
            }

            pieces.append(TimelineMap.Piece(sourceStart: timeRange.start.seconds, sourceEnd: timeRange.end.seconds,
                                            outputStart: cursor.seconds))
            cursor = cursor + timeRange.duration
        }

        return Result(composition: composition, screenTrackID: screenTrack.trackID, cameraTrackID: cameraTrack?.trackID,
                      microphoneTrack: audioTargets[.microphone], systemTrack: audioTargets[.system],
                      sourceSize: naturalSize, duration: cursor.seconds, sourceDuration: assetDuration.seconds,
                      timeline: TimelineMap(pieces: pieces))
    }

    static func videoComposition(for result: Result, recording: Recording, renderSize: CGSize,
                                 highQuality: Bool) -> AVMutableVideoComposition {
        let state = RenderState(edit: recording.edit,
                                cues: recording.transcript?.cues ?? [],
                                timeline: result.timeline,
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

    /// Track volumes, silenced during sections with muted audio.
    static func audioMix(for result: Result, edit: EditSettings) -> AVAudioMix {
        let muted = mutedRanges(edit: edit, timeline: result.timeline)
        let mix = AVMutableAudioMix()
        var parameters: [AVMutableAudioMixInputParameters] = []
        for (track, volume) in [(result.microphoneTrack, edit.audio.microphoneVolume), (result.systemTrack, edit.audio.systemVolume)] {
            guard let track else { continue }
            let input = AVMutableAudioMixInputParameters(track: track)
            for change in volumeChanges(volume: Float(volume), muted: muted) {
                input.setVolume(change.volume, at: change.time.cmTime)
            }
            parameters.append(input)
        }
        mix.inputParameters = parameters
        return mix
    }

    /// Composition-time ranges where audio is muted.
    static func mutedRanges(edit: EditSettings, timeline: TimelineMap) -> [Range<Double>] {
        var ranges: [Range<Double>] = []
        for index in edit.sections.indices where edit.sections[index].mutesAudio && !edit.sections[index].isDeleted {
            let source = edit.range(ofSectionAt: index, duration: .greatestFiniteMagnitude)
            for range in timeline.outputRanges(forSource: source) {
                if let last = ranges.last, abs(last.upperBound - range.lowerBound) < 1e-6 {
                    ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
                } else {
                    ranges.append(range)
                }
            }
        }
        return ranges
    }

    /// Volume steps for a track: `volume`, dropping to silence over each muted range.
    static func volumeChanges(volume: Float, muted: [Range<Double>]) -> [(time: Double, volume: Float)] {
        var changes: [(time: Double, volume: Float)] = [(0, volume)]
        for range in muted {
            if let last = changes.last, abs(last.time - range.lowerBound) < 1e-6 {
                changes[changes.count - 1].volume = 0
            } else {
                changes.append((range.lowerBound, 0))
            }
            changes.append((range.upperBound, volume))
        }
        return changes
    }
}
