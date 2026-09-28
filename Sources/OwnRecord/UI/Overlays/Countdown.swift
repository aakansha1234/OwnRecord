import AppKit
import SwiftUI

@MainActor
final class CountdownController {
    private unowned let controller: RecordingController
    private var panel: OverlayPanel?

    init(controller: RecordingController) {
        self.controller = controller
    }

    func show(_ value: Int, on screen: NSScreen?) {
        if panel == nil {
            let panel = OverlayPanel(level: .statusBar)
            panel.hasShadow = false
            panel.host(CountdownView(controller: controller))
            self.panel = panel
        }
        guard let panel, let frame = (screen ?? NSScreen.main)?.frame else { return }
        let size = panel.frame.size
        if !panel.isVisible || panel.screen != screen {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct CountdownView: View {
    let controller: RecordingController

    var body: some View {
        VStack(spacing: 4) {
            Text(value.map(String.init) ?? "")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: value)
            Text("Click to start now")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 200, height: 200)
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture { controller.skipCountdownNow() }
    }

    private var value: Int? {
        if case .countdown(let value) = controller.phase { return value }
        return nil
    }
}

/// Non-interactive outline around the area being recorded. Excluded from the capture.
@MainActor
final class AreaFrameIndicator {
    private var panel: OverlayPanel?

    func show(around rect: CGRect) {
        if panel == nil {
            let panel = OverlayPanel(level: .statusBar)
            panel.ignoresMouseEvents = true
            panel.hasShadow = false
            panel.contentView = NSHostingView(rootView: AreaFrameView())
            self.panel = panel
        }
        panel?.setFrame(rect.insetBy(dx: -3, dy: -3), display: true)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct AreaFrameView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            .foregroundStyle(Color.red.opacity(0.85))
    }
}
