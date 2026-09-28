import AppKit

/// Menu bar item: quick access when idle, live timer and controls while recording.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        updateButton()
        observeContinuously({ [weak self] in
            guard let self else { return }
            _ = self.model.recording.phase
            _ = self.model.recording.elapsed
        }, onChange: { [weak self] in self?.updateButton() })
    }

    private func updateButton() {
        guard let button = item.button else { return }
        let recording = model.recording!
        switch recording.phase {
        case .recording, .paused:
            let paused = recording.phase == .paused
            button.image = NSImage(systemSymbolName: paused ? "pause.circle.fill" : "record.circle.fill",
                                   accessibilityDescription: paused ? "Paused" : "Recording")
            button.contentTintColor = paused ? .systemYellow : .systemRed
            button.attributedTitle = NSAttributedString(string: " " + TimeFormat.clock(recording.elapsed), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            ])
        case .countdown(let value):
            button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Starting")
            button.contentTintColor = nil
            button.title = " \(value)"
        default:
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "OwnRecord")
            button.contentTintColor = nil
            button.title = ""
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recording = model.recording!
        switch recording.phase {
        case .recording, .paused:
            menu.addItem(item("Stop Recording", key: "", action: #selector(stop)))
            menu.addItem(item(recording.phase == .paused ? "Resume" : "Pause", key: "", action: #selector(togglePause)))
            menu.addItem(item("Restart", key: "", action: #selector(restart)))
            menu.addItem(.separator())
            menu.addItem(item("Discard Recording", key: "", action: #selector(discard)))
        case .preparing, .countdown:
            menu.addItem(item("Start Now", key: "", action: #selector(startNow)))
            menu.addItem(item("Cancel", key: "", action: #selector(discard)))
        case .finishing:
            let saving = NSMenuItem(title: "Saving recording…", action: nil, keyEquivalent: "")
            saving.isEnabled = false
            menu.addItem(saving)
        case .idle:
            let newItem = item("New Recording", key: "", action: #selector(newRecording))
            newItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
            menu.addItem(newItem)
            menu.addItem(item("Library", key: "", action: #selector(showLibrary)))
            let recent = model.library.recordings.prefix(5)
            if !recent.isEmpty {
                menu.addItem(.separator())
                let header = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for recording in recent {
                    let entry = item("\(recording.title)  ·  \(TimeFormat.clock(recording.duration))", key: "",
                                     action: #selector(openRecording(_:)))
                    entry.representedObject = recording.id
                    menu.addItem(entry)
                }
            }
            menu.addItem(.separator())
            menu.addItem(item("Settings…", key: ",", action: #selector(showSettings)))
            menu.addItem(item("Quit OwnRecord", key: "q", action: #selector(quit)))
        }
    }

    private func item(_ title: String, key: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func newRecording() { model.showRecorder() }
    @objc private func showLibrary() { model.windows.showHome() }
    @objc private func showSettings() { model.windows.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func stop() { model.recording.stop() }
    @objc private func togglePause() { model.recording.togglePause() }
    @objc private func restart() { model.recording.restart() }
    @objc private func discard() { model.recording.discard() }
    @objc private func startNow() { model.recording.skipCountdownNow() }

    @objc private func openRecording(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model.windows.openEditor(for: id)
    }
}
