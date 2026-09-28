import AppKit
@preconcurrency import AVFoundation
import SwiftUI

/// Floating, draggable live camera preview shown while setting up and during recording.
///
/// It's excluded from the screen capture; the camera is recorded separately and composited
/// in the editor. Where the user leaves the bubble becomes the overlay's initial position.
@MainActor
final class CameraBubbleController {
    private let camera: CameraCapture
    private let preferences: Preferences
    private var panel: OverlayPanel?

    init(camera: CameraCapture, preferences: Preferences) {
        self.camera = camera
        self.preferences = preferences
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        if panel == nil {
            let panel = OverlayPanel(level: .floating)
            panel.isMovableByWindowBackground = true
            panel.contentView = NSHostingView(rootView: CameraBubbleView(session: camera.session, preferences: preferences))
            let size = bubbleSize()
            let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            panel.setFrame(NSRect(x: visible.maxX - size.width - 40, y: visible.minY + 40,
                                  width: size.width, height: size.height), display: false)
            self.panel = panel
            observeContinuously({ [weak self] in
                _ = self?.preferences.bubbleSize
                _ = self?.preferences.cameraStyle.shape
            }, onChange: { [weak self] in self?.applySize() })
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func bubbleSize() -> CGSize {
        let height = preferences.bubbleSize.points
        return CGSize(width: height * preferences.cameraStyle.shape.aspectRatio, height: height)
    }

    /// Resizes around the corner nearest to the screen edge so the bubble stays put.
    private func applySize() {
        guard let panel else { return }
        let size = bubbleSize()
        let old = panel.frame
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? old
        let anchorRight = old.midX > visible.midX
        let anchorTop = old.midY > visible.midY
        let x = anchorRight ? old.maxX - size.width : old.minX
        let y = anchorTop ? old.maxY - size.height : old.minY
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true, animate: true)
        panel.invalidateShadow()
    }

    /// Camera overlay settings that reproduce where the bubble sits relative to the captured area.
    func overlayStyle(relativeTo captureFrame: CGRect, base: CameraOverlayStyle) -> CameraOverlayStyle {
        var style = base
        style.shape = preferences.cameraStyle.shape
        style.mirror = preferences.cameraStyle.mirror
        guard let bubble = panel?.frame, panel?.isVisible == true, captureFrame.width > 0, captureFrame.height > 0,
              captureFrame.contains(CGPoint(x: bubble.midX, y: bubble.midY)) else { return style }

        let minSide = min(captureFrame.width, captureFrame.height)
        style.size = Double(bubble.height / minSide).clamped(to: 0.1...0.5)
        let center = CGPoint(x: (bubble.midX - captureFrame.minX) / captureFrame.width,
                             y: (captureFrame.maxY - bubble.midY) / captureFrame.height)
        if let corner = LayoutEngine.snappedCorner(for: center, style: style, canvas: captureFrame.size) {
            style.position = corner
        } else {
            style.position = .custom
            style.customX = Double(center.x)
            style.customY = Double(center.y)
        }
        return style
    }
}

private struct CameraBubbleView: View {
    let session: AVCaptureSession
    @Bindable var preferences: Preferences
    @State private var hovering = false

    var body: some View {
        let shape = preferences.cameraStyle.shape
        let height = preferences.bubbleSize.points
        let size = CGSize(width: height * shape.aspectRatio, height: height)
        let radius = shape.cornerRadius(for: size)

        ZStack(alignment: .bottom) {
            CameraPreview(session: session, mirrored: preferences.cameraStyle.mirror, cornerRadius: radius)
            RoundedRectangle(cornerRadius: radius, style: .circular)
                .strokeBorder(.white.opacity(0.95), lineWidth: 3)
                .allowsHitTesting(false)
            if hovering {
                controls
                    .padding(.bottom, max(8, height * 0.08))
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { self.hovering = hovering }
        }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            BubbleButton(symbol: nextShape.symbol, help: "Shape: \(nextShape.title)") {
                preferences.cameraStyle.shape = nextShape
            }
            BubbleButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Size: \(preferences.bubbleSize.next.title)") {
                preferences.bubbleSize = preferences.bubbleSize.next
            }
            BubbleButton(symbol: "arrow.left.and.right", help: preferences.cameraStyle.mirror ? "Don't mirror" : "Mirror") {
                preferences.cameraStyle.mirror.toggle()
            }
        }
        .padding(3)
        .background(.black.opacity(0.6), in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private var nextShape: CameraShape {
        let all = CameraShape.allCases
        let index = all.firstIndex(of: preferences.cameraStyle.shape) ?? 0
        return all[(index + 1) % all.count]
    }
}

private struct BubbleButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Live camera preview backed by AVCaptureVideoPreviewLayer.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView(session: session)
    }

    func updateNSView(_ view: CameraPreviewNSView, context: Context) {
        view.mirrored = mirrored
        view.cornerRadius = cornerRadius
    }
}

final class CameraPreviewNSView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    var mirrored = true {
        didSet { needsLayout = true }
    }

    var cornerRadius: CGFloat = 0 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.bounds = bounds
        previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        previewLayer.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        CATransaction.commit()
    }
}
