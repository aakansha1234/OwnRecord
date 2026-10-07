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
        case idle, running(Double), failed(String)
        /// `clips` lists the clips of an iMovie export (`url` is their folder).
        case finished(URL, clips: [ExportedClip])
    }

    enum InspectorTab: String, CaseIterable, Identifiable {
        case layout, camera, blur, subtitles, audio

        var id: String { rawValue }
        var title: String { rawValue.capitalized }

        var symbol: String {
            switch self {
            case .layout: "rectangle.inset.filled"
            case .camera: "person.crop.circle"
            case .blur: "eye.slash"
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
    private(set) var currentTime: Double = 0 {
        didSet {
            // Blur selection and drawing belong to the section at the playhead; other sections can
            // have copies of the same area (same ID), which ⌫ must not delete unseen.
            if recording.edit.section(at: oldValue).id != recording.edit.section(at: currentTime).id {
                endRedactionEditing()
            }
        }
    }
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    private(set) var sourceSize: CGSize = .zero
    private(set) var hasCameraTrack = false
    private(set) var thumbnails: [NSImage] = []
    var transcription: TranscriptionState = .idle
    var export: ExportState = .idle
    var inspectorTab: InspectorTab = .layout {
        // The crop is chosen in the Layout tab; going elsewhere applies it.
        didSet { if inspectorTab != .layout { finishCropping() } }
    }
    var isExportSheetPresented = false
    var isShortcutsPresented = false
    var isSilenceSheetPresented = false
    var exportOptions = ExportOptions()
    var transcriptionLocale: String
    /// A short message over the preview, e.g. after moving the camera in one section.
    private(set) var hint: Hint?
    /// Maps preview-player time to recording time (deleted sections are left out).
    private(set) var previewTimeline = TimelineMap(ranges: [])
    /// The blurred area selected in the preview (only counts while it's in the section at the playhead).
    private(set) var selectedRedactionID: Redaction.ID?
    /// Set while dragging out a new blurred area in the preview.
    private(set) var drawingRedaction: RedactionStyle?
    /// Set while choosing the crop: the crop being chosen, applied by `finishCropping`.
    private(set) var cropDraft: CropRect?
    /// The shape the crop is locked to while choosing it.
    private(set) var cropAspect: CropAspect = .free

    struct Hint: Equatable, Identifiable {
        let id = UUID()
        var message: String
        var action: HintAction?
    }

    enum HintAction: Equatable {
        case applyCameraToAllSections
        case applyRedactionToAllSections(Redaction.ID)
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

    /// Pixel size of the screen recording.
    var recordingSize: CGSize { sourceSize == .zero ? recording.pixelSize : sourceSize }

    var canvasSize: CGSize {
        // While choosing the crop, the preview shows the whole recording.
        if isCropping { return recordingSize.evenRounded() }
        return LayoutEngine.canvasSize(source: recordingSize, edit: recording.edit)
    }

    var sections: [TimelineSection] { recording.edit.sections }
    var hasMultipleSections: Bool { sections.count > 1 }
    var currentSectionIndex: Int { recording.edit.sectionIndex(at: currentTime) }
    var currentSection: TimelineSection { sections[currentSectionIndex] }
    /// Camera position and size in the section at the playhead.
    var currentCameraPlacement: CameraPlacement { recording.edit.cameraPlacement(for: currentSection) }

    func range(ofSectionAt index: Int) -> Range<Double> {
        recording.edit.range(ofSectionAt: index, duration: duration)
    }

    /// Length of the edited video (deleted sections removed).
    var editedDuration: Double { previewTimeline.duration }

    /// Playhead position in the edited video.
    var editedTime: Double {
        previewTimeline.outputTime(forSource: currentTime).clamped(to: 0...max(0, editedDuration))
    }

    /// Recording time where the edited video starts.
    private var videoStart: Double { previewTimeline.sourceTime(forOutput: 0) }

    var canSplit: Bool {
        let time = snappedToFrame(currentTime)
        let range = self.range(ofSectionAt: currentSectionIndex)
        return time - range.lowerBound >= EditSettings.minimumSectionLength
            && range.upperBound - time >= EditSettings.minimumSectionLength
    }

    /// Whether a subtitle falls entirely within deleted sections.
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
            let ranges = recording.edit.keptRanges(duration: .infinity)
            let result = try await CompositionBuilder.build(recording: recording, files: files, ranges: ranges)
            duration = result.sourceDuration
            await install(result, at: result.timeline.sourceTime(forOutput: 0))
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
            let ranges = self.recording.edit.keptRanges(duration: .infinity)
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
                // After a seek that interrupted playback, the player's time catches up later.
                guard let self, self.isPlaying, !self.isReplacingItem, !self.seekedWhilePlaying else { return }
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
        drawingRedaction = nil
        selectedRedactionID = nil
        if previewTimeline.outputTime(forSource: currentTime) >= previewTimeline.duration - 0.05 {
            seek(to: videoStart)
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
        seek(to: videoStart)
    }

    /// Pauses before moving the playhead, so the pause doesn't move it back to where playback was.
    func pauseForSeek() {
        if isPlaying { seekedWhilePlaying = true }
        player.pause()
    }

    /// Jumps to the previous or next split.
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

    // MARK: Sections

    /// Whether an edit leaves anything to export.
    private func keepsSomething(_ edit: EditSettings, explain: Bool = false) -> Bool {
        guard edit.keptRanges(duration: duration).isEmpty else { return true }
        if explain { showHint("At least one section has to stay in the video.") }
        return false
    }

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
            recording.edit.sections[index].subtitles = nil
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

    func setCameraShape(_ shape: CameraShape, for id: TimelineSection.ID? = nil) {
        let index = sectionIndex(for: id)
        var placement = recording.edit.cameraPlacement(for: sections[index])
        placement.shape = shape
        setCameraPlacement(placement, name: "Change Camera Shape", coalescing: false, index: index)
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

    /// Uses the camera position, size and shape of the section at the playhead in every section.
    func applyCameraToAllSections() {
        let placement = currentCameraPlacement
        performEdit("Apply Camera to All Sections") {
            recording.edit.camera.placement = placement
            for index in recording.edit.sections.indices {
                recording.edit.sections[index].camera = nil
            }
        }
        dismissHint()
    }

    /// Whether every section uses the same camera position, size and shape.
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
        showHint("Camera changed in this section only.", action: .applyCameraToAllSections)
    }

    // MARK: Subtitles

    /// The subtitle style the inspector shows: the section at the playhead's own, else the recording's.
    var currentSubtitleStyle: SubtitleStyle {
        get { currentSection.subtitles ?? recording.edit.subtitles }
        set {
            let index = currentSectionIndex
            if recording.edit.sections[index].subtitles != nil {
                recording.edit.sections[index].subtitles = newValue
            } else {
                recording.edit.subtitles = newValue
            }
        }
    }

    /// Whether some sections have a subtitle style of their own.
    var hasSectionSubtitleStyles: Bool {
        sections.contains { $0.subtitles != nil }
    }

    /// Uses the subtitle style of the section at the playhead in every section.
    func applySubtitleStyleToAllSections() {
        var style = currentSubtitleStyle
        style.isEnabled = recording.edit.subtitles.isEnabled
        performEdit("Apply Subtitle Style to All Sections") {
            recording.edit.subtitles = style
            for index in recording.edit.sections.indices {
                recording.edit.sections[index].subtitles = nil
            }
        }
    }

    // MARK: Blur

    /// Blurred and pixelated areas in the section at the playhead.
    var currentRedactions: [Redaction] { currentSection.redactions }

    var selectedRedaction: Redaction? {
        guard canRedact else { return nil }
        return selectedRedactionID.flatMap { id in currentRedactions.first { $0.id == id } }
    }

    /// Whether areas can be blurred in the section at the playhead (it has to show the screen).
    var canRedact: Bool {
        !currentSection.isDeleted && currentSection.showsScreen
    }

    /// Starts dragging out a new area to blur or pixelate in the preview.
    func beginRedaction(_ style: RedactionStyle) {
        finishCropping()
        guard canRedact else {
            NSSound.beep()
            showHint(currentSection.isDeleted ? "This section is deleted." : "The screen is hidden in this section.")
            return
        }
        pauseForSeek()
        drawingRedaction = style
        selectedRedactionID = nil
        inspectorTab = .blur
        showHint("Drag over the area to \(style == .blur ? "blur" : "pixelate"). Press Esc to cancel.")
    }

    /// Adds the area dragged out after `beginRedaction`; `rect` is normalized in the screen recording.
    func finishRedaction(rect: CGRect) {
        guard let style = drawingRedaction else { return }
        drawingRedaction = nil
        let redaction = Redaction(style: style, rect: rect)
        let index = currentSectionIndex
        performEdit("Add \(style.noun)") { recording.edit.sections[index].redactions.append(redaction) }
        selectedRedactionID = redaction.id
        if hasMultipleSections {
            showHint("\(style.noun) added to this section only.", action: .applyRedactionToAllSections(redaction.id))
        } else {
            dismissHint()
        }
    }

    /// Cancels drawing a new area, or else deselects the selected one.
    func cancelRedactionEditing() {
        if drawingRedaction != nil {
            drawingRedaction = nil
            dismissHint()
        } else {
            selectedRedactionID = nil
        }
    }

    var canCancelRedactionEditing: Bool { drawingRedaction != nil || selectedRedaction != nil }

    private func endRedactionEditing() {
        selectedRedactionID = nil
        if drawingRedaction != nil {
            drawingRedaction = nil
            dismissHint()
        }
    }

    func selectRedaction(_ id: Redaction.ID?) {
        selectedRedactionID = id
        if id != nil { inspectorTab = .blur }
    }

    /// Moves or resizes an area in the section at the playhead (drags merge into one undo step).
    func setRedactionRect(_ rect: CGRect, for id: Redaction.ID, resizing: Bool) {
        guard let (section, index) = redactionIndex(id) else { return }
        let noun = recording.edit.sections[section].redactions[index].style.noun
        performEdit(resizing ? "Resize \(noun)" : "Move \(noun)", coalescing: true) {
            recording.edit.sections[section].redactions[index].rect = rect
        }
    }

    func setRedactionStyle(_ style: RedactionStyle, for id: Redaction.ID) {
        guard let (section, index) = redactionIndex(id), recording.edit.sections[section].redactions[index].style != style
        else { return }
        performEdit("Change to \(style.noun)") {
            recording.edit.sections[section].redactions[index].style = style
        }
    }

    /// Deletes an area (the selected one by default) from the section at the playhead.
    func deleteRedaction(_ id: Redaction.ID? = nil) {
        guard let id = id ?? selectedRedaction?.id, let (section, index) = redactionIndex(id) else { return }
        let noun = recording.edit.sections[section].redactions[index].style.noun
        performEdit("Delete \(noun)") { recording.edit.sections[section].redactions.remove(at: index) }
        if selectedRedactionID == id { selectedRedactionID = nil }
    }

    /// Puts an area of the section at the playhead into every section, at the same place.
    func applyRedactionToAllSections(_ id: Redaction.ID) {
        guard let redaction = currentRedactions.first(where: { $0.id == id }) else { return }
        performEdit("Apply \(redaction.style.noun) to All Sections") {
            for section in recording.edit.sections.indices {
                if let index = recording.edit.sections[section].redactions.firstIndex(where: { $0.id == id }) {
                    recording.edit.sections[section].redactions[index] = redaction
                } else {
                    recording.edit.sections[section].redactions.append(redaction)
                }
            }
        }
        dismissHint()
    }

    /// Whether every section has this area, at the same place and style.
    func redactionIsInAllSections(_ redaction: Redaction) -> Bool {
        sections.allSatisfy { $0.redactions.contains(redaction) }
    }

    private func redactionIndex(_ id: Redaction.ID) -> (section: Int, index: Int)? {
        let section = currentSectionIndex
        guard let index = sections[section].redactions.firstIndex(where: { $0.id == id }) else { return nil }
        return (section, index)
    }

    // MARK: Crop

    var isCropping: Bool { cropDraft != nil }

    /// The crop being chosen, in pixels of the recording.
    var cropDraftPixels: CGRect? { cropDraft?.pixelRect(in: recordingSize) }

    /// The shape whose crops fill the video without bars, if the video has a fixed aspect ratio.
    var cropAspectFillingVideo: CropAspect? { CropAspect(filling: recording.edit.layout.aspect) }

    /// Starts choosing the crop (on the whole recording), or applies the crop being chosen.
    func toggleCropping() {
        if isCropping { finishCropping() } else { beginCropping() }
    }

    func beginCropping() {
        guard loadState == .ready, !isCropping else { return }
        endRedactionEditing()
        cropDraft = recording.edit.crop ?? .full
        inspectorTab = .layout
        dismissHint()
        scheduleCompositionRefresh()
    }

    /// Applies the crop being chosen, as one undo step.
    func finishCropping() {
        guard let draft = cropDraft else { return }
        cropDraft = nil
        let crop = draft.isFull ? nil : draft
        if crop != recording.edit.crop {
            performEdit(crop == nil ? "Reset Crop" : "Crop") { recording.edit.crop = crop }
        } else {
            scheduleCompositionRefresh()
        }
    }

    /// Stops choosing the crop, leaving it as it was.
    func cancelCropping() {
        guard isCropping else { return }
        cropDraft = nil
        scheduleCompositionRefresh()
    }

    /// Moves or resizes the crop being chosen; `rect` is in pixels of the recording.
    func setCropDraft(pixels rect: CGRect) {
        guard isCropping else { return }
        cropDraft = CropRect(pixels: rect, in: recordingSize)
    }

    /// Changes the crop being chosen from typed pixel values. With a locked shape, a new width or
    /// height changes the other one too.
    func setCropDraft(x: CGFloat? = nil, y: CGFloat? = nil, width: CGFloat? = nil, height: CGFloat? = nil) {
        guard var rect = cropDraftPixels else { return }
        let size = recordingSize
        let ratio = cropAspect.ratio(source: size)
        if let x { rect.origin.x = x }
        if let y { rect.origin.y = y }
        if let width {
            rect.size.width = max(1, width)
            if let ratio { rect.size.height = rect.width / ratio }
        }
        if let height {
            rect.size.height = max(1, height)
            if let ratio { rect.size.width = rect.height * ratio }
        }
        if ratio != nil {
            // Too big for the recording: shrink both sides, keeping the shape.
            rect.size = rect.size.scaled(min(1, size.width / rect.width, size.height / rect.height))
        }
        setCropDraft(pixels: rect)
    }

    /// Locks the crop being chosen to a shape, fitting it inside the current crop.
    func setCropAspect(_ aspect: CropAspect) {
        cropAspect = aspect
        guard let draft = cropDraft, let ratio = aspect.ratio(source: recordingSize) else { return }
        let size = recordingSize
        let pixels = CGRect(x: draft.x * size.width, y: draft.y * size.height,
                            width: draft.width * size.width, height: draft.height * size.height)
        setCropDraft(pixels: CropRect.conforming(pixels, to: ratio, in: size))
    }

    /// Makes the crop being chosen the whole recording again.
    func resetCropDraft() {
        guard isCropping else { return }
        cropAspect = .free
        cropDraft = .full
    }

    /// Shows the whole recording again.
    func resetCrop() {
        cancelCropping()
        guard recording.edit.crop != nil else { return }
        performEdit("Reset Crop") { recording.edit.crop = nil }
    }

    // MARK: Silences

    enum SilenceAnalysis: Equatable {
        case idle, analyzing, ready(AudioLevels), failed(String)
    }

    struct SilenceSettings: Equatable {
        /// dBFS; nil uses the threshold suggested for this recording.
        var threshold: Double?
        var minimumDuration = 0.8
        var padding = 0.15
        var deletesPauses = true
    }

    private(set) var silenceAnalysis: SilenceAnalysis = .idle
    var silenceSettings = SilenceSettings()
    /// The track `silenceAnalysis` measured.
    @ObservationIgnored private var analyzedTrack: AudioTrackKind?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var pauseCache: (key: PauseCacheKey, pauses: [Range<Double>])?

    private struct PauseCacheKey: Equatable {
        var settings: SilenceSettings
        var threshold: Double
        var kept: [Range<Double>]
        var decibelCount: Int
    }

    /// The track pauses are found in.
    var silenceTrack: AudioTrackKind? { recording.silenceTrack }

    var silenceThreshold: Double {
        get {
            if let threshold = silenceSettings.threshold { return threshold }
            if case .ready(let levels) = silenceAnalysis { return levels.suggestedThreshold }
            return -50
        }
        set { silenceSettings.threshold = newValue }
    }

    /// Pauses found with the current settings, limited to what's in the video.
    var silencePauses: [Range<Double>] {
        guard case .ready(let levels) = silenceAnalysis else { return [] }
        let key = PauseCacheKey(settings: silenceSettings, threshold: silenceThreshold,
                                kept: recording.edit.keptRanges(duration: duration),
                                decibelCount: levels.decibels.count)
        if let pauseCache, pauseCache.key == key { return pauseCache.pauses }
        let found = levels.pauses(threshold: key.threshold, minimumDuration: silenceSettings.minimumDuration,
                                  padding: silenceSettings.padding).map(snappedToFrames)
        let pauses = recording.edit.pausesInVideo(found, duration: duration)
        pauseCache = (key, pauses)
        return pauses
    }

    func showSilenceSheet() {
        guard recording.hasAudio else { NSSound.beep(); return }
        pauseForSeek()
        isSilenceSheetPresented = true
        analyzeSilences()
    }

    private func analyzeSilences() {
        guard let kind = silenceTrack, let trackIndex = recording.audioTracks.firstIndex(of: kind) else { return }
        switch silenceAnalysis {
        case .analyzing, .ready:
            // Measured already, unless the track changed (e.g. the mic was muted in the mix).
            if analyzedTrack == kind { return }
        case .idle, .failed:
            break
        }
        silenceTask?.cancel()
        analyzedTrack = kind
        silenceAnalysis = .analyzing
        silenceSettings.threshold = nil
        let url = files.screen
        silenceTask = Task { [weak self] in
            do {
                let levels = try await SilenceDetector.levels(of: url, trackIndex: trackIndex)
                guard !Task.isCancelled else { return }
                self?.silenceAnalysis = .ready(levels)
            } catch {
                guard !Task.isCancelled else { return }
                self?.silenceAnalysis = .failed(error.localizedDescription)
            }
        }
    }

    /// Splits around the pauses found with the current settings, and deletes them if chosen.
    func cutSilences() {
        let pauses = silencePauses
        isSilenceSheetPresented = false
        guard !pauses.isEmpty else { return }
        var edit = recording.edit
        let deleting = silenceSettings.deletesPauses
        edit.cutPauses(pauses, deleting: deleting, duration: duration)
        guard keepsSomething(edit, explain: true) else { NSSound.beep(); return }
        performEdit(deleting ? "Remove Pauses" : "Split at Silences") { recording.edit = edit }
        let total = pauses.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        let count = pauses.count == 1 ? "1 pause" : "\(pauses.count) pauses"
        showHint(deleting ? "Removed \(count) (\(TimeFormat.length(total))). Press ⌘Z to undo."
                          : "Split at \(count). Press ⌫ on a section to delete it.")
    }

    private func snappedToFrames(_ range: Range<Double>) -> Range<Double> {
        let lower = snappedToFrame(range.lowerBound)
        return lower..<max(lower, snappedToFrame(range.upperBound))
    }

    // MARK: Hints

    func showHint(_ message: String, action: HintAction? = nil) {
        hint = Hint(message: message, action: action)
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

    /// Applies the crop being chosen, then opens the export options.
    func showExportSheet() {
        finishCropping()
        isExportSheetPresented = true
    }

    /// Takes a change made elsewhere (by the command line tool) as one undo step.
    func applyEdit(_ updated: Recording, actionName: String) {
        performEdit(actionName) { recording = updated }
    }

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
        if drawingRedaction != nil, !canRedact { endRedactionEditing() }
        // The crop changed underneath the one being chosen (undo, or the command line tool).
        if isCropping, old.edit.crop != recording.edit.crop { cancelCropping() }
        let edit = recording.edit
        let rangesChanged = old.edit.keptRanges(duration: .infinity) != edit.keptRanges(duration: .infinity)
        if rangesChanged, loadState == .ready {
            scheduleRebuild()
        } else {
            let visualChanged = old.edit.layout != edit.layout
                || old.edit.crop != edit.crop
                || old.edit.camera != edit.camera
                || old.edit.subtitles != edit.subtitles
                || old.edit.sections != edit.sections
                || old.transcript?.cues != recording.transcript?.cues
            if visualChanged { scheduleCompositionRefresh() }
            if old.edit.audio != edit.audio || old.edit.sections != edit.sections, let built {
                playerItem?.audioMix = CompositionBuilder.audioMix(for: built, edit: edit)
            }
        }
        scheduleSave()
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
                                                   highQuality: false, layer: isCropping ? .fullScreen : .composed)
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
        let recording = self.recording
        let files = self.files
        let localeIdentifier = transcriptionLocale
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
                let transcript = try await TranscriptionEngine.transcript(
                    for: recording, files: files, localeIdentifier: localeIdentifier
                ) { progress in
                    Task { @MainActor in
                        if case .running = self?.transcription { self?.transcription = .running(progress) }
                    }
                }
                guard let self else { return }
                var updated = self.recording
                updated.transcript = transcript
                updated.edit.subtitles.isEnabled = true
                self.performEdit("Generate Subtitles") { self.recording = updated }
                self.transcription = .idle
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
        guard let file = SubtitleExporter.file(for: recording, format: format) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(Self.fileName(for: recording.title)).\(format.rawValue)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? file.write(to: url, atomically: true, encoding: .utf8)
    }

    func copyTranscript() {
        guard let text = SubtitleExporter.file(for: recording, format: .txt) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Export

    func chooseDestinationAndExport() {
        let options = exportOptions
        let panel = NSSavePanel()
        if options.format == .imovie {
            panel.nameFieldStringValue = "\(Self.fileName(for: recording.title)) for iMovie"
            panel.nameFieldLabel = "Folder name:"
            panel.message = "The clips for iMovie are saved in a folder with this name."
            panel.prompt = "Export"
        } else {
            panel.nameFieldStringValue = "\(Self.fileName(for: recording.title)).\(options.format.fileExtension)"
            panel.allowedContentTypes = [options.format.contentType]
        }
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
            let progress: @Sendable (Double) -> Void = { progress in
                Task { @MainActor in
                    if case .running = self?.export { self?.export = .running(progress) }
                }
            }
            if options.format == .imovie {
                do {
                    let clips = try await IMovieExporter.export(recording: recording, files: files, options: options, to: url,
                                                                progress: progress)
                    self?.export = .finished(url, clips: clips)
                } catch {
                    self?.export = error is CancellationError || Task.isCancelled ? .idle : .failed(error.localizedDescription)
                }
                return
            }
            do {
                try await VideoExporter.export(recording: recording, files: files, options: options, to: url, progress: progress)
                if options.includeSubtitleFile, options.format != .gif, let file = SubtitleExporter.file(for: recording, format: .srt) {
                    try? file.write(to: url.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
                }
                self?.export = .finished(url, clips: [])
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
        finishCropping()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        transcriptionTask?.cancel()
        silenceTask?.cancel()
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
        let time = min(1, built.timeline.duration / 2)
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
