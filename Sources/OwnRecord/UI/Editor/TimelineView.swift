import SwiftUI

/// Filmstrip with trim handles, playhead scrubbing and a subtitle lane.
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
                                model.player.pause()
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
                            model.player.pause()
                            model.setTrimStart(time(at: value.location.x, width: width))
                        }
                )
            TrimHandle(edge: .trailing)
                .frame(width: handleWidth, height: stripHeight)
                .offset(x: max(start + handleWidth, end - handleWidth))
                .highPriorityGesture(
                    DragGesture(coordinateSpace: .named("timeline"))
                        .onChanged { value in
                            model.player.pause()
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
                    .fill(cue.id == model.currentCueID ? Color.accentColor : Color.accentColor.opacity(0.4))
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
