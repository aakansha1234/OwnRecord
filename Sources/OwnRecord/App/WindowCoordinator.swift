import AppKit
import SwiftUI

/// Creates and tracks the app's windows: library, settings, recorder panel and editors.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private var homeWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var editors: [UUID: EditorWindowController] = [:]
    private var homeHiddenForRecording = false
    let recorderPanel = RecorderPanelController()

    func showHome() {
        homeHiddenForRecording = false
        if homeWindow == nil {
            let app = AppModel.shared
            homeWindow = makeContentWindow(title: "OwnRecord", size: NSSize(width: 1040, height: 700),
                                           minSize: NSSize(width: 720, height: 480), autosaveName: "OwnRecord.Home",
                                           content: HomeView(library: app.library, permissions: app.permissions))
        }
        homeWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Gets the library window out of the way while choosing what to record.
    func hideHomeForRecording() {
        if homeWindow?.isVisible == true {
            homeWindow?.orderOut(nil)
            homeHiddenForRecording = true
        }
    }

    func restoreHomeAfterRecording() {
        if homeHiddenForRecording {
            showHome()
        }
    }

    func showSettings() {
        if settingsWindow == nil {
            let app = AppModel.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 480, height: 400)
            window.contentView = NSHostingView(rootView: SettingsView(preferences: app.preferences, permissions: app.permissions,
                                                                      library: app.library))
            window.center()
            window.setFrameAutosaveName("OwnRecord.Settings")
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func openEditor(for id: UUID, autoTranscribe: Bool = false) {
        homeHiddenForRecording = false
        if let existing = editors[id] {
            existing.showWindow(nil)
            NSApp.activate()
            return
        }
        let app = AppModel.shared
        guard let recording = app.library.recording(with: id), let files = app.library.files(for: id) else { return }
        let model = EditorModel(recording: recording, files: files, library: app.library, preferences: app.preferences)
        let controller = EditorWindowController(model: model) { [weak self] in
            self?.editors[id] = nil
        }
        editors[id] = controller
        controller.showWindow(nil)
        NSApp.activate()
        Task {
            await model.load()
            if autoTranscribe {
                model.inspectorTab = .subtitles
                model.generateTranscript(requestPermission: true)
            }
        }
    }

    func closeEditor(for id: UUID) {
        editors[id]?.close()
    }
}

/// The compact floating panel for choosing what and how to record.
@MainActor
final class RecorderPanelController {
    private var panel: OverlayPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        let app = AppModel.shared
        if panel == nil {
            let panel = OverlayPanel(level: .floating)
            panel.isMovableByWindowBackground = true
            panel.host(RecorderPanelView(recorder: app.recorder, controller: app.recording, preferences: app.preferences))
            self.panel = panel
            position(panel)
        }
        guard let panel else { return }
        if !panel.isVisible { position(panel) }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel) {
        guard let visible = NSScreen.withMouse?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 80))
    }
}

/// Hosts one recording's editor. Adds space/arrow key handling that doesn't fight text fields.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private let model: EditorModel
    private let onClose: () -> Void
    private var keyMonitor: Any?

    init(model: EditorModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        let window = makeContentWindow(title: model.recording.title, size: NSSize(width: 1320, height: 840),
                                       minSize: NSSize(width: 1000, height: 640), autosaveName: "OwnRecord.Editor",
                                       content: EditorView(model: model))
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        installKeyMonitor()
        observeContinuously({ [weak self] in _ = self?.model.recording.title },
                            onChange: { [weak self] in self?.window?.title = self?.model.recording.title ?? "" })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(window.firstResponder is NSText), window.attachedSheet == nil else { return event }
            switch event.keyCode {
            case 49: // Space
                self.model.togglePlayback()
                return nil
            case 123: // Left arrow
                self.model.step(by: event.modifierFlags.contains(.shift) ? -1 : -1.0 / Double(self.model.recording.frameRate))
                return nil
            case 124: // Right arrow
                self.model.step(by: event.modifierFlags.contains(.shift) ? 1 : 1.0 / Double(self.model.recording.frameRate))
                return nil
            default:
                return event
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.close()
        onClose()
    }
}
