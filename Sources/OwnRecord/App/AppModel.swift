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
    private(set) var recording: RecordingController!

    private init() {
        recorder = RecorderModel(preferences: preferences)
        recording = RecordingController(app: self)
        recorder.onDevicesChanged = { [weak self] in self?.recording.updateDevices() }
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
