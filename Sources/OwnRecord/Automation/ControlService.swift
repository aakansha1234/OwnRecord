import AppKit
@preconcurrency import AVFoundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// Carries out the `ownrecord` tool's requests (see `ControlChannel`) with the app's models, as if
/// the user did them: recording shows the usual controls, and edits made while the recording is
/// open in the editor can be undone there.
@MainActor
final class ControlService {
    private unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    func handle(_ name: String, _ request: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        guard let command = ControlCommand(rawValue: name) else {
            throw ControlError("OwnRecord doesn't know the command “\(name)”. If you just updated OwnRecord, quit and reopen it.")
        }
        func params<P: Decodable>() throws -> P {
            try ControlCoding.decoder.decode(ControlRequest<P>.self, from: request).params
        }
        let result: any Encodable
        switch command {
        case .status: result = status()
        case .sources: result = try await sources()
        case .list: result = list(try params())
        case .show: result = try show(params())
        case .open: result = try openEditor(params())
        case .rename: result = try rename(params())
        case .delete: result = try deleteRecording(params())
        case .record: result = try await record(params())
        case .wait: result = try await waitForRecording()
        case .stop: result = try await stop(params())
        case .pause: result = try setPaused(true)
        case .resume: result = try setPaused(false)
        case .discard: result = try await discard()
        case .trim: result = try trim(params())
        case .cut: result = try cut(params())
        case .restore: result = try restore(params())
        case .silences: result = try await silences(params())
        case .blur: result = try blur(params())
        case .unblur: result = try unblur(params())
        case .set: result = try changeSettings(params())
        case .transcribe: result = try await transcribe(params(), progress: progress)
        case .transcript: result = try transcript(params())
        case .frame: result = try await frame(params())
        case .export: result = try await export(params(), progress: progress)
        }
        return try ControlCoding.encoder.encode(result)
    }

    /// Clears files staged for tools that never picked them up.
    func removeOldStagedFiles() {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let folders = (try? fileManager.contentsOfDirectory(at: ControlChannel.stagingRoot,
                                                           includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders {
            if let created = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate, created < cutoff {
                try? fileManager.removeItem(at: folder)
            }
        }
    }

    // MARK: Status

    private func status() -> StatusInfo {
        let controller = app.recording!
        var countdown: Int?
        let state: String
        switch controller.phase {
        case .idle: state = "idle"
        case .preparing: state = "starting"
        case .countdown(let remaining):
            state = "countdown"
            countdown = remaining
        case .recording: state = "recording"
        case .paused: state = "paused"
        case .finishing: state = "saving"
        }
        app.permissions.refresh()
        let permissions = Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map {
            ($0.controlName, "\(app.permissions.state(for: $0))")
        })
        return StatusInfo(state: state, countdown: countdown, elapsed: controller.recordedTime,
                          version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                          recordingsFolder: app.library.rootURL.path, recordingCount: app.library.recordings.count,
                          permissions: permissions)
    }

    private func sources() async throws -> SourcesInfo {
        let content = try await shareableContent()
        let recorder = app.recorder
        recorder.refreshDevices()
        let main = CGMainDisplayID()
        return SourcesInfo(
            displays: ShareableContent.displays(from: content).map {
                SourcesInfo.Display(id: $0.id, name: $0.name, width: Int($0.pointSize.width), height: Int($0.pointSize.height),
                                    pixelWidth: Int($0.pixelSize.width), pixelHeight: Int($0.pixelSize.height),
                                    isMain: $0.id == main)
            },
            windows: recordableWindows(in: content).map {
                SourcesInfo.Window(id: $0.id, app: $0.appName, title: $0.title,
                                   width: Int($0.frame.width), height: Int($0.frame.height))
            },
            cameras: recorder.cameras.map { SourcesInfo.Device(id: $0.id, name: $0.name, isSelected: $0.id == recorder.cameraID) },
            microphones: recorder.microphones.map {
                SourcesInfo.Device(id: $0.id, name: $0.name, isSelected: $0.id == recorder.microphoneID)
            },
            systemAudio: recorder.captureSystemAudio)
    }

    private func shareableContent() async throws -> SCShareableContent {
        do {
            return try await ShareableContent.load()
        } catch {
            throw CaptureError.permissionDenied
        }
    }

    private func recordableWindows(in content: SCShareableContent) -> [WindowOption] {
        ShareableContent.windows(from: content)
    }

    // MARK: Library

    private func list(_ params: ListParams) -> [RecordingInfo] {
        var recordings = app.library.recordings.map(current)
        if let query = params.search?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
            recordings = recordings.filter { $0.matches(search: query) }
        }
        if let limit = params.limit {
            recordings = Array(recordings.prefix(max(0, limit)))
        }
        return recordings.map(info)
    }

    private func show(_ params: RecordingParams) throws -> RecordingDetails {
        let recording = try find(params.recording)
        let edit = recording.edit
        let timeline = recording.editedTimeline
        let sections = edit.sections.indices.map { index in
            let section = edit.sections[index]
            let range = edit.range(ofSectionAt: index, duration: recording.duration)
            let played = timeline.outputRanges(forSource: range)
            return RecordingDetails.Section(
                number: index + 1, start: range.lowerBound, end: range.upperBound,
                videoStart: played.first?.lowerBound, videoEnd: played.last?.upperBound,
                deleted: section.isDeleted, showsScreen: section.showsScreen, showsCamera: section.showsCamera,
                muted: section.mutesAudio,
                blurs: section.redactions.map { RecordingDetails.Blur(id: $0.id, style: $0.style, rect: [$0.x, $0.y, $0.width, $0.height]) })
        }
        var paths: [String: String] = [:]
        if let files = app.library.files(for: recording.id) {
            paths["metadata"] = files.metadata.path
            paths["screen"] = files.screen.path
            paths["thumbnail"] = files.thumbnail.path
            if recording.hasCamera { paths["camera"] = files.camera.path }
        }
        return RecordingDetails(recording: info(recording), trimStart: edit.trimStart, trimEnd: edit.trimEnd,
                                sections: sections, layout: edit.layout, camera: edit.camera, subtitles: edit.subtitles,
                                audio: edit.audio, transcriptLocale: recording.transcript?.localeIdentifier,
                                subtitleCount: recording.transcript?.cues.count, files: paths)
    }

    private func openEditor(_ params: RecordingParams) throws -> EditResult {
        let recording = try find(params.recording)
        app.windows.openEditor(for: recording.id)
        return EditResult(message: "Opened “\(recording.title)” in the editor.", recording: info(recording))
    }

    private func rename(_ params: RenameParams) throws -> EditResult {
        let title = params.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ControlError("The title can't be empty.") }
        let recording = try find(params.recording)
        let renamed = update(recording, "Rename") { $0.title = title }
        return EditResult(message: "Renamed “\(recording.title)” to “\(title)”.", recording: info(renamed))
    }

    private func deleteRecording(_ params: RecordingParams) throws -> EditResult {
        let recording = try find(params.recording)
        let result = EditResult(message: "Moved “\(recording.title)” to the Trash.", recording: info(recording))
        app.windows.closeEditor(for: recording.id)
        app.library.delete(recording.id)
        return result
    }

    // MARK: Recording

    private func record(_ params: RecordParams) async throws -> RecordResult {
        let controller = app.recording!
        guard controller.phase == .idle else {
            throw ControlError("OwnRecord is already recording. Run `ownrecord stop` first.")
        }
        guard params.window == nil || params.area == nil else {
            throw ControlError("Record either a window or an area, not both.")
        }
        let recorder = app.recorder
        recorder.refreshDevices()
        // Work out everything before changing the recorder's choices.
        let camera = try params.camera.map { try device($0, in: recorder.cameras, kind: "camera") }
        let microphone = try params.microphone.map { try device($0, in: recorder.microphones, kind: "microphone") }
        guard await app.permissions.request(.screen) else { throw CaptureError.permissionDenied }
        let content = try await shareableContent()
        let displays = ShareableContent.displays(from: content)
        var mode = CaptureMode.display
        var windowID: CGWindowID?
        var area: AreaSelection?
        var displayID: CGDirectDisplayID?
        if let reference = params.window {
            mode = .window
            windowID = try pick(reference, from: recordableWindows(in: content), kind: "window", id: { String($0.id) },
                                names: { [$0.appName, $0.title, "\($0.appName) — \($0.title)"] },
                                label: { $0.title.isEmpty ? $0.appName : "\($0.appName) — \($0.title)" }).id
        } else if let values = params.area {
            mode = .area
            let display = try self.display(params.display, in: displays)
            guard values.count == 4, values[2] >= 16, values[3] >= 16 else {
                throw ControlError("Give the area as x,y,width,height in points, at least 16 × 16.")
            }
            let rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            guard CGRect(origin: .zero, size: display.pointSize).contains(rect) else {
                throw ControlError("The area has to fit on \(display.name), which is \(Int(display.pointSize.width)) × \(Int(display.pointSize.height)) points.")
            }
            area = AreaSelection(displayID: display.id, rect: rect)
        } else {
            displayID = try display(params.display, in: displays).id
        }

        // These choices are only for this recording; the user's own come back when it ends.
        let usersChoices = RecorderChoices(recorder)
        recorder.mode = mode
        if let windowID { recorder.selectedWindowID = windowID }
        if let area { recorder.area = area }
        if let displayID { recorder.selectedDisplayID = displayID }
        if let camera { recorder.cameraID = camera }
        if let microphone { recorder.microphoneID = microphone }
        if let systemAudio = params.systemAudio { recorder.captureSystemAudio = systemAudio }

        // The camera and microphone run as they do with the recorder open.
        let cameraWasOff = controller.camera.deviceID == nil
        controller.setPreviewActive(true)
        do {
            try await waitForDevices()
            if recorder.cameraID != nil, cameraWasOff, (params.countdown ?? app.preferences.countdown) == 0 {
                // Without a countdown, give the camera a moment to deliver its first frames.
                try await Task.sleep(for: .seconds(1))
            }
            try await controller.startRecording(countdown: params.countdown)
        } catch {
            usersChoices.restore(to: recorder)
            if !app.windows.recorderPanel.isVisible { controller.setPreviewActive(false) }
            if error is CancellationError, !Task.isCancelled { throw ControlError("The recording was cancelled.") }
            throw error
        }

        Task {
            _ = await controller.waitForTake()
            usersChoices.restore(to: recorder)
        }
        if let duration = params.duration, let take = controller.takeID {
            Task { await self.stop(take: take, after: duration) }
        }
        return params.wait == true ? try await waitForRecording() : RecordResult(status: status(), recording: nil)
    }

    /// Waits (briefly) for the chosen camera and microphone to be on.
    private func waitForDevices() async throws {
        let controller = app.recording!
        let recorder = app.recorder
        for _ in 0..<100 {
            let cameraReady = recorder.cameraID == nil || controller.camera.deviceID == recorder.cameraID
            let microphoneReady = recorder.microphoneID == nil || controller.microphone.deviceID == recorder.microphoneID
            if cameraReady, microphoneReady { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Stops a take after `duration` seconds of recording (time spent paused doesn't count).
    private func stop(take: UUID, after duration: Double) async {
        let controller = app.recording!
        while controller.takeID == take, let recorded = controller.recordedTime, recorded < duration {
            try? await Task.sleep(for: .seconds(min(0.25, max(0.01, duration - recorded))))
        }
        if controller.takeID == take {
            await controller.finish(openEditor: false)
        }
    }

    private func waitForRecording() async throws -> RecordResult {
        guard app.recording.isActive else { throw ControlError("Nothing is being recorded.") }
        guard let saved = await app.recording.waitForTake() else {
            throw ControlError("The recording was discarded or couldn't be saved.")
        }
        return RecordResult(status: status(), recording: info(saved))
    }

    private func stop(_ params: StopParams) async throws -> RecordResult {
        let controller = app.recording!
        switch controller.phase {
        case .recording, .paused:
            break
        case .preparing, .countdown:
            throw ControlError("The recording hasn't started yet. Run `ownrecord discard` to cancel it.")
        case .finishing:
            throw ControlError("The recording is already being saved.")
        case .idle:
            throw ControlError("Nothing is being recorded.")
        }
        guard let saved = await controller.finish(openEditor: false) else {
            throw ControlError("The recording couldn't be saved.")
        }
        if params.open == true {
            app.windows.openEditor(for: saved.id)
        }
        return RecordResult(status: status(), recording: info(saved))
    }

    private func setPaused(_ paused: Bool) throws -> StatusInfo {
        let controller = app.recording!
        guard controller.isCapturing else { throw ControlError("Nothing is being recorded.") }
        if (controller.phase == .paused) != paused {
            controller.togglePause()
        }
        return status()
    }

    private func discard() async throws -> StatusInfo {
        let controller = app.recording!
        guard controller.isActive, controller.phase != .finishing else { throw ControlError("Nothing is being recorded.") }
        controller.discard(reopeningRecorder: false)
        while controller.isActive {
            try await Task.sleep(for: .milliseconds(50))
        }
        return status()
    }

    private func display(_ reference: String?, in displays: [DisplayOption]) throws -> DisplayOption {
        guard let reference else {
            guard let main = displays.first(where: { $0.id == CGMainDisplayID() }) ?? displays.first else {
                throw CaptureError.noDisplay
            }
            return main
        }
        return try pick(reference, from: displays, kind: "display", id: { String($0.id) }, names: { [$0.name] }, label: \.name)
    }

    /// A device ID from an ID or (part of) a name; nil for "none".
    private func device(_ reference: String, in devices: [CaptureDeviceOption], kind: String) throws -> String? {
        switch reference.lowercased() {
        case "none", "off", "no":
            return nil
        case "default" where kind == "microphone":
            if let id = CaptureDevices.defaultMicrophoneID { return id }
        default:
            break
        }
        return try pick(reference, from: devices, kind: kind, id: \.id, names: { [$0.name] }, label: \.name).id
    }

    /// The option with this ID, else the one whose name is (or else contains) `reference`.
    private func pick<Option>(_ reference: String, from options: [Option], kind: String, id: (Option) -> String,
                              names: (Option) -> [String], label: (Option) -> String) throws -> Option {
        if let exact = options.first(where: { id($0) == reference }) { return exact }
        var matches = options.filter { names($0).contains { $0.caseInsensitiveCompare(reference) == .orderedSame } }
        if matches.isEmpty {
            matches = options.filter { names($0).contains { $0.localizedCaseInsensitiveContains(reference) } }
        }
        guard let first = matches.first else {
            throw ControlError("No \(kind) matches “\(reference)”. Run `ownrecord sources` to see them.")
        }
        guard matches.count == 1 else {
            let list = matches.prefix(8).map { "\(id($0)) (\(label($0)))" }.joined(separator: ", ")
            throw ControlError("“\(reference)” matches \(matches.count) \(kind)s: \(list). Use the ID.")
        }
        return first
    }

    // MARK: Editing

    private func trim(_ params: TrimParams) throws -> EditResult {
        let recording = try find(params.recording)
        let duration = recording.duration
        var edit = recording.edit
        if params.reset == true {
            edit.trimStart = 0
            edit.trimEnd = nil
        }
        if let start = params.start {
            let time = snapped(start, in: recording)
            edit.trimStart = time < 0.05 ? 0 : time
        }
        if let end = params.end {
            let time = snapped(end, in: recording)
            edit.trimEnd = time > duration - 0.05 ? nil : time
        }
        guard edit.trimStart <= (edit.trimEnd ?? duration) - 0.5 else {
            throw ControlError("The video has to start at least half a second before it ends (the recording is \(ControlFormat.seconds(duration)) long).")
        }
        try requireVideo(edit, recording)
        let trimmed = update(recording, "Trim") { $0.edit = edit }
        let message = edit.trimStart == 0 && edit.trimEnd == nil
            ? "The video isn't trimmed."
            : "Trimmed to \(ControlFormat.span(edit.trimStart..<(edit.trimEnd ?? duration)))."
        return EditResult(message: "\(message) \(videoLength(trimmed))", recording: info(trimmed))
    }

    private func cut(_ params: RangeParams) throws -> EditResult {
        let recording = try find(params.recording)
        let range = try self.range(params, in: recording)
        var edit = recording.edit
        let removed = edit.cutPauses([range], deleting: true, duration: recording.duration)
        guard !removed.isEmpty else {
            throw ControlError("Nothing to cut: \(ControlFormat.span(range)) isn't in the video, or is shorter than 0.2 s.")
        }
        try requireVideo(edit, recording)
        let updated = update(recording, "Cut") { $0.edit = edit }
        let total = removed.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        return EditResult(message: "Cut \(ControlFormat.seconds(total)) (\(removed.map(ControlFormat.span).joined(separator: ", "))). \(videoLength(updated))",
                          recording: info(updated))
    }

    private func restore(_ params: RangeParams) throws -> EditResult {
        let recording = try find(params.recording)
        let range = try self.range(params, in: recording)
        var edit = recording.edit
        let restored = edit.restoreSections(overlapping: range, duration: recording.duration)
        guard restored > 0 else { throw ControlError("Nothing is cut between \(ControlFormat.span(range)).") }
        let updated = update(recording, "Restore") { $0.edit = edit }
        return EditResult(message: "Restored \(restored == 1 ? "1 section" : "\(restored) sections"). \(videoLength(updated))",
                          recording: info(updated))
    }

    private func silences(_ params: SilencesParams) async throws -> SilencesInfo {
        let recording = try find(params.recording)
        let files = try self.files(recording)
        guard let track = recording.silenceTrack, let trackIndex = recording.audioTracks.firstIndex(of: track) else {
            throw TranscriptionError.noAudio
        }
        let levels = try await SilenceDetector.levels(of: files.screen, trackIndex: trackIndex)
        let defaults = EditorModel.SilenceSettings()
        let threshold = params.threshold ?? levels.suggestedThreshold
        let found = levels.pauses(threshold: threshold, minimumDuration: params.minimumPause ?? defaults.minimumDuration,
                                  padding: params.padding ?? defaults.padding).map { pause in
            let start = snapped(pause.lowerBound, in: recording)
            return start..<max(start, snapped(pause.upperBound, in: recording))
        }
        // The recording may have been edited while its audio was measured.
        let latest = self.latest(recording)
        let pauses = latest.edit.pausesInVideo(found, duration: latest.duration)
        var updated = latest
        if let action = params.apply, !pauses.isEmpty {
            var edit = latest.edit
            edit.cutPauses(pauses, deleting: action == .delete, duration: latest.duration)
            try requireVideo(edit, latest)
            updated = update(latest, action == .delete ? "Remove Pauses" : "Split at Silences") { $0.edit = edit }
        }
        return SilencesInfo(track: track, threshold: threshold, suggestedThreshold: levels.suggestedThreshold,
                            pauses: pauses.map { [$0.lowerBound, $0.upperBound] },
                            total: pauses.reduce(0) { $0 + $1.upperBound - $1.lowerBound },
                            applied: pauses.isEmpty ? nil : params.apply, recording: info(updated))
    }

    private func blur(_ params: BlurParams) throws -> EditResult {
        let recording = try find(params.recording)
        let rect: CGRect
        if let values = params.rect {
            guard values.count == 4 else { throw ControlError("Give the area as x,y,width,height.") }
            rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        } else if let values = params.pixels {
            guard values.count == 4 else { throw ControlError("Give the area as x,y,width,height.") }
            let width = Double(max(1, recording.pixelWidth)), height = Double(max(1, recording.pixelHeight))
            rect = CGRect(x: values[0] / width, y: values[1] / height, width: values[2] / width, height: values[3] / height)
        } else {
            throw ControlError("Give the area with --rect (fractions of the recording) or --px (pixels).")
        }
        guard rect.minX >= 0, rect.minY >= 0, rect.width > 0, rect.height > 0, rect.maxX <= 1.0001, rect.maxY <= 1.0001 else {
            throw ControlError(params.rect != nil
                ? "--rect takes fractions of the recording (0 to 1) from its top-left corner. Use --px for pixels."
                : "The area has to be inside the recording, which is \(recording.pixelWidth) × \(recording.pixelHeight) pixels.")
        }
        let from = params.from.map { snapped($0, in: recording) }
        let to = params.to.map { snapped($0, in: recording) }
        if (to ?? recording.duration) <= (from ?? 0) { throw ControlError("The end has to be after the start.") }
        let redaction = Redaction(style: params.style ?? .blur, rect: rect)
        var edit = recording.edit
        edit.addRedaction(redaction, from: from, to: to, duration: recording.duration)
        let updated = update(recording, "Add \(redaction.style.noun)") { $0.edit = edit }
        let when = from == nil && to == nil
            ? "in the whole recording"
            : "from \(ControlFormat.span((from ?? 0)..<(to ?? recording.duration)))"
        return EditResult(message: "\(redaction.style == .blur ? "Blurred" : "Pixelated") the area \(when) (ID \(ControlFormat.shortID(redaction.id))).",
                          recording: info(updated), ids: [redaction.id])
    }

    private func unblur(_ params: UnblurParams) throws -> EditResult {
        let recording = try find(params.recording)
        var edit = recording.edit
        var removing = Set(edit.sections.flatMap { $0.redactions.map(\.id) })
        guard !removing.isEmpty else { throw ControlError("“\(recording.title)” has no blurred areas.") }
        if let id = params.id {
            removing = removing.filter { $0.uuidString.lowercased().hasPrefix(id.lowercased()) }
            guard !removing.isEmpty else { throw ControlError("No blurred area has the ID “\(id)”. `ownrecord show` lists them.") }
            guard removing.count == 1 else { throw ControlError("“\(id)” matches \(removing.count) blurred areas. Use more of the ID.") }
        }
        for index in edit.sections.indices {
            edit.sections[index].redactions.removeAll { removing.contains($0.id) }
        }
        let updated = update(recording, "Delete Blur") { $0.edit = edit }
        return EditResult(message: removing.count == 1 ? "Removed the blurred area." : "Removed \(removing.count) blurred areas.",
                          recording: info(updated))
    }

    private func changeSettings(_ params: SetParams) throws -> EditResult {
        guard !params.values.isEmpty else { throw ControlError("Give settings as key=value, e.g. layout.aspect=portrait.") }
        let recording = try find(params.recording)
        let edit = try recording.edit.setting(params.values)
        let updated = update(recording, "Change Settings") { $0.edit = edit }
        let changes = params.values.keys.sorted().map { "\($0) = \(params.values[$0]!)" }.joined(separator: ", ")
        return EditResult(message: "Set \(changes).", recording: info(updated))
    }

    // MARK: Subtitles

    private func transcribe(_ params: TranscribeParams, progress: @escaping @Sendable (Double) -> Void) async throws -> EditResult {
        let recording = try find(params.recording)
        let files = try self.files(recording)
        guard recording.hasAudio else { throw TranscriptionError.noAudio }
        var locale = recording.transcript?.localeIdentifier
            ?? TranscriptionEngine.bestLocaleIdentifier(for: app.preferences.transcriptionLocale)
        if let requested = params.locale {
            let language = Locale(identifier: requested).language.languageCode
            guard TranscriptionEngine.supportedLocales.contains(where: { Locale(identifier: $0.id).language.languageCode == language })
            else { throw TranscriptionError.unsupportedLanguage }
            locale = TranscriptionEngine.bestLocaleIdentifier(for: requested)
        }
        guard await app.permissions.request(.speech) else { throw TranscriptionError.notAuthorized }
        let transcript = try await TranscriptionEngine.transcript(for: recording, files: files, localeIdentifier: locale,
                                                                  progress: progress)
        // Keeps edits made while transcribing.
        let updated = update(latest(recording), "Generate Subtitles") {
            $0.transcript = transcript
            $0.edit.subtitles.isEnabled = true
        }
        return EditResult(message: "Generated \(transcript.cues.count) subtitles from \(transcript.words.count) words (\(locale)).",
                          recording: info(updated))
    }

    private func transcript(_ params: TranscriptParams) throws -> TranscriptInfo {
        let recording = try find(params.recording)
        guard let transcript = recording.transcript else {
            throw ControlError("“\(recording.title)” has no transcript yet. Run `ownrecord transcribe \(ControlFormat.shortID(recording.id))`.")
        }
        let timeline = recording.editedTimeline
        let cues = transcript.cues.map { cue in
            let played = timeline.outputRanges(forSource: cue.start..<max(cue.start, cue.end))
            return TranscriptInfo.Cue(start: cue.start, end: cue.end, videoStart: played.first?.lowerBound,
                                      videoEnd: played.last?.upperBound, text: cue.text)
        }
        return TranscriptInfo(locale: transcript.localeIdentifier, cues: cues, words: transcript.words,
                              file: params.format.flatMap { SubtitleExporter.file(for: recording, format: $0) })
    }

    // MARK: Output

    private func frame(_ params: FrameParams) async throws -> FilesResult {
        let recording = try find(params.recording)
        let files = try self.files(recording)
        let longSide = CGFloat(min(max(params.size ?? 1920, 64), 8192))
        let image: CGImage
        let time: Double
        var videoTime: Double?
        if params.raw == true {
            let timeline = recording.editedTimeline
            let requested = params.time ?? 0
            time = params.videoTime == true ? timeline.sourceTime(forOutput: requested) : requested
            guard time >= 0, time < recording.duration else {
                throw ControlError("The recording is \(ControlFormat.seconds(recording.duration)) long.")
            }
            if timeline.contains(source: time) { videoTime = timeline.outputTime(forSource: time) }
            let size = recording.pixelSize.scaled(min(1, longSide / max(recording.pixelSize.width, recording.pixelSize.height, 1)))
            image = try await Self.image(from: AVURLAsset(url: files.screen), at: time, maxSize: size, videoComposition: nil)
        } else {
            let ranges = recording.edit.keptRanges(duration: .infinity, applyingTrim: true)
            let built = try await CompositionBuilder.build(recording: recording, files: files, ranges: ranges)
            var output = 0.0
            if params.videoTime == true {
                output = params.time ?? 0
                guard output >= 0, output < built.duration else {
                    throw ControlError("The video is \(ControlFormat.seconds(built.duration)) long.")
                }
            } else if let requested = params.time {
                guard built.timeline.contains(source: requested) else {
                    let reason = requested < 0 || requested >= recording.duration ? "isn't in the recording" : "is trimmed or cut from the video"
                    throw ControlError("\(ControlFormat.seconds(requested)) \(reason). Add --raw to see the recording as captured.")
                }
                output = built.timeline.outputTime(forSource: requested)
            }
            // The very end has no frame of its own.
            output = min(output, max(0, built.duration - 1 / Double(max(1, recording.frameRate))))
            time = built.timeline.sourceTime(forOutput: output)
            videoTime = output
            let canvas = LayoutEngine.canvasSize(source: built.sourceSize, aspect: recording.edit.layout.aspect)
            let size = canvas.scaled(min(1, longSide / max(canvas.width, canvas.height))).evenRounded()
            let composition = CompositionBuilder.videoComposition(for: built, recording: recording, renderSize: size,
                                                                  highQuality: true)
            image = try await Self.image(from: built.composition, at: output, maxSize: size, videoComposition: composition)
        }
        let folder = try makeStagingFolder()
        let url = folder.appendingPathComponent(params.jpeg == true ? "frame.jpg" : "frame.png")
        guard Self.write(image, to: url, jpeg: params.jpeg == true) else {
            try? FileManager.default.removeItem(at: folder)
            throw ControlError("Couldn't save the frame.")
        }
        return FilesResult(files: [url.path], name: EditorModel.fileName(for: recording.title), width: image.width,
                           height: image.height, time: time, videoTime: videoTime)
    }

    private func export(_ params: ExportParams, progress: @escaping @Sendable (Double) -> Void) async throws -> FilesResult {
        var recording = try find(params.recording)
        let files = try self.files(recording)
        if let burn = params.burnSubtitles {
            recording.edit.subtitles.isEnabled = burn
        }
        var options = ExportOptions()
        options.format = params.format
        if let codec = params.codec { options.codec = codec }
        if let resolution = params.resolution { options.resolution = resolution }
        if let clips = params.clips { options.iMovieClips = clips }
        if let width = params.gifWidth { options.gifWidth = width }
        if let rate = params.gifFrameRate { options.gifFrameRate = rate }

        let folder = try makeStagingFolder()
        let name = EditorModel.fileName(for: recording.title)
        do {
            if options.format == .imovie {
                let clips = try await IMovieExporter.export(recording: recording, files: files, options: options, to: folder,
                                                            progress: progress)
                return FilesResult(files: clips.map(\.url.path), name: name, duration: recording.editedDuration)
            }
            let url = folder.appendingPathComponent("\(name).\(options.format.fileExtension)")
            try await VideoExporter.export(recording: recording, files: files, options: options, to: url, progress: progress)
            var paths = [url.path]
            if params.subtitleFile == true, options.format != .gif, let subtitles = SubtitleExporter.file(for: recording, format: .srt) {
                let subtitleURL = url.deletingPathExtension().appendingPathExtension("srt")
                try subtitles.write(to: subtitleURL, atomically: true, encoding: .utf8)
                paths.append(subtitleURL.path)
            }
            let canvas = LayoutEngine.canvasSize(source: recording.pixelSize, aspect: recording.edit.layout.aspect)
            let size = VideoExporter.renderSize(canvas: canvas, ratio: recording.edit.layout.aspect.ratio, options: options)
            return FilesResult(files: paths, name: name, width: Int(size.width), height: Int(size.height),
                               duration: recording.editedDuration)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func image(from asset: AVAsset, at seconds: Double, maxSize: CGSize,
                              videoComposition: AVVideoComposition?) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: seconds.cmTime).image
    }

    private static func write(_ image: CGImage, to url: URL, jpeg: Bool) -> Bool {
        let type = jpeg ? UTType.jpeg : UTType.png
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary : nil)
        return CGImageDestinationFinalize(destination)
    }

    private func makeStagingFolder() throws -> URL {
        let folder = ControlChannel.stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: Helpers

    /// A recording by ID (or its start), title, folder or "latest"; the editor's copy if it's open.
    private func find(_ reference: String) throws -> Recording {
        let recordings = app.library.recordings
        let text = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        var matches: [Recording] = []
        if ["latest", "last"].contains(text.lowercased()) {
            matches = Array(recordings.prefix(1))
        } else if !text.isEmpty {
            matches = recordings.filter { $0.id.uuidString.lowercased().hasPrefix(text.lowercased()) }
            if matches.isEmpty {
                matches = recordings.filter { $0.title.caseInsensitiveCompare(text) == .orderedSame }
            }
            if matches.isEmpty {
                let path = URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL.path
                matches = recordings.filter { app.library.files(for: $0.id)?.folder.standardizedFileURL.path == path }
            }
        }
        guard let match = matches.first else {
            throw ControlError("No recording matches “\(reference)”. Run `ownrecord list` to see them.")
        }
        guard matches.count == 1 else {
            let ids = matches.prefix(5).map { ControlFormat.shortID($0.id) }.joined(separator: ", ")
            throw ControlError("“\(reference)” matches \(matches.count) recordings (\(ids)). Use more of the ID.")
        }
        return current(match)
    }

    /// The editor's copy of a recording if it's open (it can have changes not saved yet).
    private func current(_ recording: Recording) -> Recording {
        app.windows.editorModel(for: recording.id)?.recording ?? recording
    }

    /// The recording as it is now, after anything that happened while waiting.
    private func latest(_ recording: Recording) -> Recording {
        current(app.library.recording(with: recording.id) ?? recording)
    }

    private func files(_ recording: Recording) throws -> RecordingFiles {
        guard let files = app.library.files(for: recording.id) else {
            throw ControlError("The files of “\(recording.title)” are missing.")
        }
        return files
    }

    /// Saves a change: through the recording's editor if it's open, so it can be undone there.
    @discardableResult
    private func update(_ recording: Recording, _ actionName: String, _ change: (inout Recording) -> Void) -> Recording {
        var updated = recording
        change(&updated)
        if let editor = app.windows.editorModel(for: recording.id) {
            editor.applyEdit(updated, actionName: actionName)
        } else {
            app.library.save(updated)
        }
        return updated
    }

    private func requireVideo(_ edit: EditSettings, _ recording: Recording) throws {
        guard !edit.keptRanges(duration: recording.duration, applyingTrim: true).isEmpty else {
            throw ControlError("That would leave nothing in the video.")
        }
    }

    private func range(_ params: RangeParams, in recording: Recording) throws -> Range<Double> {
        let from = snapped(params.from, in: recording)
        let to = snapped(params.to, in: recording)
        guard to > from else {
            throw ControlError("The end has to be after the start (the recording is \(ControlFormat.seconds(recording.duration)) long).")
        }
        return from..<to
    }

    /// On a frame boundary, within the recording.
    private func snapped(_ time: Double, in recording: Recording) -> Double {
        let rate = Double(max(1, recording.frameRate))
        return ((time * rate).rounded() / rate).clamped(to: 0...max(0, recording.duration))
    }

    private func videoLength(_ recording: Recording) -> String {
        "The video is now \(ControlFormat.seconds(recording.editedDuration)) long."
    }

    private func info(_ recording: Recording) -> RecordingInfo {
        RecordingInfo(id: recording.id, title: recording.title, createdAt: recording.createdAt, duration: recording.duration,
                      videoDuration: recording.editedDuration, captureMode: recording.captureMode, source: recording.sourceName,
                      width: recording.pixelWidth, height: recording.pixelHeight, frameRate: recording.frameRate,
                      hasCamera: recording.hasCamera, audioTracks: recording.audioTracks,
                      hasTranscript: recording.transcript != nil, folder: app.library.files(for: recording.id)?.folder.path)
    }
}

/// What's chosen in the recorder: source, camera, microphone and system audio.
@MainActor
private struct RecorderChoices {
    let mode: CaptureMode
    let displayID: CGDirectDisplayID?
    let windowID: CGWindowID?
    let area: AreaSelection?
    let cameraID: String?
    let microphoneID: String?
    let systemAudio: Bool

    init(_ recorder: RecorderModel) {
        mode = recorder.mode
        displayID = recorder.selectedDisplayID
        windowID = recorder.selectedWindowID
        area = recorder.area
        cameraID = recorder.cameraID
        microphoneID = recorder.microphoneID
        systemAudio = recorder.captureSystemAudio
    }

    func restore(to recorder: RecorderModel) {
        recorder.mode = mode
        recorder.selectedDisplayID = displayID
        recorder.selectedWindowID = windowID
        recorder.area = area
        recorder.cameraID = cameraID
        recorder.microphoneID = microphoneID
        recorder.captureSystemAudio = systemAudio
    }
}

private extension PermissionKind {
    var controlName: String {
        switch self {
        case .screen: "screenRecording"
        case .camera: "camera"
        case .microphone: "microphone"
        case .speech: "speechRecognition"
        }
    }
}

// MARK: - Edits

extension EditSettings {
    /// The groups `ownrecord set` changes. Sections and the trim have commands of their own.
    static let settableGroups = ["layout", "camera", "subtitles", "audio"]

    /// A copy with settings changed by path, e.g. "layout.aspect" to "portrait". Values are JSON
    /// (numbers, true or false, objects), or else text.
    func setting(_ values: [String: String]) throws -> EditSettings {
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] else {
            throw ControlError("Couldn't read the settings.")
        }
        for (path, text) in values.sorted(by: { $0.key < $1.key }) {
            let keys = path.split(separator: ".").map(String.init)
            guard keys.count >= 2, Self.settableGroups.contains(keys[0]) else {
                throw ControlError("There's no setting “\(path)”. Settings start with \(Self.settableGroups.map { $0 + "." }.joined(separator: ", ")) See `ownrecord help set`.")
            }
            let value = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) ?? text
            object = try Self.setting(value, at: keys[...], in: object, path: path)
        }
        do {
            return try JSONDecoder().decode(EditSettings.self, from: JSONSerialization.data(withJSONObject: object))
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context),
                let DecodingError.dataCorrupted(context) {
            let key = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw ControlError("That isn't a valid value for \(key.isEmpty ? "this setting" : key). See `ownrecord help set`.")
        }
    }

    private static func setting(_ value: Any, at keys: ArraySlice<String>, in object: [String: Any],
                                path: String) throws -> [String: Any] {
        guard let key = keys.first, let current = object[key] else {
            throw ControlError("There's no setting “\(path)”. See `ownrecord help set`.")
        }
        var object = object
        if keys.count == 1 {
            object[key] = value
        } else {
            guard let nested = current as? [String: Any] else {
                throw ControlError("There's no setting “\(path)”. See `ownrecord help set`.")
            }
            object[key] = try setting(value, at: keys.dropFirst(), in: nested, path: path)
        }
        return object
    }

    /// Brings back the deleted sections that overlap `range` (recording time). Returns how many.
    mutating func restoreSections(overlapping range: Range<Double>, duration: Double) -> Int {
        var count = 0
        for index in sections.indices where sections[index].isDeleted {
            if self.range(ofSectionAt: index, duration: duration).overlaps(range) {
                sections[index].isDeleted = false
                count += 1
            }
        }
        return count
    }

    /// Adds an area to blur to the sections between `from` and `to` (recording time), splitting
    /// there first, or to every section. Returns the sections' indices.
    @discardableResult
    mutating func addRedaction(_ redaction: Redaction, from: Double?, to: Double?, duration: Double) -> [Int] {
        let range = (from ?? 0)..<(to ?? duration)
        if from != nil || to != nil {
            split(at: range.lowerBound, duration: duration)
            split(at: range.upperBound, duration: duration)
        }
        let indices = sections.indices.filter { self.range(ofSectionAt: $0, duration: duration).overlaps(range) }
        for index in indices {
            sections[index].redactions.append(redaction)
        }
        return indices
    }
}
