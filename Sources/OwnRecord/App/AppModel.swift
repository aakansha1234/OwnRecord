import AppKit

/// Composition root: owns the app's long-lived models and coordinates top-level flows.
@MainActor
final class AppModel {
    static let shared = AppModel()

    let preferences = Preferences.shared
    let permissions = Permissions()
    let library = RecordingLibrary()
    let recorder: RecorderModel
    let windows = WindowCoordinator()
    let teleprompter: Teleprompter
    private(set) var recording: RecordingController!
    private(set) var control: ControlServer!
    private var controlService: ControlService!

    private init() {
        recorder = RecorderModel(preferences: preferences)
        teleprompter = Teleprompter(preferences: preferences)
        recording = RecordingController(app: self)
        recorder.onDevicesChanged = { [weak self] in self?.recording.updateDevices() }
        teleprompter.follow(recording)
        let service = ControlService(app: self)
        controlService = service
        control = ControlServer { command, request, progress in
            try await service.handle(command, request, progress: progress)
        }
    }

    /// Listens for the `ownrecord` command line tool while the user allows it in Settings.
    func startControlServer() {
        controlService.removeOldStagedFiles()
        observeContinuously({ [weak self] in _ = self?.preferences.allowsCommandLineControl },
                            onChange: { [weak self] in self?.updateControlServer() })
        updateControlServer()
    }

    private func updateControlServer() {
        guard preferences.allowsCommandLineControl else {
            control.stop()
            return
        }
        do {
            try control.start()
        } catch {
            NSLog("OwnRecord: couldn't listen for the command line tool: \(error)")
        }
    }

    /// Opens the recorder panel (source, camera and mic selection).
    func showRecorder() {
        guard !recording.isActive else { return }
        windows.hideHomeForRecording()
        recorder.refreshDevices()
        windows.recorderPanel.show()
        recording.setPreviewActive(true)
        Task { await recorder.refreshSources() }
    }

    func closeRecorder() {
        windows.recorderPanel.hide()
        recording.setPreviewActive(false)
        windows.restoreHomeAfterRecording()
    }

    /// Global shortcut: open the recorder, start from it, or stop the current recording.
    func handleRecordShortcut() {
        switch recording.phase {
        case .idle:
            if windows.recorderPanel.isVisible, recorder.canStart {
                recording.start()
            } else {
                showRecorder()
            }
        case .recording, .paused:
            recording.stop()
        case .preparing, .countdown:
            recording.skipCountdownNow()
        case .finishing:
            break
        }
    }

    func selectArea(thenStart: Bool = false) {
        windows.recorderPanel.hide()
        Task {
            let outcome = await AreaSelectionController().select(initial: recorder.area)
            switch outcome {
            case .confirmed(let area, let startRecording):
                recorder.mode = .area
                recorder.area = area
                if startRecording || thenStart {
                    recording.start()
                } else {
                    windows.recorderPanel.show()
                }
            case .cancelled:
                windows.recorderPanel.show()
            }
        }
    }
}
