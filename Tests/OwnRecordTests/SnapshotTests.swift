import AppKit
@testable import OwnRecord
import SwiftUI
import Testing

/// Renders key screens to PNGs for visual review. Opt-in: OWNRECORD_SNAPSHOTS=1 swift test --filter Snapshot
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OWNRECORD_SNAPSHOTS"] != nil))
@MainActor
struct SnapshotTests {
    static let outputDirectory = PipelineTests.scratchRoot.deletingLastPathComponent().appendingPathComponent("snapshots")

    private func snapshot<V: View>(_ view: V, size: CGSize, name: String, dark: Bool = true) async throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderBack(nil)
        for _ in 0..<5 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
        }
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }

    @Test func recorderPanel() async throws {
        let app = AppModel.shared
        let view = RecorderPanelView(recorder: app.recorder, controller: app.recording, preferences: app.preferences)
            .background(Color(white: 0.16))
        try await snapshot(view, size: CGSize(width: 420, height: 420), name: "recorder-panel")
    }

    @Test func controlBar() async throws {
        try await snapshot(ControlBarView(controller: AppModel.shared.recording).background(Color(white: 0.3)),
                           size: CGSize(width: 380, height: 70), name: "control-bar")
    }

    @Test func homeEmptyAndFilled() async throws {
        let root = PipelineTests.scratchRoot.appendingPathComponent("library-\(UUID().uuidString)")
        let library = RecordingLibrary(rootURL: root)
        try await snapshot(HomeView(library: library, permissions: Permissions()), size: CGSize(width: 1040, height: 640),
                           name: "home-empty")
        let thumbnail = PipelineTests.scratchRoot.deletingLastPathComponent().appendingPathComponent("ownrecord-export.jpg")
        for (index, title) in ["Product demo walkthrough", "Bug repro – checkout flow", "Weekly update"].enumerated() {
            let folder = try library.makeRecordingFolder(date: Date().addingTimeInterval(Double(-index) * 3600))
            try? FileManager.default.copyItem(at: thumbnail, to: RecordingFiles(folder: folder).thumbnail)
            let recording = Recording(id: UUID(), title: title, createdAt: Date().addingTimeInterval(Double(-index) * 86400),
                                      duration: Double(95 + index * 200), captureMode: .display, sourceName: "Built-in Display",
                                      pixelWidth: 3024, pixelHeight: 1964, frameRate: 60, hasCamera: index != 1,
                                      audioTracks: [.microphone], edit: EditSettings(), transcript: nil)
            library.save(recording, in: folder)
        }
        try await snapshot(HomeView(library: library, permissions: Permissions()), size: CGSize(width: 1040, height: 640),
                           name: "home-filled")
        try? FileManager.default.removeItem(at: root)
    }

    @Test func editor() async throws {
        let folder = PipelineTests.scratchRoot.appendingPathComponent("editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var (recording, files) = try await PipelineTests.makeRecording(folder: folder)
        recording.transcript?.cues = [
            SubtitleCue(start: 0, end: 0.8, text: "Hi everyone, welcome to the demo."),
            SubtitleCue(start: 0.8, end: 1.6, text: "Today I'll show how recording works."),
            SubtitleCue(start: 1.6, end: 2, text: "Let's get started."),
        ]
        let library = RecordingLibrary(rootURL: PipelineTests.scratchRoot.appendingPathComponent("editor-library-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: library.rootURL) }
        for tab in EditorModel.InspectorTab.allCases {
            let model = EditorModel(recording: recording, files: files, library: library, preferences: Preferences.shared)
            await model.load()
            model.inspectorTab = tab
            try await snapshot(EditorView(model: model), size: CGSize(width: 1320, height: 820), name: "editor-\(tab.rawValue)")
            model.close()
        }

        // Three sections: normal, deleted, and one that hides the screen.
        recording.edit.split(at: 0.6, duration: 2)
        recording.edit.split(at: 1.2, duration: 2)
        recording.edit.sections[1].isDeleted = true
        recording.edit.sections[2].showsScreen = false
        recording.edit.sections[2].mutesAudio = true
        for (name, time) in [("editor-sections", 1.7), ("editor-deleted-section", 0.9)] {
            let model = EditorModel(recording: recording, files: files, library: library, preferences: Preferences.shared)
            await model.load()
            model.inspectorTab = .camera
            model.seek(to: time)
            try await Task.sleep(for: .milliseconds(300))
            try await snapshot(EditorView(model: model), size: CGSize(width: 1320, height: 820), name: name)
            model.close()
        }
        let model = EditorModel(recording: recording, files: files, library: library, preferences: Preferences.shared)
        await model.load()
        model.isShortcutsPresented = false
        try await snapshot(ShortcutsView().background(Color(nsColor: .windowBackgroundColor)),
                           size: CGSize(width: 600, height: 440), name: "editor-shortcuts")
        model.close()
    }
}
