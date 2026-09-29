@preconcurrency import AVFoundation

/// Which clips an iMovie export contains.
enum IMovieClips: String, CaseIterable, Identifiable, Codable {
    case separate, finished, both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .separate: "Screen and camera"
        case .finished: "Finished video"
        case .both: "Both"
        }
    }
}

/// One exported clip.
struct ExportedClip: Equatable, Sendable {
    enum Kind: Sendable {
        case finished, screen, camera

        var title: String {
            switch self {
            case .finished: "Video"
            case .screen: "Screen"
            case .camera: "Camera"
            }
        }

        var symbol: String {
            switch self {
            case .finished: "film"
            case .screen: "display"
            case .camera: "video"
            }
        }
    }

    let kind: Kind
    let url: URL
}

/// iMovie can't open project files, so the edit goes over as clips with everything applied:
/// cuts, blurs, hidden parts (black) and muted parts. The finished video looks like the preview;
/// the screen and camera clips have the same length, so they line up when stacked in iMovie
/// (e.g. the camera as picture in picture). The screen clip carries the audio.
enum IMovieExporter {
    /// Writes the clips into `folder`, creating it if needed. Other files in it are left alone;
    /// if the export fails or is cancelled, the clips it was writing (and a folder it created) are removed.
    static func export(recording: Recording, files: RecordingFiles, options: ExportOptions, to folder: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> [ExportedClip] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let existed = fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory)
        if existed, !isDirectory.boolValue { try fileManager.removeItem(at: folder) }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var started: [URL] = []
        do {
            return try await write(recording: recording, files: files, options: options, to: folder,
                                   started: &started, progress: progress)
        } catch {
            for url in started { try? fileManager.removeItem(at: url) }
            if !(existed && isDirectory.boolValue), (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? fileManager.removeItem(at: folder)
            }
            throw error
        }
    }

    /// - Parameter started: Each clip's URL, added just before it's written.
    private static func write(recording: Recording, files: RecordingFiles, options: ExportOptions, to folder: URL,
                              started: inout [URL], progress: @escaping @Sendable (Double) -> Void) async throws -> [ExportedClip] {
        let movie = options.movieOptions
        let name = EditorModel.fileName(for: recording.title)
        var clips = recording.hasCamera ? options.iMovieClips : .finished

        // The separate clips need camera footage in the edit; without it, the finished video is what you see.
        var separate: (built: CompositionBuilder.Result, cameraSize: CGSize)?
        if clips != .finished {
            let ranges = recording.edit.keptRanges(duration: .infinity, applyingTrim: true)
            let built = try await CompositionBuilder.build(recording: recording, files: files, ranges: ranges)
            if built.cameraTrackID != nil, let size = try await cameraSize(files) {
                separate = (built, size)
            } else {
                clips = .finished
            }
        }

        // Progress weights: the camera clip is small and quick.
        let total = (clips != .separate ? 1 : 0) + (separate != nil ? 1.4 : 0)
        var done = 0.0
        func reporter(_ weight: Double) -> @Sendable (Double) -> Void {
            let base = done
            return { progress((base + $0 * weight) / total) }
        }

        var exported: [ExportedClip] = []
        if clips != .separate {
            let url = folder.appendingPathComponent("\(name).mov")
            started.append(url)
            try await VideoExporter.export(recording: recording, files: files, options: movie, to: url, progress: reporter(1))
            exported.append(ExportedClip(kind: .finished, url: url))
            done += 1
        }
        guard let (built, cameraSize) = separate else { return exported }

        let screenURL = folder.appendingPathComponent("\(name) – Screen.mov")
        started.append(screenURL)
        try? FileManager.default.removeItem(at: screenURL)
        try await VideoExporter.writeMovie(
            built.composition,
            videoComposition: CompositionBuilder.videoComposition(for: built, recording: recording,
                                                                  renderSize: screenClipSize(source: built.sourceSize, options: options),
                                                                  highQuality: true, layer: .screen),
            audioMix: CompositionBuilder.audioMix(for: built, edit: recording.edit),
            codec: movie.codec, fileType: .mov, to: screenURL, progress: reporter(1))
        exported.append(ExportedClip(kind: .screen, url: screenURL))
        done += 1

        // The screen clip carries the sound; the camera clip is silent.
        for track in [built.microphoneTrack, built.systemTrack].compactMap({ $0 }) {
            built.composition.removeTrack(track)
        }
        let cameraURL = folder.appendingPathComponent("\(name) – Camera.mov")
        started.append(cameraURL)
        try? FileManager.default.removeItem(at: cameraURL)
        let size = VideoExporter.renderSize(canvas: cameraSize.evenRounded(), options: movie)
        try await VideoExporter.writeMovie(
            built.composition,
            videoComposition: CompositionBuilder.videoComposition(for: built, recording: recording, renderSize: size,
                                                                  highQuality: true, layer: .camera),
            audioMix: nil, codec: movie.codec, fileType: .mov, to: cameraURL, progress: reporter(0.4))
        exported.append(ExportedClip(kind: .camera, url: cameraURL))
        return exported
    }

    /// Size of the screen clip: the recording's own shape, at the chosen resolution.
    static func screenClipSize(source: CGSize, options: ExportOptions) -> CGSize {
        VideoExporter.renderSize(canvas: source.evenRounded(), options: options.movieOptions)
    }

    private static func cameraSize(_ files: RecordingFiles) async throws -> CGSize? {
        guard FileManager.default.fileExists(atPath: files.camera.path),
              let track = try await AVURLAsset(url: files.camera).loadTracks(withMediaType: .video).first else { return nil }
        let size = try await track.load(.naturalSize)
        return size.width > 0 && size.height > 0 ? size : nil
    }
}
