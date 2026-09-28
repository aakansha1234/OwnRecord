// Renders the OwnRecord app icon into an .iconset directory.
// Usage: swift scripts/make-icon.swift build/AppIcon.iconset
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size / 1024
        // Squircle body with the standard macOS icon margin.
        let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let path = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 24 * s
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.set()
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(colors: [
            NSColor(srgbRed: 0.18, green: 0.13, blue: 0.45, alpha: 1),
            NSColor(srgbRed: 0.43, green: 0.20, blue: 0.85, alpha: 1),
        ])?.draw(in: path, angle: 60)

        // Screen outline.
        let screen = NSRect(x: 230 * s, y: 330 * s, width: 564 * s, height: 380 * s)
        let screenPath = NSBezierPath(roundedRect: screen, xRadius: 44 * s, yRadius: 44 * s)
        NSColor.white.withAlphaComponent(0.14).setFill()
        screenPath.fill()
        NSColor.white.setStroke()
        screenPath.lineWidth = 30 * s
        screenPath.stroke()

        // Stand.
        let stand = NSBezierPath(roundedRect: NSRect(x: 420 * s, y: 250 * s, width: 184 * s, height: 30 * s), xRadius: 15 * s, yRadius: 15 * s)
        NSColor.white.withAlphaComponent(0.9).setFill()
        stand.fill()

        // Record dot.
        let dot = NSBezierPath(ovalIn: NSRect(x: 432 * s, y: 440 * s, width: 160 * s, height: 160 * s))
        NSColor(srgbRed: 1.0, green: 0.27, blue: 0.33, alpha: 1).setFill()
        dot.fill()

        // Camera bubble.
        let bubbleRect = NSRect(x: 640 * s, y: 200 * s, width: 210 * s, height: 210 * s)
        let bubble = NSBezierPath(ovalIn: bubbleRect)
        NSColor.white.setFill()
        bubble.fill()
        let inner = NSBezierPath(ovalIn: bubbleRect.insetBy(dx: 18 * s, dy: 18 * s))
        NSGradient(colors: [
            NSColor(srgbRed: 0.98, green: 0.62, blue: 0.35, alpha: 1),
            NSColor(srgbRed: 0.93, green: 0.33, blue: 0.53, alpha: 1),
        ])?.draw(in: inner, angle: 90)
        let head = NSBezierPath(ovalIn: NSRect(x: 712 * s, y: 290 * s, width: 66 * s, height: 66 * s))
        NSColor.white.withAlphaComponent(0.95).setFill()
        head.fill()
        let shoulders = NSBezierPath(roundedRect: NSRect(x: 684 * s, y: 225 * s, width: 122 * s, height: 70 * s), xRadius: 35 * s, yRadius: 35 * s)
        shoulders.fill()
        return true
    }
}

let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in sizes {
    let image = drawIcon(size: px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { continue }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("\(name).png"))
}
