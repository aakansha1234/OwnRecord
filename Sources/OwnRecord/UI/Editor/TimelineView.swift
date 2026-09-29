import SwiftUI

/// Filmstrip with sections, trim handles, playhead scrubbing and a subtitle lane.
struct TimelineView: View {
    @Bindable var model: EditorModel
    @State private var scrubbing = false

    private let stripHeight: CGFloat = 58
    private let handleWidth: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    filmstrip(width: width)
                    sectionsOverlay(width: width)
                    trimOverlay(width: width)
                    if let cues = model.recording.transcript?.cues, !cues.isEmpty {
                        cueLane(cues: cues, width: width)
                            .offset(y: stripHeight + 8)
                    }
                    playhead(width: width)
                }
                .coordinateSpace(name: "timeline")
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                        .onChanged { value in
                            if !scrubbing {
                                scrubbing = true
                                model.pauseForSeek()
                                endTextEditing()
                            }
                            model.seek(to: time(at: value.location.x, width: width))
                        }
                        .onEnded { _ in scrubbing = false }
                )
            }
            .frame(height: stripHeight + (model.recording.transcript == nil ? 0 : 26))

            ruler
        }
        .padding(.top, 4)
    }

    private func x(_ time: Double, width: CGFloat) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(time / model.duration) * width
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double((x / width).clamped(to: 0...1)) * model.duration
    }

    private func filmstrip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if model.thumbnails.isEmpty {
                Rectangle().fill(Color.primary.opacity(0.08))
            } else {
                ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(model.thumbnails.count), height: stripHeight)
                        .clipped()
                }
            }
        }
        .frame(width: width, height: stripHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Split lines, deleted sections (striped), per-section badges and the current section's outline.
    private func sectionsOverlay(width: CGFloat) -> some View {
        let sections = model.sections
        let current = model.currentSectionIndex
        return ZStack(alignment: .topLeading) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                let range = model.range(ofSectionAt: index)
                let start = x(range.lowerBound, width: width)
                let length = max(1, x(range.upperBound, width: width) - start)
                SectionBlock(section: section, width: length, height: stripHeight,
                             isCurrent: sections.count > 1 && index == current,
                             showsCameraBadge: model.hasCameraTrack, showsAudioBadge: model.recording.hasAudio)
                    .frame(width: length, height: stripHeight)
                    .offset(x: start)
                    .contextMenu { SectionMenu(model: model, sectionID: section.id) }
            }
            ForEach(sections.dropFirst()) { section in
                // A gap in the filmstrip marks each split.
                Rectangle()
                    .fill(Color(nsColor: .underPageBackgroundColor))
                    .frame(width: 3, height: stripHeight)
                    .offset(x: x(section.start, width: width) - 1.5)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: stripHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func trimOverlay(width: CGFloat) -> some View {
        let start = x(model.trimStart, width: width)
        let end = x(model.trimEnd, width: width)
        return ZStack(alignment: .topLeading) {
            // Dim the parts that won't be exported.
            Rectangle().fill(Color.black.opacity(0.55))
                .frame(width: max(0, start), height: stripHeight)
            Rectangle().fill(Color.black.opacity(0.55))
                .frame(width: max(0, width - end), height: stripHeight)
                .offset(x: end)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.yellow, lineWidth: 3)
                .frame(width: max(handleWidth * 2, end - start), height: stripHeight)
                .offset(x: start)
                .allowsHitTesting(false)

            TrimHandle(edge: .leading)
                .frame(width: handleWidth, height: stripHeight)
                .offset(x: start)
                .highPriorityGesture(
                    DragGesture(coordinateSpace: .named("timeline"))
                        .onChanged { value in
                            model.pauseForSeek()
                            model.setTrimStart(time(at: value.location.x, width: width))
                        }
                )
            TrimHandle(edge: .trailing)
                .frame(width: handleWidth, height: stripHeight)
                .offset(x: max(start + handleWidth, end - handleWidth))
                .highPriorityGesture(
                    DragGesture(coordinateSpace: .named("timeline"))
                        .onChanged { value in
                            model.pauseForSeek()
                            model.setTrimEnd(time(at: value.location.x, width: width))
                        }
                )
        }
    }

    private func cueLane(cues: [SubtitleCue], width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05))
                .frame(width: width, height: 18)
            ForEach(cues) { cue in
                let start = x(cue.start, width: width)
                let length = max(3, x(cue.end, width: width) - start)
                RoundedRectangle(cornerRadius: 3)
                    .fill(model.isCut(cue) ? Color.secondary.opacity(0.25)
                          : cue.id == model.currentCueID ? Color.accentColor : Color.accentColor.opacity(0.4))
                    .frame(width: length, height: 18)
                    .overlay(alignment: .leading) {
                        if length > 40 {
                            Text(cue.text)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                        }
                    }
                    .clipped()
                    .offset(x: start)
                    .help(cue.text)
            }
        }
        .allowsHitTesting(false)
    }

    private func playhead(width: CGFloat) -> some View {
        let position = x(model.currentTime, width: width)
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.white)
                .frame(width: 2)
                .shadow(color: .black.opacity(0.6), radius: 1)
            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .shadow(color: .black.opacity(0.4), radius: 1)
                .offset(y: -5)
        }
        .frame(height: stripHeight + (model.recording.transcript == nil ? 0 : 26))
        .offset(x: position - 1)
        .allowsHitTesting(false)
    }

    private var ruler: some View {
        HStack {
            ForEach(0..<5) { index in
                let time = model.duration * Double(index) / 4
                Text(model.duration < 20 ? TimeFormat.precise(time) : TimeFormat.clock(time))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                if index < 4 { Spacer() }
            }
        }
    }
}

private struct TrimHandle: View {
    let edge: HorizontalEdge

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: edge == .leading ? 6 : 0, bottomLeadingRadius: edge == .leading ? 6 : 0,
            bottomTrailingRadius: edge == .trailing ? 6 : 0, topTrailingRadius: edge == .trailing ? 6 : 0,
            style: .continuous
        )
        .fill(Color.yellow)
        .overlay(
            Capsule().fill(Color.black.opacity(0.5)).frame(width: 2, height: 18)
        )
        .contentShape(Rectangle().inset(by: -6))
        .pointerStyle(.frameResize(position: edge == .leading ? .leading : .trailing))
        .help(edge == .leading ? "Drag to trim the start" : "Drag to trim the end")
    }
}

/// One section on the filmstrip.
private struct SectionBlock: View {
    let section: TimelineSection
    let width: CGFloat
    let height: CGFloat
    let isCurrent: Bool
    let showsCameraBadge: Bool
    let showsAudioBadge: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if section.isDeleted {
                Rectangle().fill(Color.black.opacity(0.62))
                Stripes().stroke(Color.white.opacity(0.14), lineWidth: 1.5)
                if width > 28 {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if !badges.isEmpty, width > 26 {
                HStack(spacing: 3) {
                    ForEach(badges, id: \.self) { symbol in
                        Image(systemName: symbol)
                    }
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.orange.opacity(0.9)))
                .padding(7)
            }
            if isCurrent {
                // Inset so it stays visible inside the yellow trim frame.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white, lineWidth: 2)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 5)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .help(help)
    }

    private var badges: [String] {
        var symbols: [String] = []
        if !section.showsScreen { symbols.append("rectangle.slash") }
        if showsCameraBadge, !section.showsCamera { symbols.append("video.slash") }
        if showsAudioBadge, section.mutesAudio { symbols.append("speaker.slash") }
        return symbols
    }

    private var help: String {
        if section.isDeleted { return "Deleted section. Right-click to restore it." }
        var parts: [String] = []
        if !section.showsScreen { parts.append("screen hidden") }
        if showsCameraBadge, !section.showsCamera { parts.append("camera hidden") }
        if showsAudioBadge, section.mutesAudio { parts.append("muted") }
        return parts.isEmpty ? "Right-click for section options" : parts.joined(separator: ", ").capitalizedFirst
    }
}

private struct Stripes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 9
        }
        return path
    }
}

/// Right-click menu for a section on the timeline.
struct SectionMenu: View {
    @Bindable var model: EditorModel
    let sectionID: TimelineSection.ID

    var body: some View {
        if let index = model.sections.firstIndex(where: { $0.id == sectionID }) {
            let section = model.sections[index]
            Button(section.isDeleted ? "Restore Section" : "Delete Section") { model.toggleDeleted(sectionID) }
            Divider()
            Button(section.showsScreen ? "Hide Screen" : "Show Screen") { model.toggleScreen(sectionID) }
            if model.hasCameraTrack {
                Button(section.showsCamera ? "Hide Camera" : "Show Camera") { model.toggleCamera(sectionID) }
                Menu("Camera Position") {
                    ForEach(CameraPosition.corners) { corner in
                        Button(corner.title) { model.setCameraCorner(corner, for: sectionID) }
                    }
                }
            }
            if model.recording.hasAudio {
                Button(section.mutesAudio ? "Unmute Audio" : "Mute Audio") { model.toggleMute(sectionID) }
            }
            Divider()
            Button("Join with Previous Section") { model.joinWithPrevious(sectionID) }
                .disabled(index == 0)
            Button("Join with Next Section") { model.joinWithNext(sectionID) }
                .disabled(index + 1 >= model.sections.count)
            Button("Reset Section") { model.resetSection(sectionID) }
                .disabled(!section.isCustomized || section.isDeleted)
        }
    }
}

/// Ends editing in a text field so the editor's single-key shortcuts work again.
@MainActor
func endTextEditing() {
    if let window = NSApp.keyWindow, window.firstResponder is NSText {
        window.makeFirstResponder(nil)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
