import AppKit
import SwiftUI

/// Borderless floating panel used for the recorder, camera bubble, control bar and countdown.
final class OverlayPanel: NSPanel {
    init(level: NSWindow.Level = .floating, activating: Bool = false) {
        var style: NSWindow.StyleMask = [.borderless]
        if !activating { style.insert(.nonactivatingPanel) }
        super.init(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
        isFloatingPanel = true
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Hosts a SwiftUI view that drives the panel's size.
    func host<Content: View>(_ view: Content) {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        contentViewController = controller
        setContentSize(controller.view.fittingSize)
    }
}

/// Behind-window blur for SwiftUI views hosted in transparent panels.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// A standard titled window hosting SwiftUI content with a transparent, full-size title bar.
@MainActor
func makeContentWindow<Content: View>(title: String, size: NSSize, minSize: NSSize, autosaveName: String,
                                      content: Content) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.title = title
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.minSize = minSize
    window.contentView = NSHostingView(rootView: content)
    window.center()
    window.setFrameAutosaveName(autosaveName)
    return window
}
