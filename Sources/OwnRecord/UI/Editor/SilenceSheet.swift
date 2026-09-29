import SwiftUI

/// Finds pauses in the recording's audio and splits (and optionally removes) them.
struct SilenceSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let pauses = model.silencePauses
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Split at Silences").font(.system(size: 17, weight: .semibold))
                Text(sourceDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)

            Group {
                switch model.silenceAnalysis {
                case .idle, .analyzing:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Measuring the audio…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 90)
                case .failed(let message):
                    Label("Couldn't read the audio: \(message)", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, minHeight: 90)
                case .ready(let levels):
                    LevelGraph(levels: levels, threshold: model.silenceThreshold, pauses: pauses,
                               kept: model.recording.edit.keptRanges(duration: model.duration, applyingTrim: true),
                               duration: model.duration)
                        .frame(height: 90)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom, spacing: 10) {
                    SliderRow(title: "Silence is quieter than", value: $model.silenceThreshold, range: -70...(-20),
                              format: { "\(Int($0.rounded())) dB" })
                    Button("Auto") { model.silenceSettings.threshold = nil }
                        .controlSize(.small)
                        .disabled(model.silenceSettings.threshold == nil)
                        .help("Use the level measured for this recording")
                }
                SliderRow(title: "Shortest pause", value: $model.silenceSettings.minimumDuration, range: 0.3...3,
                          format: { String(format: "%.1f s", $0) })
                SliderRow(title: "Keep before and after speech", value: $model.silenceSettings.padding, range: 0...0.5,
                          format: { String(format: "%.2f s", $0) })
                Toggle("Delete the pauses", isOn: $model.silenceSettings.deletesPauses)
                    .font(.system(size: 12))
                Text(model.silenceSettings.deletesPauses
                     ? "Each pause becomes its own deleted section. Restore any of them with ⌫, or undo with ⌘Z."
                     : "Each pause becomes its own section, ready to delete with ⌫ or to change.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .disabled(!isReady)

            Divider()
            HStack(spacing: 10) {
                Text(summary(pauses))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle(pauses.count)) { model.cutSilences() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(pauses.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560)
    }

    private var isReady: Bool {
        if case .ready = model.silenceAnalysis { return true }
        return false
    }

    private var sourceDescription: String {
        switch model.silenceTrack {
        case .microphone: "Finds pauses in your microphone audio and splits the video around them."
        case .system: "Finds pauses in the system audio and splits the video around them."
        case nil: "This recording has no audio."
        }
    }

    private func summary(_ pauses: [Range<Double>]) -> String {
        guard isReady else { return "" }
        guard !pauses.isEmpty else { return "No pauses found with these settings." }
        let total = pauses.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        let count = pauses.count == 1 ? "1 pause" : "\(pauses.count) pauses"
        return model.silenceSettings.deletesPauses
            ? "\(count) · the video gets \(TimeFormat.length(total)) shorter"
            : "\(count) · \(TimeFormat.length(total)) in total"
    }

    private func actionTitle(_ count: Int) -> String {
        let pauses = count == 1 ? "1 Pause" : "\(count) Pauses"
        guard count > 0 else { return model.silenceSettings.deletesPauses ? "Remove Pauses" : "Split" }
        return model.silenceSettings.deletesPauses ? "Remove \(pauses)" : "Split at \(pauses)"
    }
}

/// The recording's loudness over time, with the threshold and the pauses found.
private struct LevelGraph: View {
    let levels: AudioLevels
    let threshold: Double
    let pauses: [Range<Double>]
    /// Recording-time ranges that are in the video; the rest is dimmed.
    let kept: [Range<Double>]
    let duration: Double

    private static let quietest = -70.0

    var body: some View {
        Canvas { context, size in
            let total = max(duration, levels.duration, 0.001)
            func x(_ time: Double) -> CGFloat { CGFloat(time / total) * size.width }
            func height(_ decibels: Double) -> CGFloat {
                CGFloat(((decibels - Self.quietest) / -Self.quietest).clamped(to: 0...1)) * size.height / 2
            }
            let mid = size.height / 2

            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8),
                         with: .color(.primary.opacity(0.05)))
            for pause in pauses {
                let rect = CGRect(x: x(pause.lowerBound), y: 0, width: max(1, x(pause.upperBound) - x(pause.lowerBound)),
                                  height: size.height)
                context.fill(Path(rect), with: .color(.orange.opacity(0.28)))
            }

            // One bar per point column: the loudest window in it.
            let columns = max(1, Int(size.width))
            let decibels = levels.decibels
            var bars = Path()
            for column in 0..<columns {
                let start = Int(Double(column) / Double(columns) * total / AudioLevels.windowDuration)
                let end = min(decibels.count, max(start + 1, Int(Double(column + 1) / Double(columns) * total / AudioLevels.windowDuration)))
                guard start < end else { continue }
                let loudest = Double(decibels[start..<end].max() ?? AudioLevels.floor)
                let h = max(0.5, height(loudest))
                bars.addRect(CGRect(x: CGFloat(column), y: mid - h, width: 1, height: h * 2))
            }
            context.fill(bars, with: .color(.primary.opacity(0.55)))

            // Parts that aren't in the video.
            var cursor = 0.0
            for range in kept + [total..<total] {
                if range.lowerBound > cursor + 1e-6 {
                    context.fill(Path(CGRect(x: x(cursor), y: 0, width: x(range.lowerBound) - x(cursor), height: size.height)),
                                 with: .color(.black.opacity(0.45)))
                }
                cursor = max(cursor, range.upperBound)
            }

            let level = height(threshold)
            var line = Path()
            for y in [mid - level, mid + level] {
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(line, with: .color(.orange), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Audio levels with \(pauses.count) pauses marked")
    }
}
