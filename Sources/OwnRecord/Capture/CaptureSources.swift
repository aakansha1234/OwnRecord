import AppKit
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit

struct CaptureDeviceOption: Identifiable, Hashable {
    let id: String
    let name: String
}

enum CaptureDevices {
    static func cameras() -> [CaptureDeviceOption] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified
        ).devices.map { CaptureDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func microphones() -> [CaptureDeviceOption] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { CaptureDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
    }

    static var defaultMicrophoneID: String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID
    }
}

struct DisplayOption: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let pointSize: CGSize
    let pixelSize: CGSize
}

struct WindowOption: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let appName: String
    let bundleID: String?
    let processID: pid_t
    let frame: CGRect

    var displayTitle: String { title.isEmpty ? appName : title }
}

enum ShareableContent {
    static func load(onScreenOnly: Bool = true) async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: onScreenOnly)
    }

    @MainActor
    static func displays(from content: SCShareableContent) -> [DisplayOption] {
        content.displays.map { display in
            let screen = NSScreen.screen(withDisplayID: display.displayID)
            let scale = screen?.backingScaleFactor ?? 2
            let size = CGSize(width: display.width, height: display.height)
            return DisplayOption(id: display.displayID,
                                 name: screen?.localizedName ?? "Display \(display.displayID)",
                                 pointSize: size,
                                 pixelSize: size.scaled(scale))
        }
    }

    static func windows(from content: SCShareableContent) -> [WindowOption] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let hiddenApps: Set<String> = ["com.apple.dock", "com.apple.controlcenter", "com.apple.WindowManager",
                                       "com.apple.notificationcenterui", "com.apple.Spotlight"]
        return content.windows.compactMap { window -> WindowOption? in
            guard window.windowLayer == 0, window.isOnScreen,
                  window.frame.width >= 120, window.frame.height >= 80,
                  let app = window.owningApplication, app.processID != ownPID,
                  !hiddenApps.contains(app.bundleIdentifier) else { return nil }
            let appName = app.applicationName
            let title = window.title ?? ""
            guard !(appName.isEmpty && title.isEmpty) else { return nil }
            return WindowOption(id: window.windowID, title: title, appName: appName, bundleID: app.bundleIdentifier,
                                processID: app.processID, frame: window.frame)
        }
    }

    static func thumbnail(for window: SCWindow, maxDimension: CGFloat = 320) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = maxDimension / max(window.frame.width, window.frame.height, 1)
        configuration.width = max(2, Int(window.frame.width * scale))
        configuration.height = max(2, Int(window.frame.height * scale))
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

/// Everything needed to start a capture of the user's selection.
struct CaptureTarget {
    let filter: SCContentFilter
    let pixelSize: CGSize
    let sourceRect: CGRect?
    /// Captured region in Cocoa global coordinates (for positioning overlays).
    let frame: CGRect
    let screen: NSScreen?
    let name: String
    let mode: CaptureMode
    let windowProcessID: pid_t?

    @MainActor
    static func resolve(mode: CaptureMode, displayID: CGDirectDisplayID?, windowID: CGWindowID?, area: AreaSelection?,
                        content: SCShareableContent, hideDesktopIcons: Bool) throws -> CaptureTarget {
        switch mode {
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first
            else { throw CaptureError.noDisplay }
            let filter = displayFilter(display: display, content: content, hideDesktopIcons: hideDesktopIcons)
            let screen = NSScreen.screen(withDisplayID: display.displayID)
            let size = filter.contentRect.size.scaled(CGFloat(filter.pointPixelScale)).evenRounded()
            return CaptureTarget(filter: filter, pixelSize: size, sourceRect: nil,
                                 frame: screen?.frame ?? filter.contentRect, screen: screen,
                                 name: screen?.localizedName ?? "Display", mode: mode, windowProcessID: nil)

        case .window:
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureError.windowUnavailable
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let frame = GlobalCoordinates.cocoaRect(fromCG: window.frame)
            let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? NSScreen.main
            let size = filter.contentRect.size.scaled(CGFloat(filter.pointPixelScale)).evenRounded()
            let appName = window.owningApplication?.applicationName ?? ""
            let title = window.title ?? ""
            return CaptureTarget(filter: filter, pixelSize: size, sourceRect: nil, frame: frame, screen: screen,
                                 name: title.isEmpty ? appName : "\(appName) — \(title)", mode: mode,
                                 windowProcessID: window.owningApplication?.processID)

        case .area:
            guard let area, let display = content.displays.first(where: { $0.displayID == area.displayID }) else {
                throw CaptureError.areaUnavailable
            }
            let filter = displayFilter(display: display, content: content, hideDesktopIcons: hideDesktopIcons)
            let screen = NSScreen.screen(withDisplayID: display.displayID)
            let rect = area.rect.integral
            let size = rect.size.scaled(CGFloat(filter.pointPixelScale)).evenRounded()
            let screenFrame = screen?.frame ?? .zero
            let frame = CGRect(x: screenFrame.minX + rect.minX, y: screenFrame.maxY - rect.maxY,
                               width: rect.width, height: rect.height)
            return CaptureTarget(filter: filter, pixelSize: size, sourceRect: rect, frame: frame, screen: screen,
                                 name: "Area on \(screen?.localizedName ?? "Display")", mode: mode, windowProcessID: nil)
        }
    }

    /// Captures a display without OwnRecord's own windows (recorder, camera bubble, controls).
    private static func displayFilter(display: SCDisplay, content: SCShareableContent, hideDesktopIcons: Bool) -> SCContentFilter {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var excludedApps = content.applications.filter { $0.processID == ownPID }
        var exceptedWindows: [SCWindow] = []
        if hideDesktopIcons, let finder = content.applications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) {
            // Exclude Finder (and with it the desktop icons) but keep its regular windows.
            excludedApps.append(finder)
            exceptedWindows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == "com.apple.finder" && $0.windowLayer == 0
            }
        }
        return SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: exceptedWindows)
    }

    func streamConfiguration(frameRate: Int, showsCursor: Bool, highlightClicks: Bool, systemAudio: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        if let sourceRect { configuration.sourceRect = sourceRect }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.showsCursor = showsCursor
        configuration.showMouseClicks = highlightClicks
        if mode == .window {
            configuration.scalesToFit = true
            configuration.ignoreShadowsSingleWindow = true
        }
        configuration.capturesAudio = systemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        return configuration
    }
}
