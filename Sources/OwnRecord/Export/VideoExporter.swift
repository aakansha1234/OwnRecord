@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case mp4, mov, gif

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }

    var contentType: UTType {
        switch self {
        case .mp4: .mpeg4Movie
        case .mov: .quickTimeMovie
        case .gif: .gif
        }
    }
}

enum ExportCodec: String, CaseIterable, Identifiable, Codable {
    case h264, hevc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }

    var detail: String {
        switch self {
        case .h264: "Plays everywhere"
        case .hevc: "Smaller files, modern devices"
        }
    }
}

enum ExportResolution: String, CaseIterable, Identifiable, Codable {
    case original, uhd, qhd, fullHD, hd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original"
        case .uhd: "4K"
        case .qhd: "1440p"
        case .fullHD: "1080p"
        case .hd: "720p"
        }
    }

    /// Target length of the canvas' shorter side.
    var shortSide: CGFloat? {
        switch self {
        case .original: nil
        case .uhd: 2160
        case .qhd: 1440
        case .fullHD: 1080
        case .hd: 720
        }
    }
}

struct ExportOptions: Codable, Hashable {
    var format: ExportFormat = .mp4
    var codec: ExportCodec = .h264
    var resolution: ExportResolution = .fullHD
    var gifWidth: Int = 800
    var gifFrameRate: Int = 15
    var includeSubtitleFile = false
}

enum VideoExporter {
    /// Output pixel size for a canvas. Never upscales; keeps H.264 within its 4096 px limit.
    /// - Parameter ratio: The aspect preset's exact ratio, so e.g. 16:9 at 1080p is exactly 1920×1080.
    static func renderSize(canvas: CGSize, ratio: CGFloat? = nil, options: ExportOptions) -> CGSize {
        if options.format == .gif {
            let width = min(CGFloat(options.gifWidth), canvas.width)
            return CGSize(width: width, height: width / canvas.aspectRatio).evenRounded()
        }
        var scale: CGFloat = 1
        if let shortSide = options.resolution.shortSide {
            scale = min(1, shortSide / min(canvas.width, canvas.height))
        }
        if options.codec == .h264 {
            scale = min(scale, 4096 / max(canvas.width, canvas.height))
        }
        var size = canvas.scaled(scale)
        if let ratio {
            if size.width >= size.height {
                size.width = size.height * ratio
            } else {
                size.height = size.width / ratio
            }
        }
        return size.evenRounded()
    }

    static func export(recording: Recording, files: RecordingFiles, options: ExportOptions, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        // Trimmed and deleted parts are left out; the rest plays back to back.
        let ranges = recording.edit.keptRanges(duration: .infinity, applyingTrim: true)
        let built = try await CompositionBuilder.build(recording: recording, files: files, ranges: ranges)
        let canvas = LayoutEngine.canvasSize(source: built.sourceSize, aspect: recording.edit.layout.aspect)
        let size = renderSize(canvas: canvas, ratio: recording.edit.layout.aspect.ratio, options: options)
        let videoComposition = CompositionBuilder.videoComposition(for: built, recording: recording, renderSize: size,
                                                                   highQuality: true)
        try? FileManager.default.removeItem(at: url)

        if options.format == .gif {
            try await exportGIF(built: built, videoComposition: videoComposition, options: options, to: url, progress: progress)
            return
        }

        let preset = options.codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset) else {
            throw CaptureError.writerSetupFailed("This export preset isn't available.")
        }
        session.videoComposition = videoComposition
        session.audioMix = CompositionBuilder.audioMix(for: built, edit: recording.edit)
        session.shouldOptimizeForNetworkUse = true

        let monitor = Task {
            for await state in session.states(updateInterval: 0.1) {
                if case .exporting(let exportProgress) = state {
                    progress(exportProgress.fractionCompleted)
                }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: url, as: options.format == .mov ? .mov : .mp4)
        progress(1)
    }

    private static func exportGIF(built: CompositionBuilder.Result, videoComposition: AVVideoComposition,
                                  options: ExportOptions, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let frameInterval = 1.0 / Double(max(1, options.gifFrameRate))
        let times = stride(from: 0.0, to: built.duration, by: frameInterval).map { $0.cmTime }
        guard !times.isEmpty,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, times.count, nil)
        else { throw CompositionError.emptyRange }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameInterval,
                kCGImagePropertyGIFUnclampedDelayTime: frameInterval,
            ],
        ] as CFDictionary

        var completed = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            if let image = try? result.image {
                CGImageDestinationAddImage(destination, image, frameProperties)
            }
            completed += 1
            progress(Double(completed) / Double(times.count))
        }
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.writerSetupFailed("Couldn't write the GIF.")
        }
    }
}
