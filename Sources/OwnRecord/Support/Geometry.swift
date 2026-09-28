import AppKit
import CoreGraphics

extension CGSize {
    var aspectRatio: CGFloat { height > 0 ? width / height : 1 }

    /// Rounds both dimensions down to even integers (video encoders require even sizes).
    func evenRounded() -> CGSize {
        CGSize(width: CGFloat(max(2, Int(width.rounded()) & ~1)),
               height: CGFloat(max(2, Int(height.rounded()) & ~1)))
    }

    func scaled(_ factor: CGFloat) -> CGSize { CGSize(width: width * factor, height: height * factor) }
}

extension CGRect {
    /// The largest rect with `size`'s aspect ratio that fits inside `rect`, centered.
    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(withDisplayID id: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == id }
    }

    static var withMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) } ?? main
    }
}

enum GlobalCoordinates {
    /// Converts a rect in CoreGraphics global space (top-left origin of the primary display)
    /// into Cocoa global space (bottom-left origin).
    @MainActor
    static func cocoaRect(fromCG rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
