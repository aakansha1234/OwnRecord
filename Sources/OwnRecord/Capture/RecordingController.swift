import AppKit
@preconcurrency import AVFoundation
import Observation
@preconcurrency import ScreenCaptureKit

/// Orchestrates a recording: devices, capture, countdown, pause/resume, and finalizing files.
@MainActor @Observable
final class RecordingController {
    enum Phase: Equatable {
        case idle
        case preparing
        case countdown(Int)
        case recording
        case paused
        case finishing
    }

    private(set) var phase: Phase = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var microphoneLevel: Float = 0

    var isActive: Bool { phase != .idle }
    var isCapturing: Bool { phase == .recording || phase == .paused }

    /// Identifies the take in progress (nil once it's being saved).
    var takeID: UUID? { session?.id }

    /// Seconds recorded in the take so far, not counting pauses.
    var recordedTime: TimeInterval? {
        guard isCapturing, let clock = session?.clock else { return nil }
        return clock.elapsed(at: RecordingClock.now())
    }

    @ObservationIgnored let camera = CameraCapture()
    @ObservationIgnored let microphone: MicrophoneCapture
    @ObservationIgnored private let sampleQueue = DispatchQueue(label: "com.ownrecord.samples", qos: .userInitiated)
    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var session: ActiveSession?
    @ObservationIgnored private var startTask: Task<Error?, Never>?
    @ObservationIgnored private var skipCountdown = false
    @ObservationIgnored private var interruption: Error?
    @ObservationIgnored private var previewActive = false
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var levelTimer: Timer?
    @ObservationIgnored private var takeWaiters: [CheckedContinuation<Recording?, Never>] = []

    @ObservationIgnored private(set) lazy var bubble = CameraBubbleController(camera: camera, preferences: app.preferences)
    @ObservationIgnored private lazy var controlBar = ControlBarController(controller: self)
    @ObservationIgnored private lazy var countdownOverlay = CountdownController(controller: self)
    @ObservationIgnored private lazy var areaFrame = AreaFrameIndicator()

    private struct ActiveSession {
        let id: UUID
        let folder: URL
        let target: CaptureTarget
        let clock: RecordingClock
        let screen: ScreenCaptureSession
        let writer: MovieWriter
        let audioTracks: [AudioTrackKind]
        let recordsCamera: Bool
        let frameRate: Int
        let cameraStyle: CameraOverlayStyle
    }

    init(app: AppModel) {
        self.app = app
        microphone = MicrophoneCapture(sampleQueue: sampleQueue)
    }

    // MARK: Device preview

    /// Runs the camera bubble and microphone meter while the recorder panel is open.
    func setPreviewActive(_ active: Bool) {
        previewActive = active
        updateDevices()
    }

    func updateDevices() {
        let wanted = previewActive || isActive
        let recorder = app.recorder

        if wanted, let cameraID = recorder.cameraID {
            Task {
                guard await app.permissions.request(.camera) else {
                    recorder.cameraID = nil
                    return
                }
                guard previewActive || isActive, recorder.cameraID == cameraID else { return }
                camera.use(deviceID: cameraID)
                bubble.show()
            }
        } else if !isActive {
            camera.stop()
            bubble.hide()
        }

        if wanted, let microphoneID = recorder.microphoneID {
            Task {
                guard await app.permissions.request(.microphone) else {
                    recorder.microphoneID = nil
                    return
                }
                guard previewActive || isActive, recorder.microphoneID == microphoneID else { return }
                microphone.use(deviceID: microphoneID)
                startLevelTimer()
            }
        } else if !isActive {
            microphone.stop()
            stopLevelTimer()
        }
    }

    // MARK: Controls

    func start() {
        guard phase == .idle else { return }
        phase = .preparing
        skipCountdown = false
        startTask = Task { await performStart(interactive: true) }
    }

    /// Starts recording for the command line tool and returns once it's recording (after the
    /// countdown). Unlike `start()`, a failure is thrown rather than shown, and the recorder
    /// doesn't reopen.
    /// - Parameter countdown: Seconds; nil uses the countdown from Settings.
    func startRecording(countdown: Int? = nil) async throws {
        guard phase == .idle else { throw ControlError("OwnRecord is already recording.") }
        phase = .preparing
        skipCountdown = false
        let task = Task { await performStart(interactive: false, countdown: countdown) }
        startTask = task
        if let error = await task.value { throw error }
    }

    /// Waits for the take in progress to end. Returns the saved recording, or nil if it was
    /// discarded or couldn't be saved.
    func waitForTake() async -> Recording? {
        guard isActive else { return nil }
        return await withCheckedContinuation { takeWaiters.append($0) }
    }

    func stop() {
        guard let session = takeSession() else { return }
        Task { await complete(session, openEditor: true) }
    }

    func togglePause() {
        guard let session else { return }
        let now = RecordingClock.now()
        switch phase {
        case .recording:
            session.clock.pause(at: now)
            phase = .paused
        case .paused:
            session.clock.resume(at: now)
            let screen = session.screen
            let clock = session.clock
            // The screen may have changed while paused but won't emit a new frame until it
            // changes again, so re-append the latest frame at the resume point.
            sampleQueue.async {
                if let time = clock.outputTime(for: now) { screen.writeHeldFrame(at: time) }
            }
            phase = .recording
        default:
            break
        }
    }

    /// Throws away the current recording (or cancels the countdown).
    /// - Parameter reopeningRecorder: Show the recorder again, to record another take.
    func discard(reopeningRecorder: Bool = true) {
        switch phase {
        case .preparing, .countdown:
            startTask?.cancel()
        case .recording, .paused:
            guard let session = takeSession() else { return }
            Task {
                await dispose(session)
                phase = .idle
                takeEnded(nil)
                if reopeningRecorder {
                    app.showRecorder()
                } else {
                    updateDevices()
                }
            }
        default:
            break
        }
    }

    func restart() {
        guard let session = takeSession() else { return }
        Task {
            await dispose(session)
            phase = .idle
            takeEnded(nil)
            start()
        }
    }

    /// Finishes or cancels whatever is in progress so the app can quit without losing a take.
    func prepareForTermination() async {
        switch phase {
        case .recording, .paused:
            await finish(openEditor: false)
        case .preparing, .countdown:
            startTask?.cancel()
            _ = await startTask?.value
        default:
            break
        }
        let deadline = Date().addingTimeInterval(15)
        while phase != .idle, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func skipCountdownNow() {
        skipCountdown = true
    }

    // MARK: Start

    /// Returns why the recording didn't start, if it didn't.
    /// - Parameter interactive: Show errors and reopen the recorder when the recording can't start.
    private func performStart(interactive: Bool, countdown: Int? = nil) async -> Error? {
        let preferences = app.preferences
        let countdown = countdown ?? preferences.countdown
        let recorder = app.recorder
        do {
            guard await app.permissions.request(.screen) else { throw CaptureError.permissionDenied }
            let content: SCShareableContent
            do {
                content = try await ShareableContent.load(onScreenOnly: false)
            } catch {
                throw CaptureError.permissionDenied
            }
            let target = try CaptureTarget.resolve(mode: recorder.mode, displayID: recorder.selectedDisplayID,
                                                   windowID: recorder.selectedWindowID, area: recorder.area,
                                                   content: content, hideDesktopIcons: preferences.hideDesktopIcons)
            try Task.checkCancellation()

            let folder = try app.library.makeRecordingFolder()
            let files = RecordingFiles(folder: folder)
            let clock = RecordingClock()
            let usesMicrophone = recorder.microphoneID != nil && microphone.deviceID != nil
            var audioTracks: [AudioTrackKind] = []
            if recorder.captureSystemAudio { audioTracks.append(.system) }
            if usesMicrophone { audioTracks.append(.microphone) }

            let frameRate = preferences.frameRate
            let writer = try MovieWriter(url: files.screen,
                                         video: .screen(size: target.pixelSize, frameRate: frameRate, quality: preferences.videoQuality),
                                         audioTracks: audioTracks)
            let screen = ScreenCaptureSession(queue: sampleQueue, clock: clock, writer: writer)
            screen.onUnexpectedStop = { [weak self] _ in
                Task { @MainActor in self?.captureStoppedBySystem() }
            }
            let configuration = target.streamConfiguration(frameRate: frameRate, showsCursor: preferences.showCursor,
                                                           highlightClicks: preferences.highlightClicks,
                                                           systemAudio: recorder.captureSystemAudio)
            do {
                try await screen.start(filter: target.filter, configuration: configuration)
            } catch {
                writer.cancel()
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
            if usesMicrophone { microphone.attach(writer: writer, clock: clock) }
            let recordsCamera = recorder.cameraID != nil && camera.isActive
            if recordsCamera { camera.beginRecording(to: files.camera, clock: clock) }

            session = ActiveSession(id: UUID(), folder: folder, target: target, clock: clock, screen: screen,
                                    writer: writer, audioTracks: audioTracks, recordsCamera: recordsCamera,
                                    frameRate: frameRate,
                                    cameraStyle: bubble.overlayStyle(relativeTo: target.frame, base: preferences.cameraStyle))

            app.windows.recorderPanel.hide()
            previewActive = false // Devices now stay alive because a recording is active.
            if let pid = target.windowProcessID {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
            if target.mode == .area { areaFrame.show(around: target.frame) }
            controlBar.show(on: target.screen ?? NSScreen.main)

            for remaining in stride(from: countdown, through: 1, by: -1) where !skipCountdown {
                phase = .countdown(remaining)
                countdownOverlay.show(remaining, on: target.screen ?? NSScreen.main)
                for _ in 0..<10 where !skipCountdown {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            countdownOverlay.hide()
            try Task.checkCancellation()

            let startTime = RecordingClock.now()
            sampleQueue.sync {
                clock.begin(at: startTime)
                writer.start(at: startTime)
                screen.writeHeldFrame(at: startTime)
            }
            phase = .recording
            startTicker()
            startTask = nil
            return nil
        } catch {
            await abandonStart()
            startTask = nil
            var failure = error
            if error is CancellationError, let interruption {
                self.interruption = nil
                failure = interruption
            }
            if interactive {
                if !(failure is CancellationError) { presentError(failure, title: "Recording couldn't start") }
                app.showRecorder()
            }
            return failure
        }
    }

    private func abandonStart() async {
        countdownOverlay.hide()
        if let session {
            self.session = nil
            await dispose(session)
        } else {
            hideRecordingUI()
        }
        phase = .idle
        takeEnded(nil)
    }

    // MARK: Stop

    /// Stops and saves the take. Returns the saved recording.
    @discardableResult
    func finish(openEditor: Bool) async -> Recording? {
        guard let session = takeSession() else { return nil }
        return await complete(session, openEditor: openEditor)
    }

    /// Detaches the active session and moves to `.finishing` before any suspension point, so
    /// stop, discard and restart can never act on the same session twice.
    private func takeSession() -> ActiveSession? {
        guard let session, isCapturing else { return nil }
        self.session = nil
        phase = .finishing
        stopTicker()
        return session
    }

    @discardableResult
    private func complete(_ session: ActiveSession, openEditor: Bool) async -> Recording? {
        let endHost = RecordingClock.now()
        let endTime = session.clock.endTime(at: endHost) ?? endHost
        let startTime = session.clock.startTime ?? endTime

        await session.screen.stop()
        let writer = session.writer
        let microphone = self.microphone
        sampleQueue.sync {
            session.clock.end()
            microphone.detachOnQueue()
            writer.prepareToFinish(at: endTime)
        }

        var saved = false
        do {
            saved = try await writer.finishWriting()
        } catch {
            presentError(error, title: "Recording couldn't be saved")
        }
        let hasCamera = session.recordsCamera ? await camera.finishRecording(at: endTime) : false

        hideRecordingUI()
        phase = .idle
        elapsed = 0
        updateDevices()

        guard saved else {
            try? FileManager.default.removeItem(at: session.folder)
            app.windows.restoreHomeAfterRecording()
            takeEnded(nil)
            return nil
        }

        let files = RecordingFiles(folder: session.folder)
        // Tracks that never received samples aren't written, so read what's actually in the file.
        let audioTracks = await MovieWriter.audioTrackKinds(in: files.screen) ?? session.audioTracks
        var edit = EditSettings()
        edit.camera = session.cameraStyle
        let recording = Recording(id: UUID(), title: Self.defaultTitle(), createdAt: Date(),
                                  duration: max(0, (endTime - startTime).seconds), captureMode: session.target.mode,
                                  sourceName: session.target.name, pixelWidth: Int(session.target.pixelSize.width),
                                  pixelHeight: Int(session.target.pixelSize.height), frameRate: session.frameRate,
                                  hasCamera: hasCamera, audioTracks: audioTracks, edit: edit, transcript: nil)
        if let image = await Thumbnailer.image(from: AVURLAsset(url: files.screen), at: min(1, recording.duration / 2),
                                               maxSize: CGSize(width: 640, height: 640)) {
            Thumbnailer.writeJPEG(image, to: files.thumbnail)
        }
        app.library.save(recording, in: session.folder)

        if openEditor, app.preferences.openEditorAfterRecording {
            app.windows.openEditor(for: recording.id,
                                   autoTranscribe: app.preferences.autoTranscribe && recording.hasAudio)
        } else {
            app.windows.restoreHomeAfterRecording()
        }
        takeEnded(recording)
        return recording
    }

    private func takeEnded(_ recording: Recording?) {
        let waiters = takeWaiters
        takeWaiters = []
        for waiter in waiters {
            waiter.resume(returning: recording)
        }
    }

    // MARK: Teardown

    /// Stops capture and deletes everything recorded in `session`.
    private func dispose(_ session: ActiveSession) async {
        stopTicker()
        countdownOverlay.hide()
        session.clock.end()
        await session.screen.stop()
        let microphone = self.microphone
        sampleQueue.sync {
            microphone.detachOnQueue()
            session.writer.cancel()
        }
        camera.cancelRecording()
        try? FileManager.default.removeItem(at: session.folder)
        hideRecordingUI()
        elapsed = 0
    }

    private func captureStoppedBySystem() {
        switch phase {
        case .recording, .paused:
            Task { await finish(openEditor: true) }
        case .preparing, .countdown:
            interruption = CaptureError.interrupted
            startTask?.cancel()
        default:
            break
        }
    }

    private func hideRecordingUI() {
        controlBar.hide()
        countdownOverlay.hide()
        areaFrame.hide()
    }

    // MARK: Timers

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let clock = self.session?.clock else { return }
                self.elapsed = clock.elapsed(at: RecordingClock.now())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func startLevelTimer() {
        guard levelTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let level = self.microphone.level
                if abs(level - self.microphoneLevel) > 0.01 { self.microphoneLevel = level }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        microphoneLevel = 0
    }

    // MARK: Helpers

    private static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Recording \(formatter.string(from: Date()))"
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if case CaptureError.permissionDenied = error {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn {
                app.permissions.openSystemSettings(for: .screen)
            }
        } else {
            NSApp.activate()
            alert.runModal()
        }
    }
}
