import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        NSApp.mainMenu = MainMenu.make()
        statusItem = StatusItemController(model: model)

        HotKeyCenter.shared.register(id: 1, shortcut: HotKeyCenter.toggleRecording) {
            AppModel.shared.handleRecordShortcut()
        }
        HotKeyCenter.shared.register(id: 2, shortcut: HotKeyCenter.togglePause) {
            AppModel.shared.recording.togglePause()
        }
        HotKeyCenter.shared.register(id: 3, shortcut: HotKeyCenter.toggleTeleprompter) {
            AppModel.shared.teleprompter.toggleScrolling()
        }
        // Created up front so it can be left out of recordings from the start (see Teleprompter.windowID).
        _ = model.teleprompter.windowID
        model.startControlServer()

        // The command line tool starts the app in the background, without the library.
        if !ProcessInfo.processInfo.arguments.contains(CommandLineTool.backgroundLaunchArgument) {
            model.windows.showHome()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, !AppModel.shared.recording.isActive {
            AppModel.shared.windows.showHome()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppModel.shared.permissions.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.control.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let recording = AppModel.shared.recording!
        guard recording.isActive else { return .terminateNow }
        // Save (or cleanly cancel) the take in progress before quitting.
        Task {
            await recording.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Menu actions

    @objc func newRecording(_ sender: Any?) {
        AppModel.shared.showRecorder()
    }

    @objc func showLibrary(_ sender: Any?) {
        AppModel.shared.windows.showHome()
    }

    @objc func showSettings(_ sender: Any?) {
        AppModel.shared.windows.showSettings()
    }

    @objc func openRecordingsFolder(_ sender: Any?) {
        NSWorkspace.shared.open(AppModel.shared.library.rootURL)
    }

    @objc func toggleTeleprompter(_ sender: Any?) {
        AppModel.shared.teleprompter.toggleVisibility()
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleTeleprompter(_:)) {
            item.title = AppModel.shared.teleprompter.isVisible ? "Hide Teleprompter" : "Show Teleprompter"
        }
        return true
    }
}

enum MainMenu {
    @MainActor
    static func make() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About OwnRecord", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide OwnRecord", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit OwnRecord", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "OwnRecord")

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Recording", action: #selector(AppDelegate.newRecording(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Library", action: #selector(AppDelegate.showLibrary(_:)), keyEquivalent: "l")
        fileMenu.addItem(withTitle: "Open Recordings Folder", action: #selector(AppDelegate.openRecordingsFolder(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: fileMenu, title: "File")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: editMenu, title: "Edit")

        // Editor commands. Their single-key shortcuts are disabled while typing in a text field
        // (see EditorWindowController), so they never swallow text input.
        let timelineMenu = NSMenu(title: "Timeline")
        for command: EditorCommand in [.split, .splitAtSilences, .deleteSection, .joinNext] {
            timelineMenu.addItem(command.menuItem())
        }
        timelineMenu.addItem(.separator())
        for command: EditorCommand in [.toggleScreen, .toggleCamera, .toggleAudio, .resetSection] {
            timelineMenu.addItem(command.menuItem())
        }
        let cameraMenu = NSMenu(title: "Move Camera")
        for command: EditorCommand in [.cameraLeft, .cameraRight, .cameraUp, .cameraDown] {
            cameraMenu.addItem(command.menuItem())
        }
        cameraMenu.addItem(.separator())
        cameraMenu.addItem(EditorCommand.cameraEverywhere.menuItem())
        timelineMenu.addItem(submenu: cameraMenu, title: "Move Camera")
        timelineMenu.addItem(.separator())
        for command: EditorCommand in [.blurArea, .pixelateArea, .cancelEditing] {
            timelineMenu.addItem(command.menuItem())
        }
        timelineMenu.addItem(.separator())
        for command: EditorCommand in [.trimStart, .trimEnd, .resetTrim] {
            timelineMenu.addItem(command.menuItem())
        }
        main.addItem(submenu: timelineMenu, title: "Timeline")

        let playbackMenu = NSMenu(title: "Playback")
        for command: EditorCommand in [.playPause, .goToStart] {
            playbackMenu.addItem(command.menuItem())
        }
        playbackMenu.addItem(.separator())
        for command: EditorCommand in [.previousFrame, .nextFrame, .backOneSecond, .forwardOneSecond] {
            playbackMenu.addItem(command.menuItem())
        }
        playbackMenu.addItem(.separator())
        for command: EditorCommand in [.previousEdit, .nextEdit] {
            playbackMenu.addItem(command.menuItem())
        }
        main.addItem(submenu: playbackMenu, title: "Playback")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let teleprompter = windowMenu.addItem(withTitle: "Show Teleprompter", action: #selector(AppDelegate.toggleTeleprompter(_:)),
                                              keyEquivalent: "t")
        teleprompter.keyEquivalentModifierMask = [.command, .option]
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        main.addItem(submenu: windowMenu, title: "Window")

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(EditorCommand.showShortcuts.menuItem())
        NSApp.helpMenu = helpMenu
        main.addItem(submenu: helpMenu, title: "Help")

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
