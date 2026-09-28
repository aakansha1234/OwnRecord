import AppKit
@preconcurrency import AVFoundation
import Observation
@preconcurrency import ScreenCaptureKit

/// What the user has chosen in the recorder panel: source, camera, microphone, audio.
@MainActor @Observable
final class RecorderModel {
    var mode: CaptureMode {
        didSet {
            preferences.captureMode = mode
            if mode == .window { Task { await refreshSources() } }
        }
    }

    private(set) var displays: [DisplayOption] = []
    private(set) var windows: [WindowOption] = []
    private(set) var windowThumbnails: [CGWindowID: NSImage] = [:]
    var selectedDisplayID: CGDirectDisplayID?
    var selectedWindowID: CGWindowID?
    var area: AreaSelection? {
        didSet { preferences.lastArea = area }
    }

    private(set) var cameras: [CaptureDeviceOption] = []
    private(set) var microphones: [CaptureDeviceOption] = []
    var cameraID: String? {
        didSet {
            guard cameraID != oldValue else { return }
            preferences.cameraID = cameraID
            onDevicesChanged?()
        }
    }
    var microphoneID: String? {
        didSet {
            guard microphoneID != oldValue else { return }
            preferences.microphoneID = microphoneID
            onDevicesChanged?()
        }
    }
    var captureSystemAudio: Bool {
        didSet { preferences.captureSystemAudio = captureSystemAudio }
    }

    private(set) var isLoadingSources = false
    private(set) var sourceError: String?

    @ObservationIgnored var onDevicesChanged: (() -> Void)?
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var scWindows: [CGWindowID: SCWindow] = [:]
    @ObservationIgnored private var deviceObservers: [NSObjectProtocol] = []

    init(preferences: Preferences) {
        self.preferences = preferences
        mode = preferences.captureMode
        cameraID = preferences.cameraID
        microphoneID = preferences.microphoneID
        captureSystemAudio = preferences.captureSystemAudio
        area = preferences.lastArea
        refreshDevices()

        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            })
        }
    }

    var selectedWindow: WindowOption? {
        windows.first { $0.id == selectedWindowID }
    }

    var selectedDisplay: DisplayOption? {
        displays.first { $0.id == selectedDisplayID } ?? displays.first
    }

    var canStart: Bool {
        switch mode {
        case .display: true
        case .window: selectedWindowID != nil
        case .area: area != nil
        }
    }

    func refreshDevices() {
        cameras = CaptureDevices.cameras()
        microphones = CaptureDevices.microphones()
        if let id = cameraID, !cameras.contains(where: { $0.id == id }) {
            cameraID = nil
        }
        if let id = microphoneID, !microphones.contains(where: { $0.id == id }) {
            microphoneID = CaptureDevices.defaultMicrophoneID
        }
    }

    func refreshSources() async {
        isLoadingSources = true
        defer { isLoadingSources = false }
        do {
            let content = try await ShareableContent.load()
            displays = ShareableContent.displays(from: content)
            windows = ShareableContent.windows(from: content)
            scWindows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
            if selectedDisplayID == nil || !displays.contains(where: { $0.id == selectedDisplayID }) {
                selectedDisplayID = NSScreen.main?.displayID ?? displays.first?.id
            }
            if let id = selectedWindowID, !windows.contains(where: { $0.id == id }) {
                selectedWindowID = nil
            }
            sourceError = nil
            if mode == .window { await loadThumbnails() }
        } catch {
            sourceError = CaptureError.permissionDenied.localizedDescription
        }
    }

    private func loadThumbnails() async {
        let targets = windows.prefix(30).compactMap { option in scWindows[option.id].map { (option.id, $0) } }
        await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            for (id, window) in targets {
                group.addTask { (id, await ShareableContent.thumbnail(for: window)) }
            }
            for await (id, image) in group {
                if let image {
                    windowThumbnails[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                }
            }
        }
    }
}
