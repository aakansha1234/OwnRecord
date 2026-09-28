import AppKit
import SwiftUI

/// Full-screen overlay for drawing, moving and resizing the area to record.
@MainActor
final class AreaSelectionController {
    enum Outcome {
        case confirmed(AreaSelection, startRecording: Bool)
        case cancelled
    }

    private var windows: [NSWindow] = []
    private var views: [AreaSelectionView] = []
    private var continuation: CheckedContinuation<Outcome, Never>?

    func select(initial: AreaSelection?) async -> Outcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            present(initial: initial)
        }
    }

    private func present(initial: AreaSelection?) {
        NSApp.activate()
        let mouseScreen = NSScreen.withMouse
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            let window = AreaSelectionWindow()
            window.setFrame(screen.frame, display: false)
            let view = AreaSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.displayID = displayID
            if let initial, initial.displayID == displayID {
                let rect = initial.rect.intersection(view.bounds)
                if rect.width >= 16, rect.height >= 16 { view.selection = rect }
            }
            view.onBeginInteraction = { [weak self, weak view] in
                self?.views.filter { $0 !== view }.forEach { $0.selection = nil }
            }
            view.onConfirm = { [weak self] rect, startRecording in
                self?.finish(.confirmed(AreaSelection(displayID: displayID, rect: rect), startRecording: startRecording))
            }
            view.onCancel = { [weak self] in self?.finish(.cancelled) }
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
            if screen == mouseScreen {
                window.makeKey()
                window.makeFirstResponder(view)
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

private final class AreaSelectionWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        // Above the menu bar and Dock, but below pop-up menus so the toolbar's menu shows.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
}

enum AspectLock: String, CaseIterable, Identifiable {
    case free, landscape, classic, square, portrait

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Freeform"
        case .landscape: "16:9"
        case .classic: "4:3"
        case .square: "1:1"
        case .portrait: "9:16"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .landscape: 16.0 / 9.0
        case .classic: 4.0 / 3.0
        case .square: 1
        case .portrait: 9.0 / 16.0
        }
    }
}

private final class AreaSelectionView: NSView {
    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum Drag {
        case create(start: CGPoint)
        case move(offset: CGSize)
        case resize(Handle, original: CGRect)
    }

    var displayID: CGDirectDisplayID = 0
    var selection: CGRect? {
        didSet {
            needsDisplay = true
            updateToolbar()
        }
    }
    var onBeginInteraction: (() -> Void)?
    var onConfirm: ((CGRect, Bool) -> Void)?
    var onCancel: (() -> Void)?

    private var drag: Drag?
    private var aspect: AspectLock = .free
    private var toolbar: NSHostingView<AreaToolbar>?
    private static let minimumSize: CGFloat = 32

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let rect = selection {
            dim.append(NSBezierPath(rect: rect))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()

        guard let rect = selection else {
            drawHint()
            return
        }

        let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.stroke()

        if drag == nil || isResizing {
            for handle in Handle.allCases {
                let point = self.point(for: handle, in: rect)
                let dot = NSBezierPath(ovalIn: NSRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
                NSColor.white.setFill()
                dot.fill()
                NSColor.black.withAlphaComponent(0.35).setStroke()
                dot.lineWidth = 1
                dot.stroke()
            }
        }

        if drag != nil {
            drawSizeLabel(for: rect)
        }
    }

    private var isResizing: Bool {
        if case .resize = drag { return true }
        return false
    }

    private func drawHint() {
        let text = "Drag to select an area  ·  Esc to cancel" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let pill = NSRect(x: bounds.midX - size.width / 2 - 16, y: bounds.midY - size.height / 2 - 10,
                          width: size.width + 32, height: size.height + 20)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: NSPoint(x: pill.minX + 16, y: pill.minY + 10), withAttributes: attributes)
    }

    private func drawSizeLabel(for rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        var origin = NSPoint(x: rect.minX, y: rect.minY - size.height - 12)
        if origin.y < 4 { origin.y = rect.minY + 6; origin.x += 6 }
        let pill = NSRect(x: origin.x, y: origin.y, width: size.width + 14, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        text.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + 3), withAttributes: attributes)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onBeginInteraction?()
        window?.makeFirstResponder(self)
        if event.clickCount == 2, let rect = selection, rect.contains(point) {
            onConfirm?(rect, true)
            return
        }
        if let rect = selection, let handle = handle(at: point, in: rect) {
            drag = .resize(handle, original: rect)
        } else if let rect = selection, rect.contains(point) {
            drag = .move(offset: CGSize(width: point.x - rect.minX, height: point.y - rect.minY))
        } else {
            drag = .create(start: point)
            selection = nil
        }
        updateToolbar()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamp(convert(event.locationInWindow, from: nil))
        switch drag {
        case .create(let start):
            selection = constrained(from: start, to: point)
        case .move(let offset):
            guard let rect = selection else { return }
            let x = (point.x - offset.width).clamped(to: 0...max(0, bounds.width - rect.width))
            let y = (point.y - offset.height).clamped(to: 0...max(0, bounds.height - rect.height))
            selection = CGRect(x: x, y: y, width: rect.width, height: rect.height)
        case .resize(let handle, let original):
            selection = resized(original, handle: handle, to: point)
        case nil:
            break
        }
        NSCursor.crosshair.set()
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        if let rect = selection, rect.width < Self.minimumSize || rect.height < Self.minimumSize {
            selection = nil
        }
        needsDisplay = true
        updateToolbar()
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: onCancel?() // Esc
        case 36, 76: // Return, Enter
            if let rect = selection { onConfirm?(rect, true) }
        default: super.keyDown(with: event)
        }
    }

    private func updateCursor(at point: CGPoint) {
        if let toolbar, toolbar.frame.contains(point) {
            NSCursor.arrow.set()
        } else if let rect = selection, let handle = handle(at: point, in: rect) {
            cursor(for: handle).set()
        } else if let rect = selection, rect.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func cursor(for handle: Handle) -> NSCursor {
        switch handle {
        case .topLeft: .frameResize(position: .topLeft, directions: .all)
        case .top: .frameResize(position: .top, directions: .all)
        case .topRight: .frameResize(position: .topRight, directions: .all)
        case .right: .frameResize(position: .right, directions: .all)
        case .bottomRight: .frameResize(position: .bottomRight, directions: .all)
        case .bottom: .frameResize(position: .bottom, directions: .all)
        case .bottomLeft: .frameResize(position: .bottomLeft, directions: .all)
        case .left: .frameResize(position: .left, directions: .all)
        }
    }

    // MARK: Geometry

    private func point(for handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        Handle.allCases.first { hypot(self.point(for: $0, in: rect).x - point.x, self.point(for: $0, in: rect).y - point.y) < 9 }
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x.clamped(to: 0...bounds.width), y: point.y.clamped(to: 0...bounds.height))
    }

    private func constrained(from start: CGPoint, to end: CGPoint) -> CGRect {
        var width = abs(end.x - start.x)
        var height = abs(end.y - start.y)
        if let ratio = aspect.ratio {
            if width / max(height, 1) > ratio { height = width / ratio } else { width = height * ratio }
        }
        let x = end.x >= start.x ? start.x : start.x - width
        let y = end.y >= start.y ? start.y : start.y - height
        return CGRect(x: x, y: y, width: width, height: height).intersection(bounds)
    }

    private func resized(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        }
        var result = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        if let ratio = aspect.ratio {
            switch handle {
            case .top, .bottom: result.size.width = result.height * ratio
            default: result.size.height = result.width / ratio
            }
            if handle == .topLeft || handle == .topRight || handle == .top {
                result.origin.y = rect.maxY - result.height
            }
            if handle == .topLeft || handle == .bottomLeft || handle == .left {
                result.origin.x = rect.maxX - result.width
            }
        }
        return result.intersection(bounds)
    }

    private func applyAspect(_ lock: AspectLock) {
        aspect = lock
        guard let ratio = lock.ratio, let rect = selection else {
            updateToolbar()
            return
        }
        var size = CGSize(width: rect.width, height: rect.width / ratio)
        if size.height > bounds.height { size = CGSize(width: bounds.height * ratio, height: bounds.height) }
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        selection = fitted(CGRect(origin: origin, size: size))
    }

    private func applyPreset(_ size: CGSize) {
        aspect = .free
        let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        selection = fitted(rect)
    }

    /// Moves `rect` inside the bounds, shrinking it if needed.
    private func fitted(_ rect: CGRect) -> CGRect {
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        let x = rect.minX.clamped(to: 0...(bounds.width - width))
        let y = rect.minY.clamped(to: 0...(bounds.height - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: Toolbar

    private func updateToolbar() {
        guard let rect = selection, drag == nil else {
            toolbar?.isHidden = true
            return
        }
        let content = AreaToolbar(
            size: rect.size,
            aspect: aspect,
            onAspect: { [weak self] in self?.applyAspect($0) },
            onPreset: { [weak self] in self?.applyPreset($0) },
            onCancel: { [weak self] in self?.onCancel?() },
            onConfirm: { [weak self] start in
                guard let self, let rect = self.selection else { return }
                self.onConfirm?(rect, start)
            })
        let toolbar: NSHostingView<AreaToolbar>
        if let existing = self.toolbar {
            existing.rootView = content
            toolbar = existing
        } else {
            toolbar = NSHostingView(rootView: content)
            addSubview(toolbar)
            self.toolbar = toolbar
        }
        toolbar.isHidden = false
        let size = toolbar.fittingSize
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.maxY + 12)
        if origin.y + size.height > bounds.height - 8 {
            origin.y = rect.minY - size.height - 12
            if origin.y < 8 { origin.y = rect.maxY - size.height - 12 }
        }
        origin.x = origin.x.clamped(to: 8...max(8, bounds.width - size.width - 8))
        toolbar.frame = CGRect(origin: origin, size: size)
    }
}

private struct AreaToolbar: View {
    let size: CGSize
    let aspect: AspectLock
    let onAspect: (AspectLock) -> Void
    let onPreset: (CGSize) -> Void
    let onCancel: () -> Void
    let onConfirm: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Section("Aspect Ratio") {
                    ForEach(AspectLock.allCases) { lock in
                        Button {
                            onAspect(lock)
                        } label: {
                            if lock == aspect { Label(lock.title, systemImage: "checkmark") } else { Text(lock.title) }
                        }
                    }
                }
                Section("Size") {
                    Button("1280 × 720") { onPreset(CGSize(width: 1280, height: 720)) }
                    Button("1920 × 1080") { onPreset(CGSize(width: 1920, height: 1080)) }
                    Button("1080 × 1080") { onPreset(CGSize(width: 1080, height: 1080)) }
                    Button("1080 × 1920") { onPreset(CGSize(width: 1080, height: 1920)) }
                }
            } label: {
                Label(aspect.title, systemImage: "aspectratio")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Text("\(Int(size.width)) × \(Int(size.height))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)

            Divider().frame(height: 18)

            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
            Button("Done") { onConfirm(false) }
                .buttonStyle(.bordered)
                .help("Keep this area and return to the recorder")
            Button {
                onConfirm(true)
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }
}
