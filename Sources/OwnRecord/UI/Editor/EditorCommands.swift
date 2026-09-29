import AppKit

/// Editor actions with their menu titles and keyboard shortcuts. The Playback and Timeline menus,
/// the shortcuts reference and the menu validation are all built from this list.
enum EditorCommand: Int, CaseIterable {
    case playPause = 1, goToStart, previousFrame, nextFrame, backOneSecond, forwardOneSecond, previousEdit, nextEdit
    case split, deleteSection, toggleScreen, toggleCamera, toggleAudio, joinNext, resetSection
    case cameraLeft, cameraRight, cameraUp, cameraDown, cameraEverywhere
    case trimStart, trimEnd, resetTrim
    case showShortcuts
    case blurArea, pixelateArea, cancelEditing
    case splitAtSilences

    enum Group: String, CaseIterable {
        case playback = "Playback"
        case sections = "Sections"
        case camera = "Camera"
        case blur = "Blur"
        case trim = "Trim"
    }

    var group: Group {
        switch self {
        case .playPause, .goToStart, .previousFrame, .nextFrame, .backOneSecond, .forwardOneSecond, .previousEdit, .nextEdit:
            .playback
        case .split, .deleteSection, .toggleScreen, .toggleCamera, .toggleAudio, .joinNext, .resetSection, .showShortcuts,
             .splitAtSilences:
            .sections
        case .cameraLeft, .cameraRight, .cameraUp, .cameraDown, .cameraEverywhere:
            .camera
        case .trimStart, .trimEnd, .resetTrim:
            .trim
        case .blurArea, .pixelateArea, .cancelEditing:
            .blur
        }
    }

    /// Menu title when nothing more specific applies (see `title(for:)`).
    var title: String {
        switch self {
        case .playPause: "Play/Pause"
        case .goToStart: "Go to Start"
        case .previousFrame: "Previous Frame"
        case .nextFrame: "Next Frame"
        case .backOneSecond: "Back 1 Second"
        case .forwardOneSecond: "Forward 1 Second"
        case .previousEdit: "Previous Split"
        case .nextEdit: "Next Split"
        case .split: "Split at Playhead"
        case .deleteSection: "Delete Section"
        case .toggleScreen: "Hide Screen in Section"
        case .toggleCamera: "Hide Camera in Section"
        case .toggleAudio: "Mute Section"
        case .joinNext: "Join with Next Section"
        case .resetSection: "Reset Section"
        case .cameraLeft: "Move Camera Left"
        case .cameraRight: "Move Camera Right"
        case .cameraUp: "Move Camera Up"
        case .cameraDown: "Move Camera Down"
        case .cameraEverywhere: "Apply Camera to All Sections"
        case .trimStart: "Trim Start to Playhead"
        case .trimEnd: "Trim End to Playhead"
        case .resetTrim: "Reset Trim"
        case .showShortcuts: "Keyboard Shortcuts"
        case .blurArea: "Blur Area"
        case .pixelateArea: "Pixelate Area"
        case .cancelEditing: "Deselect"
        case .splitAtSilences: "Split at Silences…"
        }
    }

    /// Short description for the shortcuts reference.
    var summary: String {
        switch self {
        case .deleteSection: "Delete or restore section (or the selected blur)"
        case .toggleScreen: "Hide or show the screen"
        case .toggleCamera: "Hide or show the camera"
        case .toggleAudio: "Mute or unmute audio"
        case .playPause: "Play / pause"
        case .previousEdit: "Previous split or trim point"
        case .nextEdit: "Next split or trim point"
        case .blurArea: "Blur an area"
        case .pixelateArea: "Pixelate an area"
        case .cancelEditing: "Cancel or deselect"
        case .splitAtSilences: "Split at silences"
        default: title
        }
    }

    private static func functionKey(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt32(key))!))
    }

    var keyEquivalent: String {
        switch self {
        case .playPause: " "
        case .goToStart: Self.functionKey(NSHomeFunctionKey)
        case .previousFrame, .backOneSecond, .cameraLeft: Self.functionKey(NSLeftArrowFunctionKey)
        case .nextFrame, .forwardOneSecond, .cameraRight: Self.functionKey(NSRightArrowFunctionKey)
        case .previousEdit, .cameraUp: Self.functionKey(NSUpArrowFunctionKey)
        case .nextEdit, .cameraDown: Self.functionKey(NSDownArrowFunctionKey)
        // Shifted letters are given in upper case: a lower-case key with Shift would also catch the plain key.
        case .split: "s"
        case .splitAtSilences: "S"
        case .blurArea: "b"
        case .pixelateArea: "B"
        case .cancelEditing: "\u{1b}"
        case .deleteSection: "\u{8}"
        case .toggleScreen: "h"
        case .toggleCamera: "c"
        case .toggleAudio: "m"
        case .trimStart: "i"
        case .trimEnd: "o"
        case .showShortcuts: "/"
        case .joinNext, .resetSection, .cameraEverywhere, .resetTrim: ""
        }
    }

    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .backOneSecond, .forwardOneSecond, .pixelateArea, .splitAtSilences: [.shift]
        case .cameraLeft, .cameraRight, .cameraUp, .cameraDown: [.option]
        case .showShortcuts: [.command]
        default: []
        }
    }

    /// The shortcut as shown in the reference, e.g. "⌥←".
    var shortcutLabel: String? {
        let key: String
        switch self {
        case .playPause: key = "Space"
        case .goToStart: key = "Home"
        case .previousFrame, .backOneSecond, .cameraLeft: key = "←"
        case .nextFrame, .forwardOneSecond, .cameraRight: key = "→"
        case .previousEdit, .cameraUp: key = "↑"
        case .nextEdit, .cameraDown: key = "↓"
        case .deleteSection: key = "⌫"
        case .cancelEditing: key = "Esc"
        default:
            guard !keyEquivalent.isEmpty else { return nil }
            key = keyEquivalent.uppercased()
        }
        var prefix = ""
        if modifiers.contains(.option) { prefix += "⌥" }
        if modifiers.contains(.shift) { prefix += "⇧" }
        if modifiers.contains(.command) { prefix += "⌘" }
        return prefix + key
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(EditorWindowController.performEditorCommand(_:)),
                              keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.tag = rawValue
        return item
    }

    // MARK: Behavior

    /// Title reflecting the section under the playhead, e.g. "Restore Section".
    @MainActor
    func title(for model: EditorModel) -> String {
        let section = model.currentSection
        switch self {
        case .deleteSection:
            if let redaction = model.selectedRedaction { return "Delete \(redaction.style.noun)" }
            return section.isDeleted ? "Restore Section" : "Delete Section"
        case .toggleScreen: return section.showsScreen ? "Hide Screen in Section" : "Show Screen in Section"
        case .toggleCamera: return section.showsCamera ? "Hide Camera in Section" : "Show Camera in Section"
        case .toggleAudio: return section.mutesAudio ? "Unmute Section" : "Mute Section"
        case .cancelEditing: return model.drawingRedaction != nil ? "Cancel Blur" : "Deselect"
        default: return title
        }
    }

    @MainActor
    func isEnabled(for model: EditorModel) -> Bool {
        switch self {
        case .split: return model.canSplit
        case .joinNext: return model.currentSectionIndex + 1 < model.sections.count
        case .resetSection: return model.currentSection.isCustomized && !model.currentSection.isDeleted
        case .toggleCamera, .cameraLeft, .cameraRight, .cameraUp, .cameraDown: return model.hasCameraTrack
        case .cameraEverywhere: return model.hasCameraTrack && !model.cameraPlacementIsUniform
        case .toggleAudio: return model.recording.hasAudio
        case .resetTrim: return model.isTrimmed
        case .blurArea, .pixelateArea: return model.canRedact
        case .cancelEditing: return model.canCancelRedactionEditing
        case .splitAtSilences: return model.recording.hasAudio
        default: return true
        }
    }

    @MainActor
    func perform(on model: EditorModel) {
        switch self {
        case .playPause: model.togglePlayback()
        case .goToStart: model.goToStart()
        case .previousFrame: model.stepFrame(forward: false)
        case .nextFrame: model.stepFrame(forward: true)
        case .backOneSecond: model.step(by: -1)
        case .forwardOneSecond: model.step(by: 1)
        case .previousEdit: model.goToEditPoint(forward: false)
        case .nextEdit: model.goToEditPoint(forward: true)
        case .split: model.splitAtPlayhead()
        case .deleteSection:
            if model.selectedRedaction != nil { model.deleteRedaction() } else { model.toggleDeleted() }
        case .toggleScreen: model.toggleScreen()
        case .toggleCamera: model.toggleCamera()
        case .toggleAudio: model.toggleMute()
        case .joinNext: model.joinWithNext()
        case .resetSection: model.resetSection()
        case .cameraLeft: model.nudgeCamera(toward: .left)
        case .cameraRight: model.nudgeCamera(toward: .right)
        case .cameraUp: model.nudgeCamera(toward: .top)
        case .cameraDown: model.nudgeCamera(toward: .bottom)
        case .cameraEverywhere: model.applyCameraToAllSections()
        case .trimStart: model.setTrimStartAtPlayhead()
        case .trimEnd: model.setTrimEndAtPlayhead()
        case .resetTrim: model.resetTrim()
        case .showShortcuts: model.isShortcutsPresented.toggle()
        case .blurArea: model.beginRedaction(.blur)
        case .pixelateArea: model.beginRedaction(.pixelate)
        case .cancelEditing: model.cancelRedactionEditing()
        case .splitAtSilences: model.showSilenceSheet()
        }
    }
}
