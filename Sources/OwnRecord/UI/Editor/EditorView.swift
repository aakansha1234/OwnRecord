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
            .sheet(isPresented: $model.isSilenceSheetPresented) {
                SilenceSheet(model: model)
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
                    .onTapGesture {
                        endTextEditing()
                        model.selectRedaction(nil)
                    }

                let section = model.currentSection
                if model.loadState == .ready, section.isDeleted, !model.isPlaying {
                    DeletedSectionOverlay(model: model)
                        .frame(width: stage.width, height: stage.height)
                        .position(x: stage.midX, y: stage.midY)
                } else if model.loadState == .ready, model.hasCameraTrack, section.showsCamera, section.showsScreen,
                          model.drawingRedaction == nil {
                    CameraDragHandle(model: model, stage: stage)
                }
                if model.loadState == .ready, model.canRedact, !model.isPlaying {
                    RedactionLayer(model: model, screen: screenFrame(in: stage))
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
            .coordinateSpace(name: "preview")
        }
        .frame(minHeight: 300)
    }

    /// Where the screen recording appears in the preview.
    private func screenFrame(in stage: CGRect) -> CGRect {
        let canvas = model.canvasSize
        let scale = stage.width / max(canvas.width, 1)
        let rect = LayoutEngine.layout(canvas: canvas, source: model.sourceSize, edit: model.recording.edit,
                                       hasCamera: false).screenRect
        return CGRect(x: stage.minX + rect.minX * scale, y: stage.minY + rect.minY * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }
}

// MARK: - Blurred areas

/// Outlines and handles for the blurred areas of the section at the playhead, and the surface
/// for dragging out a new one. Coordinates are in the "preview" space.
private struct RedactionLayer: View {
    @Bindable var model: EditorModel
    let screen: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.currentRedactions.enumerated()), id: \.element.id) { index, redaction in
                RedactionBox(model: model, redaction: redaction, number: index + 1, screen: screen,
                             isSelected: model.selectedRedaction?.id == redaction.id)
                    .allowsHitTesting(model.drawingRedaction == nil)
            }
            if let style = model.drawingRedaction {
                RedactionDrawingSurface(model: model, style: style, screen: screen)
            }
        }
    }
}

private struct RedactionBox: View {
    @Bindable var model: EditorModel
    let redaction: Redaction
    let number: Int
    let screen: CGRect
    let isSelected: Bool
    @State private var hovering = false
    /// The area's rect when the current drag began.
    @State private var dragStart: CGRect?

    private enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var isLeading: Bool { self == .topLeading || self == .bottomLeading }
        var isTop: Bool { self == .topLeading || self == .topTrailing }

        var pointer: FrameResizePosition {
            switch self {
            case .topLeading: .topLeading
            case .topTrailing: .topTrailing
            case .bottomLeading: .bottomLeading
            case .bottomTrailing: .bottomTrailing
            }
        }
    }

    var body: some View {
        let frame = viewRect(redaction.rect)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .overlay(
                    Rectangle().strokeBorder(
                        isSelected ? Color.accentColor : Color.white.opacity(hovering ? 0.95 : 0.55),
                        style: StrokeStyle(lineWidth: isSelected ? 2 : 1.5, dash: isSelected ? [] : [5, 4]))
                )
                .shadow(color: .black.opacity(0.4), radius: 1)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .onHover { hovering = $0 }
                .pointerStyle(.grabIdle)
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named("preview"))
                        .onChanged { value in
                            let start = beginDrag()
                            var rect = start
                            rect.origin.x += value.translation.width / screen.width
                            rect.origin.y += value.translation.height / screen.height
                            model.setRedactionRect(rect, for: redaction.id, resizing: false)
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .onTapGesture { model.selectRedaction(redaction.id) }
                .contextMenu { menu }
                .help("\(redaction.style.noun) \(number). Drag to move; right-click for options.")
                .accessibilityLabel("\(redaction.style.noun) \(number)")

            if isSelected {
                ForEach(Corner.allCases, id: \.self) { corner in
                    handle(corner, frame: frame)
                }
            }
        }
    }

    private func handle(_ corner: Corner, frame: CGRect) -> some View {
        Rectangle()
            .fill(Color.white)
            .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            .frame(width: 9, height: 9)
            .contentShape(Rectangle().inset(by: -5))
            .position(x: corner.isLeading ? frame.minX : frame.maxX, y: corner.isTop ? frame.minY : frame.maxY)
            .pointerStyle(.frameResize(position: corner.pointer))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("preview"))
                    .onChanged { value in
                        let start = beginDrag()
                        let dx = value.translation.width / screen.width
                        let dy = value.translation.height / screen.height
                        let side = Redaction.minimumSide
                        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
                        if corner.isLeading {
                            minX = min(max(0, start.minX + dx), maxX - side)
                        } else {
                            maxX = max(min(1, start.maxX + dx), minX + side)
                        }
                        if corner.isTop {
                            minY = min(max(0, start.minY + dy), maxY - side)
                        } else {
                            maxY = max(min(1, start.maxY + dy), minY + side)
                        }
                        model.setRedactionRect(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                                               for: redaction.id, resizing: true)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }

    @ViewBuilder private var menu: some View {
        ForEach(RedactionStyle.allCases) { style in
            Button(style.title) { model.setRedactionStyle(style, for: redaction.id) }
                .disabled(redaction.style == style)
        }
        if model.hasMultipleSections {
            Divider()
            Button("Apply to All Sections") { model.applyRedactionToAllSections(redaction.id) }
                .disabled(model.redactionIsInAllSections(redaction))
        }
        Divider()
        Button("Delete \(redaction.style.noun)") { model.deleteRedaction(redaction.id) }
    }

    private func beginDrag() -> CGRect {
        if let dragStart { return dragStart }
        dragStart = redaction.rect
        model.selectRedaction(redaction.id)
        return redaction.rect
    }

    private func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(x: screen.minX + rect.minX * screen.width, y: screen.minY + rect.minY * screen.height,
               width: rect.width * screen.width, height: rect.height * screen.height)
    }
}

/// Dims the screen while drawing a new area; drag out a rectangle, or click for a default-sized one.
private struct RedactionDrawingSurface: View {
    @Bindable var model: EditorModel
    let style: RedactionStyle
    let screen: CGRect
    @State private var start: CGPoint?
    @State private var current: CGPoint?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.black.opacity(0.25))
                .frame(width: screen.width, height: screen.height)
                .position(x: screen.midX, y: screen.midY)
                .pointerStyle(.rectSelection)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("preview"))
                        .onChanged { value in
                            if start == nil { start = clamped(value.startLocation) }
                            current = clamped(value.location)
                        }
                        .onEnded { value in
                            finish(from: start ?? clamped(value.startLocation), to: clamped(value.location))
                            start = nil
                            current = nil
                        }
                )
                .accessibilityLabel("Drag to choose the area to \(style == .blur ? "blur" : "pixelate")")

            if let start, let current {
                let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                                  width: abs(current.x - start.x), height: abs(current.y - start.y))
                Rectangle()
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x.clamped(to: screen.minX...screen.maxX), y: point.y.clamped(to: screen.minY...screen.maxY))
    }

    private func finish(from start: CGPoint, to end: CGPoint) {
        guard screen.width > 0, screen.height > 0 else { return }
        var rect = CGRect(x: (min(start.x, end.x) - screen.minX) / screen.width,
                          y: (min(start.y, end.y) - screen.minY) / screen.height,
                          width: abs(end.x - start.x) / screen.width,
                          height: abs(end.y - start.y) / screen.height)
        if abs(end.x - start.x) < 6, abs(end.y - start.y) < 6 {
            // A click: a field-sized area centered on it.
            let size = CGSize(width: 0.22, height: 0.07)
            rect = CGRect(x: rect.minX - size.width / 2, y: rect.minY - size.height / 2,
                          width: size.width, height: size.height)
        }
        model.finishRedaction(rect: rect)
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
            switch hint.action {
            case .applyCameraToAllSections:
                Button("Apply to All Sections") { model.applyCameraToAllSections() }
                    .controlSize(.small)
                    .help("Use this camera shape, position and size in every section")
            case .applyRedactionToAllSections(let id):
                Button("Apply to All Sections") { model.applyRedactionToAllSections(id) }
                    .controlSize(.small)
                    .help("Blur this area in every section")
            case nil:
                EmptyView()
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
            case .finished(let url, let clips) where !clips.isEmpty:
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Ready for iMovie")
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize()
                        .help("Drag the clips into your iMovie project, or import them with File › Import Media")
                    ForEach(clips, id: \.url) { clip in
                        ClipChip(clip: clip)
                    }
                    if let iMovie = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iMovieApp") {
                        Button("Open iMovie") {
                            NSWorkspace.shared.openApplication(at: iMovie, configuration: NSWorkspace.OpenConfiguration())
                        }
                        .controlSize(.small)
                        .help("Then drag the clips into your iMovie project, or use File › Import Media")
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(clips.map(\.url)) }
                        .controlSize(.small)
                        .help(url.path)
                    Button {
                        model.dismissExportStatus()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .statusCapsule()
            case .finished(let url, _):
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

/// An exported clip that can be dragged straight into iMovie (or anywhere that takes files).
private struct ClipChip: View {
    let clip: ExportedClip

    var body: some View {
        Label(clip.kind.title, systemImage: clip.kind.symbol)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.14)))
            .fixedSize()
            .onDrag { NSItemProvider(contentsOf: clip.url) ?? NSItemProvider() }
            .pointerStyle(.grabIdle)
            .help("Drag \(clip.url.lastPathComponent) into iMovie")
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
