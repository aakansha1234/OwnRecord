import AppKit
import SwiftUI

/// Floating recording controls: timer, pause, restart, discard, stop.
@MainActor
final class ControlBarController {
    private unowned let controller: RecordingController
    private var panel: OverlayPanel?

    init(controller: RecordingController) {
        self.controller = controller
    }

    func show(on screen: NSScreen?) {
        if panel == nil {
            let panel = OverlayPanel(level: .statusBar)
            panel.isMovableByWindowBackground = true
            panel.host(ControlBarView(controller: controller))
            self.panel = panel
        }
        guard let panel, let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

struct ControlBarView: View {
    let controller: RecordingController
    @State private var discardArmed = false

    var body: some View {
        HStack(spacing: 6) {
            switch controller.phase {
            case .preparing, .countdown:
                countdownContent
            default:
                recordingContent
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 7)
        .frame(width: 360, height: 50)
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }

    private var countdownContent: some View {
        Group {
            ProgressView().controlSize(.small)
            if case .countdown(let value) = controller.phase {
                Text("Recording starts in \(value)…")
                    .font(.system(size: 13, weight: .medium))
                    .contentTransition(.numericText(countsDown: true))
            } else {
                Text("Preparing…").font(.system(size: 13, weight: .medium))
            }
            Spacer()
            Button("Start Now") { controller.skipCountdownNow() }
                .buttonStyle(.bordered)
                .disabled(controller.phase == .preparing)
            Button("Cancel") { controller.discard() }
                .buttonStyle(.bordered)
        }
    }

    private var recordingContent: some View {
        Group {
            HStack(spacing: 8) {
                RecordingIndicator(paused: controller.phase == .paused)
                Text(TimeFormat.clock(controller.elapsed))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(controller.phase == .paused ? .secondary : .primary)
                if AppModel.shared.recorder.microphoneID != nil {
                    LevelMeter(level: controller.microphoneLevel, bars: 5)
                        .frame(width: 22, height: 14)
                }
            }
            .gesture(WindowDragGesture())

            Spacer(minLength: 4)

            ControlButton(symbol: controller.phase == .paused ? "play.fill" : "pause.fill",
                          help: controller.phase == .paused ? "Resume (⌥⇧⌘P)" : "Pause (⌥⇧⌘P)",
                          accessibilityTitle: controller.phase == .paused ? "Resume" : "Pause") {
                controller.togglePause()
            }
            ControlButton(symbol: "arrow.counterclockwise", help: "Restart recording", accessibilityTitle: "Restart") {
                controller.restart()
            }
            ControlButton(symbol: discardArmed ? "trash.fill" : "trash",
                          help: discardArmed ? "Click again to discard" : "Discard recording",
                          accessibilityTitle: discardArmed ? "Confirm Discard" : "Discard",
                          tint: discardArmed ? .red : nil) {
                if discardArmed {
                    controller.discard()
                } else {
                    discardArmed = true
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        discardArmed = false
                    }
                }
            }

            Button {
                controller.stop()
            } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).frame(width: 9, height: 9)
                    Text("Stop").font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Color.red, in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Stop recording (⌥⇧⌘R)")
            .disabled(controller.phase == .finishing)
        }
    }
}

private struct ControlButton: View {
    let symbol: String
    let help: String
    var accessibilityTitle: String
    var tint: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? .primary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(accessibilityTitle)
    }
}

struct RecordingIndicator: View {
    let paused: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if paused {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.yellow)
            } else {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .opacity(pulse ? 0.45 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// Small bar-style audio level meter.
struct LevelMeter: View {
    let level: Float
    var bars = 8

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<bars, id: \.self) { index in
                    let threshold = Float(index) / Float(bars)
                    let active = level > threshold
                    RoundedRectangle(cornerRadius: 1)
                        .fill(active ? color(for: index) : Color.secondary.opacity(0.3))
                        .frame(height: geometry.size.height * (0.35 + 0.65 * CGFloat(index + 1) / CGFloat(bars)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .animation(.linear(duration: 0.08), value: level)
    }

    private func color(for index: Int) -> Color {
        let position = Double(index) / Double(max(1, bars - 1))
        return position > 0.85 ? .red : (position > 0.6 ? .yellow : .green)
    }
}
