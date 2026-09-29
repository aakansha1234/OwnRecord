@preconcurrency import AVFoundation
import SwiftUI

struct EditorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            EditorHeader(model: model)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PreviewStage(model: model)
                    Divider()
                    TransportBar(model: model)
                    TimelineView(model: model)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                InspectorView(model: model)
                    .frame(width: 320)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(edges: .top)
        .sheet(isPresented: $model.isExportSheetPresented) {
            ExportSheet(model: model)
        }
    }
}

// MARK: - Header

private struct EditorHeader: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 64)
            VStack(alignment: .leading, spacing: 1) {
                TextField("Title", text: $model.recording.title)
                    .onSubmit { endTextEditing() }
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: 420)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([model.files.screen])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show recording files in Finder")
            .accessibilityLabel("Show in Finder")
            Button {
                model.isExportSheetPresented = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("e", modifiers: .command)
            .disabled(model.loadState != .ready || isExporting)
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .background(WindowDragArea())
    }

    private var isExporting: Bool {
        if case .running = model.export { return true }
        return false
    }

    private var subtitle: String {
        let recording = model.recording
        return [recording.createdAt.formatted(date: .abbreviated, time: .shortened),
                TimeFormat.clock(model.loadState == .ready ? model.editedDuration : recording.editedDuration),
                "\(recording.pixelWidth) × \(recording.pixelHeight)",
                recording.sourceName].joined(separator: "  ·  ")
    }
}

// MARK: - Preview

private struct PreviewStage: View {
    @Bindable var model: EditorModel

    var body: some View {
        GeometryReader { geometry in
            let canvas = model.canvasSize
            let stage = CGRect.aspectFit(canvas, in: CGRect(origin: .zero, size: geometry.size).insetBy(dx: 28, dy: 24))
            ZStack(alignment: .topLeading) {
                PlayerLayerView(player: model.player)
                    .frame(width: stage.width, height: stage.height)
                    .background(Color.black)
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                    .position(x: stage.midX, y: stage.midY)
                    .onTapGesture { endTextEditing() }

                let section = model.currentSection
                if model.loadState == .ready, section.isDeleted, !model.isPlaying {
                    DeletedSectionOverlay(model: model)
                        .frame(width: stage.width, height: stage.height)
                        .position(x: stage.midX, y: stage.midY)
                } else if model.loadState == .ready, model.hasCameraTrack, section.showsCamera, section.showsScreen {
                    CameraDragHandle(model: model, stage: stage)
                }

                if let hint = model.hint {
                    HintView(model: model, hint: hint)
                        .frame(width: geometry.size.width)
                        .position(x: geometry.size.width / 2, y: max(28, stage.minY + 30))
                }

                switch model.loadState {
                case .loading:
                    ProgressView()
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                case .failed(let message):
                    ContentUnavailableView("Couldn't open recording", systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                case .ready:
                    EmptyView()
                }

                ExportStatusView(model: model)
                    .frame(width: geometry.size.width)
                    .position(x: geometry.size.width / 2, y: geometry.size.height - 44)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minHeight: 300)
    }
}

/// Invisible handle over the camera overlay so it can be dragged anywhere in the preview.
private struct CameraDragHandle: View {
    @Bindable var model: EditorModel
    let stage: CGRect
    @State private var hovering = false
    @State private var dragOrigin: CGPoint?

    var body: some View {
        let canvas = model.canvasSize
        let scale = stage.width / max(canvas.width, 1)
        let style = model.recording.edit.camera.with(model.currentCameraPlacement)
        let rect = LayoutEngine.cameraRect(style: style, canvas: canvas)
        let frame = CGRect(x: stage.minX + rect.minX * scale, y: stage.minY + rect.minY * scale,
                           width: rect.width * scale, height: rect.height * scale)
        let radius = style.shape.cornerRadius(for: frame.size)
        let active = hovering || dragOrigin != nil

        RoundedRectangle(cornerRadius: radius, style: .circular)
            .fill(Color.white.opacity(0.001))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .circular)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .opacity(active ? 1 : 0)
            )
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .onHover { hovering = $0 }
            .pointerStyle(.grabIdle)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let origin = dragOrigin ?? CGPoint(x: rect.midX, y: rect.midY)
                        if dragOrigin == nil { dragOrigin = origin }
                        let center = CGPoint(x: origin.x + value.translation.width / scale,
                                             y: origin.y + value.translation.height / scale)
                        model.moveCamera(to: CGPoint(x: center.x / canvas.width, y: center.y / canvas.height))
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                        model.finishMovingCamera()
                    }
            )
            .help(model.hasMultipleSections
                  ? "Drag to move the camera in this section. Release near a corner to snap."
                  : "Drag to move the camera. Release near a corner to snap.")
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Transport

private struct TransportBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 14) {
            Button {
                model.goToStart()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(.borderless)
            .help("Go to start (Home)")
            .accessibilityLabel("Go to Start")

            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Play/Pause (Space)")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            Text("\(TimeFormat.precise(model.editedTime)) / \(TimeFormat.precise(model.editedDuration))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            if model.isTrimmed {
                Button("Reset Trim") { model.resetTrim() }
                    .controlSize(.small)
                    .help("Trimmed \(TimeFormat.precise(model.trimStart)) – \(TimeFormat.precise(model.trimEnd))")
            }
            if model.hasMultipleSections {
                Text("Section \(model.currentSectionIndex + 1) of \(model.sections.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else if !model.isTrimmed {
                Text("Press S to split")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            SectionToolbar(model: model)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Split, delete and per-section visibility controls. They act on the section under the playhead.
private struct SectionToolbar: View {
    @Bindable var model: EditorModel

    var body: some View {
        let section = model.currentSection
        HStack(spacing: 2) {
            ToolButton(model: model, command: .split, symbol: "scissors")
            ToolButton(model: model, command: .deleteSection,
                       symbol: section.isDeleted ? "arrow.uturn.backward" : "trash", isOff: section.isDeleted)
            Divider().frame(height: 18).padding(.horizontal, 5)
            ToolButton(model: model, command: .toggleScreen,
                       symbol: section.showsScreen ? "display" : "rectangle.slash", isOff: !section.showsScreen)
            if model.hasCameraTrack {
                ToolButton(model: model, command: .toggleCamera,
                           symbol: section.showsCamera ? "video" : "video.slash", isOff: !section.showsCamera)
            }
            if model.recording.hasAudio {
                ToolButton(model: model, command: .toggleAudio,
                           symbol: section.mutesAudio ? "speaker.slash" : "speaker.wave.2", isOff: section.mutesAudio)
            }
            Divider().frame(height: 18).padding(.horizontal, 5)
            ToolButton(model: model, command: .showShortcuts, symbol: "keyboard")
                .popover(isPresented: $model.isShortcutsPresented, arrowEdge: .bottom) {
                    ShortcutsView()
                }
        }
        .disabled(model.loadState != .ready)
    }
}

private struct ToolButton: View {
    @Bindable var model: EditorModel
    let command: EditorCommand
    let symbol: String
    var isOff = false
    @State private var hovering = false

    var body: some View {
        let title = command.title(for: model)
        Button {
            command.perform(on: model)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundStyle(isOff ? Color.orange : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOff ? Color.orange.opacity(0.16) : Color.primary.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(!command.isEnabled(for: model))
        .help(command.shortcutLabel.map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(title)
    }
}

/// Keyboard shortcut reference, built from the editor's commands.
struct ShortcutsView: View {
    private let extras: [(title: String, shortcut: String)] = [
        ("Undo", "⌘Z"), ("Redo", "⇧⌘Z"), ("Export", "⌘E"), ("Keyboard shortcuts", "⌘/"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 13, weight: .semibold))
            Text("Section commands apply to the section under the playhead.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    group(.sections)
                    group(.camera)
                }
                VStack(alignment: .leading, spacing: 14) {
                    group(.playback)
                    group(.trim)
                    VStack(alignment: .leading, spacing: 5) {
                        header("General")
                        ForEach(extras, id: \.title) { row($0.title, $0.shortcut) }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    private func group(_ group: EditorCommand.Group) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            header(group.rawValue)
            ForEach(EditorCommand.allCases.filter { $0.group == group && $0.shortcutLabel != nil && $0 != .showShortcuts },
                    id: \.self) { command in
                row(command.summary, command.shortcutLabel ?? "")
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }

    private func row(_ title: String, _ shortcut: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer(minLength: 16)
            Text(shortcut)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
        }
        .frame(width: 250)
    }
}

// MARK: - Section overlays

private struct DeletedSectionOverlay: View {
    @Bindable var model: EditorModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
            VStack(spacing: 8) {
                Image(systemName: "trash")
                    .font(.system(size: 22, weight: .medium))
                Text("This section is deleted")
                    .font(.system(size: 14, weight: .semibold))
                Text("It won't appear in the video.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                Button("Restore Section") { model.toggleDeleted() }
                    .controlSize(.regular)
                    .padding(.top, 4)
                    .help("Restore (⌫)")
            }
            .foregroundStyle(.white)
        }
        .environment(\.colorScheme, .dark)
    }
}

private struct HintView: View {
    @Bindable var model: EditorModel
    let hint: EditorModel.Hint

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
            Text(hint.message)
                .font(.system(size: 12, weight: .medium))
            if hint.offersApplyToAll {
                Button("Apply to All Sections") { model.applyCameraToAllSections() }
                    .controlSize(.small)
                    .help("Use this camera shape, position and size in every section")
            }
            Button {
                model.dismissHint()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .statusCapsule()
        .id(hint.id)
    }
}

// MARK: - Export status

private struct ExportStatusView: View {
    @Bindable var model: EditorModel

    var body: some View {
        Group {
            switch model.export {
            case .idle:
                EmptyView()
            case .running(let progress):
                HStack(spacing: 12) {
                    ProgressView(value: progress)
                        .frame(width: 180)
                    Text("Exporting… \(Int(progress * 100))%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                    Button("Cancel") { model.cancelExport() }
                        .controlSize(.small)
                }
                .statusCapsule()
            case .finished(let url):
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Exported \(url.lastPathComponent)")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .controlSize(.small)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([url as NSURL])
                    }
                    .controlSize(.small)
                    .help("Copy the file to paste into Slack, Mail, Finder…")
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        .controlSize(.small)
                    Button {
                        model.dismissExportStatus()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .statusCapsule()
            case .failed(let message):
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Export failed: \(message)")
                        .font(.system(size: 12))
                        .lineLimit(2)
                    Button("Dismiss") { model.dismissExportStatus() }
                        .controlSize(.small)
                }
                .statusCapsule()
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.export)
    }
}

private extension View {
    func statusCapsule() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(VisualEffectBackground(material: .hudWindow, blending: .withinWindow))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .environment(\.colorScheme, .dark)
            .shadow(radius: 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
