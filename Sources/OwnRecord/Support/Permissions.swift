import AppKit
@preconcurrency import AVFoundation
import CoreGraphics
import Observation
import Speech

enum PermissionState {
    case granted, denied, notDetermined
}

enum PermissionKind: CaseIterable, Identifiable {
    case screen, camera, microphone, speech

    var id: Self { self }

    var title: String {
        switch self {
        case .screen: "Screen Recording"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .speech: "Speech Recognition"
        }
    }

    var detail: String {
        switch self {
        case .screen: "Required to capture your screen and windows."
        case .camera: "Needed for the speaker camera overlay."
        case .microphone: "Needed to record your voice."
        case .speech: "Needed to generate subtitles on this Mac."
        }
    }

    var symbol: String {
        switch self {
        case .screen: "rectangle.dashed.badge.record"
        case .camera: "video"
        case .microphone: "mic"
        case .speech: "captions.bubble"
        }
    }

    fileprivate var settingsAnchor: String {
        switch self {
        case .screen: "Privacy_ScreenCapture"
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        case .speech: "Privacy_SpeechRecognition"
        }
    }
}

@MainActor @Observable
final class Permissions {
    private(set) var screen: PermissionState = .notDetermined
    private(set) var camera: PermissionState = .notDetermined
    private(set) var microphone: PermissionState = .notDetermined
    private(set) var speech: PermissionState = .notDetermined

    init() {
        refresh()
    }

    func state(for kind: PermissionKind) -> PermissionState {
        switch kind {
        case .screen: screen
        case .camera: camera
        case .microphone: microphone
        case .speech: speech
        }
    }

    func refresh() {
        // macOS doesn't distinguish "denied" from "not asked" for screen capture.
        screen = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        camera = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        microphone = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speech = .granted
        case .notDetermined: speech = .notDetermined
        default: speech = .denied
        }
    }

    @discardableResult
    func request(_ kind: PermissionKind) async -> Bool {
        defer { refresh() }
        switch kind {
        case .screen:
            if CGPreflightScreenCaptureAccess() { return true }
            // Shows the system prompt the first time; afterwards the user must use System Settings.
            return CGRequestScreenCaptureAccess()
        case .camera, .microphone:
            let type: AVMediaType = kind == .camera ? .video : .audio
            switch AVCaptureDevice.authorizationStatus(for: type) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
            default:
                openSystemSettings(for: kind)
                return false
            }
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return true
            case .notDetermined:
                return await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { status in
                        continuation.resume(returning: status == .authorized)
                    }
                }
            default:
                openSystemSettings(for: .speech)
                return false
            }
        }
    }

    func openSystemSettings(for kind: PermissionKind) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)")!
        NSWorkspace.shared.open(url)
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}
