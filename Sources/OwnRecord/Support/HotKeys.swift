import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts via Carbon hot keys (no Accessibility permission needed).
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    struct Shortcut {
        let keyCode: Int
        let modifiers: NSEvent.ModifierFlags
        let display: String
    }

    static let toggleRecording = Shortcut(keyCode: kVK_ANSI_R, modifiers: [.command, .shift, .option], display: "⌥⇧⌘R")
    static let togglePause = Shortcut(keyCode: kVK_ANSI_P, modifiers: [.command, .shift, .option], display: "⌥⇧⌘P")
    static let toggleTeleprompter = Shortcut(keyCode: kVK_ANSI_T, modifiers: [.command, .shift, .option], display: "⌥⇧⌘T")

    private var handlers: [UInt32: () -> Void] = [:]
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false

    func register(id: UInt32, shortcut: Shortcut, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        if let existing = references.removeValue(forKey: id) {
            UnregisterEventHotKey(existing)
        }
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F57_5243), id: id) // 'OWRC'
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), Self.carbonModifiers(shortcut.modifiers),
                                         hotKeyID, GetApplicationEventTarget(), 0, &reference)
        if status == noErr, let reference {
            references[id] = reference
            handlers[id] = handler
        }
    }

    fileprivate func fire(id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.fire(id: id) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}
