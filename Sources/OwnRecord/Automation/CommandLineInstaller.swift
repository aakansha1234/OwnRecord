import AppKit

/// Puts the `ownrecord` command on the PATH: a link in /usr/local/bin to the app's executable,
/// which acts as the tool when started under that name (see `CommandLineTool`).
@MainActor
enum CommandLineInstaller {
    static let linkPath = "/usr/local/bin/ownrecord"

    static var executablePath: String? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
    }

    static var isInstalled: Bool {
        guard let executablePath, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) else {
            return false
        }
        return URL(fileURLWithPath: target).resolvingSymlinksInPath().path == executablePath
    }

    /// Creates the link, asking for an administrator's password if /usr/local/bin needs one.
    /// Throws `CancellationError` if the password prompt is cancelled.
    static func install() throws {
        guard let executablePath else { throw ControlError("Couldn't find OwnRecord's executable.") }
        let fileManager = FileManager.default
        if let attributes = try? fileManager.attributesOfItem(atPath: linkPath),
           attributes[.type] as? FileAttributeType != .typeSymbolicLink {
            throw ControlError("There's already a file at \(linkPath).")
        }
        do {
            try? fileManager.removeItem(atPath: linkPath)
            try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: executablePath)
        } catch {
            let quoted = "'" + executablePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let command = "mkdir -p /usr/local/bin && ln -sf \(quoted) \(linkPath)"
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            var failure: NSDictionary?
            NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&failure)
            if let failure {
                if failure[NSAppleScript.errorNumber] as? Int == -128 { throw CancellationError() }
                throw ControlError(failure[NSAppleScript.errorMessage] as? String ?? "Couldn't install the command.")
            }
        }
    }
}
