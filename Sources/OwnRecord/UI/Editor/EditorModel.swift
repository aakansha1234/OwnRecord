import AppKit
@preconcurrency import AVFoundation
import Observation

/// State and actions for one recording's editor window.
@MainActor @Observable
final class EditorModel {
    enum LoadState: Equatable {
        case loading, ready, failed(String)
    }

    enum TranscriptionState: Equatable {
        case idle, running(Double), failed(String)
    }

    enum ExportState: Equatable {
        case idle, running(Double), finished(URL), failed(String)
    }

    enum InspectorTab: String, CaseIterable, Identifiable {
        case layout, camera, subtitles, audio

        var id: String { rawValue }
        var title: String { rawValue.capitalized }

        var symbol: String {
            switch self {
            case .layout: "rectangle.inset.filled"
            case .camera: "person.crop.circle"
            case .subtitles: "captions.bubble"
            case .audio: "speaker.wave.2"
            }
        }
    }

    var recording: Recording {
        didSet { recordingChanged(from: oldValue) }
    }

    let files: RecordingFiles
    let player = AVPlayer()

    private(set) var loadState: LoadState = .loading
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    private(set) var sourceSize: CGSize = .zero
    private(set) var hasCameraTrack = false
    private(set) var thumbnails: [NSImage] = []
    var transcription: TranscriptionState = .idle
    var export: ExportState = .idle
    var inspectorTab: InspectorTab = .layout
    var isExportSheetPresented = false
    var exportOptions = ExportOptions()
    var transcriptionLocale: String

    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private var built: CompositionBuilder.Result?
    @ObservationIgnored private var playerItem: AVPlayerItem?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    init(recording: Recording, files: RecordingFiles, library: RecordingLibrary, preferences: Preferences) {
        self.recording = recording
        self.files = files
        self.library = library
        transcriptionLocale = recording.transcript?.localeIdentifier
            ?? TranscriptionEngine.bestLocaleIdentifier(for: preferences.transcriptionLocale)
    }

    // MARK: Derived values

    var canvasSize: CGSize {
        LayoutEngine.canvasSize(source: sourceSize == .zero ? recording.pixelSize : sourceSize,
                                aspect: recording.edit.layout.aspect)
    }

    var trimStart: Double { recording.edit.trimStart }
    var trimEnd: Double { recording.edit.trimEnd ?? duration }
    var isTrimmed: Bool { trimStart > 0.01 || recording.edit.trimEnd != nil }

    var currentCueID: SubtitleCue.ID? {
        recording.transcript?.cue(at: currentTime)?.id
    }

    /// Preview renders at up to 1080p-ish for smooth playback; exports render at full size.
    private var previewRenderSize: CGSize {
        let canvas = canvasSize
        let scale = min(1, 1920 / max(canvas.width, canvas.height))
        return canvas.scaled(scale).evenRounded()
    }

    // MARK: Loading

    func load() async {
        do {
            let result = try await CompositionBuilder.build(recording: recording, files: files, range: nil)
            built = result
            duration = result.duration
            sourceSize = result.sourceSize
            hasCameraTrack = result.cameraTrackID != nil

            let item = AVPlayerItem(asset: result.composition)
            item.videoComposition = makePreviewComposition()
            item.audioMix = CompositionBuilder.audioMix(for: result, settings: recording.edit.audio)
            applyPlaybackRange(to: item)
            player.replaceCurrentItem(with: item)
            playerItem = item
            observePlayer()
            await player.seek(to: trimStart.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = trimStart
            loadState = .ready
            await loadThumbnails()
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.currentTime = time.seconds
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = playing
                if !playing { self.currentTime = player.currentTime().seconds }
            }
        }
    }

    private func loadThumbnails() async {
        let asset = AVURLAsset(url: files.screen)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
        let count = 14
        let times = (0..<count).map { (Double($0) + 0.5) / Double(count) * max(duration, 0.1) }.map(\.cmTime)
        var images: [NSImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image {
                images.append(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
            }
        }
        thumbnails = images
    }

    // MARK: Playback

    func togglePlayback() {
        guard loadState == .ready else { return }
        if isPlaying {
            player.pause()
            return
        }
        if currentTime >= trimEnd - 0.05 || currentTime < trimStart {
            seek(to: trimStart)
        }
        player.play()
    }

    func seek(to time: Double) {
        let clamped = time.clamped(to: 0...max(0, duration))
        currentTime = clamped
        player.seek(to: clamped.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(by seconds: Double) {
        player.pause()
        seek(to: currentTime + seconds)
    }

    // MARK: Editing

    func setTrimStart(_ value: Double) {
        let clamped = value.clamped(to: 0...max(0, trimEnd - 0.5))
        recording.edit.trimStart = clamped < 0.05 ? 0 : clamped
        seek(to: recording.edit.trimStart)
    }

    func setTrimEnd(_ value: Double) {
        let clamped = value.clamped(to: min(duration, trimStart + 0.5)...max(0, duration))
        recording.edit.trimEnd = clamped > duration - 0.05 ? nil : clamped
        seek(to: clamped)
    }

    func resetTrim() {
        recording.edit.trimStart = 0
        recording.edit.trimEnd = nil
    }

    func setBackground(_ preset: BackgroundPreset) {
        recording.edit.layout.background = preset
        if preset != .none, recording.edit.layout.padding < 0.01 {
            // A background only shows with some breathing room; start from a pleasant default.
            recording.edit.layout.padding = 0.06
            recording.edit.layout.cornerRadius = max(recording.edit.layout.cornerRadius, 0.018)
        }
    }

    /// Moves the camera overlay; `center` is normalized with a top-left origin.
    func moveCamera(to center: CGPoint) {
        recording.edit.camera.position = .custom
        recording.edit.camera.customX = Double(center.x.clamped(to: 0...1))
        recording.edit.camera.customY = Double(center.y.clamped(to: 0...1))
    }

    func snapCamera() {
        let style = recording.edit.camera
        guard style.position == .custom else { return }
        let center = CGPoint(x: style.customX, y: style.customY)
        if let corner = LayoutEngine.snappedCorner(for: center, style: style, canvas: canvasSize) {
            recording.edit.camera.position = corner
        }
    }

    func updateCue(_ id: SubtitleCue.ID, text: String) {
        guard let index = recording.transcript?.cues.firstIndex(where: { $0.id == id }) else { return }
        recording.transcript?.cues[index].text = text
    }

    func deleteCue(_ id: SubtitleCue.ID) {
        recording.transcript?.cues.removeAll { $0.id == id }
    }

    func deleteTranscript() {
        recording.transcript = nil
    }

    // MARK: Change handling

    private func recordingChanged(from old: Recording) {
        let visualChanged = old.edit.layout != recording.edit.layout
            || old.edit.camera != recording.edit.camera
            || old.edit.subtitles != recording.edit.subtitles
            || old.transcript?.cues != recording.transcript?.cues
        if visualChanged { scheduleCompositionRefresh() }
        if old.edit.audio != recording.edit.audio, let built {
            playerItem?.audioMix = CompositionBuilder.audioMix(for: built, settings: recording.edit.audio)
        }
        if old.edit.trimStart != recording.edit.trimStart || old.edit.trimEnd != recording.edit.trimEnd,
           let playerItem {
            applyPlaybackRange(to: playerItem)
        }
        scheduleSave()
    }

    private func applyPlaybackRange(to item: AVPlayerItem) {
        item.forwardPlaybackEndTime = recording.edit.trimEnd?.cmTime ?? .invalid
    }

    private func scheduleCompositionRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let self else { return }
            self.playerItem?.videoComposition = self.makePreviewComposition()
            if !self.isPlaying {
                // Re-render the paused frame with the new settings.
                self.player.seek(to: self.currentTime.cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            }
        }
    }

    private func makePreviewComposition() -> AVVideoComposition? {
        guard let built else { return nil }
        return CompositionBuilder.videoComposition(for: built, recording: recording, renderSize: previewRenderSize,
                                                   timeOffset: 0, highQuality: false)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.library.save(self.recording)
        }
    }

    // MARK: Transcription

    func generateTranscript(requestPermission: Bool = true) {
        guard recording.hasAudio, transcriptionTask == nil else { return }
        // Transcribe every track that's audible in the edit (muted tracks are skipped).
        let audio = recording.edit.audio
        let audible = recording.audioTracks.indices.filter {
            (recording.audioTracks[$0] == .microphone ? audio.microphoneVolume : audio.systemVolume) > 0
        }
        let trackIndices = audible.isEmpty ? Array(recording.audioTracks.indices) : audible
        let localeIdentifier = transcriptionLocale
        let url = files.screen
        transcription = .running(0)
        transcriptionTask = Task { [weak self] in
            defer { self?.transcriptionTask = nil }
            if requestPermission {
                guard await AppModel.shared.permissions.request(.speech) else {
                    self?.transcription = .failed(TranscriptionError.notAuthorized.localizedDescription)
                    return
                }
            }
            do {
                let words = try await TranscriptionEngine.transcribe(
                    assetURL: url, audioTrackIndices: trackIndices, locale: Locale(identifier: localeIdentifier)
                ) { progress in
                    Task { @MainActor in
                        if case .running = self?.transcription { self?.transcription = .running(progress) }
                    }
                }
                guard let self else { return }
                let cues = CueBuilder.cues(from: words, joiner: CueBuilder.joiner(for: localeIdentifier))
                if cues.isEmpty {
                    self.transcription = .failed("No speech was detected in this recording.")
                } else {
                    self.recording.transcript = Transcript(localeIdentifier: localeIdentifier, createdAt: Date(),
                                                           words: words, cues: cues)
                    self.recording.edit.subtitles.isEnabled = true
                    self.transcription = .idle
                }
            } catch is CancellationError {
                self?.transcription = .idle
            } catch {
                self?.transcription = .failed(error.localizedDescription)
            }
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
    }

    func exportSubtitles(format: SubtitleFileFormat) {
        guard let transcript = recording.transcript else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(Self.fileName(for: recording.title)).\(format.rawValue)"
        panel.canCreateDirectories = true
        let cues = SubtitleExporter.cues(transcript.cues, trimStart: trimStart, trimEnd: trimEnd)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? SubtitleExporter.string(for: cues, format: format).write(to: url, atomically: true, encoding: .utf8)
    }

    func copyTranscript() {
        guard let transcript = recording.transcript else { return }
        let cues = SubtitleExporter.cues(transcript.cues, trimStart: trimStart, trimEnd: trimEnd)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SubtitleExporter.string(for: cues, format: .txt), forType: .string)
    }

    // MARK: Export

    func chooseDestinationAndExport() {
        let options = exportOptions
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(Self.fileName(for: recording.title)).\(options.format.fileExtension)"
        panel.allowedContentTypes = [options.format.contentType]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startExport(options: options, to: url)
    }

    private func startExport(options: ExportOptions, to url: URL) {
        player.pause()
        library.save(recording)
        let recording = self.recording
        let files = self.files
        export = .running(0)
        exportTask = Task { [weak self] in
            do {
                try await VideoExporter.export(recording: recording, files: files, options: options, to: url) { progress in
                    Task { @MainActor in
                        if case .running = self?.export { self?.export = .running(progress) }
                    }
                }
                if options.includeSubtitleFile, options.format != .gif, let transcript = recording.transcript {
                    let cues = SubtitleExporter.cues(transcript.cues, trimStart: recording.edit.trimStart, trimEnd: recording.trimEnd)
                    try? SubtitleExporter.string(for: cues, format: .srt)
                        .write(to: url.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
                }
                self?.export = .finished(url)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
                self?.export = .idle
            } catch {
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: url)
                    self?.export = .idle
                } else {
                    self?.export = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func dismissExportStatus() {
        export = .idle
    }

    // MARK: Lifecycle

    func close() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        transcriptionTask?.cancel()
        saveTask?.cancel()
        library.save(recording)
        Task { await refreshLibraryThumbnail() }
    }

    /// Updates the library thumbnail to reflect the edited look (background, camera, etc.).
    private func refreshLibraryThumbnail() async {
        guard let built else { return }
        let canvas = canvasSize
        let size = canvas.scaled(min(1, 640 / max(canvas.width, canvas.height))).evenRounded()
        let composition = CompositionBuilder.videoComposition(for: built, recording: recording, renderSize: size,
                                                              timeOffset: 0, highQuality: false)
        let time = min(trimStart + 1, (trimStart + trimEnd) / 2)
        if let image = await Thumbnailer.image(from: built.composition, at: time, maxSize: size, videoComposition: composition) {
            Thumbnailer.writeJPEG(image, to: files.thumbnail)
            library.thumbnailDidChange(recording.id)
        }
    }

    nonisolated static func fileName(for title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = title.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Recording" : cleaned
    }
}
