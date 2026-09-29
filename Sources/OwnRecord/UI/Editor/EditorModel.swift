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
    var isShortcutsPresented = false
    var exportOptions = ExportOptions()
    var transcriptionLocale: String
    /// A short message over the preview, e.g. after moving the camera in one section.
    private(set) var hint: Hint?
    /// Maps preview-player time to recording time (deleted sections are left out).
    private(set) var previewTimeline = TimelineMap(ranges: [])

    struct Hint: Equatable, Identifiable {
        let id = UUID()
        var message: String
        var offersApplyToAll = false
    }

    /// Undo for every edit. The editor window hands it to AppKit, so ⌘Z and the Edit menu work.
    @ObservationIgnored let undoManager = UndoManager()

    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private var built: CompositionBuilder.Result?
    @ObservationIgnored private var playerItem: AVPlayerItem?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var isReplacingItem = false
    /// Set when a seek interrupts playback, so the pause that follows doesn't move the playhead back.
    @ObservationIgnored private var seekedWhilePlaying = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var pendingEdit: (name: String, coalesces: Bool)?
    @ObservationIgnored private var lastCoalescedEdit: (name: String, date: Date)?

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

    var sections: [TimelineSection] { recording.edit.sections }
    var hasMultipleSections: Bool { sections.count > 1 }
    var currentSectionIndex: Int { recording.edit.sectionIndex(at: currentTime) }
    var currentSection: TimelineSection { sections[currentSectionIndex] }
    /// Camera position and size in the section at the playhead.
    var currentCameraPlacement: CameraPlacement { recording.edit.cameraPlacement(for: currentSection) }

    func range(ofSectionAt index: Int) -> Range<Double> {
        recording.edit.range(ofSectionAt: index, duration: duration)
    }

    /// Length of the edited video (trimmed, deleted sections removed).
    var editedDuration: Double {
        max(0, previewTimeline.outputTime(forSource: trimEnd) - previewTimeline.outputTime(forSource: trimStart))
    }

    /// Playhead position in the edited video.
    var editedTime: Double {
        let position = previewTimeline.outputTime(forSource: currentTime) - previewTimeline.outputTime(forSource: trimStart)
        return position.clamped(to: 0...max(0, editedDuration))
    }

    var canSplit: Bool {
        let time = snappedToFrame(currentTime)
        let range = self.range(ofSectionAt: currentSectionIndex)
        return time - range.lowerBound >= EditSettings.minimumSectionLength
            && range.upperBound - time >= EditSettings.minimumSectionLength
    }

    /// Whether a subtitle falls entirely within deleted or trimmed parts.
    func isCut(_ cue: SubtitleCue) -> Bool {
        recording.editedTimeline.outputRanges(forSource: cue.start..<max(cue.start, cue.end)).isEmpty
    }

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
            let ranges = recording.edit.keptRanges(duration: .infinity, applyingTrim: false)
            let result = try await CompositionBuilder.build(recording: recording, files: files, ranges: ranges)
            duration = result.sourceDuration
            await install(result, at: trimStart)
            observePlayer()
            loadState = .ready
            await loadThumbnails()
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Swaps in a new preview composition, keeping the playhead where it was.
    private func install(_ result: CompositionBuilder.Result, at time: Double) async {
        let wasPlaying = isPlaying
        isReplacingItem = true
        built = result
        previewTimeline = result.timeline
        sourceSize = result.sourceSize
        hasCameraTrack = result.cameraTrackID != nil

        let item = AVPlayerItem(asset: result.composition)
        item.videoComposition = makePreviewComposition()
        item.audioMix = CompositionBuilder.audioMix(for: result, edit: recording.edit)
        applyPlaybackRange(to: item)
        player.replaceCurrentItem(with: item)
        playerItem = item
        currentTime = time
        await player.seek(to: result.timeline.outputTime(forSource: time).cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        isReplacingItem = false
        if wasPlaying { player.play() }
    }

    /// Rebuilds the preview after sections were deleted or restored.
    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            let ranges = self.recording.edit.keptRanges(duration: .infinity, applyingTrim: false)
            do {
                let result = try await CompositionBuilder.build(recording: self.recording, files: self.files, ranges: ranges)
                guard !Task.isCancelled else { return }
                await self.install(result, at: self.currentTime)
            } catch {
                guard !Task.isCancelled else { return }
                self.showHint("Couldn't update the preview: \(error.localizedDescription)")
            }
        }
    }

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, !self.isReplacingItem else { return }
                self.currentTime = self.previewTimeline.sourceTime(forOutput: time.seconds)
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in
                guard let self, !self.isReplacingItem else { return }
                let wasPlaying = self.isPlaying
                self.isPlaying = playing
                if wasPlaying, !playing {
                    if self.seekedWhilePlaying {
                        // The playhead was just moved on purpose; the player is catching up.
                        self.seekedWhilePlaying = false
                    } else {
                        // At a cut, show the end of what just played rather than what comes next.
                        self.currentTime = self.previewTimeline.sourceTime(forOutput: player.currentTime().seconds,
                                                                           preferringEarlier: true)
                    }
                }
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
        let position = previewTimeline.outputTime(forSource: currentTime)
        if currentTime < trimStart || position >= previewTimeline.outputTime(forSource: trimEnd) - 0.05 {
            seek(to: trimStart)
        }
        player.play()
    }

    /// Moves the playhead to recording time `time`. Inside a deleted section the preview shows
    /// where the video continues.
    func seek(to time: Double) {
        let clamped = time.clamped(to: 0...max(0, duration))
        currentTime = clamped
        player.seek(to: previewTimeline.outputTime(forSource: clamped).cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Steps through the edited video, skipping deleted sections.
    func step(by seconds: Double) {
        pauseForSeek()
        let output = (previewTimeline.outputTime(forSource: currentTime) + seconds).clamped(to: 0...previewTimeline.duration)
        currentTime = previewTimeline.sourceTime(forOutput: output)
        player.seek(to: output.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stepFrame(forward: Bool) {
        step(by: (forward ? 1 : -1) / Double(max(1, recording.frameRate)))
    }

    func goToStart() {
        pauseForSeek()
        seek(to: trimStart)
    }

    /// Pauses before moving the playhead, so the pause doesn't move it back to where playback was.
    func pauseForSeek() {
        if isPlaying { seekedWhilePlaying = true }
        player.pause()
    }

    /// Jumps to the previous or next split or trim point.
    func goToEditPoint(forward: Bool) {
        pauseForSeek()
        let points = recording.edit.editPoints(duration: duration)
        let epsilon = 0.5 / Double(max(1, recording.frameRate))
        let target = forward
            ? points.first { $0 > currentTime + epsilon }
            : points.last { $0 < currentTime - epsilon }
        if let target { seek(to: target) } else { NSSound.beep() }
    }

    private func snappedToFrame(_ time: Double) -> Double {
        let rate = Double(max(1, recording.frameRate))
        return ((time * rate).rounded() / rate).clamped(to: 0...max(0, duration))
    }

    // MARK: Trimming

    func setTrimStart(_ value: Double) {
        let clamped = value.clamped(to: 0...max(0, trimEnd - 0.5))
        var edit = recording.edit
        edit.trimStart = clamped < 0.05 ? 0 : clamped
        guard keepsSomething(edit) else { return }
        performEdit("Trim Start", coalescing: true) { recording.edit = edit }
        seek(to: recording.edit.trimStart)
    }

    func setTrimEnd(_ value: Double) {
        let clamped = value.clamped(to: min(duration, trimStart + 0.5)...max(0, duration))
        var edit = recording.edit
        edit.trimEnd = clamped > duration - 0.05 ? nil : clamped
        guard keepsSomething(edit) else { return }
        performEdit("Trim End", coalescing: true) { recording.edit = edit }
        seek(to: clamped)
    }

    func setTrimStartAtPlayhead() {
        var edit = recording.edit
        edit.trimStart = snappedToFrame(currentTime)
        guard currentTime < trimEnd - 0.5, keepsSomething(edit, explain: true) else { NSSound.beep(); return }
        performEdit("Set Trim Start") { recording.edit = edit }
    }

    func setTrimEndAtPlayhead() {
        let time = snappedToFrame(currentTime)
        var edit = recording.edit
        edit.trimEnd = time > duration - 0.05 ? nil : time
        guard currentTime > trimStart + 0.5, keepsSomething(edit, explain: true) else { NSSound.beep(); return }
        performEdit("Set Trim End") { recording.edit = edit }
    }

    /// Whether an edit leaves anything to export.
    private func keepsSomething(_ edit: EditSettings, explain: Bool = false) -> Bool {
        guard edit.keptRanges(duration: duration, applyingTrim: true).isEmpty else { return true }
        if explain { showHint("At least one section has to stay in the video.") }
        return false
    }

    func resetTrim() {
        performEdit("Reset Trim") {
            recording.edit.trimStart = 0
            recording.edit.trimEnd = nil
        }
    }

    // MARK: Sections

    /// Splits the section under the playhead at the playhead.
    func splitAtPlayhead() {
        let time = snappedToFrame(currentTime)
        var edit = recording.edit
        guard edit.split(at: time, duration: duration) else {
            NSSound.beep()
            return
        }
        performEdit("Split") { recording.edit = edit }
    }

    /// Deletes a section from the video, or restores it if it's already deleted.
    func toggleDeleted(_ id: TimelineSection.ID? = nil) {
        let index = sectionIndex(for: id)
        var edit = recording.edit
        edit.sections[index].isDeleted.toggle()
        guard keepsSomething(edit, explain: true) else {
            NSSound.beep()
            return
        }
        performEdit(edit.sections[index].isDeleted ? "Delete Section" : "Restore Section") { recording.edit = edit }
    }

    func toggleScreen(_ id: TimelineSection.ID? = nil) {
        let index = sectionIndex(for: id)
        performEdit(sections[index].showsScreen ? "Hide Screen" : "Show Screen") {
            recording.edit.sections[index].showsScreen.toggle()
        }
    }

    func toggleCamera(_ id: TimelineSection.ID? = nil) {
        guard hasCameraTrack else { NSSound.beep(); return }
        let index = sectionIndex(for: id)
        performEdit(sections[index].showsCamera ? "Hide Camera" : "Show Camera") {
            recording.edit.sections[index].showsCamera.toggle()
        }
    }

    func toggleMute(_ id: TimelineSection.ID? = nil) {
        guard recording.hasAudio else { NSSound.beep(); return }
        let index = sectionIndex(for: id)
        performEdit(sections[index].mutesAudio ? "Unmute Section" : "Mute Section") {
            recording.edit.sections[index].mutesAudio.toggle()
        }
    }

    /// Removes the split after section `id` (or the one under the playhead).
    func joinWithNext(_ id: TimelineSection.ID? = nil) {
        var edit = recording.edit
        guard edit.joinSection(at: sectionIndex(for: id)), keepsSomething(edit, explain: true) else { NSSound.beep(); return }
        performEdit("Join Sections") { recording.edit = edit }
    }

    func joinWithPrevious(_ id: TimelineSection.ID? = nil) {
        let index = sectionIndex(for: id)
        var edit = recording.edit
        guard index > 0, edit.joinSection(at: index - 1), keepsSomething(edit, explain: true) else { NSSound.beep(); return }
        performEdit("Join Sections") { recording.edit = edit }
    }

    /// Shows screen, camera and audio again and returns the camera to its default position.
    func resetSection(_ id: TimelineSection.ID? = nil) {
        let index = sectionIndex(for: id)
        performEdit("Reset Section") {
            recording.edit.sections[index].showsScreen = true
            recording.edit.sections[index].showsCamera = true
            recording.edit.sections[index].mutesAudio = false
            recording.edit.sections[index].camera = nil
        }
    }

    private func sectionIndex(for id: TimelineSection.ID?) -> Int {
        id.flatMap { id in sections.firstIndex { $0.id == id } } ?? currentSectionIndex
    }

    // MARK: Camera

    /// Moves the camera in the section at the playhead; `center` is normalized with a top-left origin.
    func moveCamera(to center: CGPoint) {
        var placement = currentCameraPlacement
        placement.position = .custom
        placement.customX = Double(center.x.clamped(to: 0...1))
        placement.customY = Double(center.y.clamped(to: 0...1))
        setCameraPlacement(placement, name: "Move Camera", coalescing: true)
    }

    func finishMovingCamera() {
        var placement = currentCameraPlacement
        let style = recording.edit.camera.with(placement)
        if placement.position == .custom,
           let corner = LayoutEngine.snappedCorner(for: CGPoint(x: placement.customX, y: placement.customY),
                                                   style: style, canvas: canvasSize) {
            placement.position = corner
            setCameraPlacement(placement, name: "Move Camera", coalescing: true)
        }
        hintIfSectionOnly()
    }

    func setCameraCorner(_ corner: CameraPosition, for id: TimelineSection.ID? = nil) {
        let index = sectionIndex(for: id)
        var placement = recording.edit.cameraPlacement(for: sections[index])
        placement.position = corner
        setCameraPlacement(placement, name: "Move Camera", coalescing: false, index: index)
        hintIfSectionOnly()
    }

    /// Moves the camera toward an edge of the frame (keyboard: ⌥ + arrow).
    func nudgeCamera(toward edge: CameraEdge) {
        guard hasCameraTrack else { NSSound.beep(); return }
        setCameraCorner(LayoutEngine.corner(of: currentCameraPlacement, movedToward: edge))
    }

    var cameraSize: Double {
        get { currentCameraPlacement.size }
        set {
            var placement = currentCameraPlacement
            placement.size = newValue
            setCameraPlacement(placement, name: "Resize Camera", coalescing: true)
        }
    }

    /// Uses the camera position and size of the section at the playhead in every section.
    func applyCameraToAllSections() {
        let placement = currentCameraPlacement
        performEdit("Use Camera Position Everywhere") {
            recording.edit.camera.placement = placement
            for index in recording.edit.sections.indices {
                recording.edit.sections[index].camera = nil
            }
        }
        dismissHint()
    }

    /// Whether every section uses the same camera placement.
    var cameraPlacementIsUniform: Bool {
        Set(sections.map { recording.edit.cameraPlacement(for: $0) }).count <= 1
    }

    private func setCameraPlacement(_ placement: CameraPlacement, name: String, coalescing: Bool, index: Int? = nil) {
        let index = index ?? currentSectionIndex
        performEdit(name, coalescing: coalescing) {
            recording.edit.sections[index].camera = placement
        }
    }

    private func hintIfSectionOnly() {
        guard hasMultipleSections, !cameraPlacementIsUniform else { return }
        showHint("Camera moved in this section only.", offersApplyToAll: true)
    }

    // MARK: Hints

    func showHint(_ message: String, offersApplyToAll: Bool = false) {
        hint = Hint(message: message, offersApplyToAll: offersApplyToAll)
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.hint = nil
        }
    }

    func dismissHint() {
        hintTask?.cancel()
        hint = nil
    }

    // MARK: Other edits

    func setBackground(_ preset: BackgroundPreset) {
        performEdit("Change Background") {
            recording.edit.layout.background = preset
            if preset != .none, recording.edit.layout.padding < 0.01 {
                // A background only shows with some breathing room; start from a pleasant default.
                recording.edit.layout.padding = 0.06
                recording.edit.layout.cornerRadius = max(recording.edit.layout.cornerRadius, 0.018)
            }
        }
    }

    func updateCue(_ id: SubtitleCue.ID, text: String) {
        guard let index = recording.transcript?.cues.firstIndex(where: { $0.id == id }) else { return }
        recording.transcript?.cues[index].text = text
    }

    func deleteCue(_ id: SubtitleCue.ID) {
        performEdit("Delete Subtitle") { recording.transcript?.cues.removeAll { $0.id == id } }
    }

    func deleteTranscript() {
        performEdit("Delete Transcript") { recording.transcript = nil }
    }

    // MARK: Undo

    /// Runs an edit as one named undo step. Coalescing edits (drags, sliders) merge with the
    /// previous step of the same name if it happened within a second.
    private func performEdit(_ name: String, coalescing: Bool = false, _ change: () -> Void) {
        pendingEdit = (name, coalescing)
        change()
        pendingEdit = nil
    }

    private struct UndoSnapshot {
        var edit: EditSettings
        /// Only restored when the step changed the transcript's structure (not typed text).
        var transcript: Transcript??
    }

    private func registerUndo(from old: Recording) {
        let transcriptChanged = old.transcript?.cues.map(\.id) != recording.transcript?.cues.map(\.id)
            || (old.transcript == nil) != (recording.transcript == nil)
        guard old.edit != recording.edit || transcriptChanged else { return }

        let replaying = undoManager.isUndoing || undoManager.isRedoing
        // Changes made through bindings (sliders, switches, pickers) arrive without a name; they're
        // named after what changed and only merge with further changes to the same setting.
        let fields = pendingEdit == nil ? Self.changedFields(old.edit, recording.edit) : []
        let name = pendingEdit?.name ?? Self.actionName(for: fields)
        let key = pendingEdit?.name ?? fields.joined(separator: ",")
        let coalesces = !replaying && (pendingEdit?.coalesces ?? true)
        if coalesces, let last = lastCoalescedEdit, last.name == key, Date().timeIntervalSince(last.date) < 1 {
            lastCoalescedEdit = (key, Date())
            return
        }
        let snapshot = UndoSnapshot(edit: old.edit, transcript: transcriptChanged ? .some(old.transcript) : .none)
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(snapshot) }
        }
        if !replaying { undoManager.setActionName(name) }
        lastCoalescedEdit = coalesces ? (key, Date()) : nil
    }

    /// Settings that differ between two edits, e.g. ["camera.mirror"].
    private static func changedFields(_ old: EditSettings, _ new: EditSettings) -> [String] {
        var fields: [String] = []
        for (before, after) in zip(Mirror(reflecting: old).children, Mirror(reflecting: new).children) {
            guard let label = before.label, String(describing: before.value) != String(describing: after.value) else { continue }
            let inner = zip(Mirror(reflecting: before.value).children, Mirror(reflecting: after.value).children)
                .filter { String(describing: $0.0.value) != String(describing: $0.1.value) }
                .compactMap(\.0.label)
            fields += inner.isEmpty ? [label] : inner.map { "\(label).\($0)" }
        }
        return fields
    }

    private static func actionName(for fields: [String]) -> String {
        switch fields.first?.split(separator: ".").first {
        case "layout": "Change Layout"
        case "camera": "Change Camera Style"
        case "subtitles": "Change Subtitle Style"
        case "audio": "Change Volume"
        default: "Change"
        }
    }

    private func restore(_ snapshot: UndoSnapshot) {
        var restored = recording
        restored.edit = snapshot.edit
        if case .some(var transcript) = snapshot.transcript {
            // Text typed since the snapshot isn't part of this step; keep it.
            if let current = recording.transcript, transcript != nil {
                let texts = Dictionary(current.cues.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
                for index in transcript!.cues.indices {
                    if let text = texts[transcript!.cues[index].id] { transcript!.cues[index].text = text }
                }
            }
            restored.transcript = transcript
        }
        recording = restored
    }

    // MARK: Change handling

    private func recordingChanged(from old: Recording) {
        registerUndo(from: old)
        let edit = recording.edit
        let rangesChanged = old.edit.keptRanges(duration: .infinity, applyingTrim: false)
            != edit.keptRanges(duration: .infinity, applyingTrim: false)
        if rangesChanged, loadState == .ready {
            scheduleRebuild()
        } else {
            let visualChanged = old.edit.layout != edit.layout
                || old.edit.camera != edit.camera
                || old.edit.subtitles != edit.subtitles
                || old.edit.sections != edit.sections
                || old.transcript?.cues != recording.transcript?.cues
            if visualChanged { scheduleCompositionRefresh() }
            if old.edit.audio != edit.audio || old.edit.sections != edit.sections, let built {
                playerItem?.audioMix = CompositionBuilder.audioMix(for: built, edit: edit)
            }
            if old.edit.trimStart != edit.trimStart || old.edit.trimEnd != edit.trimEnd, let playerItem {
                applyPlaybackRange(to: playerItem)
            }
        }
        scheduleSave()
    }

    private func applyPlaybackRange(to item: AVPlayerItem) {
        item.forwardPlaybackEndTime = recording.edit.trimEnd.map { previewTimeline.outputTime(forSource: $0).cmTime } ?? .invalid
    }

    private func scheduleCompositionRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let self else { return }
            self.playerItem?.videoComposition = self.makePreviewComposition()
            if !self.isPlaying {
                // Re-render the paused frame with the new settings.
                self.player.seek(to: self.player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            }
        }
    }

    private func makePreviewComposition() -> AVVideoComposition? {
        guard let built else { return nil }
        return CompositionBuilder.videoComposition(for: built, recording: recording, renderSize: previewRenderSize,
                                                   highQuality: false)
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
                    var updated = self.recording
                    updated.transcript = Transcript(localeIdentifier: localeIdentifier, createdAt: Date(), words: words, cues: cues)
                    updated.edit.subtitles.isEnabled = true
                    self.performEdit("Generate Subtitles") { self.recording = updated }
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
        let cues = SubtitleExporter.cues(transcript.cues, timeline: recording.editedTimeline)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? SubtitleExporter.string(for: cues, format: format).write(to: url, atomically: true, encoding: .utf8)
    }

    func copyTranscript() {
        guard let transcript = recording.transcript else { return }
        let cues = SubtitleExporter.cues(transcript.cues, timeline: recording.editedTimeline)
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
                    let cues = SubtitleExporter.cues(transcript.cues, timeline: recording.editedTimeline)
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
        rebuildTask?.cancel()
        hintTask?.cancel()
        saveTask?.cancel()
        undoManager.removeAllActions()
        library.save(recording)
        Task { await refreshLibraryThumbnail() }
    }

    /// Updates the library thumbnail to reflect the edited look (background, camera, etc.).
    private func refreshLibraryThumbnail() async {
        guard let built else { return }
        let canvas = canvasSize
        let size = canvas.scaled(min(1, 640 / max(canvas.width, canvas.height))).evenRounded()
        let composition = CompositionBuilder.videoComposition(for: built, recording: recording, renderSize: size,
                                                              highQuality: false)
        let start = built.timeline.outputTime(forSource: trimStart)
        let end = built.timeline.outputTime(forSource: trimEnd)
        let time = min(start + 1, (start + end) / 2)
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
