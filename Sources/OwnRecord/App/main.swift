import AppKit

// Run as `ownrecord` (or with a command), this is the command line tool rather than the app.
if let status = CommandLineTool.run(CommandLine.arguments) {
    exit(status)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
