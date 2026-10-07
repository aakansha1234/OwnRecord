@preconcurrency import AVFoundation
import Foundation
@testable import OwnRecord
import Testing

/// Runs a mutating call outside `#expect` (the macro can't mutate its argument).
private func mutate(_ edit: inout EditSettings, _ change: (inout EditSettings) -> Bool) -> Bool {
    change(&edit)
}

@Suite struct SectionTests {
    @Test func splitCopiesTheSectionAndRejectsSlivers() {
        var edit = EditSettings()
        edit.sections[0].showsCamera = false
        #expect(mutate(&edit) { $0.split(at: 4, duration: 10) })
        #expect(edit.sections.map(\.start) == [0, 4])
        #expect(edit.sections[1].showsCamera == false)
        #expect(edit.sections[0].id != edit.sections[1].id)

        #expect(!mutate(&edit) { $0.split(at: 4.05, duration: 10) })
        #expect(!mutate(&edit) { $0.split(at: 9.95, duration: 10) })
        #expect(mutate(&edit) { $0.split(at: 7, duration: 10) })
        #expect(edit.sections.map(\.start) == [0, 4, 7])
    }

    @Test func sectionLookupAtSplitPoints() {
        var edit = EditSettings()
        edit.split(at: 2, duration: 10)
        edit.split(at: 5, duration: 10)
        #expect(edit.sectionIndex(at: 0) == 0)
        #expect(edit.sectionIndex(at: 1.999) == 0)
        #expect(edit.sectionIndex(at: 2) == 1)
        #expect(edit.sectionIndex(at: 9.9) == 2)
        #expect(edit.range(ofSectionAt: 1, duration: 10) == 2..<5)
        #expect(edit.range(ofSectionAt: 2, duration: 10) == 5..<10)
    }

    @Test func joinKeepsTheFirstSectionsSettings() {
        var edit = EditSettings()
        edit.split(at: 3, duration: 10)
        edit.sections[1].mutesAudio = true
        #expect(mutate(&edit) { $0.joinSection(at: 0) })
        #expect(edit.sections.count == 1)
        #expect(edit.sections[0].mutesAudio == false)
        #expect(!mutate(&edit) { $0.joinSection(at: 0) })
    }

    @Test func keptRangesSkipDeletedSections() {
        var edit = EditSettings()
        edit.split(at: 2, duration: 10)
        edit.split(at: 4, duration: 10)
        edit.split(at: 6, duration: 10)
        edit.sections[1].isDeleted = true
        #expect(edit.keptRanges(duration: 10) == [0..<2, 4..<10])

        // Adjacent kept sections merge into one range.
        edit.sections[1].isDeleted = false
        #expect(edit.keptRanges(duration: 10) == [0..<10])

        edit.sections[0].isDeleted = true
        edit.sections[2].isDeleted = true
        #expect(edit.keptRanges(duration: 10) == [2..<4, 6..<10])
        #expect(edit.keptRanges(duration: .infinity).last?.upperBound == .infinity)
    }

    @Test func editPointsAreSplitsAndEnds() {
        var edit = EditSettings()
        edit.split(at: 3, duration: 10)
        edit.split(at: 9, duration: 10)
        #expect(edit.editPoints(duration: 10) == [0, 3, 9, 10])
    }

    @Test func decodesRecordingsSavedBeforeSections() throws {
        // `edit` as written by earlier versions: no sections, one camera switch for the whole video.
        let json = """
        {"trimStart":1,"layout":{"aspect":"original","background":"none","padding":0,"cornerRadius":0,"shadow":0.6},
         "camera":{"isVisible":false,"shape":"circle","size":0.3,"position":"topLeft","customX":0.85,"customY":0.8,
                   "margin":0.035,"borderWidth":0.025,"borderColor":{"red":1,"green":1,"blue":1,"alpha":1},
                   "shadow":true,"mirror":true},
         "subtitles":{"isEnabled":true,"fontScale":0.048,"position":"bottom",
                      "textColor":{"red":1,"green":1,"blue":1,"alpha":1},
                      "backgroundColor":{"red":0,"green":0,"blue":0,"alpha":0.62},"bold":true},
         "audio":{"microphoneVolume":1,"systemVolume":0.5}}
        """
        let edit = try JSONDecoder().decode(EditSettings.self, from: Data(json.utf8))
        #expect(edit.sections.count == 1)
        #expect(edit.sections[0].start == 0)
        #expect(edit.sections[0].showsCamera == false)
        #expect(edit.cameraPlacement(for: edit.sections[0]).position == .topLeft)
        #expect(edit.cameraPlacement(for: edit.sections[0]).size == 0.3)
        #expect(edit.audio.systemVolume == 0.5)
    }

    @Test func sectionsSurviveARoundTrip() throws {
        var edit = EditSettings()
        edit.split(at: 2.5, duration: 10)
        edit.sections[1].isDeleted = true
        edit.sections[0].camera = CameraPlacement(position: .custom, customX: 0.3, customY: 0.4, size: 0.2)
        let decoded = try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(edit))
        #expect(decoded == edit)
    }

    @Test func cameraShapeIsPerSection() throws {
        var edit = EditSettings()
        edit.camera.shape = .roundedSquare
        edit.split(at: 2, duration: 10)
        // Sections without their own shape (including ones saved before shapes were per section)
        // use the recording's shape.
        let saved = #"{"start":2,"camera":{"position":"topLeft","customX":0.85,"customY":0.8,"size":0.3}}"#
        edit.sections[1] = try JSONDecoder().decode(TimelineSection.self, from: Data(saved.utf8))
        #expect(edit.cameraPlacement(for: edit.sections[0]).shape == .roundedSquare)
        #expect(edit.cameraPlacement(for: edit.sections[1]).shape == .roundedSquare)

        edit.sections[1].camera?.shape = .roundedRectangle
        #expect(edit.cameraPlacement(for: edit.sections[1]).shape == .roundedRectangle)
        #expect(edit.cameraPlacement(for: edit.sections[0]).shape == .roundedSquare)
        let canvas = CGSize(width: 1920, height: 1080)
        let wide = LayoutEngine.layout(canvas: canvas, source: canvas, edit: edit, hasCamera: true, at: 5).cameraRect!
        let square = LayoutEngine.layout(canvas: canvas, source: canvas, edit: edit, hasCamera: true, at: 1).cameraRect!
        #expect(abs(wide.width / wide.height - 16.0 / 9.0) < 0.001)
        #expect(square.width == square.height)
    }

    @Test func cameraNudgesBetweenCorners() {
        var placement = CameraPlacement()
        placement.position = .bottomRight
        #expect(LayoutEngine.corner(of: placement, movedToward: .left) == .bottomLeft)
        #expect(LayoutEngine.corner(of: placement, movedToward: .top) == .topRight)
        #expect(LayoutEngine.corner(of: placement, movedToward: .right) == .bottomRight)
        placement.position = .custom
        placement.customX = 0.2
        placement.customY = 0.3
        #expect(LayoutEngine.corner(of: placement, movedToward: .bottom) == .bottomLeft)
    }
}

@Suite struct TimelineMapTests {
    let map = TimelineMap(ranges: [1..<3, 5..<6, 8..<10])

    @Test func mapsBothWays() {
        #expect(map.duration == 5)
        #expect(map.outputTime(forSource: 1) == 0)
        #expect(map.outputTime(forSource: 2.5) == 1.5)
        #expect(map.outputTime(forSource: 5.5) == 2.5)
        #expect(map.sourceTime(forOutput: 2.5) == 5.5)
        #expect(map.sourceTime(forOutput: 3) == 8)
        #expect(map.sourceTime(forOutput: 4.5) == 9.5)
    }

    @Test func removedTimesMapToWhereTheVideoContinues() {
        #expect(map.outputTime(forSource: 0.5) == 0)
        #expect(map.outputTime(forSource: 4) == 2)
        #expect(map.outputTime(forSource: 11) == 5)
        #expect(!map.contains(source: 4))
        #expect(map.contains(source: 5))
    }

    @Test func endsMapInsideThePartThatPlayed() {
        // The very end and (on request) cut points map to the end of the part before them,
        // not onto the removed part that follows.
        #expect(abs(map.sourceTime(forOutput: 5) - (10 - TimelineMap.endInset)) < 1e-9)
        #expect(abs(map.sourceTime(forOutput: 2, preferringEarlier: true) - (3 - TimelineMap.endInset)) < 1e-9)
        #expect(map.sourceTime(forOutput: 2) == 5)
    }

    @Test func outputRangesJoinAcrossCuts() {
        #expect(map.outputRanges(forSource: 2..<9) == [1..<4])
        #expect(map.outputRanges(forSource: 3..<5).isEmpty)
    }

    @Test func subtitlesFollowTheEditedTimeline() {
        let cues = [SubtitleCue(start: 0.5, end: 1.5, text: "a"),  // starts before the video
                    SubtitleCue(start: 3.2, end: 4.8, text: "b"),  // entirely cut
                    SubtitleCue(start: 2.5, end: 5.5, text: "c"),  // spans a cut
                    SubtitleCue(start: 8.5, end: 9, text: "d")]
        let mapped = SubtitleExporter.cues(cues, timeline: map)
        #expect(mapped.map(\.text) == ["a", "c", "d"])
        #expect(mapped[0].start == 0 && mapped[0].end == 0.5)
        #expect(mapped[1].start == 1.5 && mapped[1].end == 2.5)
        #expect(mapped[2].start == 3.5 && mapped[2].end == 4)
    }
}

@Suite struct SectionLayoutTests {
    let canvas = CGSize(width: 1920, height: 1080)

    private func edit() -> EditSettings {
        var edit = EditSettings()
        edit.camera.position = .bottomRight
        edit.split(at: 2, duration: 10)
        edit.split(at: 4, duration: 10)
        return edit
    }

    @Test func hiddenScreenLetsTheCameraFillTheStage() {
        var edit = edit()
        edit.layout.padding = 0.05
        edit.sections[1].showsScreen = false
        let layout = LayoutEngine.layout(canvas: canvas, source: canvas, edit: edit, hasCamera: true, at: 3)
        #expect(layout.screenOpacity == 0)
        let camera = try! #require(layout.camera)
        #expect(camera.fillsStage)
        #expect(camera.rect == CGRect(origin: .zero, size: canvas).insetBy(dx: 54, dy: 54))
    }

    @Test func hiddenCameraAndPerSectionPlacement() {
        var edit = edit()
        edit.sections[1].showsCamera = false
        edit.sections[2].camera = CameraPlacement(position: .topLeft, size: 0.2)
        #expect(LayoutEngine.layout(canvas: canvas, source: canvas, edit: edit, hasCamera: true, at: 3).camera == nil)

        let first = try! #require(LayoutEngine.layout(canvas: canvas, source: canvas, edit: edit, hasCamera: true, at: 1).cameraRect)
        #expect(first.maxX > canvas.width / 2 && first.maxY > canvas.height / 2)
        let moved = try! #require(LayoutEngine.layout(canvas: canvas, source: canvas, edit: edit, hasCamera: true, at: 5).cameraRect)
        #expect(moved.minX < canvas.width / 2 && moved.minY < canvas.height / 2)
        #expect(abs(moved.height - 0.2 * 1080) < 0.001)
    }

    @Test func changesAnimateIntoTheNextSection() {
        var edit = edit()
        edit.sections[1].camera = CameraPlacement(position: .topLeft)
        let start = LayoutEngine.layout(canvas: canvas, source: canvas, edit: edit, hasCamera: true, at: 1.9).cameraRect!
        let end = LayoutEngine.layout(canvas: canvas, source: canvas, edit: edit, hasCamera: true, at: 3).cameraRect!
        let middle = LayoutEngine.layout(canvas: canvas, source: canvas, edit: edit, hasCamera: true,
                                         at: 2 + LayoutEngine.transitionDuration / 2).cameraRect!
        #expect(abs(middle.midX - (start.midX + end.midX) / 2) < 1)
        #expect(abs(middle.midY - (start.midY + end.midY) / 2) < 1)

        // Hiding the screen fades it out while the camera grows.
        edit.sections[2].showsScreen = false
        let fading = LayoutEngine.layout(canvas: canvas, source: canvas, edit: edit, hasCamera: true,
                                         at: 4 + LayoutEngine.transitionDuration / 2)
        #expect(abs(fading.screenOpacity - 0.5) < 0.01)
        #expect(fading.cameraRect!.width > end.width && fading.cameraRect!.width < canvas.width)
    }

    @Test func deletedSectionsAreSkippedWhenAnimating() {
        var edit = edit()
        edit.sections[1].isDeleted = true
        edit.sections[1].showsCamera = false
        // Section 3 follows section 1 directly in the video; both show the camera in the same spot.
        let layout = LayoutEngine.layout(canvas: canvas, source: canvas, edit: edit, hasCamera: true, at: 4.05)
        #expect(layout.camera?.opacity == 1)
    }

    @Test func noTransitionFromDeletedParts() {
        var edit = edit()
        edit.sections[1].camera = CameraPlacement(position: .topLeft)
        let settled = LayoutEngine.layout(canvas: canvas, source: canvas, edit: edit, hasCamera: true, at: 3).cameraRect!

        // The export starts at section 2, so it shouldn't slide in from section 1's position.
        edit.sections[0].isDeleted = true
        let late = TimelineMap(ranges: edit.keptRanges(duration: 10))
        let first = LayoutEngine.layout(canvas: canvas, source: canvas, edit: edit, hasCamera: true, at: 2.05, timeline: late)
        #expect(first.cameraRect == settled)

        // Sections that play back to back still animate.
        edit.sections[0].isDeleted = false
        let full = TimelineMap(ranges: edit.keptRanges(duration: 10))
        let moving = LayoutEngine.layout(canvas: canvas, source: canvas, edit: edit, hasCamera: true, at: 2.05, timeline: full)
        #expect(moving.cameraRect != settled)

        // Across a deleted section, the transition starts from what played before the cut.
        edit.split(at: 3, duration: 10)
        edit.sections[2].isDeleted = true
        edit.sections[3].camera = CameraPlacement(position: .topLeft)
        let cut = TimelineMap(ranges: edit.keptRanges(duration: 10))
        let afterCut = LayoutEngine.layout(canvas: canvas, source: canvas, edit: edit, hasCamera: true, at: 4.05, timeline: cut)
        #expect(afterCut.cameraRect == settled)
    }

    @Test func mutedSectionsSilenceTheMix() {
        var edit = edit()
        edit.sections[1].mutesAudio = true
        edit.sections[2].mutesAudio = true
        edit.split(at: 6, duration: 10)
        edit.sections[3].mutesAudio = false
        let timeline = TimelineMap(ranges: edit.keptRanges(duration: 10))
        #expect(CompositionBuilder.mutedRanges(edit: edit, timeline: timeline) == [2..<6])
        let changes = CompositionBuilder.volumeChanges(volume: 0.8, muted: [0..<1, 2..<6])
        #expect(changes.map(\.time) == [0, 1, 2, 6])
        #expect(changes.map(\.volume) == [0, 0.8, 0, 0.8])
    }
}

@MainActor @Suite(.serialized) struct EditorModelTests {
    private func makeModel(microphone: Bool = false) async throws -> (EditorModel, URL) {
        let root = PipelineTests.scratchRoot.appendingPathComponent("editor-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("take")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (recording, files) = microphone
            ? try await PipelineTests.makeRecordingWithMicrophone(folder: folder)
            : try await PipelineTests.makeRecording(folder: folder)
        let model = EditorModel(recording: recording, files: files, library: RecordingLibrary(rootURL: root),
                                preferences: .shared)
        await model.load()
        try #require(model.loadState == .ready)
        return (model, root)
    }

    /// Performs one user action, then lets the run loop close its undo group like an event would.
    private func step(_ model: EditorModel, _ action: () -> Void) {
        action()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    @Test func splitDeleteUndoAndRedo() async throws {
        let (model, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        model.seek(to: 0.8)
        step(model) { model.splitAtPlayhead() }
        model.seek(to: 1.4)
        step(model) { model.splitAtPlayhead() }
        try #require(model.sections.map(\.start) == [0, 0.8, 1.4])
        #expect(model.currentSectionIndex == 2)

        model.seek(to: 1)
        step(model) { model.toggleDeleted() }
        #expect(model.sections[1].isDeleted)
        #expect(abs(model.recording.editedDuration - 1.4) < 0.01)
        #expect(model.undoManager.undoActionName == "Delete Section")

        // The preview is rebuilt without the deleted section.
        for _ in 0..<100 where abs(model.previewTimeline.duration - 1.4) > 0.05 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(abs(model.previewTimeline.duration - 1.4) < 0.05)
        #expect(abs(model.editedDuration - 1.4) < 0.05)

        model.undoManager.undo()
        #expect(!model.sections[1].isDeleted)
        model.undoManager.undo()
        #expect(model.sections.count == 2)
        model.undoManager.redo()
        #expect(model.sections.count == 3)
    }

    @Test func slidersCoalesceIntoOneUndoStep() async throws {
        let (model, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        for size in stride(from: 0.2, through: 0.4, by: 0.05) {
            step(model) { model.cameraSize = size }
        }
        #expect(abs(model.currentCameraPlacement.size - 0.4) < 0.001)
        model.undoManager.undo()
        #expect(model.currentSection.camera == nil)
        #expect(!model.undoManager.canUndo)
    }

    @Test func shapeChangesOnlyTheCurrentSection() async throws {
        let (model, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        model.seek(to: 1)
        step(model) { model.splitAtPlayhead() }
        step(model) { model.setCameraShape(.roundedRectangle) }
        #expect(model.currentCameraPlacement.shape == .roundedRectangle)
        #expect(model.recording.edit.cameraPlacement(for: model.sections[0]).shape == .circle)
        #expect(model.recording.edit.camera.shape == .circle)
        #expect(model.hint?.action == .applyCameraToAllSections)

        step(model) { model.applyCameraToAllSections() }
        #expect(model.sections.allSatisfy { model.recording.edit.cameraPlacement(for: $0).shape == .roundedRectangle })
        model.undoManager.undo()
        #expect(model.recording.edit.cameraPlacement(for: model.sections[0]).shape == .circle)
    }

    @Test func cannotRemoveEverything() async throws {
        let (model, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        step(model) { model.toggleDeleted() }
        #expect(!model.sections[0].isDeleted)
        #expect(model.hint != nil)

        // Joining the only kept section into a deleted one is refused too.
        model.seek(to: 1)
        step(model) { model.splitAtPlayhead() }
        model.seek(to: 0.5)
        step(model) { model.toggleDeleted() }
        model.seek(to: 1.5)
        step(model) { model.joinWithPrevious() }
        #expect(model.sections.count == 2)
        #expect(!model.recording.edit.keptRanges(duration: model.duration).isEmpty)
    }

    @Test func seekingDuringPlaybackSticks() async throws {
        let (model, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        model.seek(to: 0.6)
        step(model) { model.splitAtPlayhead() }
        model.seek(to: 1.2)
        step(model) { model.splitAtPlayhead() }
        model.seek(to: 0.9)
        step(model) { model.toggleDeleted() }
        for _ in 0..<100 where abs(model.previewTimeline.duration - 1.4) > 0.05 {
            try await Task.sleep(for: .milliseconds(20))
        }

        model.seek(to: 0)
        model.togglePlayback()
        for _ in 0..<50 where !model.isPlaying { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.isPlaying)
        // Like clicking the timeline: pause, then put the playhead inside the deleted section.
        model.pauseForSeek()
        model.seek(to: 0.9)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!model.isPlaying)
        #expect(model.currentTime == 0.9)
        #expect(model.currentSection.isDeleted)
    }

    @Test func undoKeepsSubtitleTextTypedLater() async throws {
        let (model, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = SubtitleCue(start: 0, end: 1, text: "one")
        let second = SubtitleCue(start: 1, end: 2, text: "two")
        model.recording.transcript?.cues = [first, second]
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        step(model) { model.deleteCue(first.id) }
        model.updateCue(second.id, text: "two, edited")
        model.undoManager.undo()
        #expect(model.recording.transcript?.cues.map(\.text) == ["one", "two, edited"])
    }

    @Test func cropIsChosenOnTheWholeRecordingAndAppliedOnce() async throws {
        let (model, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let full = model.canvasSize

        model.beginCropping()
        #expect(model.isCropping)
        #expect(model.canvasSize == full)
        // Dragging only changes the crop being chosen.
        step(model) { model.setCropDraft(pixels: CGRect(x: 40, y: 20, width: 330, height: 200)) }
        step(model) { model.setCropDraft(width: 320) }
        #expect(model.recording.edit.crop == nil)
        #expect(model.canvasSize == full)
        #expect(model.cropDraftPixels == CGRect(x: 40, y: 20, width: 320, height: 200))

        step(model) { model.finishCropping() }
        #expect(!model.isCropping)
        #expect(model.recording.edit.crop?.pixelRect(in: model.recordingSize) == CGRect(x: 40, y: 20, width: 320, height: 200))
        #expect(model.canvasSize == CGSize(width: 320, height: 200))
        #expect(model.undoManager.undoActionName == "Crop")

        // A locked shape fits inside the crop; Esc leaves the crop as it was.
        model.beginCropping()
        model.setCropAspect(.square)
        #expect(model.cropDraftPixels == CGRect(x: 100, y: 20, width: 200, height: 200))
        EditorCommand.cancelEditing.perform(on: model)
        #expect(!model.isCropping)
        #expect(model.canvasSize == CGSize(width: 320, height: 200))

        // Undo while choosing drops the crop being chosen.
        model.beginCropping()
        model.undoManager.undo()
        #expect(!model.isCropping)
        #expect(model.recording.edit.crop == nil)

        // Leaving the Layout tab applies it.
        model.beginCropping()
        model.setCropDraft(pixels: CGRect(x: 0, y: 0, width: 320, height: 400))
        model.inspectorTab = .camera
        #expect(!model.isCropping)
        #expect(model.recording.edit.crop?.pixelRect(in: model.recordingSize) == CGRect(x: 0, y: 0, width: 320, height: 400))
    }

    @Test func blurAreasAreDrawnSelectedAndDeleted() async throws {
        let (model, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        model.seek(to: 1)
        step(model) { model.splitAtPlayhead() }
        step(model) { EditorCommand.blurArea.perform(on: model) }
        #expect(model.drawingRedaction == .blur)
        #expect(EditorCommand.cancelEditing.isEnabled(for: model))
        step(model) { model.finishRedaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1)) }
        #expect(model.drawingRedaction == nil)
        #expect(model.currentRedactions.count == 1)
        #expect(model.sections[0].redactions.isEmpty)
        let id = try #require(model.selectedRedaction?.id)
        #expect(model.hint?.action == .applyRedactionToAllSections(id))
        #expect(model.undoManager.undoActionName == "Add Blur")

        // Drags merge into one step.
        for x in stride(from: 0.12, through: 0.3, by: 0.06) {
            step(model) { model.setRedactionRect(CGRect(x: x, y: 0.1, width: 0.3, height: 0.1), for: id, resizing: false) }
        }
        #expect(abs((model.selectedRedaction?.x ?? 0) - 0.3) < 1e-9)
        model.undoManager.undo()
        #expect(abs((model.selectedRedaction?.x ?? 0) - 0.1) < 1e-9)

        step(model) { model.applyRedactionToAllSections(id) }
        #expect(model.sections.allSatisfy { $0.redactions.map(\.id) == [id] })

        // The selection stays in its section: elsewhere ⌫ deletes the section, not an unseen copy.
        model.seek(to: 0.5)
        #expect(model.selectedRedaction == nil)
        #expect(EditorCommand.deleteSection.title(for: model) == "Delete Section")
        model.seek(to: 1.5)
        model.selectRedaction(id)

        // With a blur selected, ⌫ deletes the blur rather than the section.
        #expect(EditorCommand.deleteSection.title(for: model) == "Delete Blur")
        step(model) { EditorCommand.deleteSection.perform(on: model) }
        #expect(model.currentRedactions.isEmpty)
        #expect(!model.currentSection.isDeleted)
        #expect(model.sections[0].redactions.count == 1)
        #expect(EditorCommand.deleteSection.title(for: model) == "Delete Section")

        // Hidden screens can't be blurred.
        step(model) { model.toggleScreen() }
        #expect(!EditorCommand.blurArea.isEnabled(for: model))
    }

    @Test func takesCommandLineEditsAsUndoSteps() async throws {
        let (model, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        var updated = model.recording
        updated.edit.cutPauses([0.5..<1.2], deleting: true, duration: updated.duration)
        step(model) { model.applyEdit(updated, actionName: "Cut") }
        #expect(model.undoManager.undoActionName == "Cut")
        #expect(abs(model.recording.editedDuration - (updated.duration - 0.7)) < 0.01)

        model.undoManager.undo()
        #expect(model.sections.count == 1)
        #expect(!model.sections[0].isDeleted)
    }

    @Test func removesSilencesInOneUndoStep() async throws {
        let (model, root) = try await makeModel(microphone: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(EditorCommand.splitAtSilences.isEnabled(for: model))
        step(model) { EditorCommand.splitAtSilences.perform(on: model) }
        #expect(model.isSilenceSheetPresented)
        for _ in 0..<100 where model.silenceAnalysis == .analyzing { try await Task.sleep(for: .milliseconds(20)) }
        guard case .ready = model.silenceAnalysis else {
            Issue.record("Analysis didn't finish: \(model.silenceAnalysis)")
            return
        }
        model.silenceSettings.minimumDuration = 0.5
        model.silenceSettings.padding = 0.1
        let pauses = model.silencePauses
        try #require(pauses.count == 1, "\(pauses)")
        #expect(abs(pauses[0].lowerBound - 0.7) < 0.07 && abs(pauses[0].upperBound - 1.4) < 0.07)

        step(model) { model.cutSilences() }
        #expect(!model.isSilenceSheetPresented)
        #expect(model.sections.count == 3)
        #expect(model.sections.map(\.isDeleted) == [false, true, false])
        #expect(model.undoManager.undoActionName == "Remove Pauses")
        #expect(model.hint?.message.hasPrefix("Removed 1 pause") == true)
        model.undoManager.undo()
        #expect(model.sections.count == 1)
    }

    @Test func differentSettingsAreSeparateUndoSteps() async throws {
        let (model, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        let mirror = model.recording.edit.camera.mirror
        let shadow = model.recording.edit.camera.shadow
        step(model) { model.recording.edit.camera.mirror.toggle() }
        step(model) { model.recording.edit.camera.shadow.toggle() }
        #expect(model.undoManager.undoActionName == "Change Camera Style")
        model.undoManager.undo()
        #expect(model.recording.edit.camera.shadow == shadow)
        #expect(model.recording.edit.camera.mirror != mirror)
        model.undoManager.undo()
        #expect(model.recording.edit.camera.mirror == mirror)
    }
}
