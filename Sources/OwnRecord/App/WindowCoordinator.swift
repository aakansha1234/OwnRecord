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

/// Hosts one recording's editor, and handles the Timeline and Playback menu commands for it.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let model: EditorModel
    private let onClose: () -> Void

    init(model: EditorModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        let window = makeContentWindow(title: model.recording.title, size: NSSize(width: 1320, height: 840),
                                       minSize: NSSize(width: 1000, height: 640), autosaveName: "OwnRecord.Editor",
                                       content: EditorView(model: model))
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        observeContinuously({ [weak self] in _ = self?.model.recording.title },
                            onChange: { [weak self] in self?.window?.title = self?.model.recording.title ?? "" })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Start with nothing focused, so single-key shortcuts work right away instead of
        // typing into the title field.
        window?.makeFirstResponder(nil)
    }

    @objc func performEditorCommand(_ sender: NSMenuItem) {
        guard acceptsEditorCommands, let command = EditorCommand(rawValue: sender.tag) else { return }
        command.perform(on: model)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(performEditorCommand(_:)), let command = EditorCommand(rawValue: item.tag) else {
            return true
        }
        guard acceptsEditorCommands else {
            item.title = command.title
            return false
        }
        item.title = command.title(for: model)
        return command.isEnabled(for: model)
    }

    /// Editor shortcuts are single keys, so they're off while typing (and while a sheet is open).
    private var acceptsEditorCommands: Bool {
        guard let window, window.isKeyWindow, window.attachedSheet == nil, model.loadState == .ready else { return false }
        return !(window.firstResponder is NSText)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        model.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        model.close()
        onClose()
    }
}
