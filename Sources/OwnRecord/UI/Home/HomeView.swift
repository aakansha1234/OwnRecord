import ImageIO
import SwiftUI

/// Library window: all recordings, search, and the main "New Recording" entry point.
struct HomeView: View {
    let library: RecordingLibrary
    let permissions: Permissions
    @State private var search = ""
    @State private var renaming: Recording?
    @State private var renameText = ""
    @State private var deleting: Recording?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if needsOnboarding {
                PermissionsBanner(permissions: permissions)
                    .padding([.horizontal, .top], 20)
            }
            if library.recordings.isEmpty {
                EmptyLibraryView()
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(edges: .top)
        .alert("Rename Recording", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let renaming { library.rename(renaming.id, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Move “\(deleting?.title ?? "")” to the Trash?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let deleting {
                    AppModel.shared.windows.closeEditor(for: deleting.id)
                    library.delete(deleting.id)
                }
                deleting = nil
            }
        } message: {
            Text("The recording and its files will be moved to the Trash.")
        }
    }

    private var needsOnboarding: Bool {
        permissions.screen != .granted || permissions.microphone == .notDetermined || permissions.camera == .notDetermined
    }

    private var filtered: [Recording] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return library.recordings }
        return library.recordings.filter { $0.matches(search: query) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 64)
            VStack(alignment: .leading, spacing: 1) {
                Text("Recordings")
                    .font(.system(size: 15, weight: .semibold))
                Text(library.recordings.count == 1 ? "1 recording" : "\(library.recordings.count) recordings")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SearchField(text: $search)
                .frame(width: 240)
            Button {
                AppModel.shared.windows.showSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Button {
                AppModel.shared.showRecorder()
            } label: {
                Label("New Recording", systemImage: "record.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .help("New Recording (⌘N, or \(HotKeyCenter.toggleRecording.display) from anywhere)")
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .background(WindowDragArea())
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 20)], spacing: 22) {
                ForEach(filtered) { recording in
                    RecordingCard(recording: recording, library: library)
                        .onTapGesture { AppModel.shared.windows.openEditor(for: recording.id) }
                        .contextMenu {
                            Button("Open") { AppModel.shared.windows.openEditor(for: recording.id) }
                            Button("Rename…") {
                                renameText = recording.title
                                renaming = recording
                            }
                            Button("Show in Finder") { library.revealInFinder(recording.id) }
                            Divider()
                            Button("Move to Trash", role: .destructive) { deleting = recording }
                        }
                }
            }
            .padding(20)
        }
    }
}

private struct RecordingCard: View {
    let recording: Recording
    let library: RecordingLibrary
    @State private var hovering = false
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.85))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
                if hovering {
                    Color.black.opacity(0.25)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.95))
                        .shadow(radius: 6)
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Text(TimeFormat.clock(recording.editedDuration))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(.white)
                    .padding(8)
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    if recording.hasCamera { Badge(symbol: "person.crop.circle", label: "Has camera") }
                    if recording.transcript != nil { Badge(symbol: "captions.bubble", label: "Has subtitles") }
                }
                .padding(8)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovering ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: hovering ? 2 : 1)
            )
            .shadow(color: .black.opacity(hovering ? 0.18 : 0.08), radius: hovering ? 10 : 4, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(recording.createdAt.formatted(.relative(presentation: .named)) + " · " + recording.sourceName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { self.hovering = hovering } }
        .task(id: library.thumbnailRevision[recording.id, default: 0]) {
            image = await Self.loadThumbnail(library.files(for: recording.id)?.thumbnail)
        }
    }

    private static func loadThumbnail(_ url: URL?) async -> NSImage? {
        guard let url else { return nil }
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }.value
        return image.map { NSImage(cgImage: $0, size: .zero) }
    }
}

private struct Badge: View {
    let symbol: String
    let label: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(.black.opacity(0.55), in: Circle())
            .accessibilityLabel(label)
    }
}

private struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.red.opacity(0.12)).frame(width: 110, height: 110)
                Image(systemName: "record.circle")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.red)
            }
            VStack(spacing: 6) {
                Text("Record your first video")
                    .font(.system(size: 20, weight: .semibold))
                Text("Capture your screen, a window or any area — with your camera and voice.\nAdd subtitles automatically and export anywhere.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                AppModel.shared.showRecorder()
            } label: {
                Label("New Recording", systemImage: "record.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            HStack(spacing: 6) {
                Text("Tip: press")
                Text(HotKeyCenter.toggleRecording.display)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.08)))
                Text("from any app to start or stop recording.")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct PermissionsBanner: View {
    let permissions: Permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("Finish setting up OwnRecord")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Refresh") { permissions.refresh() }
                    .buttonStyle(.borderless)
            }
            HStack(spacing: 12) {
                ForEach([PermissionKind.screen, .microphone, .camera]) { kind in
                    PermissionTile(kind: kind, permissions: permissions)
                }
            }
            if permissions.screen != .granted {
                Text("After enabling Screen Recording in System Settings, macOS may ask you to quit and reopen OwnRecord.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.25)))
    }
}

struct PermissionTile: View {
    let kind: PermissionKind
    let permissions: Permissions

    var body: some View {
        let state = permissions.state(for: kind)
        HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.system(size: 16))
                .frame(width: 22)
                .foregroundStyle(state == .granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(.system(size: 12, weight: .medium))
                Text(kind.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if state == .granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(state == .denied ? "Open Settings" : "Allow") {
                    if state == .denied {
                        permissions.openSystemSettings(for: kind)
                    } else {
                        Task { await permissions.request(kind) }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search titles and transcripts", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
    }
}

/// Makes empty header space drag the window (the title bar is transparent and hidden).
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
    }
}
