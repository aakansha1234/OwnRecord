import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: Preferences
    let permissions: Permissions
    let library: RecordingLibrary
    @State private var locales: [TranscriptionEngine.LocaleOption] = []
    @State private var commandInstalled = false
    @State private var installError: String?

    var body: some View {
        Form {
            Section("Recording") {
                Picker("Frame rate", selection: $preferences.frameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Quality", selection: $preferences.videoQuality) {
                    ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
                }
                Picker("Countdown", selection: $preferences.countdown) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                Toggle("Show cursor", isOn: $preferences.showCursor)
                Toggle("Highlight mouse clicks", isOn: $preferences.highlightClicks)
                Toggle("Hide desktop icons", isOn: $preferences.hideDesktopIcons)
            }

            Section("After Recording") {
                Toggle("Open the editor", isOn: $preferences.openEditorAfterRecording)
                Toggle("Generate subtitles automatically", isOn: $preferences.autoTranscribe)
                Picker("Subtitle language", selection: $preferences.transcriptionLocale) {
                    ForEach(locales) { Text($0.name).tag($0.id) }
                    if !locales.contains(where: { $0.id == preferences.transcriptionLocale }) {
                        Text(preferences.transcriptionLocale).tag(preferences.transcriptionLocale)
                    }
                }
            }

            Section {
                Picker("Shape", selection: $preferences.cameraStyle.shape) {
                    ForEach(CameraShape.allCases) { Text($0.title).tag($0) }
                }
                Picker("Bubble size while recording", selection: $preferences.bubbleSize) {
                    ForEach(BubbleSize.allCases) { Text($0.title).tag($0) }
                }
                Picker("Default position", selection: $preferences.cameraStyle.position) {
                    ForEach(CameraPosition.corners) { Text($0.title).tag($0) }
                }
                Toggle("Mirror camera", isOn: $preferences.cameraStyle.mirror)
                Toggle("Border", isOn: Binding(
                    get: { preferences.cameraStyle.borderWidth > 0 },
                    set: { preferences.cameraStyle.borderWidth = $0 ? 0.025 : 0 }))
            } header: {
                Text("Camera Overlay")
            } footer: {
                Text("Where you leave the camera bubble while recording becomes its position in the video. Everything can be changed later in the editor.")
            }

            Section("Keyboard Shortcuts") {
                LabeledContent("Start / stop recording") { ShortcutLabel(HotKeyCenter.toggleRecording.display) }
                LabeledContent("Pause / resume") { ShortcutLabel(HotKeyCenter.togglePause.display) }
                LabeledContent("Play / pause in editor") { ShortcutLabel("Space") }
                LabeledContent("Step one frame") { ShortcutLabel("← →") }
            }

            Section {
                Toggle("Allow control from the command line", isOn: $preferences.allowsCommandLineControl)
                LabeledContent("Command") {
                    HStack {
                        Text("ownrecord")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button(commandInstalled ? "Installed" : "Install…") { installCommand() }
                            .disabled(commandInstalled)
                    }
                }
            } header: {
                Text("Command Line")
            } footer: {
                Text("The ownrecord command lets scripts and AI agents such as Claude Code record, edit and export with OwnRecord. Run “ownrecord help” in Terminal to see what it can do. Recordings it starts show the usual controls, and only apps running as you can use it. Install puts the command in /usr/local/bin.")
            }

            Section("Storage") {
                LabeledContent("Recordings folder") {
                    HStack {
                        Text(library.rootURL.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Show in Finder") { NSWorkspace.shared.open(library.rootURL) }
                    }
                }
            }

            Section("Permissions") {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionTile(kind: kind, permissions: permissions)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
            }
        }
        .formStyle(.grouped)
        .task {
            permissions.refresh()
            locales = TranscriptionEngine.supportedLocales
            commandInstalled = CommandLineInstaller.isInstalled
        }
        .alert("Couldn't install the command", isPresented: Binding(get: { installError != nil },
                                                                    set: { if !$0 { installError = nil } })) {
            Button("OK") {}
        } message: {
            Text(installError ?? "")
        }
    }

    private func installCommand() {
        do {
            try CommandLineInstaller.install()
        } catch is CancellationError {
        } catch {
            installError = error.localizedDescription
        }
        commandInstalled = CommandLineInstaller.isInstalled
    }
}

private struct ShortcutLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.08)))
    }
}
