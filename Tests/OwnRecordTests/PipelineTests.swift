@preconcurrency import AVFoundation
import CoreImage
@testable import OwnRecord
import Testing

/// End-to-end: write synthetic screen + camera movies with the real writer, then composite
/// and export them through the same code the editor uses.
@Suite(.serialized) struct PipelineTests {
    /// Scratch space inside the repository (`tmp/`, git-ignored).
    static let scratchRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tmp/tests", isDirectory: true)

    private static func makeFolder() throws -> URL {
        let url = scratchRoot.appendingPathComponent("pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func solidBuffer(width: Int, height: Int, bgra: (UInt8, UInt8, UInt8)) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base + y * bytesPerRow + x * 4
                pixel[0] = bgra.0; pixel[1] = bgra.1; pixel[2] = bgra.2; pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    /// Writes `duration` seconds of a solid color through MovieWriter, simulating real-time capture.
    private static func writeMovie(url: URL, size: CGSize, color: (UInt8, UInt8, UInt8), duration: Double,
                                   start: CMTime, camera: Bool) async throws {
        let settings = camera
            ? MovieWriter.VideoSettings.camera(width: Int(size.width), height: Int(size.height))
            : MovieWriter.VideoSettings.screen(size: size, frameRate: 30, quality: .standard)
        let writer = try MovieWriter(url: url, video: settings, audioTracks: [])
        writer.start(at: start)
        let buffer = solidBuffer(width: Int(size.width), height: Int(size.height), bgra: color)
        let frames = Int(duration * 30)
        for frame in 0..<frames {
            writer.appendVideo(buffer, at: start + CMTime(value: CMTimeValue(frame), timescale: 30))
            try await Task.sleep(for: .milliseconds(4))
        }
        writer.prepareToFinish(at: start + CMTime(seconds: duration, preferredTimescale: 600))
        #expect(try await writer.finishWriting())
    }

    static func makeRecording(folder: URL) async throws -> (Recording, RecordingFiles) {
        let files = RecordingFiles(folder: folder)
        let start = CMTime(seconds: 1000, preferredTimescale: 600)
        // Screen is pure red, camera pure green (BGRA order).
        try await writeMovie(url: files.screen, size: CGSize(width: 640, height: 400), color: (0, 0, 255),
                             duration: 2, start: start, camera: false)
        try await writeMovie(url: files.camera, size: CGSize(width: 320, height: 240), color: (0, 255, 0),
                             duration: 2, start: start, camera: true)
        var edit = EditSettings()
        edit.camera.position = .bottomRight
        edit.camera.borderWidth = 0
        edit.camera.shadow = false
        let recording = Recording(id: UUID(), title: "Test", createdAt: Date(), duration: 2, captureMode: .display,
                                  sourceName: "Test", pixelWidth: 640, pixelHeight: 400, frameRate: 30, hasCamera: true,
                                  audioTracks: [], edit: edit,
                                  transcript: Transcript(localeIdentifier: "en_US", createdAt: Date(), words: [],
                                                         cues: [SubtitleCue(start: 0, end: 2, text: "Hello")]))
        return (recording, files)
    }

    /// A recording whose screen movie also has a microphone track: 0.6 s of tone, 0.9 s of silence,
    /// then tone until the end.
    static func makeRecordingWithMicrophone(folder: URL) async throws -> (Recording, RecordingFiles) {
        var (recording, files) = try await makeRecording(folder: folder)
        let tone = folder.appendingPathComponent("tone.m4a")
        try SilenceTests.writeTone(to: tone, segments: [(0.6, 0.3), (0.9, 0), (0.5, 0.3)])

        let composition = AVMutableComposition()
        let screen = AVURLAsset(url: files.screen)
        let audio = AVURLAsset(url: tone)
        let video = try #require(try await screen.loadTracks(withMediaType: .video).first)
        let sound = try #require(try await audio.loadTracks(withMediaType: .audio).first)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: video, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: sound, at: .zero)
        let combined = folder.appendingPathComponent("combined.mov")
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: combined, as: .mov)
        try FileManager.default.removeItem(at: files.screen)
        try FileManager.default.moveItem(at: combined, to: files.screen)
        try? FileManager.default.removeItem(at: tone)

        recording.audioTracks = [.microphone]
        return (recording, files)
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    @Test func compositesScreenCameraAndSubtitles() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (recording, files) = try await Self.makeRecording(folder: folder)

        let built = try await CompositionBuilder.build(recording: recording, files: files, ranges: nil)
        #expect(built.cameraTrackID != nil)
        #expect(abs(built.duration - 2) < 0.1)

        let canvas = CGSize(width: 640, height: 400)
        let composition = CompositionBuilder.videoComposition(for: built, recording: recording, renderSize: canvas,
                                                              highQuality: true)
        let image = try #require(await Thumbnailer.image(from: built.composition, at: 1, maxSize: canvas,
                                                         videoComposition: composition))
        #expect(image.width == 640 && image.height == 400)
        if let path = ProcessInfo.processInfo.environment["OWNRECORD_DUMP_FRAME"] {
            Thumbnailer.writeJPEG(image, to: URL(fileURLWithPath: path), quality: 0.95)
        }

        // Top-left of the canvas shows the (red) screen.
        let screen = Self.pixel(image, x: 40, y: 40)
        #expect(screen.r > 200 && screen.g < 60)

        // The camera (green) sits in the bottom-right corner.
        let layout = LayoutEngine.layout(canvas: canvas, source: canvas, edit: recording.edit, hasCamera: true)
        let camera = try #require(layout.cameraRect)
        let bubble = Self.pixel(image, x: Int(camera.midX), y: Int(camera.midY))
        #expect(bubble.g > 200 && bubble.r < 80)
        // Outside the circle's corner, the screen shows through.
        let corner = Self.pixel(image, x: Int(camera.minX) + 2, y: Int(camera.minY) + 2)
        #expect(corner.r > 200)

        // Subtitle box is rendered near the bottom center (dark background over red).
        let subtitle = Self.pixel(image, x: 320, y: Int(canvas.height - layout.subtitleMargin - 4))
        #expect(subtitle.r < 150)
    }

    @Test func exportsTrimmedMP4AndGIF() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var (recording, files) = try await Self.makeRecording(folder: folder)
        recording.edit.trimStart = 0.5
        recording.edit.layout.aspect = .square
        recording.edit.layout.background = .aurora
        recording.edit.layout.padding = 0.08
        recording.edit.layout.cornerRadius = 0.03
        recording.edit.camera.borderWidth = 0.03
        recording.edit.camera.shadow = true

        var options = ExportOptions()
        options.resolution = .hd
        let movieURL = folder.appendingPathComponent("export.mp4")
        try await VideoExporter.export(recording: recording, files: files, options: options, to: movieURL) { _ in }
        let asset = AVURLAsset(url: movieURL)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1.5) < 0.15)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.width == size.height) // 1:1 canvas
        #expect(size.width == 640)
        if let path = ProcessInfo.processInfo.environment["OWNRECORD_DUMP_EXPORT"],
           let frame = await Thumbnailer.image(from: asset, at: 0.8, maxSize: size) {
            Thumbnailer.writeJPEG(frame, to: URL(fileURLWithPath: path), quality: 0.95)
        }

        options.format = .gif
        options.gifWidth = 480
        options.gifFrameRate = 10
        let gifURL = folder.appendingPathComponent("export.gif")
        try await VideoExporter.export(recording: recording, files: files, options: options, to: gifURL) { _ in }
        let source = try #require(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
        #expect(CGImageSourceGetCount(source) >= 12)
    }

    @Test func exportsSectionsWithCutsAndHiddenScreen() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var (recording, files) = try await Self.makeRecording(folder: folder)
        recording.edit.split(at: 0.6, duration: 2)
        recording.edit.split(at: 1.2, duration: 2)
        recording.edit.sections[1].isDeleted = true
        recording.edit.sections[2].showsScreen = false
        recording.transcript = nil

        var options = ExportOptions()
        options.resolution = .original
        let url = folder.appendingPathComponent("sections.mp4")
        try await VideoExporter.export(recording: recording, files: files, options: options, to: url) { _ in }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1.4) < 0.1)

        // First section: red screen with the green camera in the corner.
        let size = CGSize(width: 640, height: 400)
        let first = try #require(await Thumbnailer.image(from: asset, at: 0.3, maxSize: size))
        let screen = Self.pixel(first, x: 40, y: 40)
        #expect(screen.r > 200 && screen.g < 60)
        // Last section hides the screen, so the camera fills the frame.
        let last = try #require(await Thumbnailer.image(from: asset, at: 1.25, maxSize: size))
        let camera = Self.pixel(last, x: 40, y: 40)
        #expect(camera.g > 200 && camera.r < 80)
    }

    @Test func exportsLinedUpClipsForIMovie() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var (recording, files) = try await Self.makeRecordingWithMicrophone(folder: folder)
        // Kept: 0–0.5 as recorded, 1–1.5 without the camera, 1.5–2 without the screen.
        for time in [0.5, 1, 1.5] { recording.edit.split(at: time, duration: 2) }
        recording.edit.sections[1].isDeleted = true
        recording.edit.sections[2].showsCamera = false
        recording.edit.sections[3].showsScreen = false
        recording.edit.sections[0].redactions = [Redaction(rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2))]
        recording.transcript = nil

        var options = ExportOptions()
        options.format = .imovie
        options.iMovieClips = .both
        options.resolution = .original
        let output = folder.appendingPathComponent("Test for iMovie")
        let clips = try await IMovieExporter.export(recording: recording, files: files, options: options, to: output) { _ in }
        #expect(clips.map(\.kind) == [.finished, .screen, .camera])
        #expect(clips.map(\.url.lastPathComponent) == ["Test.mov", "Test – Screen.mov", "Test – Camera.mov"])

        func check(_ kind: ExportedClip.Kind, size: CGSize, audioTracks: Int) async throws -> AVURLAsset {
            let asset = AVURLAsset(url: try #require(clips.first { $0.kind == kind }).url)
            #expect(abs(try await asset.load(.duration).seconds - 1.5) < 0.1, "\(kind)")
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            #expect(try await track.load(.naturalSize) == size, "\(kind)")
            #expect(try await asset.loadTracks(withMediaType: .audio).count == audioTracks, "\(kind)")
            return asset
        }
        _ = try await check(.finished, size: CGSize(width: 640, height: 400), audioTracks: 1)
        let screen = try await check(.screen, size: CGSize(width: 640, height: 400), audioTracks: 1)
        let camera = try await check(.camera, size: CGSize(width: 320, height: 240), audioTracks: 0)

        func color(_ asset: AVAsset, at time: Double, size: CGSize) async throws -> (r: Int, g: Int, b: Int) {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: time.cmTime).image
            return Self.pixel(image, x: 20, y: 20)
        }
        let screenSize = CGSize(width: 640, height: 400), cameraSize = CGSize(width: 320, height: 240)
        // The screen clip shows the screen (no camera, no background) and goes black where it's hidden.
        let red = try await color(screen, at: 0.25, size: screenSize)
        #expect(red.r > 200 && red.g < 60)
        let screenWithoutCamera = try await color(screen, at: 0.95, size: screenSize)
        #expect(screenWithoutCamera.r > 200)
        let hiddenScreen = try await color(screen, at: 1.45, size: screenSize)
        #expect(hiddenScreen.r < 30 && hiddenScreen.g < 30)
        // The camera clip goes black where the camera is hidden, and lines up with the screen clip.
        let green = try await color(camera, at: 0.25, size: cameraSize)
        #expect(green.g > 200 && green.r < 80)
        let hiddenCamera = try await color(camera, at: 0.95, size: cameraSize)
        #expect(hiddenCamera.g < 30)
        let cameraAgain = try await color(camera, at: 1.45, size: cameraSize)
        #expect(cameraAgain.g > 200)
    }

    @Test func iMovieExportFallsBackToTheFinishedVideoWithoutCamera() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (recording, files) = try await Self.makeRecording(folder: folder)
        try FileManager.default.removeItem(at: files.camera)

        var options = ExportOptions()
        options.format = .imovie
        options.iMovieClips = .separate
        let output = folder.appendingPathComponent("Out")
        // Something that was there before stays.
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let other = output.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: other)
        let clips = try await IMovieExporter.export(recording: recording, files: files, options: options, to: output) { _ in }
        #expect(clips.map(\.kind) == [.finished])
        #expect(FileManager.default.fileExists(atPath: other.path))
    }
}
